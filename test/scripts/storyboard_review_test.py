"""Tests for the visual review records (#4036, AC 6 to AC 8): the comment and the follow-up entries.

Run: python3 -m unittest discover -s test/scripts -p 'storyboard_review_test.py'
"""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("review", ROOT / "design/tools/storyboard/review.py")
review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review)

RECORD = {
    "scenarios": ["edit.plain", "edit.whichkey.leader"],
    "verdicts": [
        {"scenario": "edit.plain", "reviewer": "structure-1", "verdict": "pass", "notes": ""},
        {"scenario": "edit.plain", "reviewer": "structure-2", "verdict": "pass", "notes": ""},
        {"scenario": "edit.whichkey.leader", "reviewer": "structure-1", "verdict": "concern",
         "notes": "TUI 80x24: labels cut without …"},
        {"scenario": "edit.whichkey.leader", "reviewer": "structure-2", "verdict": "pass", "notes": ""},
    ],
    "critic": [
        {"round": 1, "items": [
            {"scenario": "edit.whichkey.leader", "part": "whichKey.entry", "issue": "rows are 22 pt", "suggested": "24 pt",
             "status": "declined", "reason": "owned by #4044"},
            {"scenario": "edit.plain", "part": "modeline", "issue": "0%% shows a doubled percent", "suggested": "0%",
             "status": "open"},
        ]},
    ],
}


class ReviewRecordTest(unittest.TestCase):
    def test_the_comment_records_the_count_both_reviewers_and_the_critic(self):
        body = review.comment_body(RECORD)
        self.assertIn("## Visual review", body)
        self.assertIn("Changed scenarios reviewed: **2**", body)
        self.assertIn("| `edit.whichkey.leader` | **concern**: TUI 80x24: labels cut without … | **pass** |", body)
        self.assertIn("1 round(s)", body)
        self.assertIn("never changes the merge decision", body)

    def test_follow_ups_hold_concerns_disagreements_and_open_or_declined_critic_items(self):
        entries = review.followup_entries(RECORD, 4127, "https://example.test/c/1")
        self.assertEqual(len(entries), 4)
        self.assertTrue(all(e.startswith("- [ ] `") and "#4127" in e and "https://example.test/c/1" in e for e in entries))
        self.assertTrue(any("reviewers disagree" in e for e in entries))
        self.assertTrue(any("declined: owned by #4044" in e for e in entries))

    def test_a_clean_review_files_nothing(self):
        clean = {"scenarios": ["edit.plain"],
                 "verdicts": [{"scenario": "edit.plain", "reviewer": r, "verdict": "pass", "notes": ""} for r in ("a", "b")],
                 "critic": [{"round": 1, "items": []}]}
        self.assertEqual(review.followup_entries(clean, 1, "url"), [])


if __name__ == "__main__":
    unittest.main()
