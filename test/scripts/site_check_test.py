#!/usr/bin/env python3
"""Unit tests for design/tools/site_check.py."""

from __future__ import annotations

import importlib.util
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

    def check_ts(self, source: str, baseline: str) -> list[str]:
        src = self.root / "src"
        src.mkdir(exist_ok=True)
        (src / "lab.ts").write_text(source, encoding="utf-8")
        baseline_path = self.root / "baseline.tsv"
        baseline_path.write_text(baseline, encoding="utf-8")
        findings: list[str] = []
        site_check.check_ts_copy(src, baseline_path, [UNBACKED], findings)
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

    def test_backed_metadata_passes(self) -> None:
        self.assertEqual(self.check_page('<meta name="description" content="Press SPC f f to find a file.">'), [])

    def test_json_ld_that_does_not_parse_fails(self) -> None:
        findings = self.check_page('<script type="application/ld+json">{"description": </script>')

        self.assertEqual(len(findings), 1)
        self.assertIn("markup 'application/ld+json'", findings[0])


class LabCopyTest(SiteCheckCase):
    def test_new_key_legend_in_a_string_fails(self) -> None:
        findings = self.check_ts('export const hint = "Press SPC a y to keep";\n', "")

        self.assertEqual(len(findings), 1)
        self.assertIn("lab.ts:1 ts-copy 'SPC a y'", findings[0])

    def test_new_claim_phrase_in_a_template_fails(self) -> None:
        findings = self.check_ts("const html = `<p>${n} lines. Frobnicating undo keeps yours.</p>`;\n", "")

        self.assertEqual(len(findings), 1)
        self.assertIn("ts-copy 'frobnicating undo'", findings[0])

    def test_baselined_copy_passes(self) -> None:
        source = 'const a = "SPC a y keeps";\nconst b = `<kbd>SPC a y</kbd> ${a ? "frobnicating undo" : ""}`;\n'
        baseline = "# file\tkind\tvalue\tcount\nlab.ts\tkey\tSPC a y\t2\nlab.ts\tclaim\tfrobnicating undo\t1\n"

        self.assertEqual(self.check_ts(source, baseline), [])

    def test_one_more_occurrence_than_the_baseline_fails(self) -> None:
        source = 'const a = "SPC a y keeps";\nconst b = "SPC a y again";\n'

        findings = self.check_ts(source, "lab.ts\tkey\tSPC a y\t1\n")

        self.assertEqual(len(findings), 1)
        self.assertIn("2 here, the baseline allows 1", findings[0])

    def test_stale_baseline_row_fails(self) -> None:
        findings = self.check_ts('export const hint = "Press a key";\n', "lab.ts\tkey\tSPC a y\t1\n")

        self.assertEqual(len(findings), 1)
        self.assertIn("baseline.tsv:1 ts-baseline 'SPC a y' stale row", findings[0])
        self.assertIn("remove the row", findings[0])

    def test_baseline_count_above_the_sources_fails(self) -> None:
        findings = self.check_ts('const a = "SPC a y keeps";\n', "lab.ts\tkey\tSPC a y\t3\n")

        self.assertEqual(len(findings), 1)
        self.assertIn("lower its count to 1", findings[0])

    def test_code_that_is_not_copy_is_ignored(self) -> None:
        source = (
            "// SPC a y in a comment\n"
            "/* frobnicating undo */\n"
            'const pending = key === " " ? "SPC" : "";\n'
            'const cls = "keep_frobnicating undo_row";\n'
            "const re = /SPC a y['\"]/g;\n"
            "const ratio = a / b; // SPC a d\n"
        )

        self.assertEqual(self.check_ts(source, ""), [])

    def test_range_legend_counts_as_one_sequence(self) -> None:
        findings = self.check_ts('const note = "Pinned to SPC 1-4 (macOS too)";\n', "")

        self.assertEqual(len(findings), 1)
        self.assertIn("ts-copy 'SPC 1-4'", findings[0])

    def test_unterminated_string_is_reported_instead_of_skipped(self) -> None:
        findings = self.check_ts('const a = "SPC a y\n', "")

        self.assertEqual(len(findings), 1)
        self.assertIn("cannot read the string literals", findings[0])

    def test_malformed_baseline_row_fails(self) -> None:
        findings = self.check_ts('const a = "plain";\n', "lab.ts\tkey\tSPC a y\n")

        self.assertEqual(len(findings), 1)
        self.assertIn("baseline.tsv:1 ts-baseline", findings[0])


class RepositoryTest(unittest.TestCase):
    def test_pruning_the_committed_baseline_changes_nothing(self) -> None:
        claims = site_check.load_claims()
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "baseline.tsv"
            copy.write_text(site_check.TS_BASELINE.read_text(encoding="utf-8"), encoding="utf-8")
            site_check.write_ts_baseline(site_check.TS_SRC, copy, claims)

            self.assertEqual(copy.read_text(encoding="utf-8"), site_check.TS_BASELINE.read_text(encoding="utf-8"))

    def test_pruning_cannot_add_rows_or_raise_counts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            src.mkdir()
            (src / "lab.ts").write_text('const a = "SPC a y, SPC a y, SPC a d";\n', encoding="utf-8")
            baseline = Path(tmp) / "baseline.tsv"
            baseline.write_text("# header\nlab.ts\tkey\tSPC a y\t1\nlab.ts\tkey\tSPC a p\t1\n", encoding="utf-8")

            site_check.write_ts_baseline(src, baseline, [])

            self.assertEqual(baseline.read_text(encoding="utf-8"), "# header\nlab.ts\tkey\tSPC a y\t1\n")


if __name__ == "__main__":
    unittest.main()
