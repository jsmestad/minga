"""Tests for the storyboard layout audit (#4036, AC 5): the scales it reads and the rules it applies.

Run: python3 -m unittest discover -s test/scripts -p 'storyboard_audit_test.py'
"""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "design/tools/storyboard"))
SPEC = importlib.util.spec_from_file_location("audit", ROOT / "design/tools/storyboard/audit.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)

FRAME = {"scenario": "s", "frontend": "macos", "theme": "t", "size": "1440"}


def part(name, x, y, w, h, **extra):
    return {"part": name, "frame": [x, y, w, h], **extra}


class ScaleTest(unittest.TestCase):
    def test_the_scale_comes_from_the_token_sources(self):
        scale = audit.Scale()
        self.assertEqual(scale.mac("whichKeyColumnGap"), 24)
        self.assertEqual(scale.cols("whichKeyColumnGap"), 3)
        self.assertEqual(scale.cols("whichKeyKeyToLabel"), 1)
        self.assertEqual(scale.cols("whichKeyMarginCols"), 0)
        self.assertEqual(scale.rows("whichKeyInsetV"), 0)
        self.assertEqual(scale.row_pitch, 24)
        self.assertEqual((scale.text_contrast, scale.glyph_contrast), (4.5, 3.0))


class RuleTest(unittest.TestCase):
    def setUp(self):
        self.audit = audit.Audit(audit.Scale())

    def which_key(self, pitch=24, gap=8, inset=12):
        panel = part("whichKey.panel", 100, 100, 400, 200)
        parts = [panel]
        for row in range(3):
            y = 130 + row * pitch
            parts.append(part("whichKey.entryKey", 100 + inset, y, 7, 14, baseline=y + 11))
            parts.append(part("whichKey.entryLabel", 100 + inset + 7 + gap, y, 60, 14, baseline=y + 11))
        return parts

    def rules(self):
        return {(f["part"], f["rule"]) for f in self.audit.findings}

    def test_a_which_key_panel_on_the_anatomy_passes(self):
        audit.which_key(self.audit, FRAME, self.which_key(), mac=True)
        self.assertEqual(self.audit.findings, [])

    def test_row_pitch_gap_and_inset_are_measured(self):
        audit.which_key(self.audit, FRAME, self.which_key(pitch=22, gap=6, inset=10), mac=True)
        self.assertEqual(self.rules(), {("whichKey.entry", "entry pitch"), ("whichKey.entry", "key to label"),
                                        ("whichKey.panel", "inset")})

    def test_a_label_cut_without_an_ellipsis_fails(self):
        parts = self.which_key()
        parts[2]["truncated"] = True
        audit.which_key(self.audit, FRAME, parts, mac=True)
        self.assertIn(("whichKey.entryLabel", "truncates with …"), self.rules())

    def test_contrast_is_measured_against_the_targets(self):
        self.assertEqual(audit.contrast("#000000", "#ffffff"), 21.0)
        self.assertLess(audit.contrast("#949cbb", "#c6d0f5"), 4.5)

    def test_one_finding_per_rule_keeps_every_value(self):
        for value in (22, 23, 22):
            self.audit.check(FRAME, "p", "r", 24, value)
        self.assertEqual(len(self.audit.findings), 1)
        self.assertEqual(self.audit.findings[0]["actual"], [22, 23])


    def test_the_modeline_inset_gap_and_hit_targets_are_measured(self):
        parts = [part("modeline", 0, 870, 1440, 22), part("modeline.control", 10, 870, 26, 22),
                 part("modeline.segment", 120, 872, 50, 18), part("modeline.segment", 174, 872, 80, 18)]
        audit.modeline(self.audit, FRAME, parts, mac=True)
        self.assertEqual(self.rules(), {("modeline", "leading inset"), ("modeline.segment", "gap between segments"),
                                        ("modeline", "hit target at least one row pitch"),
                                        ("modeline.control", "hit target at least one row pitch")})

    def test_tui_cells_are_judged_against_text_and_glyph_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            frame = Path(tmp) / "tui-t-4x2.txt"
            frame.write_text("# size: 4x2\n## text\nab\n~\n## styles (row start-end fg bg attrs)\n"
                             "0 0-1 #777777 #888888 -\n1 0-0 #000000 #ffffff -\n")
            audit.tui_contrast(self.audit, {**FRAME, "frontend": "tui"}, frame)
        self.assertEqual(self.rules(), {("text", "contrast")})


class ExceptionTest(unittest.TestCase):
    FINDING = {**FRAME, "part": "whichKey.entry", "rule": "entry pitch"}

    def test_an_exception_names_scenarios_frontend_part_rule_and_optionally_a_theme(self):
        base = {"frontend": "macos", "part": "whichKey.entry", "rule": "entry pitch"}
        self.assertTrue(audit.matches({**base, "scenario": "s"}, self.FINDING))
        self.assertTrue(audit.matches({**base, "scenario": ["x", "s"]}, self.FINDING))
        self.assertTrue(audit.matches({**base, "scenario": "*", "theme": "t"}, self.FINDING))
        self.assertFalse(audit.matches({**base, "scenario": "other"}, self.FINDING))
        self.assertFalse(audit.matches({**base, "scenario": "s", "theme": "latte"}, self.FINDING))

    def test_an_exception_without_a_reason_or_an_issue_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved = audit.EXCEPTIONS
            audit.EXCEPTIONS = Path(tmp) / "x.toml"
            audit.EXCEPTIONS.write_text('[[exception]]\nscenario = "s"\nfrontend = "tui"\npart = "p"\nrule = "r"\nreason = "why"\n')
            try:
                with self.assertRaises(audit.Failure):
                    audit.load_exceptions()
            finally:
                audit.EXCEPTIONS = saved


if __name__ == "__main__":
    unittest.main()
