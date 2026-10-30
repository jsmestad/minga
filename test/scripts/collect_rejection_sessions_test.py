"""Evidence integrity tests; synthetic fixtures never enter the real-session cohort."""

import argparse
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/collect_rejection_sessions.py"
SPEC = importlib.util.spec_from_file_location("collect_rejection_sessions", SCRIPT)
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)

REJECTION = 'Rejected semantic activation surface=picker generation=42 id="retained item" reason=stale_generation'
OTHER = 'Rejected semantic activation surface=file_tree generation=8 id="other" reason=not_found'


class RejectionSessionCollectionTest(unittest.TestCase):
    def make_session(self, root, name="session", debug="", canonical="", native="", launcher="", kind="real", **updates):
        session = root / name
        session.mkdir()
        metadata = {
            "kind": kind, "build": {"source_commit": "e" * 40},
            "started_at": "2026-10-30T19:00:00Z", "finished_at": "2026-10-30T20:00:00Z",
            "note": "Synthetic unit fixture", "launcher_exit_code": 0, "boundary_kind": "operator_bracketed",
            "session_attested": True, "declared_editor_warning_level": "warning",
            "canonical_before": None, "canonical_after": {"offset": len(canonical.encode())}, "problems": [],
        }
        (session / "debug.log").write_text(collector.HEADER + "\nMinga test | fixture\n" + debug)
        (session / "canonical.log").write_text(canonical)
        (session / "native-output.log").write_text(native)
        (session / "launcher-output.log").write_text(launcher)
        metadata["retained_logs"] = {
            name: collector.evidence_fingerprint(session / name) for name in collector.EVIDENCE_FILES
        }
        metadata.update(updates)
        (session / "session.json").write_text(json.dumps(metadata))
        return session

    def test_rejections_correlate_by_message_and_preserve_surface_generation_and_multiplicity(self):
        with tempfile.TemporaryDirectory() as directory:
            session = self.make_session(
                Path(directory), debug=f"[WARNING] [warning] {REJECTION}\n" * 2,
                canonical=f"2026-10-30T19:01:00Z warning: {REJECTION}\n" * 2,
            )
            result = collector.analyze(session)
            self.assertEqual(result["rejection_count"], 2)
            self.assertTrue(result["real_candidate"])
            self.assertEqual(result["surfaces"], [
                {"surface": "picker", "generation": "42", "reason": "stale_generation", "count": 2}
            ])

    def test_missing_ambiguous_or_unattributed_rejections_are_unknown_not_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            for index, (debug, canonical) in enumerate([
                (REJECTION + "\n", ""),
                (REJECTION + "\n", (REJECTION + "\n") * 2),
                ("", OTHER + "\n"),
                ("Rejected semantic activation changed-wire-shape\n", ""),
            ]):
                with self.subTest(index=index):
                    session = self.make_session(Path(directory), name=str(index), debug=debug, canonical=canonical)
                    result = collector.analyze(session)
                    self.assertIsNone(result["rejection_count"])
                    self.assertFalse(result["real_candidate"])

    def test_only_attested_terminal_orderly_shutdown_is_not_a_registry_gap(self):
        with tempfile.TemporaryDirectory() as directory:
            shutdown = "[debug-log] events registry down: :shutdown\n"
            cases = [
                (shutdown, True, 0),
                (shutdown, False, None),
                (shutdown + "Later event\n", True, None),
                ("[debug-log] events registry down: :killed\n", True, None),
                (shutdown + "[debug-log] events registry re-subscribed; missed events may exist\n", True, None),
            ]
            for index, (debug, attested, expected) in enumerate(cases):
                with self.subTest(index=index):
                    session = self.make_session(Path(directory), name=str(index), debug=debug, session_attested=attested)
                    self.assertEqual(collector.analyze(session)["rejection_count"], expected)

    def test_failed_or_unconfirmed_capture_cannot_become_a_zero_rejection_session(self):
        with tempfile.TemporaryDirectory() as directory:
            for index, updates in enumerate([
                {"launcher_exit_code": 1}, {"launcher_exit_code": None},
                {"session_attested": False}, {"declared_editor_warning_level": "error"},
                {"problems": ["Canonical log was replaced or rotated"]},
            ]):
                session = self.make_session(Path(directory), name=str(index), **updates)
                self.assertIsNone(collector.analyze(session)["rejection_count"])
            missing = self.make_session(Path(directory), name="missing")
            (missing / "debug.log").unlink()
            self.assertIsNone(collector.analyze(missing)["rejection_count"])
            restarted = self.make_session(Path(directory), name="restart", debug=collector.HEADER + "\n")
            self.assertIsNone(collector.analyze(restarted)["rejection_count"])

    def test_retained_logs_cannot_be_truncated_or_rewritten_into_zero_rejection_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            for index, (filename, replacement) in enumerate([
                ("canonical.log", ""),
                ("canonical.log", "Changed message!\n"),
                ("debug.log", collector.HEADER + "\n"),
                ("native-output.log", None),
            ]):
                with self.subTest(filename=filename, index=index):
                    session = self.make_session(
                        Path(directory), name=str(index), debug="Editor ready\n", canonical="Original message\n"
                    )
                    if replacement is None:
                        (session / filename).unlink()
                    else:
                        (session / filename).write_text(replacement)
                    result = collector.analyze(session)
                    self.assertIsNone(result["rejection_count"])
                    self.assertFalse(result["real_candidate"])

    def test_debug_writer_failure_diagnostics_in_captured_outputs_disqualify_zero_counts(self):
        failures = [
            "Debug log final flush failed for /tmp/debug.log: :enospc",
            "Debug log close failed for /tmp/debug.log: :eio",
            "Failed to stop debug log during shutdown: {:debug_log_not_running, path}",
            "{:debug_log_write_failed, path, :enospc}",
        ]
        with tempfile.TemporaryDirectory() as directory:
            for index, message in enumerate(failures):
                for output in ["canonical", "native", "launcher"]:
                    with self.subTest(message=message, output=output):
                        session = self.make_session(
                            Path(directory), name=f"{index}-{output}", **{output: message + "\n"}
                        )
                        result = collector.analyze(session)
                        self.assertIsNone(result["rejection_count"])
                        self.assertTrue(any("Debug writer failure" in issue for issue in result["problems"]))

    def test_unfinished_brackets_exclude_another_root_and_cancellation_releases_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Minga.app"
            launcher = app / "Contents/Resources/bin/minga"
            launcher.parent.mkdir(parents=True)
            launcher.write_text("#!/bin/sh\nexit 0\n")
            launcher.chmod(0o700)
            receipt = root / "build.json"
            receipt.write_text(json.dumps({
                "app_path": str(app), "source_commit": "e" * 40,
                "payload_sha256": collector.payload_digest(app),
            }))
            canonical = root / "minga.log"
            canonical.write_text("")
            args = argparse.Namespace(
                build=receipt, root=root / "first", canonical=canonical,
                kind="smoke", warning_level="warning", note="Synthetic bracket fixture", files=[],
            )
            with patch.object(collector, "require_no_running_app"), redirect_stdout(io.StringIO()):
                self.assertEqual(collector.begin(args), 0)
                session = next((root / "first").iterdir())
                args.root = root / "second"
                with self.assertRaisesRegex(ValueError, "unfinished collection bracket"):
                    collector.begin(args)
                with patch("builtins.input", return_value="no"):
                    self.assertEqual(collector.finish(argparse.Namespace(session=session)), 2)
                self.assertIsNone(collector.analyze(session)["rejection_count"])
                self.assertEqual(collector.begin(args), 0)

    def test_summary_never_counts_smoke_or_incomplete_sessions_as_real(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_session(root, name="real")
            self.make_session(root, name="smoke", kind="smoke")
            self.make_session(root, name="incomplete", session_attested=False)
            output = io.StringIO()
            with redirect_stdout(output):
                collector.report(argparse.Namespace(root=root))
            result = json.loads(output.getvalue())
            self.assertEqual(result["complete_real_candidates"], 1)
            by_name = {session["session"]: session for session in result["sessions"]}
            self.assertEqual(by_name["real"]["rejection_count"], 0)
            self.assertFalse(by_name["smoke"]["real_candidate"])
            self.assertIsNone(by_name["incomplete"]["rejection_count"])

    def test_copied_evidence_cannot_count_as_another_real_session(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = self.make_session(root, name="original")
            shutil.copytree(session, root / "backup")
            self.make_session(root, name="different-session", debug="A different session started\n")
            output = io.StringIO()
            with redirect_stdout(output):
                collector.report(argparse.Namespace(root=root))
            result = json.loads(output.getvalue())
            self.assertEqual(result["complete_real_candidates"], 2)
            self.assertEqual(sum("duplicate_of" in row for row in result["sessions"]), 1)

    def test_canonical_interval_excludes_previous_sessions_and_rejects_replacement_or_rewrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, retained = root / "minga.log", root / "canonical.log"
            source.write_bytes(b"previous session\n")
            before = collector.canonical_snapshot(source)
            with source.open("ab") as stream:
                stream.write(b"current session\n")
            collector.retain_canonical_interval(source, before, retained)
            self.assertEqual(retained.read_bytes(), b"current session\n")
            source.write_bytes(b"rewritten prefix\ncurrent session\n")
            with self.assertRaisesRegex(ValueError, "boundary changed"):
                collector.retain_canonical_interval(source, before, retained)
            source.rename(root / "old.log")
            source.write_bytes(b"replacement\n")
            with self.assertRaisesRegex(ValueError, "replaced or rotated"):
                collector.retain_canonical_interval(source, before, retained)

    def test_payload_identity_changes_with_contents_or_symlink_target(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / "one").write_text("original")
            (app / "two").write_text("second")
            (app / "link").symlink_to("one")
            original = collector.payload_digest(app)
            (app / "one").write_text("modified")
            self.assertNotEqual(collector.payload_digest(app), original)
            modified = collector.payload_digest(app)
            (app / "link").unlink()
            (app / "link").symlink_to("two")
            self.assertNotEqual(collector.payload_digest(app), modified)
            (app / "link").unlink()
            (app / "link").symlink_to(app.parent / "outside")
            with self.assertRaisesRegex(ValueError, "escapes"):
                collector.payload_digest(app)


if __name__ == "__main__":
    unittest.main()
