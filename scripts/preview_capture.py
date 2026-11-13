#!/usr/bin/env python3
"""Bound the existing PreviewHost build and rendered-window still capture."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time

from chrome_preview_evidence import registry_names


class CaptureFailure(RuntimeError):
    pass


def bounded_seconds(value):
    seconds = float(value)
    if not 1 <= seconds <= 900:
        raise argparse.ArgumentTypeError("wall timeout must be between 1 and 900 seconds")
    return seconds


def run(command, *, cwd, deadline, log, environment=None):
    """A shared deadline includes builds, children and captures; kill descendants."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise CaptureFailure(f"whole-run deadline expired before {command[0]}")
    with log.open("wb") as output:
        process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            # The leader may have exited while a descendant ignored SIGTERM.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise CaptureFailure(f"whole-run deadline expired: {command[0]}; log: {log}") from None
    if status:
        raise CaptureFailure(f"command exited {status}: {command[0]}; log: {log}")
    return log.read_text(errors="replace").strip()


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("view", help="registered view, --all, or --agent-workspace")
    parser.add_argument("--wall-timeout", type=bounded_seconds, default=600)
    # Treat the historic flag-like view selectors as positional values.
    arguments = list(sys.argv[1:] if argv is None else argv)
    arguments = ["all" if value == "--all" else "agent-workspace" if value == "--agent-workspace" else value
                 for value in arguments]
    args = parser.parse_args(arguments)
    started = time.monotonic()
    deadline = started + args.wall_timeout
    root = Path(os.environ.get("PREVIEW_PROJECT_ROOT", Path(__file__).resolve().parents[1])).resolve()
    output = Path(os.environ.get("PREVIEW_OUTPUT_DIR", root / "macos/Tests/Snapshots")).resolve()
    build = Path(os.environ.get("PREVIEW_DERIVED_DATA", root / "macos/DerivedData/PreviewHost")).resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"version": 1, "status": "failed", "channel": "fixture-still",
              "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "configuration": "Debug", "theme": "doom-one", "motion": "frozen",
              "wall_timeout_seconds": args.wall_timeout, "cleanup_grace_seconds": 1,
              "qualification": "Production ContentView and renderer with immutable fixture data; not live-session or release qualification.",
              "captures": []}
    manifest = output / "preview-run.json"
    try:
        names = registry_names(root / "macos/Sources/PreviewRegistry.swift")
        if args.view == "agent-workspace":
            captures = [("AgentChromeView", width, f"AgentChromeView-{width}-doom-one") for width in (800, 1200)]
        else:
            selected = names if args.view == "all" else [args.view]
            if any(name not in names for name in selected):
                raise CaptureFailure(f"unknown registered preview: {args.view}")
            captures = [(name, 1200, name) for name in selected]
        for _, _, name in captures:
            for suffix in (".png", ".json"):
                (output / f"{name}{suffix}").unlink(missing_ok=True)
        facts = {
            "revision": ["git", "rev-parse", "HEAD"],
            "os": ["sw_vers"], "architecture": ["uname", "-m"],
            "xcode": ["xcodebuild", "-version"], "swift": ["xcrun", "swift", "--version"],
            "sdk_version": ["xcrun", "--sdk", "macosx", "--show-sdk-version"],
            "sdk_build": ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"],
            "sdk_path": ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
        }
        report["toolchain"] = {}
        for key, command in facts.items():
            report["toolchain"][key] = run(command, cwd=root, deadline=deadline, log=output / f"{key}.log")
        # Generation is a prerequisite, never a warning followed by stale opcodes.
        run(["mix", "protocol.gen"], cwd=root, deadline=deadline, log=output / "protocol.log")
        run(["xcodegen", "generate", "--quiet"], cwd=root / "macos", deadline=deadline, log=output / "project.log")
        sources = sorted(path for directory in ("macos/Sources", "macos/Resources", "macos/.generated")
                         for path in (root / directory).rglob("*") if path.is_file())
        sources += [root / name for name in ("macos/project.yml", "mix.lock")]
        report["sources_sha256"] = {str(path.relative_to(root)): sha256(path) for path in sources}
        report["driver_sha256"] = {
            str(Path(__file__).resolve()): sha256(Path(__file__).resolve()),
            str(Path(__file__).with_name("preview.sh").resolve()): sha256(Path(__file__).with_name("preview.sh")),
        }
        build_started = time.monotonic()
        command = ["xcodebuild", "build", "-project", "macos/Minga.xcodeproj", "-scheme", "PreviewHost",
                   "-configuration", "Debug", "-derivedDataPath", str(build), "CODE_SIGNING_ALLOWED=NO", "-quiet"]
        report["build_command"] = command
        run(command, cwd=root, deadline=deadline, log=output / "build.log")
        report["build_elapsed_seconds"] = time.monotonic() - build_started
        app = build / "Build/Products/Debug/PreviewHost.app"
        binary = app / "Contents/MacOS/PreviewHost"
        if not binary.is_file():
            raise CaptureFailure(f"PreviewHost executable missing: {binary}")
        report["executable_sha256"] = sha256(binary)
        report["app_info"] = str(app / "Contents/Info.plist")
        app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        report["app_build_information"] = {
            key: app_info[key] for key in (
                "DTCompiler", "DTPlatformBuild", "DTPlatformVersion", "DTSDKBuild",
                "DTSDKName", "DTXcode", "DTXcodeBuild") if key in app_info
        }
        for view, width, name in captures:
            environment = dict(os.environ, PREVIEW_EAGER_LAYOUT="1", PREVIEW_VIEW=view,
                               PREVIEW_AGENT_WIDTH=str(width), PREVIEW_THEME="doom-one",
                               PREVIEW_OUTPUT_NAME=name, PREVIEW_OUTPUT_DIR=str(output),
                               PREVIEW_BUILD_CONFIGURATION="Debug", LC_ALL="en_US.UTF-8", TZ="UTC")
            capture_started = time.monotonic()
            run([str(binary)], cwd=root, deadline=deadline, log=output / f"{name}.log", environment=environment)
            png = output / f"{name}.png"
            receipt = output / f"{name}.json"
            if not png.is_file() or not receipt.is_file():
                raise CaptureFailure(f"capture did not produce both PNG and metadata: {name}")
            metadata = json.loads(receipt.read_text())
            report["captures"].append({"png": str(png), "metadata": metadata, "sha256": sha256(png),
                                       "elapsed_seconds": time.monotonic() - capture_started})
            print(png, flush=True)
        report["status"] = "captured-awaiting-visual-review"
        return 0
    except (CaptureFailure, OSError, ValueError) as error:
        report["error"] = str(error)
        print(f"error: {error}", file=sys.stderr)
        return 1
    finally:
        report["elapsed_seconds"] = time.monotonic() - started
        manifest.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(manifest, flush=True)


if __name__ == "__main__":
    sys.exit(main())
