#!/usr/bin/env python3
"""Synthetic accounting fixture only. Never use its output as native UI evidence."""

import argparse
import hashlib
import json
import os
import signal
import time
import struct
import sys
import zlib
from pathlib import Path


def write_fixture(directory, run_id, width, observer_pid, observer, host, host_pid, write_ready=True):
    bounds = {"x": 10, "y": 10, "width": width, "height": 430}
    identity = {"pid": host_pid, "executable": str(host.resolve()), "bundle_identifier": "com.minga.test-host", "window_id": 99}
    ready = {"schema": "minga-approval-host-v1", "run_id": run_id, "width": width, **identity}

    def chunk(kind, data):
        payload = kind + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)

    pixels = (b"\0" + b"\0\0\0\xff" * width) * 430
    image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, 430, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
    (directory / "window.png").write_bytes(image)
    buttons = [{
        "title": title, "title_attribute": "AXTitle", "role": "AXButton",
        "frame": {"x": 20, "y": 50 + index * 40, "width": 180, "height": 30},
        "enabled": True, "press_capable": True, "center_hits_exact_button": True, "label_width": 100,
    } for index, title in enumerate(("Approve (y)", "Trust for session (a)", "Trust for this turn (t)", "Deny (n)"))]
    value = {
        "schema": "minga-approval-geometry-v2", "kind": "observation", "run_id": run_id, "width": width,
        "observer_pid": observer_pid, "observer_executable": str(observer.resolve()), "host": identity,
        "workspace_count": 1, "workspace": {"x": 10, "y": 40, "width": width, "height": 400}, "buttons": buttons,
        "hit_oracle": "system-wide-AX-hit-test",
        "capture": {"filename": "window.png", "api": "ScreenCaptureKit.SCScreenshotManager.desktopIndependentWindow", "window_id": 99, "host_pid": host_pid, "point_bounds": bounds, "ax_window_bounds": dict(bounds), "scale": 1, "pixel_width": width, "pixel_height": 430, "decoded_pixel_width": width, "decoded_pixel_height": 430, "sha256": hashlib.sha256(image).hexdigest()},
    }
    if write_ready:
        (directory / "host-ready.json").write_text(json.dumps(ready) + "\n")
    (directory / "observation.json").write_text(json.dumps(value) + "\n")
    return value


def run_host():
    executable = Path(sys.argv[0]).resolve()
    ready = Path(os.environ["MINGA_APPROVAL_GEOMETRY_READY"])
    ignore_shutdown = executable.with_name("ignore-host-shutdown").exists()
    if ignore_shutdown:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if executable.with_name("withhold-host-ready").exists():
        while True:
            signal.pause()
    value = {
        "schema": "minga-approval-host-v1", "run_id": os.environ["MINGA_APPROVAL_GEOMETRY_RUN_ID"],
        "width": int(os.environ["MINGA_TEST_APPROVAL_WIDTH"]), "pid": os.getpid(),
        "executable": str(executable), "bundle_identifier": "com.minga.test-host", "window_id": 99,
    }
    temporary = ready.with_suffix(".tmp")
    temporary.write_text(json.dumps(value) + "\n")
    temporary.replace(ready)
    if ignore_shutdown:
        while True:
            signal.pause()
    sys.stdin.buffer.read()


def run_observer():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host-pid", type=int, required=True)
    parser.add_argument("--host-executable", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path, required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    executable = Path(sys.argv[0]).resolve()
    if executable.with_name("ignore-observer-term").exists():
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        executable.with_name("observer-armed").write_text("SIGTERM ignored\n")
        while True:
            signal.pause()
    deadline = time.monotonic() + 5
    while not args.ready_file.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("Synthetic host did not publish readiness")
        time.sleep(0.01)
    if executable.with_name("hang-observer").exists():
        while True:
            signal.pause()
    if executable.with_name("early-observer-exit").exists():
        return 7
    write_fixture(args.output_dir, args.run_id, args.width, os.getpid(), executable, args.host_executable, args.host_pid, write_ready=False)
    return 0


if __name__ == "__main__":
    if Path(sys.argv[0]).name == "MingaTestHost":
        run_host()
    else:
        sys.exit(run_observer())
