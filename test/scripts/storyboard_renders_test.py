"""Tests for the storyboard render gate: stale baselines, missing baselines and the parity rule (#4036).

Run: python3 -m unittest discover -s test/scripts -p 'storyboard_renders_test.py'
"""

import argparse
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("renders", ROOT / "design/tools/storyboard/renders.py")
renders = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(renders)


def macos_export(text, scale=2):
    return json.dumps({"scenario": "s", "theme": "t", "size": "1440", "window": {}, "grid": {}, "backing_scale": scale,
                       "parts": [{"part": "modeline.segment", "text": text, "frame": [0, 0, 10, 10]}], "elements": []})


class RenderGateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.out = root / "out"
        self.baselines = root / "baselines"
        (self.out / "renders" / "s").mkdir(parents=True)
        (self.baselines / "s").mkdir(parents=True)
        manifest = {"scenarios": [{"id": "s", "status": "built", "frontends": ["macos", "tui"]},
                                  {"id": "p", "status": "pending", "issue": 1, "reason": "later"}]}
        (self.out / "manifest.json").write_text(json.dumps(manifest))
        self.base = {}
        self.saved = (renders.BASELINES, renders.git_show, renders.resolve_ref, renders.macos_required)
        renders.BASELINES = self.baselines
        renders.git_show = lambda ref, path: self.base.get(path.name)
        renders.resolve_ref = lambda ref: ref
        renders.macos_required = lambda out, manifest, base: False

    def tearDown(self):
        renders.BASELINES, renders.git_show, renders.resolve_ref, renders.macos_required = self.saved
        self.tmp.cleanup()

    def write(self, where, name, text):
        (where / "s" / name).write_text(text)

    def diff(self, frontends="tui,macos", assume_unchanged=""):
        args = argparse.Namespace(out=self.out, frontends=frontends, base="main", check=True, github_output=None,
                                  assume_unchanged=assume_unchanged)
        status = renders.cmd_diff(args)
        return status, json.loads((self.out / "diff.json").read_text())

    def test_unchanged_renders_pass_and_pending_scenarios_are_listed_not_failed(self):
        for where in (self.out / "renders", self.baselines):
            self.write(where, "tui-a-80x24.txt", "grid")
            self.write(where, "macos-a-1440.json", macos_export("NORMAL"))
        self.base = {"tui-a-80x24.txt": "grid", "macos-a-1440.json": macos_export("NORMAL")}
        status, report = self.diff()
        self.assertEqual(status, 0)
        self.assertEqual(report["changed"], [])
        self.assertEqual(report["orphan_baseline"], [])
        self.assertEqual([p["scenario"] for p in report["pending"]], ["p"])

    def test_a_render_that_differs_from_its_committed_baseline_fails(self):
        self.write(self.out / "renders", "tui-a-80x24.txt", "new grid")
        self.write(self.baselines, "tui-a-80x24.txt", "old grid")
        status, report = self.diff(frontends="tui")
        self.assertEqual(status, 1)
        self.assertEqual(report["stale"][0]["file"], "tui-a-80x24.txt")

    def test_a_built_scenario_without_a_baseline_fails(self):
        self.write(self.out / "renders", "tui-a-80x24.txt", "grid")
        status, report = self.diff(frontends="tui")
        self.assertEqual(status, 1)
        self.assertEqual(report["missing_baseline"][0]["frontend"], "tui")

    def test_a_change_on_one_frontend_only_fails_the_parity_rule(self):
        for where in (self.out / "renders", self.baselines):
            self.write(where, "tui-a-80x24.txt", "new grid")
            self.write(where, "macos-a-1440.json", macos_export("NORMAL"))
        self.base = {"tui-a-80x24.txt": "old grid", "macos-a-1440.json": macos_export("NORMAL")}
        status, report = self.diff()
        self.assertEqual(status, 1)
        self.assertEqual(report["parity_violations"], [{"scenario": "s", "frontend": "tui"}])

    def test_a_platform_specific_reason_accepts_a_one_sided_change(self):
        for where in (self.out / "renders", self.baselines):
            self.write(where, "tui-a-80x24.txt", "new grid")
            self.write(where, "macos-a-1440.json", macos_export("NORMAL"))
        self.write(self.baselines, "promotion.json", json.dumps({"platform_specific": {"frontend": "tui", "reason": "cells only"}}))
        self.base = {"tui-a-80x24.txt": "old grid", "macos-a-1440.json": macos_export("NORMAL")}
        status, report = self.diff()
        self.assertEqual(status, 0)
        self.assertEqual(report["platform_specific"][0]["reason"], "cells only")

    def test_a_change_on_both_frontends_is_listed_and_passes(self):
        for where in (self.out / "renders", self.baselines):
            self.write(where, "tui-a-80x24.txt", "new grid")
            self.write(where, "macos-a-1440.json", macos_export("INSERT"))
        self.base = {"tui-a-80x24.txt": "old grid", "macos-a-1440.json": macos_export("NORMAL")}
        status, report = self.diff()
        self.assertEqual(status, 0)
        self.assertEqual(sorted(report["changed"][0]["frontends"]), ["macos", "tui"])

    def test_a_tui_only_change_fails_parity_when_macos_was_skipped_as_unchanged(self):
        for where in (self.out / "renders", self.baselines):
            self.write(where, "tui-a-80x24.txt", "new grid")
        self.write(self.baselines, "macos-a-1440.json", macos_export("NORMAL"))
        self.base = {"tui-a-80x24.txt": "old grid"}
        status, report = self.diff(frontends="tui", assume_unchanged="macos")
        self.assertEqual(status, 1)
        self.assertEqual(report["parity_violations"], [{"scenario": "s", "frontend": "tui"}])

    def test_a_baseline_without_a_render_fails(self):
        for where in (self.out / "renders", self.baselines):
            self.write(where, "tui-a-80x24.txt", "grid")
        self.write(self.baselines, "tui-a-150x38.txt", "gone")
        self.base = {"tui-a-80x24.txt": "grid"}
        status, report = self.diff(frontends="tui")
        self.assertEqual(status, 1)
        self.assertEqual(report["orphan_baseline"][0]["file"], "tui-a-150x38.txt")

    def test_macos_must_draw_when_a_transcript_differs_from_its_promotion(self):
        transcripts = self.out / "transcripts" / "s"
        transcripts.mkdir(parents=True)
        (transcripts / "macos-a-1440.json").write_text(json.dumps({"digest": "new"}))
        self.write(self.baselines, "promotion.json", json.dumps({"macos": {"transcripts": {"macos-a-1440.json": "old"}}}))
        manifest = json.loads((self.out / "manifest.json").read_text())
        required = self.saved[3]
        saved_run = renders.subprocess.run
        renders.subprocess.run = lambda *a, **k: argparse.Namespace(returncode=0)
        try:
            self.assertTrue(required(self.out, manifest, "main"))
            self.write(self.baselines, "promotion.json", json.dumps({"macos": {"transcripts": {"macos-a-1440.json": "new"}}}))
            self.assertFalse(required(self.out, manifest, "main"))
            self.assertTrue(required(self.out, manifest, None))
        finally:
            renders.subprocess.run = saved_run

    def test_macos_baselines_ignore_facts_about_the_machine(self):
        self.assertEqual(renders.comparable("macos", macos_export("x", scale=1)),
                         renders.comparable("macos", macos_export("x", scale=2)))
        self.assertNotEqual(renders.comparable("macos", macos_export("x")), renders.comparable("macos", macos_export("y")))

    def test_promote_records_the_commit_and_clears_a_stale_platform_tag(self):
        self.write(self.out / "renders", "tui-a-80x24.txt", "grid")
        self.write(self.baselines, "promotion.json", json.dumps({"platform_specific": {"frontend": "tui", "reason": "old"}}))
        saved = renders.commit_identity
        renders.commit_identity = lambda: "abc123"
        try:
            args = argparse.Namespace(out=self.out, macos=None, scenario=None, no_render=True, platform_specific=None)
            renders.cmd_promote(args)
        finally:
            renders.commit_identity = saved
        promotion = json.loads((self.baselines / "s" / "promotion.json").read_text())
        self.assertEqual(promotion["tui"]["commit"], "abc123")
        self.assertNotIn("platform_specific", promotion)
        self.assertEqual((self.baselines / "s" / "tui-a-80x24.txt").read_text(), "grid")

    def test_promote_refuses_a_render_with_an_open_audit_finding(self):
        self.write(self.out / "renders", "tui-a-80x24.txt", "# size: 80x24\n## text\n\n## styles (row start-end fg bg attrs)\n")
        self.write(self.out / "renders", "tui-a-80x24.parts.json", json.dumps(
            {"frontend": "tui", "theme": "a", "size": "80x24", "parts": [{"part": "modeline", "text": "NORMAL", "missing": True}]}))
        args = argparse.Namespace(out=self.out, macos=None, scenario=None, no_render=True, platform_specific=None)
        with self.assertRaisesRegex(renders.Failure, "fail the layout audit"):
            renders.cmd_promote(args)
        self.assertFalse((self.baselines / "s" / "tui-a-80x24.txt").exists())

if __name__ == "__main__":
    unittest.main()
