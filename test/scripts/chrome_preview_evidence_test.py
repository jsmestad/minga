"""Unit fixtures for evidence accounting, not screenshots or visual approval."""

import argparse
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/chrome_preview_evidence.py"
SPEC = importlib.util.spec_from_file_location("chrome_preview_evidence", SCRIPT)
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


class ChromePreviewEvidenceTest(unittest.TestCase):
    def test_registry_inventory_uses_the_view_switch_not_unrelated_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / "PreviewRegistry.swift"
            registry.write_text('''
                static func view(named name: String) -> some View {
                    switch name {
                    case "RowView": row()
                    case "PanelView": panel()
                    default: error()
                    }
                }
                func anotherSwitch() { switch x { case "NotAPreview": break } }
            ''')
            self.assertEqual(evidence.registry_names(registry), ["RowView", "PanelView"])

    def test_base_supplement_preserves_existing_views_and_uses_identical_new_fixtures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before, after = root / "before", root / "after"
            registry = (
                "    static func view(named name: String) -> some View {\n"
                "        switch name {\n"
                '        case "ExistingView": existing()\n'
                "        default: error()\n"
                "        }\n"
                "    }\n"
            )
            policy = (
                "    static func size(named name: String) -> CGSize {\n"
                "        switch name {\n"
                '        case "ExistingView": existingSize\n'
                "        default: defaultSize\n"
                "        }\n"
                "    }\n"
            )
            for checkout in [before, after]:
                sources = checkout / "macos/Sources"
                (sources / "Views").mkdir(parents=True)
                (sources / "PreviewRegistry.swift").write_text(registry)
                (sources / "PreviewSnapshotPolicy.swift").write_text(policy)
                (sources / "PreviewHostApp.swift").write_text("shared preview capture transport")
                (sources / "Views/ExistingView.swift").write_text(f"production view from {checkout.name}")
                project = "".join(
                    f'  {target}:\n    sources:\n      - path: Sources\n        excludes:\n          - "PreviewRegistry.swift"\n'
                    for target in ["Minga", "MingaTests", "NativeRenderPerformance"]
                )
                project += '  PreviewHost:\n    sources:\n      - path: Sources\n'
                (checkout / "macos/project.yml").write_text(project)
            cases = (
                "        // BEGIN chrome migration preview cases\n"
                '        case "AddedView": added()\n'
                "        // END chrome migration preview cases\n"
            )
            sizes = (
                "        // BEGIN chrome migration preview sizes\n"
                '        case "AddedView": addedSize\n'
                "        // END chrome migration preview sizes\n"
            )
            after_sources = after / "macos/Sources"
            (after_sources / "PreviewRegistry.swift").write_text(
                registry.replace("        default:", cases + "        default:")
            )
            (after_sources / "PreviewSnapshotPolicy.swift").write_text(
                policy.replace("        default:", sizes + "        default:")
            )
            fixture_name = "PreviewRegistry+ChromeMigration.swift"
            fixture = "identical fixture construction for both revisions"
            (after_sources / fixture_name).write_text(fixture)
            args = argparse.Namespace(before_root=before, after_root=after, output=root / "supplement.json")
            with patch.object(evidence, "revision", side_effect=["base-sha", "head-sha"]):
                evidence.prepare_base(args)
            before_sources = before / "macos/Sources"
            self.assertEqual(
                (before_sources / "Views/ExistingView.swift").read_text(), "production view from before"
            )
            self.assertEqual(
                evidence.registry_names(before_sources / "PreviewRegistry.swift"), ["ExistingView", "AddedView"]
            )
            self.assertIn('case "ExistingView": existing()', (before_sources / "PreviewRegistry.swift").read_text())
            self.assertIn(sizes, (before_sources / "PreviewSnapshotPolicy.swift").read_text())
            prepared_project = (before / "macos/project.yml").read_text()
            self.assertEqual(prepared_project.count('- "PreviewRegistry+*.swift"'), 3)
            self.assertEqual(prepared_project.split("  PreviewHost:")[1], project.split("  PreviewHost:")[1])
            manifest = json.loads(args.output.read_text())
            self.assertEqual(manifest["originalBaseNames"], ["ExistingView"])
            self.assertEqual(manifest["comparisonNames"], ["ExistingView", "AddedView"])
            # Preparing an already supplemented base must not duplicate registry cases.
            with patch.object(evidence, "revision", side_effect=["base-sha", "head-sha"]):
                evidence.prepare_base(args)
            self.assertEqual(
                evidence.registry_names(before_sources / "PreviewRegistry.swift"), ["ExistingView", "AddedView"]
            )
            self.assertEqual((before / "macos/project.yml").read_text(), prepared_project)
            args.before_root = after
            with self.assertRaises(ValueError):
                evidence.prepare_base(args)

    def test_pixel_manifest_distinguishes_equal_metadata_from_changed_pixels(self):
        from PIL import Image, PngImagePlugin

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for revision in ["before", "after"]:
                registry = root / revision / "macos/Sources/PreviewRegistry.swift"
                registry.parent.mkdir(parents=True)
                registry.write_text('''
                    static func view(named name: String) -> some View {
                        switch name {
                        case "SameView": same()
                        case "ChangedView": changed()
                        default: error()
                        }
                    }
                ''')
                captures = root / revision / "captures"
                captures.mkdir()
                image = Image.new("RGBA", (4, 4), (20, 30, 40, 255))
                metadata = PngImagePlugin.PngInfo()
                metadata.add_text("revision", revision)
                image.save(captures / "SameView.png", pnginfo=metadata)
                if revision == "after":
                    image.putpixel((2, 1), (21, 30, 40, 255))
                image.save(captures / "ChangedView.png")
            inventory = root / "inventory.json"
            inventory.write_text(json.dumps({"snaps": [], "unpreviewedViews": [], "derivedValues": []}))
            args = argparse.Namespace(
                before=root / "before/captures", after=root / "after/captures",
                before_root=root / "before", after_root=root / "after",
                inventory=inventory, output=root / "evidence",
            )
            with patch.object(evidence, "revision", side_effect=["base-sha", "head-sha"]):
                evidence.compare(args)
            manifest = json.loads((args.output / "pixel-change-manifest.json").read_text())
            self.assertEqual(manifest["pixelIdenticalViews"], ["SameView"])
            self.assertEqual(manifest["changedViews"], ["ChangedView"])
            self.assertEqual(manifest["unexpectedPixelChanges"], ["ChangedView"])
            changed = next(view for view in manifest["views"] if view["view"] == "ChangedView")
            self.assertEqual(changed["changedPixels"], 1)
            self.assertEqual(changed["differenceBounds"], [2, 1, 3, 2])
            self.assertTrue((args.output / "contact-sheet-01.png").is_file())
            (args.before / "SameView.png").unlink()
            with self.assertRaises(FileNotFoundError):
                evidence.compare(args)


if __name__ == "__main__":
    unittest.main()
