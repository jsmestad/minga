"""Standalone pinned-venv consumer tests; synthetic children prove failures only.

Run: <private-venv>/bin/python test/scripts/go_tui_capture_test.py
No ExUnit launcher: pyte is an optional developer tool, not a CI dependency.
"""

import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import go_tui_capture as capture


def corpus_document():
    return {"version": 1, "theme": "astrodark", "dynamic_cells": [], "sizes": [
        {"name": name, "columns": columns, "rows": rows, "steps": [
            {"label": "workspace", "payload_base64": base64.b64encode(b"consumer-boundary").decode(),
             "present": ["COMPLETE", "NEIGHBOR"], "absent": ["STALE"]}
        ]} for name, columns, rows in capture.SIZES
    ]}


class TerminalConsumerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pyte, _ = capture.decoder_dependencies()

    def test_stateful_cursor_erase_and_fragmented_utf8_preserve_neighbors(self):
        terminal = capture.TerminalGrid(self.pyte, 20, 4)
        emitted = "\x1b[2J\x1b[HOLD\x1b[2;1HNEIGHBOR\x1b[1;1H\x1b[2KNEW界".encode()
        for byte in emitted:
            terminal.feed(bytes([byte]))
        self.assertEqual(terminal.lines()[0].rstrip(), "NEW界")
        self.assertEqual(terminal.lines()[1].rstrip(), "NEIGHBOR")
        self.assertNotIn("OLD", "\n".join(terminal.lines()))
        terminal.feed(b"\x1b[6n")
        self.assertTrue(terminal.replies.startswith(b"\x1b[1;"))

    def test_masks_use_terminal_cells_without_modifying_unmasked_grid(self):
        original = ["界S meaningful"]
        compared = capture.comparison_grid(original, [{"row": 0, "col": 2, "length": 1}])
        self.assertEqual(compared, ["界  meaningful"])
        self.assertEqual(original, ["界S meaningful"])

    def test_empty_partial_and_stale_grids_cannot_satisfy_step(self):
        step = corpus_document()["sizes"][0]["steps"][0]
        for lines in ([""], ["COMPLETE"], ["COMPLETE NEIGHBOR STALE"]):
            self.assertFalse(capture.matches(lines, step))
        self.assertTrue(capture.matches(["COMPLETE", "NEIGHBOR"], step))

    def test_emitted_short_status_overwrite_retains_suffix_and_clears_title(self):
        # Actual production narrow terminal bytes[2293:2322] from run-bf76571b64754897b1b3b116f1db1b67.
        # No EL follows UNKNOWN_OK on row 24; the emitted CUP+EL instead explicitly clears row 1.
        update = b"\r\x1b[24d\x1b[1mUNKNOWN_OK\x1b[m\x1b[H\x1b[K"
        for chunks in ([update], [bytes([byte]) for byte in update]):
            terminal = capture.TerminalGrid(self.pyte, 60, 24)
            terminal.feed(b"\x1b[HMinga\x1b[24;1HSTATUS_ROWS")
            for chunk in chunks:
                terminal.feed(chunk)
            self.assertEqual(terminal.lines()[0].strip(), "")
            self.assertEqual(terminal.lines()[23].rstrip(), "UNKNOWN_OKS")
            self.assertFalse(capture.matches(terminal.lines(), {"present": ["UNKNOWN_OK"], "absent": []}))
            terminal.feed(b"\r\x1b[24d\x1b[1mSTATUS_NEW\x1b[m\x1b[H")
            self.assertEqual(terminal.lines()[23].rstrip(), "STATUS_NEWS")
            self.assertFalse(capture.matches(terminal.lines(), {"present": ["STATUS_NEW"], "absent": []}))
            # Only a real status-row erase fixes the residue.
            # The adapter must never infer one merely because a shorter expected label appears.
            terminal.feed(b"\r\x1b[24dSTATUS_NEW\x1b[K\x1b[H")
            self.assertEqual(terminal.lines()[23].rstrip(), "STATUS_NEW")
            self.assertTrue(capture.matches(terminal.lines(), {"present": ["STATUS_NEW"], "absent": []}))

    def test_initial_status_cannot_accept_stale_boot_footer_digit(self):
        # Actual wide stream contains "row 1 col 1" (11 cells) at byte 296, then STATUS_OLD (10 cells) at byte 4925 without a following EL.
        terminal = capture.TerminalGrid(self.pyte, 140, 40)
        terminal.feed(b"\x1b[40;1Hrow 1 col 1\x1b[K\x1b[H")
        terminal.feed(b"\x1b[40;1H\x1b[1mSTATUS_OLD\x1b[m\x1b[H\x1b[K")
        self.assertEqual(terminal.lines()[39].rstrip(), "STATUS_OLD1")
        self.assertFalse(capture.matches(terminal.lines(), {"present": ["STATUS_OLD"], "absent": []}))

    def test_expected_labels_allow_punctuation_but_not_stale_token_affixes(self):
        step = {"present": ["STATUS_NEW", "y approve"], "absent": ["STATUS_OLD"]}
        self.assertTrue(capture.matches(["│STATUS_NEW│", "│ y approve · n reject│"], step))
        for line in ("STATUS_NEWS", "STATUS_NEW1", "OLD_STATUS_NEW", "xSTATUS_NEW"):
            self.assertFalse(capture.matches([line, "y approve"], step))
        self.assertFalse(capture.matches(["STATUS_NEW", "y approve", "STATUS_OLDS"], step))

    def test_corpus_rejects_unsafe_labels_sizes_and_outside_masks(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "corpus.json"
            changes = [lambda c: c["sizes"][0].update(columns=61),
                       lambda c: c["sizes"][0]["steps"][0].update(label="../escape"),
                       lambda c: c["dynamic_cells"].append({"size": "narrow", "step": "workspace", "row": 24,
                                                           "col": 0, "length": 1, "reason": "spinner"})]
            for change in changes:
                document = corpus_document()
                change(document)
                path.write_text(json.dumps(document))
                with self.assertRaises(ValueError):
                    capture.read_corpus(path)

    def test_retention_deletes_only_marked_non_symlink_runs_and_caps_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            unrelated = root / ("run-" + "a" * 32)
            unrelated.mkdir()
            (unrelated / "keep").write_text("unrelated")
            target = root / "outside"
            target.mkdir()
            (target / capture.MARKER).write_text(capture.OWNER)
            link = root / ("run-" + "b" * 32)
            link.symlink_to(target, target_is_directory=True)
            first = capture.Artifacts(root, 128 * 1024, 1)
            old = first.path
            first.close()
            second = capture.Artifacts(root, 128 * 1024, 1)
            self.assertFalse(old.exists())
            self.assertTrue((unrelated / "keep").exists())
            self.assertTrue(link.is_symlink())
            self.assertTrue(target.is_dir())
            with self.assertRaises(RuntimeError):
                second.write("overflow.bin", b"x" * (128 * 1024))
            second.json("metadata.json", {"status": "failed"}, diagnostic=True)
            self.assertLessEqual(sum(p.stat().st_size for p in second.path.iterdir()), 128 * 1024)
            second.close()
            with self.assertRaises(ValueError):
                capture.Artifacts(link, 128 * 1024, 1)

    def test_cli_flags_can_only_tighten_bounds(self):
        for flag, value in (("--step-timeout", "6"), ("--wall-timeout", "61"),
                            ("--retain-runs", "6"), ("--max-bytes", str(capture.MAX_BYTES + 1)),
                            ("--step-timeout", "nan")):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                capture.main(["--binary", "unused", "--corpus", "unused", "--output", "unused", flag, value])
            self.assertEqual(error.exception.code, 2)


# Serialized unittest execution: these cases own real OS processes and PTYs.
# Every subprocess invocation has an explicit 12-second outer timeout.
class ProcessFailureTest(unittest.TestCase):
    def run_failure(self, mode, byte_limit=1024 * 1024):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            binary = root / "synthetic-failure-child"
            pidfile = root / "child.pid"
            binary.write_text(f'''#!{sys.executable}
import fcntl, os, signal, struct, sys, termios, time
mode = {mode!r}
open({str(pidfile)!r}, "w").write(str(os.getpid()))
fd = os.open(os.environ["MINGA_TTY"], os.O_RDWR)
rows, columns, _, _ = struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\\0" * 8))
if mode == "crash":
    os.write(2, b"crash diagnostic\\n")
    sys.exit(23)
if mode in ("ignore-shutdown", "valid-ignore-shutdown"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode == "valid-term-zero":
    signal.signal(signal.SIGTERM, lambda *_args: sys.exit(0))
if mode not in ("no-ready", "ignore-shutdown"):
    ready = bytes([3]) + struct.pack(">HH", columns + (mode == "wrong-size"), rows)
    os.write(1, struct.pack(">I", len(ready)) + ready)
if mode == "flood":
    os.write(2, b"stderr flood\\n" * 20000)
    os.write(1, b"p" * 200000)
if mode in ("partial", "empty", "flood", "truncated-utf8", "valid-eof-failure", "valid-ignore-shutdown", "valid-term-zero"):
    length = struct.unpack(">I", sys.stdin.buffer.read(4))[0]
    sys.stdin.buffer.read(length)
    if mode == "partial":
        os.write(fd, b"\\x1b[2J\\x1b[HCOMPLETE")
    elif mode == "truncated-utf8":
        os.write(fd, b"\\x1b[2J\\x1b[HCOMPLETE NEIGHBOR\\xe7")
    elif mode == "flood":
        os.write(fd, b"\\x1b[2J\\x1b[HCOMPLETE")
    elif mode.startswith("valid-"):
        os.write(fd, b"\\x1b[2J\\x1b[HCOMPLETE NEIGHBOR")
        if mode == "valid-eof-failure":
            sys.stdin.buffer.read()
            os.write(2, b"EOF failure diagnostic\\n")
            sys.exit(23)
os.write(2, b"failure boundary drained\\n")
while True:
    time.sleep(1)
''')
            binary.chmod(0o700)
            corpus = root / "corpus.json"
            corpus.write_text(json.dumps(corpus_document()))
            output = root / "captures"
            completed = subprocess.run(
                [sys.executable, str(SCRIPTS / "go_tui_capture.py"), "--binary", str(binary),
                 "--corpus", str(corpus), "--output", str(output), "--step-timeout", "0.3",
                 "--wall-timeout", "8", "--max-bytes", str(byte_limit)],
                capture_output=True, text=True, timeout=12,
            )
            self.assertNotEqual(completed.returncode, 0, completed.stdout)
            self.assertNotIn("PASS", completed.stdout)
            runs = [p for p in output.iterdir() if capture.RUN_NAME.fullmatch(p.name)]
            self.assertEqual(len(runs), 1)
            metadata = json.loads((runs[0] / "metadata.json").read_text())
            self.assertEqual(metadata["status"], "failed")
            self.assertIn("error", metadata)
            self.assertEqual(metadata["binary"]["sha256"], hashlib.sha256(binary.read_bytes()).hexdigest())
            failed_step = metadata["sizes"][0]["failed_step"]
            self.assertTrue((runs[0] / f"narrow.{failed_step}.partial.grid.json").exists())
            self.assertLessEqual(sum(p.stat().st_size for p in runs[0].iterdir()), byte_limit)
            pid = int(pidfile.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            return metadata, (runs[0] / "narrow.stderr.bin").read_bytes(), completed.stderr

    def test_crash_drains_stderr_and_reaps_without_success(self):
        metadata, stderr, _ = self.run_failure("crash")
        # EOF and waitpid can become observable in either order; the reaped status, not the first detected transport symptom, identifies a crash.
        self.assertEqual(metadata["sizes"][0]["exit_status"], 23)
        self.assertIn(b"crash diagnostic", stderr)

    def test_silence_partial_empty_and_truncated_utf8_are_failures(self):
        for mode in ("no-ready", "partial", "empty", "truncated-utf8"):
            with self.subTest(mode=mode):
                metadata, stderr, _ = self.run_failure(mode)
                self.assertIn("TimeoutError", metadata["error"])
                self.assertIn(b"failure boundary drained", stderr)

    def test_kernel_winsize_is_required_in_ready(self):
        metadata, _, _ = self.run_failure("wrong-size")
        self.assertIn("ready size 61x24, expected 60x24", metadata["error"])

    def test_protocol_and_stderr_are_drained_concurrently_with_terminal(self):
        metadata, stderr, _ = self.run_failure("flood")
        self.assertIn("TimeoutError", metadata["error"])
        self.assertGreater(len(stderr), 200000)
        self.assertIn(b"failure boundary drained", stderr)

    def test_stream_cap_preserves_diagnostic_without_unbounded_artifacts(self):
        metadata, stderr, _ = self.run_failure("flood", byte_limit=128 * 1024)
        self.assertIn("byte limit", metadata["error"])
        self.assertIn(b"stderr flood", stderr)

    def test_noncooperative_child_is_killed_and_reaped(self):
        metadata, _, _ = self.run_failure("ignore-shutdown")
        self.assertEqual(metadata["sizes"][0]["exit_status"], -9)

    def test_unsuccessful_eof_shutdown_rejects_complete_output(self):
        metadata, stderr, _ = self.run_failure("valid-eof-failure")
        report = metadata["sizes"][0]
        self.assertEqual([step["label"] for step in report["steps"]], ["workspace"])
        self.assertEqual(report["failed_step"], "shutdown")
        self.assertEqual(report["exit_status"], 23)
        self.assertIn(b"EOF failure diagnostic", stderr)

    def test_forced_shutdown_rejects_complete_output_even_with_zero_exit(self):
        for mode, exit_status, action in (("valid-term-zero", 0, "terminate"), ("valid-ignore-shutdown", -9, "kill")):
            with self.subTest(mode=mode):
                metadata, _, _ = self.run_failure(mode)
                report = metadata["sizes"][0]
                self.assertEqual([step["label"] for step in report["steps"]], ["workspace"])
                self.assertEqual(report["failed_step"], "shutdown")
                self.assertEqual(report["exit_status"], exit_status)
                self.assertEqual(report["shutdown_action"], action)


if __name__ == "__main__":
    unittest.main()
