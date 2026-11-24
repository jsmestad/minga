#!/usr/bin/env python3
"""Unit tests for design/tools/site_check.py."""

from __future__ import annotations

import contextlib
import importlib.util
import io
from pathlib import Path
import re
import sys
import tempfile
import unittest

SCRIPT_PATH = Path(__file__).resolve().parents[2] / "design" / "tools" / "site_check.py"
SPEC = importlib.util.spec_from_file_location("site_check", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
site_check = importlib.util.module_from_spec(SPEC)
sys.modules["site_check"] = site_check
SPEC.loader.exec_module(site_check)

# A phrase no code backs: the pattern never matches the one small file it searches.
UNBACKED = site_check.Claim("frobnicating undo", re.compile("no_such_symbol_zz"), ["design/tools/site_retired_keys.txt"], "not built")

PAGE = """<!DOCTYPE html>
<html>
<head{head_attrs}>
  <title>Lesson</title>
  {metadata}
</head>
<body><main><p>Plain copy.</p></main></body>
</html>
"""


class SiteCheckCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.keys = site_check.KeySets(shipped={"SPC", "SPC f f"}, designed={"SPC a y"})

    def check_page(self, metadata: str, head_attrs: str = "") -> list[str]:
        page = self.root / "page.html"
        page.write_text(PAGE.format(metadata=metadata, head_attrs=head_attrs), encoding="utf-8")
        findings: list[str] = []
        site_check.check_page(page, self.keys, [], [UNBACKED], findings)
        return findings

    def check_ts(self, source: str, baseline: str | None = "", claims: list | None = None) -> list[str]:
        """Check one lab source against a baseline. Pass None to keep the baseline file as it is."""
        src = self.root / "src"
        src.mkdir(exist_ok=True)
        (src / "lab.ts").write_text(source, encoding="utf-8")
        baseline_path = self.root / "baseline.tsv"
        if baseline is not None:
            baseline_path.write_text(baseline, encoding="utf-8")
        findings: list[str] = []
        site_check.check_ts_copy(src, baseline_path, [UNBACKED] if claims is None else claims, findings)
        return findings


class MetadataTest(SiteCheckCase):
    def test_meta_description_with_an_unbacked_phrase_fails(self) -> None:
        findings = self.check_page('<meta name="description" content="Try frobnicating undo in a live lab.">')

        self.assertEqual(len(findings), 1)
        self.assertIn("page.html:5 claim 'frobnicating undo'", findings[0])

    def test_planned_head_lets_metadata_name_an_unbacked_phrase(self) -> None:
        metadata = '<meta name="description" content="Try frobnicating undo in a live lab.">'

        self.assertEqual(self.check_page(metadata, head_attrs=' data-status="planned"'), [])

    def test_every_description_field_is_checked(self) -> None:
        fields = {
            "og": '<meta property="og:description" content="Has frobnicating undo.">',
            "twitter": '<meta name="twitter:description" content="Has frobnicating undo.">',
            "json-ld": '<script type="application/ld+json">{"@graph":[{"@type":"A","description":"Has frobnicating undo."}]}</script>',
        }
        for name, metadata in fields.items():
            with self.subTest(field=name):
                findings = self.check_page(metadata)
                self.assertEqual(len(findings), 1)
                self.assertIn("claim 'frobnicating undo'", findings[0])

    def test_metadata_key_must_be_shipped_unless_the_head_is_planned(self) -> None:
        metadata = '<meta name="description" content="Press SPC a y to keep a change.">'

        findings = self.check_page(metadata)
        self.assertEqual(len(findings), 1)
        self.assertIn("key 'SPC a y' not in the shipped keymap", findings[0])
        self.assertEqual(self.check_page(metadata, head_attrs=' data-status="planned"'), [])

    def test_self_closed_meta_tag_is_checked(self) -> None:
        findings = self.check_page('<meta name="description" content="Try frobnicating undo in a live lab." />')

        self.assertEqual(len(findings), 1)
        self.assertIn("claim 'frobnicating undo'", findings[0])

    def test_json_ld_description_shapes_are_checked(self) -> None:
        shapes = {
            "list": '{"description": ["Fine.", "Has frobnicating undo."]}',
            "@value object": '{"description": {"@language": "en", "@value": "Has frobnicating undo."}}',
            "list of @value objects": '{"@graph": [{"description": [{"@value": "Has frobnicating undo."}]}]}',
        }
        for name, body in shapes.items():
            with self.subTest(shape=name):
                findings = self.check_page(f'<script type="application/ld+json">{body}</script>')
                self.assertEqual(len(findings), 1)
                self.assertIn("claim 'frobnicating undo'", findings[0])

    def test_json_ld_type_with_a_charset_parameter_is_checked(self) -> None:
        script = '<script type="application/ld+json; charset=utf-8">{"description": "Has frobnicating undo."}</script>'

        self.assertEqual(len(self.check_page(script)), 1)

    def test_meta_tag_with_both_name_and_property_is_checked(self) -> None:
        meta = '<meta name="summary" property="og:description" content="Has frobnicating undo.">'

        self.assertEqual(len(self.check_page(meta)), 1)

    def test_json_ld_under_a_planned_head_passes(self) -> None:
        script = '<script type="application/ld+json">{"@graph": [{"description": "Has frobnicating undo. Press SPC a y."}]}</script>'

        self.assertEqual(len(self.check_page(script)), 2)
        self.assertEqual(self.check_page(script, head_attrs=' data-status="planned"'), [])

    def test_backed_metadata_passes(self) -> None:
        self.assertEqual(self.check_page('<meta name="description" content="Press SPC f f to find a file.">'), [])

    def test_json_ld_that_does_not_parse_fails(self) -> None:
        findings = self.check_page('<script type="application/ld+json">{"description": </script>')

        self.assertEqual(len(findings), 1)
        self.assertIn("markup 'application/ld+json'", findings[0])


class LabCopyTest(SiteCheckCase):
    def test_new_key_legend_fails_and_points_at_the_page_html(self) -> None:
        findings = self.check_ts('export const hint = "Press SPC a y to keep";\n')

        self.assertEqual(len(findings), 1)
        self.assertIn("lab.ts:1 ts-copy 'SPC a y'", findings[0])
        self.assertIn("Move the copy into the page HTML", findings[0])

    def test_new_claim_phrase_fails(self) -> None:
        findings = self.check_ts("const html = `<p>${n} lines. Frobnicating undo keeps yours.</p>`;\n")

        self.assertEqual(len(findings), 1)
        self.assertIn("ts-copy 'frobnicating undo'", findings[0])

    def test_baselined_copy_passes(self) -> None:
        source = 'const a = "SPC a y keeps";\nconst b = `<kbd>SPC a y</kbd> ${a ? "frobnicating undo" : ""}`;\n'
        baseline = "# kind\tvalue\tcount\nkey\tSPC a y\t2\nclaim\tfrobnicating undo\t1\n"

        self.assertEqual(self.check_ts(source, baseline), [])

    def test_one_more_occurrence_than_the_baseline_fails(self) -> None:
        source = 'const a = "SPC a y keeps";\nconst b = "SPC a y again";\n'

        findings = self.check_ts(source, "key\tSPC a y\t1\n")

        self.assertEqual(len(findings), 1)
        self.assertIn("2 in lab.ts, the baseline allows 1", findings[0])

    def test_copy_is_found_whatever_code_surrounds_it(self) -> None:
        sources = {
            "after a division": 'let i = 0; const w = i++ / 2; const s = "Press SPC a y"; const z = w / 3;\n',
            "after an escaped quote": 'const s = "Press \\"SPC a y\\" to open";\n',
            "before an escaped newline": 'const s = "Press SPC a y\\nthen wait";\n',
            "one tag per key": "const s = `<kbd>SPC</kbd> <kbd>a</kbd> <kbd>y</kbd>`;\n",
            "non-breaking spaces": "const s = `Press SPC&nbsp;a&nbsp;y`;\n",
            "quoted inside a template": 'const s = `bind :normal, "SPC a y", :keep`;\n',
            "in an aria-label": 'const s = `<div class="stage" aria-label="Type SPC a y to keep"></div>`;\n',
        }
        for name, source in sources.items():
            with self.subTest(case=name):
                findings = self.check_ts(source)
                self.assertEqual(len(findings), 1)
                self.assertIn("ts-copy 'SPC a y'", findings[0])

    def test_claim_split_by_markup_is_found(self) -> None:
        findings = self.check_ts('const s = "<b>frobnicating</b> undo";\n')

        self.assertEqual(len(findings), 1)
        self.assertIn("ts-copy 'frobnicating undo'", findings[0])

    def test_valid_code_never_fails_the_scan(self) -> None:
        source = (
            "function f(s){ return /[\"']/.test(s) }\n"
            'const pending = key === " " ? "SPC" : "";\n'
            "const legend = 'SPC ' + key;\n"
            "const label = `<span>SPC</span> Which-key`;\n"
            'const open = "unterminated\n'
        )

        self.assertEqual(self.check_ts(source), [])

    def test_one_word_phrase_matches_as_written_only(self) -> None:
        claims = [site_check.Claim("Twist", re.compile("x"), [], ""), site_check.Claim("Orbit", re.compile("x"), [], "")]
        tags = 'const a = { kind: "twist" };\nswitch (k) { case "orbit": break; }\nconst c = "keep_Twist-row";\n'

        self.assertEqual(self.check_ts(tags, claims=claims), [])

        findings = self.check_ts('const s = "The Twist marks whose lines are whose";\n', claims=claims)
        self.assertEqual(len(findings), 1)
        self.assertIn("ts-copy 'Twist'", findings[0])

    def test_multi_word_phrase_ignores_case(self) -> None:
        findings = self.check_ts('const s = "FROBNICATING  Undo";\n')

        self.assertEqual(len(findings), 1)

    def test_comments_count(self) -> None:
        findings = self.check_ts("// press SPC a y here\n")

        self.assertEqual(len(findings), 1)
        self.assertIn("ts-copy 'SPC a y'", findings[0])

    def test_range_legend_counts_as_one_sequence(self) -> None:
        findings = self.check_ts('const note = "Pinned to SPC 1-4 (macOS too)";\n')

        self.assertEqual(len(findings), 1)
        self.assertIn("ts-copy 'SPC 1-4'", findings[0])

    def test_copy_that_moved_to_another_file_needs_no_baseline_change(self) -> None:
        baseline = "key\tSPC a y\t1\n"
        self.assertEqual(self.check_ts('const a = "SPC a y keeps";\n', baseline), [])

        (self.root / "src" / "lab.ts").unlink()
        (self.root / "src" / "labs").mkdir()
        (self.root / "src" / "labs" / "review.ts").write_text('const a = "SPC a y keeps";\n', encoding="utf-8")
        findings: list[str] = []
        site_check.check_ts_copy(self.root / "src", self.root / "baseline.tsv", [UNBACKED], findings)

        self.assertEqual(findings, [])

    def test_deleted_copy_makes_the_row_stale_and_prune_removes_it(self) -> None:
        baseline = "# header\nkey\tSPC a y\t2\nkey\tSPC a d\t1\n"
        findings = self.check_ts('const a = "SPC a d rejects";\n', baseline)

        self.assertEqual(len(findings), 1)
        self.assertIn("baseline.tsv:2 ts-baseline 'SPC a y' stale row", findings[0])
        self.assertIn("--prune-ts-baseline", findings[0])

        site_check.write_ts_baseline(self.root / "src", self.root / "baseline.tsv", [UNBACKED])

        self.assertEqual((self.root / "baseline.tsv").read_text(encoding="utf-8"), "# header\nkey\tSPC a d\t1\n")
        self.assertEqual(self.check_ts('const a = "SPC a d rejects";\n', None), [])

    def test_baseline_count_above_the_sources_fails_and_prune_lowers_it(self) -> None:
        findings = self.check_ts('const a = "SPC a y keeps";\n', "key\tSPC a y\t3\n")

        self.assertEqual(len(findings), 1)
        self.assertIn("the sources have 1 of this key, the row says 3", findings[0])

        site_check.write_ts_baseline(self.root / "src", self.root / "baseline.tsv", [UNBACKED])

        self.assertEqual((self.root / "baseline.tsv").read_text(encoding="utf-8"), "key\tSPC a y\t1\n")

    def test_prune_never_adds_a_row_or_raises_a_count(self) -> None:
        self.check_ts('const a = "SPC a y, SPC a y, SPC a d, frobnicating undo";\n', "# header\nkey\tSPC a y\t1\n")

        site_check.write_ts_baseline(self.root / "src", self.root / "baseline.tsv", [UNBACKED])

        self.assertEqual((self.root / "baseline.tsv").read_text(encoding="utf-8"), "# header\nkey\tSPC a y\t1\n")

    def test_malformed_baseline_row_fails(self) -> None:
        findings = self.check_ts('const a = "plain";\n', "lab.ts\tkey\tSPC a y\t1\n")

        self.assertEqual(len(findings), 1)
        self.assertIn("baseline.tsv:1 ts-baseline", findings[0])


class CommandLineTest(unittest.TestCase):
    def test_prune_with_a_page_argument_is_rejected_and_writes_nothing(self) -> None:
        before = site_check.TS_BASELINE.read_text(encoding="utf-8")
        for argv in (["--prune-ts-baseline", "site/index.html"], ["site/index.html", "--prune-ts-baseline"], ["--no-such-flag"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(site_check.main(argv), 2)
                self.assertIn("--prune-ts-baseline", stderr.getvalue())

        self.assertEqual(site_check.TS_BASELINE.read_text(encoding="utf-8"), before)

    def test_pruning_the_committed_baseline_changes_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "baseline.tsv"
            copy.write_text(site_check.TS_BASELINE.read_text(encoding="utf-8"), encoding="utf-8")
            site_check.write_ts_baseline(site_check.TS_SRC, copy, site_check.load_claims())

            self.assertEqual(copy.read_text(encoding="utf-8"), site_check.TS_BASELINE.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
