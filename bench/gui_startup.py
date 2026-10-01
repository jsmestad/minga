import json
import os
import pathlib
import re
import signal
import subprocess
import time

import psutil
import argparse
import math
import statistics

parser = argparse.ArgumentParser(
    description="Compare two instrumented Release apps using isolated startup profiles."
)
parser.add_argument("--baseline", required=True)
parser.add_argument("--candidate", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--samples", type=int, default=20)
args = parser.parse_args()
ROOT = pathlib.Path(args.output)
ROOT.mkdir(parents=True, exist_ok=False)
APPS = {
    "baseline": str(pathlib.Path(args.baseline).resolve()),
    "candidate": str(pathlib.Path(args.candidate).resolve()),
}


def active_builds():
    return [
        p.info["name"]
        for p in psutil.process_iter(["name"])
        if p.info["name"] in ["xcodebuild", "swift-frontend", "clang", "zig", "go"]
    ]


def sample(side, mode, index):
    if active_builds():
        raise RuntimeError("concurrent build")
    root = ROOT / (side + "-" + mode + ("-" + str(index) if mode == "cold" else ""))
    for name in ["h", "c", "a", "d", "s", "i", "t", "w"]:
        (root / name).mkdir(parents=True, exist_ok=True)
    (root / "i").chmod(0o700)
    (root / "w" / "startup.txt").write_text("startup fixture\n")
    config = root / "c" / "minga.exs"
    config.write_text(
        "use Minga.Config\nset :theme, :doom_one\n"
        + """{:module, LLMDB} = Code.ensure_loaded(LLMDB)
{:module, LLMDB.Catalog} = Code.ensure_loaded(LLMDB.Catalog)
:erlang.trace_pattern({LLMDB, :models, 0}, true, [])
:erlang.trace_pattern({LLMDB.Catalog, :lazy_load, 0}, true, [:local])
path = """
        + json.dumps(str(root / "catalog.trace"))
        + """
probe = spawn(fn ->
  loop = fn loop ->
    receive do
      {:trace, pid, :call, {module, function, []}} ->
        name = case Process.info(pid, :registered_name) do
          {:registered_name, name} -> name
          _ -> :unnamed
        end
        File.write!(path, "#{inspect(module)}.#{function} #{name}\\n", [:append])
        loop.(loop)
    end
  end
  loop.(loop)
end)
:erlang.trace(:new, true, [:call, {:tracer, probe}])
"""
        + """
action_path = """
        + json.dumps(str(root / "edit.trigger"))
        + """
receipt_path = """
        + json.dumps(str(root / "edit.json"))
        + """
spawn(fn ->
  loop = fn loop ->
    receive do
    after 10 ->
      if File.exists?(action_path) do
        File.rm!(action_path)
        editor = Process.whereis(MingaEditor)
        action_started = System.monotonic_time(:nanosecond)
        for cp <- ~c"iX" ++ [27], do: send(editor, {:minga_input, {:key_press, cp, 0}})
        state = :sys.get_state(editor)
        content = Minga.Buffer.content(state.workspace.buffers.active)
        File.write!(receipt_path <> ".tmp", JSON.encode!(%{content: content, theme: state.appearance.theme.name, dispatch_ms: (System.monotonic_time(:nanosecond) - action_started) / 1_000_000}))
        File.rename!(receipt_path <> ".tmp", receipt_path)
      else
        loop.(loop)
      end
    end
  end
  loop.(loop)
end)
"""
    )
    for p in [
        root / "catalog.trace",
        root / "t" / "minga-startup-timer.txt",
        root / "edit.trigger",
        root / "edit.json",
    ]:
        if p.exists():
            p.unlink()
    env = {
        k: os.environ[k]
        for k in [
            "PATH",
            "LANG",
            "LC_ALL",
            "SHELL",
            "USER",
            "LOGNAME",
            "__CF_USER_TEXT_ENCODING",
        ]
        if k in os.environ
    }
    env.update(
        HOME=str(root / "h"),
        XDG_CONFIG_HOME=str(root / "c"),
        XDG_CACHE_HOME=str(root / "a"),
        XDG_DATA_HOME=str(root / "d"),
        XDG_STATE_HOME=str(root / "s"),
        TMPDIR=str(root / "t") + "/",
        MINGA_STARTUP_TIMER="1",
    )
    logpath = root / ("stderr-" + str(index) + ".log")
    result = {"revision": side, "profile": mode, "sample": index}
    with logpath.open("w") as log:
        launched = time.monotonic_ns()
        proc = subprocess.Popen(
            [
                APPS[side] + "/Contents/MacOS/Minga",
                "-NSTreatUnknownArgumentsAsOpen",
                "NO",
                "--editor",
                "--config",
                str(config),
                "--minga-ipc-runtime-parent",
                str(root / "i"),
                str(root / "w" / "startup.txt"),
            ],
            cwd=root / "w",
            env=env,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )
        maximum = 0
        try:
            while time.monotonic_ns() - launched < 30_000_000_000:
                if active_builds():
                    raise RuntimeError("concurrent build")
                if proc.poll() is not None:
                    raise RuntimeError("app exited " + str(proc.returncode))
                own = psutil.Process(proc.pid)
                try:
                    processes = [own] + own.children(recursive=True)
                except psutil.NoSuchProcess:
                    continue
                rss = 0
                for process in processes:
                    try:
                        rss += process.memory_info().rss
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        pass
                maximum = max(maximum, rss)
                output = logpath.read_text()
                shown = [
                    e
                    for e in re.findall(
                        r"drawable_presented uptime_ns=(\d+) frame=(\d+) presented_time=([\d.]+)",
                        output,
                    )
                    if float(e[2]) > 0
                ]
                if shown:
                    ns, frame, presented = shown[0]
                    result.update(
                        presentation_ms=(float(presented) * 1e9 - launched) / 1e6,
                        callback_ms=(int(ns) - launched) / 1e6,
                        frame=int(frame),
                        peak_sampled_rss_mib=maximum / 1048576,
                    )
                    phases = re.findall(
                        r"\[startup-native\] (\w+) uptime_ns=(\d+)", output
                    )
                    result["native_ms"] = {
                        name: (int(ns) - launched) / 1e6
                        for name, ns in phases
                        if name != "drawable_presented"
                    }
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("no displayed frame")
            requested = time.monotonic_ns()
            (root / "edit.trigger").touch()
            deadline = time.monotonic() + 10
            while not (root / "edit.json").exists() and time.monotonic() < deadline:
                time.sleep(0.025)
            if not (root / "edit.json").exists():
                raise RuntimeError("no editing receipt")
            edit = json.loads((root / "edit.json").read_text())
            if edit["content"] != "Xstartup fixture\n" or edit["theme"] != "doom_one":
                raise RuntimeError("first edit/configuration failed")
            result["edit_dispatch_ms"] = edit["dispatch_ms"]
            result["launch_to_edit_verified_ms"] = (
                time.monotonic_ns() - launched
            ) / 1e6
            result["first_edit_action_ms"] = (time.monotonic_ns() - requested) / 1e6
            # Read the existing BEAM report separately from the presentation endpoint.
            until = time.monotonic() + 5
            while (
                not (root / "t" / "minga-startup-timer.txt").exists()
                and time.monotonic() < until
            ):
                time.sleep(0.05)
            timer = root / "t" / "minga-startup-timer.txt"
            if timer.exists():
                result["beam_ms"] = {
                    name: float(delta)
                    for name, delta in re.findall(
                        r"^  (\w+)\s+([\d.]+)ms", timer.read_text(), re.M
                    )
                }
            trace = (
                (root / "catalog.trace").read_text()
                if (root / "catalog.trace").exists()
                else ""
            )
            result["catalog_calls"] = trace.strip().splitlines()
        finally:
            children = (
                psutil.Process(proc.pid).children(recursive=True)
                if proc.poll() is None
                else []
            )
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            proc.wait(timeout=5)
            _, alive = psutil.wait_procs(children, timeout=15)
            if alive:
                raise RuntimeError(
                    "fixture left living children " + str([p.pid for p in alive])
                )
    return result


with (
    (ROOT / "raw.jsonl").open("w") as raw,
    (ROOT / "excluded.jsonl").open("w") as excluded,
):
    for mode in ["cold", "warm"]:
        for index in range(args.samples):
            for side in (
                ["baseline", "candidate"]
                if index % 2 == 0
                else ["candidate", "baseline"]
            ):
                attempt = 0
                while True:
                    try:
                        result = sample(side, mode, str(index) + "-" + str(attempt))
                    except Exception as error:
                        failure = {
                            "revision": side,
                            "profile": mode,
                            "sample": index,
                            "error": str(error),
                        }
                        excluded.write(json.dumps(failure) + "\n")
                        excluded.flush()
                        if str(error) != "concurrent build":
                            raise
                        if attempt == 0:
                            print(
                                "Waiting for independent builds to finish", flush=True
                            )
                        attempt += 1
                        time.sleep(5)
                        continue
                    result["sample"] = index
                    raw.write(json.dumps(result) + "\n")
                    raw.flush()
                    print(
                        json.dumps(
                            {
                                k: v
                                for k, v in result.items()
                                if k not in ["native_ms", "beam_ms", "catalog_calls"]
                            }
                        ),
                        flush=True,
                    )
                    break

# Each group contains fresh processes. Warm groups reuse one profile per revision.
rows = [json.loads(line) for line in (ROOT / "raw.jsonl").read_text().splitlines()]
summary = {}
for side in APPS:
    for mode in ["cold", "warm"]:
        group = [
            row for row in rows if row["revision"] == side and row["profile"] == mode
        ]
        metrics = {}
        for metric in [
            "presentation_ms",
            "launch_to_edit_verified_ms",
            "first_edit_action_ms",
            "edit_dispatch_ms",
            "peak_sampled_rss_mib",
        ]:
            values = sorted(row[metric] for row in group)
            metrics[metric] = {
                "median": statistics.median(values),
                "p95": values[math.ceil(len(values) * 0.95) - 1],
            }
        for metric in ["config_extensions_started", "editor_init_done", "TOTAL"]:
            values = sorted(row["beam_ms"][metric] for row in group)
            metrics[metric] = {
                "median": statistics.median(values),
                "p95": values[math.ceil(len(values) * 0.95) - 1],
            }
        metrics["spawn_from_app_startup_ms"] = statistics.median(
            row["native_ms"]["beam_spawned"] - row["native_ms"]["app_startup"]
            for row in group
        )
        metrics["native_setup_ms"] = statistics.median(
            row["native_ms"]["native_ready"] - row["native_ms"]["fonts_ready"]
            for row in group
        )
        metrics["catalog_call_counts"] = [len(row["catalog_calls"]) for row in group]
        summary[side + "-" + mode] = metrics
(ROOT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
