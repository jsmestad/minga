#!/usr/bin/env python3
"""Measure real TUI Agent-open keys against an assembled shipping launcher."""

import argparse
import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

import pyte

from go_tui_capture import TerminalGrid

COLUMNS, ROWS = 100, 34
READY_TEXT = "Shipping Agent open timing fixture"
KEYS = (b" ", b"a", b"S", b"n")


def cpu_model():
    if platform.system() == "Darwin":
        return subprocess.check_output(
            ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True
        ).strip()
    with Path("/proc/cpuinfo").open(encoding="utf-8") as cpuinfo:
        for line in cpuinfo:
            key, _, value = line.partition(":")
            if key.strip() in ("model name", "Hardware"):
                return value.strip()
    return platform.processor() or platform.machine()


def isolated_environment(profile):
    env = {key: os.environ[key] for key in ("PATH", "LANG", "TZ", "TERMINFO", "TERMINFO_DIRS") if key in os.environ}
    for key, name in {
        "HOME": "home",
        "XDG_CONFIG_HOME": "config",
        "XDG_DATA_HOME": "data",
        "XDG_STATE_HOME": "state",
        "XDG_CACHE_HOME": "cache",
        "TMPDIR": "tmp",
        "RELEASE_TMP": "release-tmp",
    }.items():
        directory = profile / name
        directory.mkdir(mode=0o700)
        env[key] = str(directory)
    env.update(
        TERM="xterm-256color",
        OPENAI_API_KEY="sk-minga-offline-fixture-never-submit",
        HTTP_PROXY="http://127.0.0.1:1",
        HTTPS_PROXY="http://127.0.0.1:1",
    )
    return env


def write_input(terminal, data):
    instant = time.monotonic_ns()
    if os.write(terminal, data) != len(data):
        raise RuntimeError("short PTY input write")
    return instant


def read_terminal(terminal, timeout):
    if not select.select([terminal], [], [], timeout)[0]:
        return None, None
    try:
        payload = os.read(terminal, 65536)
    except OSError as error:
        if error.errno != errno.EIO:
            raise
        payload = b""
    return payload, time.monotonic_ns()


def wait_screen(terminal, grid, trace, condition, description, seconds):
    deadline = time.monotonic() + seconds
    while (remaining := deadline - time.monotonic()) > 0:
        chunk, received = read_terminal(terminal, remaining)
        if not chunk:
            break
        trace.write(chunk)
        grid.feed(chunk)
        if grid.replies:
            write_input(terminal, grid.replies)
            grid.replies.clear()
        lines = grid.lines()
        if condition(lines):
            return received, lines
    raise RuntimeError(f"{description} did not appear before the PTY closed or the deadline expired")


def file_visible(lines):
    return any(READY_TEXT in line for line in lines) and not any("╭ Prompt" in line for line in lines)


def prompt_visible(lines, mode):
    for heading, input_line in zip(lines, lines[1:]):
        if (
            "╭ Prompt" in heading
            and f"❯ {mode}" in input_line
            and "Ask Minga to edit, explain, search, or run tools" in input_line
        ):
            return True
    return False


def ready_conversation(lines):
    return prompt_visible(lines, "INSERT") and not any(
        phrase in line
        for line in lines
        for phrase in ("Starting Agent", "Agent unavailable", "No model configured", "Model not resolved")
    ) and any("Agent UI registry online" in line or "Session started" in line for line in lines)


def capture_open(terminal, grid, trace, out, condition, seconds):
    writes = [write_input(terminal, key) for key in KEYS]
    received, lines = wait_screen(
        terminal, grid, trace, lambda lines: prompt_visible(lines, "INSERT"), f"{condition} Agent composer", seconds
    )
    (out / f"{condition}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return {"condition": condition, "key_write_ns": writes, "visible_read_ns": received, "elapsed_ns": received - writes[-1]}


def await_exit(pid, terminal, trace, seconds):
    deadline = time.monotonic() + seconds
    while (remaining := deadline - time.monotonic()) > 0:
        child, status = os.waitpid(pid, os.WNOHANG)
        if child:
            return os.waitstatus_to_exitcode(status)
        chunk, _ = read_terminal(terminal, min(remaining, 0.1))
        if chunk:
            trace.write(chunk)
        elif chunk == b"":
            # A closed PTY stays readable while the launcher finishes exiting.
            time.sleep(min(remaining, 0.01))
    return None


def measure_pair(launcher, out, seconds, record_sample):
    grid = TerminalGrid(pyte, COLUMNS, ROWS)
    with tempfile.TemporaryDirectory(prefix="minga-agent-open-profile-") as private:
        profile = Path(private)
        env = isolated_environment(profile)
        project = profile / "project"
        project.mkdir()
        fixture = project / "agent-open.txt"
        fixture.write_text(READY_TEXT + "\n", encoding="utf-8")
        with (out / "terminal.ansi").open("wb") as trace:
            pid, terminal = pty.fork()
            if pid == 0:
                try:
                    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))
                    os.chdir(project)
                    os.execve(launcher, [str(launcher), "--safe", "--editor", str(fixture)], env)
                except OSError as error:
                    os.write(2, f"Could not launch shipping Minga: {error}\n".encode())
                    os._exit(127)

            exit_code = None
            try:
                wait_screen(terminal, grid, trace, file_visible, "the initial editor file", seconds)
                record_sample(capture_open(terminal, grid, trace, out, "cold", seconds))
                # Opening a composer may precede the catalog, so wait for the first conversation before the warm pair.
                if not ready_conversation(grid.lines()):
                    wait_screen(terminal, grid, trace, ready_conversation, "the first configured conversation", seconds)
                write_input(terminal, b"\x1b")
                wait_screen(terminal, grid, trace, lambda lines: prompt_visible(lines, "NORMAL"), "normal composer mode", seconds)
                write_input(terminal, b" av")
                wait_screen(terminal, grid, trace, file_visible, "the file before the warm open", seconds)
                record_sample(capture_open(terminal, grid, trace, out, "warm", seconds))
                write_input(terminal, b"\x1b")
                wait_screen(terminal, grid, trace, lambda lines: prompt_visible(lines, "NORMAL"), "normal composer mode before quit", seconds)
                write_input(terminal, b":qa!\r")
                exit_code = await_exit(pid, terminal, trace, seconds)
                if exit_code != 0:
                    raise RuntimeError(f"shipping editor did not quit cleanly: exit={exit_code}")
            except (RuntimeError, OSError) as error:
                (out / "last-screen.txt").write_text("\n".join(grid.lines()) + "\n", encoding="utf-8")
                raise RuntimeError(f"{error}; see {out}") from error
            finally:
                if exit_code is None:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    os.waitpid(pid, 0)
                os.close(terminal)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--launcher", type=Path, required=True, help="Packaged launchers/minga or the app's bundled minga-tui")
    parser.add_argument("--revision", required=True, help="Full commit SHA used when assembling that release")
    parser.add_argument("--output", required=True, type=Path, help="New directory for the summary and raw evidence")
    parser.add_argument("--runs", type=int, default=20, help="Cold/warm pairs (at least 20)")
    parser.add_argument("--timeout", type=float, default=30, help="Seconds before a missing screen fails the run")
    args = parser.parse_args()
    if args.runs < 20 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--runs must be at least 20 and --timeout must be positive and finite")
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        parser.error("--revision must be a full source commit SHA")
    launcher = args.launcher.resolve()
    if not launcher.is_file() or not os.access(launcher, os.X_OK):
        parser.error("--launcher must be an executable shipping launcher")
    args.output.mkdir(parents=True, exist_ok=False)
    identity = {
        "revision": args.revision,
        "build_mode": "shipping-release",
        "fixture": "native-offline-openai-model-discovery-v1",
        "os": platform.platform(),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "cpu_model": cpu_model(),
        "launcher_sha256": hashlib.sha256(launcher.read_bytes()).hexdigest(),
        "terminal": {"columns": COLUMNS, "rows": ROWS, "term": "xterm-256color"},
    }
    (args.output / "identity.json").write_text(json.dumps(identity, indent=2) + "\n", encoding="utf-8")
    values = {"cold": [], "warm": []}
    with (args.output / "samples.ndjson").open("w", encoding="utf-8", buffering=1) as samples:
        for index in range(1, args.runs + 1):
            out = args.output / f"pair-{index:03}"
            out.mkdir()

            def record(sample):
                samples.write(json.dumps({"pair": index, **sample}) + "\n")
                values[sample["condition"]].append(sample["elapsed_ns"])

            measure_pair(launcher, out, args.timeout, record)

    for value in values.values():
        value.sort()
    summary = {
        condition: {"samples": len(results), **{
            f"p{p}_ms": round(results[math.ceil(len(results) * p / 100) - 1] / 1_000_000, 3)
            for p in (50, 95)
        }}
        for condition, results in values.items()
    }
    (args.output / "summary.json").write_text(json.dumps({**identity, "timing": summary}, indent=2) + "\n", encoding="utf-8")
    for condition, stats in summary.items():
        print(f"{condition}: n={stats['samples']} p50={stats['p50_ms']} ms p95={stats['p95_ms']} ms")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError) as error:
        sys.exit(str(error))
