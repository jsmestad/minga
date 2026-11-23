#!/usr/bin/env python3
"""Measure the first Agent open in the shipping macOS app (receipt for #3610).

Each launch starts a fresh copy of an assembled Release Minga.app through Launch
Services with a private profile, posts real key events to that process only, and
reads two traces:

* the BEAM trace written by trace_config.exs (OS wall clock, microseconds), and
* the app's opt-in startup probe on stderr (MINGA_STARTUP_TIMER=1), whose
  drawable_presented lines carry the BEAM frame sequence and the uptime clock.

Endpoints, all measured from the moment the final key-down was posted:

* composer_emit_ms: the BEAM wrote the first frame rendered after the open
  installed the Agent chat (BEAM-side; this is the frame that carries the composer).
* composer_presented_ms: the app presented that frame (frontend-side), when the
  Metal layer presented it.
* send_ready_ms: the first frame written after both the Editor installed the new
  session and the session finished attaching its provider (BEAM-side).

Scenarios (one launch each):

* n-immediate: SPC a n as soon as the first frame is presented, then later opens.
* n-later: SPC a n after --later-delay seconds, then later opens.
* a-immediate / a-later: the same with SPC a a.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
FIXTURE_TEXT = "Shipping Agent open timing fixture\n"
OPEN_KEYS = {"n": ["space", "a", "n"], "a": ["space", "a", "a"]}


def realtime_minus_uptime_ns():
    best = None
    for _ in range(5):
        before = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
        real = time.time_ns()
        after = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
        if best is None or after - before < best[0]:
            best = (after - before, real - (before + after) // 2)
    return best[1]


class Launch:
    def __init__(self, app, out, hook):
        self.app = app
        self.out = out
        self.private = Path(tempfile.mkdtemp(prefix="minga-agent-first-open-"))
        self.trace_path = out / "beam-trace.ndjson"
        self.stderr_path = out / "app-stderr.log"
        self.trace_offset = 0
        self.events = []
        self.presented = []
        self.stderr_offset = 0
        self.pid = None
        self.hook = hook

    def env(self):
        env = {}
        for key, name in {
            "HOME": "home",
            "XDG_CONFIG_HOME": "config",
            "XDG_DATA_HOME": "data",
            "XDG_STATE_HOME": "state",
            "XDG_CACHE_HOME": "cache",
            "TMPDIR": "tmp",
            "RELEASE_TMP": "release-tmp",
        }.items():
            directory = self.private / name
            directory.mkdir(mode=0o700)
            env[key] = str(directory)
        config = self.private / "config" / "minga"
        config.mkdir(parents=True)
        shutil.copy(HERE / "trace_config.exs", config / "config.exs")
        env.update(
            MINGA_AGENT_OPEN_TRACE=str(self.trace_path),
            MINGA_STARTUP_TIMER="1",
            OPENAI_API_KEY="sk-minga-offline-fixture-never-submit",
            HTTP_PROXY="http://127.0.0.1:1",
            HTTPS_PROXY="http://127.0.0.1:1",
        )
        if self.hook:
            env["MINGA_AGENT_OPEN_HOOK"] = self.hook
        return env

    def start(self):
        os.chmod(self.private, 0o700)
        project = self.private / "project"
        project.mkdir()
        fixture = project / "agent-open.txt"
        fixture.write_text(FIXTURE_TEXT, encoding="utf-8")
        self.trace_path.touch()
        command = ["/usr/bin/open", "-n", "-a", str(self.app), "--stderr", str(self.stderr_path)]
        for key, value in self.env().items():
            command += ["--env", f"{key}={value}"]
        command += ["--args", "--editor", str(fixture)]
        launched = time.time_ns()
        subprocess.run(command, check=True)
        binary = str(self.app / "Contents" / "MacOS" / "Minga")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            found = subprocess.run(["/usr/bin/pgrep", "-n", "-f", binary], capture_output=True, text=True)
            if found.stdout.strip():
                self.pid = int(found.stdout.split()[0])
                return launched
            time.sleep(0.02)
        raise RuntimeError("the app process did not appear")

    def poll(self):
        with self.trace_path.open("rb") as trace:
            trace.seek(self.trace_offset)
            data = trace.read()
        complete = data.rfind(b"\n") + 1
        self.trace_offset += complete
        for line in data[:complete].splitlines():
            self.events.append(json.loads(line))
        if self.stderr_path.exists():
            with self.stderr_path.open("rb") as stderr:
                stderr.seek(self.stderr_offset)
                data = stderr.read()
            complete = data.rfind(b"\n") + 1
            self.stderr_offset += complete
            for line in data[:complete].decode("utf-8", "replace").splitlines():
                if line.startswith("[startup-native] drawable_presented"):
                    fields = dict(part.split("=", 1) for part in line.split()[2:])
                    self.presented.append(
                        {"uptime_ns": int(fields["uptime_ns"]), "frame": int(fields["frame"]),
                         "presented_time": float(fields["presented_time"])}
                    )

    def wait_for(self, predicate, description, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.poll()
            result = predicate()
            if result:
                return result
            time.sleep(0.005)
        raise RuntimeError(f"{description} did not happen within {seconds} s")

    def find(self, event, after_us, key="at_us"):
        return next((e for e in self.events if e["event"] == event and e[key] >= after_us), None)

    def stop(self):
        if self.pid is None:
            return
        try:
            post_keys(self.pid, ["escape", "escape", "colon", "q", "a", "bang", "return"])
        except (RuntimeError, OSError):
            pass
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and process_alive(self.pid):
            time.sleep(0.05)
        if process_alive(self.pid):
            os.kill(self.pid, signal.SIGTERM)
            time.sleep(1)
        if process_alive(self.pid):
            os.kill(self.pid, signal.SIGKILL)
        subprocess.run(["/usr/bin/pkill", "-KILL", "-f", str(self.private)], check=False)
        shutil.rmtree(self.private, ignore_errors=True)


def process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


POST_KEYS = None


def post_keys(pid, keys):
    result = subprocess.run([str(POST_KEYS), str(pid), *keys], capture_output=True, text=True, check=True)
    posts = []
    for line in result.stdout.splitlines():
        name, real, uptime = line.split()
        posts.append({"key": name, "realtime_ns": int(real), "uptime_ns": int(uptime)})
    return posts


def frame_after(launch, after_us, description, seconds):
    """Returns the first rendered frame that started after after_us and the port write that carried it."""
    frame = launch.wait_for(
        lambda: next((e for e in launch.events if e["event"] == "minga.render.pipeline.stop"
                      and "frame_seq" in e and e["start_us"] >= after_us), None),
        f"{description} frame render", seconds,
    )
    emit = launch.wait_for(lambda: launch.find("minga.port.write.stop", frame["at_us"]), f"{description} frame write", seconds)
    return frame, emit


def measure_open(launch, keys, expects_session, offset_ns, seconds):
    posts = post_keys(launch.pid, keys)
    final = posts[-1]
    final_us = final["realtime_ns"] // 1000

    key = launch.wait_for(lambda: launch.find("minga.input.dispatch.start", final_us - 2_000), "final key dispatch", seconds)
    if expects_session:
        installed = launch.wait_for(
            lambda: launch.find("minga.agent.start_agent_session.stop", final_us), "session start", seconds
        )
        installed_us = installed["at_us"]
    else:
        command = launch.wait_for(
            lambda: next((e for e in launch.events if e["event"] == "minga.command.execute.stop"
                          and e["start_us"] >= key["at_us"]), None),
            "open command", seconds,
        )
        installed_us = command["at_us"]
    frame, emit = frame_after(launch, installed_us, "composer", seconds)

    attached_us = installed_us
    if expects_session:
        attach = launch.wait_for(
            lambda: launch.find("minga.agent.session_start_hooks.stop", final_us)
            or launch.find("minga.agent.provider_start.stop", final_us),
            "provider attachment", seconds,
        )
        attached_us = max(installed_us, attach["at_us"])
    _ready_frame, ready_emit = frame_after(launch, max(installed_us, attached_us), "send-ready", seconds)

    presented = None
    deadline = time.monotonic() + 1.0
    while presented is None and time.monotonic() < deadline:
        launch.poll()
        presented = next((p for p in launch.presented if p["frame"] == frame.get("frame_seq")), None)
        time.sleep(0.01)

    # Settle so the open's trailing spans are in the trace before attribution.
    time.sleep(0.5)
    launch.poll()
    window = [e for e in launch.events if final_us - 2_000 <= e.get("start_us", e["at_us"]) and e["at_us"] <= ready_emit["at_us"]]
    stages = {}
    for e in window:
        name = e["event"]
        if name.startswith("minga.agent.") and name.endswith(".stop"):
            stage = name[len("minga.agent."):-len(".stop")]
            stages.setdefault(stage, []).append(
                {"start_ms": round((e["start_us"] - final_us) / 1000, 3), "duration_ms": round(e["duration_us"] / 1000, 3), "pid": e["pid"]}
            )
        elif name == "minga.command.execute.stop":
            stages.setdefault("command:" + str(e.get("command")), []).append(
                {"start_ms": round((e["start_us"] - final_us) / 1000, 3), "duration_ms": round(e["duration_us"] / 1000, 3), "pid": e["pid"]}
            )

    def ms(us):
        return round((us - final_us) / 1000, 3)

    presented_ms = None
    if presented is not None:
        # presented_time is the display time Metal reports, on the same mach clock as uptime_ns.
        shown_ns = int(presented["presented_time"] * 1e9) if presented["presented_time"] > 0 else presented["uptime_ns"]
        presented_ms = round((shown_ns + offset_ns - final["realtime_ns"]) / 1_000_000, 3)
    return {
        "keys": [p["key"] for p in posts],
        "key_posts_ns": [p["realtime_ns"] for p in posts],
        "final_key_dispatch_ms": ms(key["at_us"]),
        "installed_ms": ms(installed_us),
        "composer_frame_seq": frame.get("frame_seq"),
        "composer_emit_ms": ms(emit["at_us"]),
        "composer_presented_ms": presented_ms,
        "send_ready_ms": ms(ready_emit["at_us"]),
        "stages": stages,
    }


def return_to_editor(launch, seconds):
    posts = post_keys(launch.pid, ["escape", "space", "a", "a"])
    after_us = posts[-1]["realtime_ns"] // 1000
    launch.wait_for(
        lambda: next((e for e in launch.events if e["event"] == "minga.command.execute.stop"
                      and e.get("command") == ":toggle_agentic_view" and e["start_us"] >= after_us - 2_000), None),
        "return to the editor", seconds,
    )
    time.sleep(1.0)


def run_scenario(app, out, scenario, args, record):
    kind, timing = scenario.split("-")
    launch = Launch(app, out, args.hook)
    try:
        launched_ns = launch.start()
        first = launch.wait_for(lambda: launch.presented[0] if launch.presented else None, "first presented frame", args.timeout)
        offset = realtime_minus_uptime_ns()
        record({"scenario": scenario, "condition": "launch", "first_presented_ms": round((first["uptime_ns"] + offset - launched_ns) / 1e6, 3)})
        launch.wait_for(lambda: launch.find("trace_ready", 0), "trace collector", args.timeout)
        if timing == "later":
            time.sleep(args.later_delay)
        condition = "immediate" if timing == "immediate" else "later-first"
        sample = measure_open(launch, OPEN_KEYS[kind], True, offset, args.timeout)
        record({"scenario": scenario, "condition": condition, "command": kind, **sample})
        for _ in range(args.repeats):
            return_to_editor(launch, args.timeout)
            sample = measure_open(launch, OPEN_KEYS[kind], kind == "n", realtime_minus_uptime_ns(), args.timeout)
            record({"scenario": scenario, "condition": "later-same-run", "command": kind, **sample})
    finally:
        launch.stop()


def nearest_rank(values, p):
    values = sorted(values)
    return values[math.ceil(len(values) * p / 100) - 1]


def main():
    global POST_KEYS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", type=Path, required=True, help="Assembled Release Minga.app")
    parser.add_argument("--revision", required=True, help="Commit the app was assembled from")
    parser.add_argument("--output", type=Path, required=True, help="New directory for raw samples and the summary")
    parser.add_argument("--runs", type=int, default=20, help="Launches per scenario")
    parser.add_argument("--scenarios", default="n-immediate,n-later,a-immediate,a-later")
    parser.add_argument("--repeats", type=int, default=1, help="Later opens after the first, per launch")
    parser.add_argument("--later-delay", type=float, default=10.0, help="Seconds after the first frame before a later first open")
    parser.add_argument("--hook", help="Shell command installed as a SessionStart hook")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--first-run", type=int, default=1, help="Index of the first run, to resume an interrupted matrix in a new directory")
    parser.add_argument("--attempts", type=int, default=3, help="Launches tried per run before giving up; each failure is kept in failures.ndjson")
    args = parser.parse_args()

    app = args.app.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    POST_KEYS = args.output / "post_keys"
    subprocess.run(["swiftc", "-O", str(HERE / "post_keys.swift"), "-o", str(POST_KEYS)], check=True)
    identity = {
        "revision": args.revision,
        "build_mode": "Release, assembled with MIX_ENV=prod mix app.assemble",
        "app_binary_sha256": hashlib.sha256((app / "Contents/MacOS/Minga").read_bytes()).hexdigest(),
        "os": platform.mac_ver()[0],
        "os_build": subprocess.run(["/usr/bin/sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip(),
        "cpu_model": subprocess.check_output(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "memory_bytes": int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], text=True)),
        "scenarios": args.scenarios,
        "later_delay_s": args.later_delay,
        "hook": args.hook,
    }
    (args.output / "identity.json").write_text(json.dumps(identity, indent=2) + "\n", encoding="utf-8")

    samples = []
    with (args.output / "samples.ndjson").open("w", encoding="utf-8", buffering=1) as sink:
        for index in range(args.first_run, args.first_run + args.runs):
            for scenario in args.scenarios.split(","):
                for attempt in range(1, args.attempts + 1):
                    out = args.output / f"{scenario}-{index:03}-{attempt}"
                    out.mkdir()
                    pending = []
                    try:
                        run_scenario(app, out, scenario, args, lambda sample: pending.append({"run": index, **sample}))
                    except RuntimeError as error:
                        # A failed launch keeps its traces; none of its samples are used.
                        with (args.output / "failures.ndjson").open("a", encoding="utf-8") as failures:
                            failures.write(json.dumps({"run": index, "scenario": scenario, "attempt": attempt, "error": str(error)}) + "\n")
                        time.sleep(2)
                        if attempt == args.attempts:
                            raise
                        continue
                    for sample in pending:
                        sink.write(json.dumps(sample) + "\n")
                        samples.append(sample)
                    break
                time.sleep(2)
                print(f"run {index} {scenario} done", flush=True)

    summary = {}
    for sample in samples:
        if sample["condition"] == "launch":
            continue
        cell = summary.setdefault(f"{sample['command']}:{sample['condition']}", {})
        for endpoint in ("composer_emit_ms", "composer_presented_ms", "send_ready_ms", "final_key_dispatch_ms"):
            if sample.get(endpoint) is not None:
                cell.setdefault(endpoint, []).append(sample[endpoint])
    table = {
        cell: {endpoint: {"n": len(v), "p50": nearest_rank(v, 50), "p95": nearest_rank(v, 95)} for endpoint, v in endpoints.items()}
        for cell, endpoints in summary.items()
    }
    (args.output / "summary.json").write_text(json.dumps({**identity, "cells": table}, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(table, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
