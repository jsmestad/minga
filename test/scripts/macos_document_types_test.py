#!/usr/bin/env python3
"""Minga.app is offered under Finder's "Open With" for every file, and claims defaults only for text.

macOS ignores CFBundleTypeExtensions whenever LSItemContentTypes is present, and many files Minga edits
have no text type at all (.ex is a dynamic type, .exs belongs to Logic Pro, dotfiles are plain data). So
the app declares content types only, with a catch-all at Alternate rank.
"""

from pathlib import Path
import plistlib
import unittest

INFO_PLIST = Path(__file__).resolve().parents[2] / "macos/Info.plist"


class MacosDocumentTypesTest(unittest.TestCase):
    def setUp(self):
        with INFO_PLIST.open("rb") as stream:
            self.document_types = plistlib.load(stream)["CFBundleDocumentTypes"]

    def claims(self, rank):
        return {
            content_type
            for entry in self.document_types if entry.get("LSHandlerRank") == rank
            for content_type in entry["LSItemContentTypes"]
        }

    def test_every_file_is_offered_without_claiming_its_default(self):
        self.assertEqual(self.claims("Alternate"), {"public.data"})

    def test_text_types_are_default_claims(self):
        self.assertEqual(self.claims("Default"),
                         {"public.plain-text", "public.source-code", "public.json", "public.yaml"})

    def test_every_entry_is_an_editor_declared_by_content_type_with_an_explicit_rank(self):
        for entry in self.document_types:
            with self.subTest(name=entry.get("CFBundleTypeName")):
                self.assertEqual(entry["CFBundleTypeRole"], "Editor")
                self.assertIn(entry.get("LSHandlerRank"), ("Default", "Alternate"))
                self.assertTrue(entry.get("LSItemContentTypes"))
                # Ignored by macOS beside LSItemContentTypes, and deprecated on its own.
                self.assertNotIn("CFBundleTypeExtensions", entry)


if __name__ == "__main__":
    unittest.main()
