"""Behavioral checks for the still driver's build receipts and failure bounds."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("preview_capture", SCRIPTS / "preview_capture.py")
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


class PreviewCaptureTest(unittest.TestCase):
    def test_receipt_includes_protocol_sources_created_by_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "macos").mkdir()
            (root / "macos/project.yml").write_text("name: CaptureFixture\n")
            (root / "mix.lock").write_text("%{}\n")
            output = root / "captures"
            build = root / "derived"
            app = build / "Build/Products/Debug/PreviewHost.app"
            binary = app / "Contents/MacOS/PreviewHost"
            generated = root / "macos/.generated/protocol/Capture.generated.swift"
            generated_bytes = b"enum CaptureVersion { static let value = 42 }\n"

            def run(command, **_options):
                if command == ["mix", "protocol.gen"]:
                    generated.parent.mkdir(parents=True)
                    generated.write_bytes(generated_bytes)
                elif command[0] == "xcodebuild" and "build" in command:
                    binary.parent.mkdir(parents=True)
                    binary.write_bytes(b"fixture executable")
                    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({}))
                elif command == [str(binary)]:
                    (output / "AgentChromeView.png").write_bytes(b"fixture image")
                    (output / "AgentChromeView.json").write_text("{}")
                return "fixture toolchain"

            environment = {
                "PREVIEW_PROJECT_ROOT": str(root),
                "PREVIEW_OUTPUT_DIR": str(output),
                "PREVIEW_DERIVED_DATA": str(build),
            }
            with patch.dict(os.environ, environment, clear=True), \
                    patch.object(capture, "registry_names", return_value=["AgentChromeView"]), \
                    patch.object(capture, "run", side_effect=run):
                capture.main(["AgentChromeView"])

            report = json.loads((output / "preview-run.json").read_text())
            self.assertEqual(
                report["sources_sha256"]["macos/.generated/protocol/Capture.generated.swift"],
                hashlib.sha256(generated_bytes).hexdigest(),
            )

    def test_nonzero_child_is_a_failure_with_diagnostic_log(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "child.log"
            with self.assertRaisesRegex(capture.CaptureFailure, "exited 17"):
                capture.run([sys.executable, "-c", "print('renderer unavailable', flush=True); raise SystemExit(17)"],
                            cwd=directory, deadline=time.monotonic() + 5, log=log)
            self.assertIn("renderer unavailable", log.read_text())

    def test_deadline_kills_descendants_even_after_the_leader_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "survived"
            ready = root / "ready"
            descendant = ("import signal,time; from pathlib import Path; "
                          "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                          f"Path({str(ready)!r}).touch(); time.sleep(1.5); Path({str(marker)!r}).touch()")
            parent = ("import subprocess,sys,time; from pathlib import Path; "
                      f"subprocess.Popen([sys.executable, '-c', {descendant!r}]); "
                      "time.sleep(10)")
            started = time.monotonic()
            with self.assertRaisesRegex(capture.CaptureFailure, "deadline expired"):
                capture.run([sys.executable, "-c", parent], cwd=root,
                            deadline=started + 0.7, log=root / "timeout.log")
            self.assertTrue(ready.exists(), "descendant must have started before the timeout")
            self.assertLess(time.monotonic() - started, 2)
            time.sleep(1)
            self.assertFalse(marker.exists(), "timed-out descendant must not survive its parent")

    def test_expired_budget_does_not_launch_more_work(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "launched"
            with self.assertRaisesRegex(capture.CaptureFailure, "before"):
                capture.run([sys.executable, "-c", f"open({str(marker)!r}, 'w').close()"],
                            cwd=directory, deadline=time.monotonic() - 1, log=Path(directory) / "unused.log")
            self.assertFalse(marker.exists())

    def test_wall_bounds_reject_nonfinite_or_unbounded_requests(self):
        for value in ("0", "-1", "901", "nan", "inf"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                capture.bounded_seconds(value)
        self.assertEqual(capture.bounded_seconds("1"), 1)
        self.assertEqual(capture.bounded_seconds("900"), 900)


if __name__ == "__main__":
    unittest.main()
