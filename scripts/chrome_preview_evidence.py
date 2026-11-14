#!/usr/bin/env python3
"""Inventory PreviewRegistry and compare real PreviewHost captures for PR review.

Pixel differences are evidence, not a pass/fail gate. Missing captures are errors.
The names command uses only the standard library; comparison needs Pillow.
"""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path


def registry_names(registry):
    source = registry.read_text()
    start = source.index("static func view(named name: String)")
    end = source.index("        default:", start)
    names = re.findall(r'^\s*case\s+"([A-Za-z][A-Za-z0-9]+)":', source[start:end], re.MULTILINE)
    if not names or len(names) != len(set(names)):
        raise ValueError(f"empty or duplicate preview registry: {registry}")
    return names


def revision(root):
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()


def preview_block(source, kind):
    start_marker = f"        // BEGIN chrome migration preview {kind}\n"
    end_marker = f"        // END chrome migration preview {kind}\n"
    start = source.index(start_marker)
    end = source.index(end_marker, start) + len(end_marker)
    return source[start:end]


def install_preview_block(source, block, kind, signature):
    marker = f"        // BEGIN chrome migration preview {kind}\n"
    if marker in source:
        return source.replace(preview_block(source, kind), block, 1)
    insertion = source.index("        default:", source.index(signature))
    return source[:insertion] + block + source[insertion:]


def isolate_preview_extensions(project):
    """Match each non-preview target's existing owner exclusion without copying other build settings."""
    lines = project.splitlines(keepends=True)
    result = []
    owner_count = 0
    exclusion = '- "PreviewRegistry+*.swift"'
    for index, line in enumerate(lines):
        result.append(line)
        if line.strip() != '- "PreviewRegistry.swift"':
            continue
        owner_count += 1
        if index + 1 == len(lines) or lines[index + 1].strip() != exclusion:
            indentation = line[:len(line) - len(line.lstrip())]
            result.append(f"{indentation}{exclusion}\n")
    if owner_count != 3:
        raise ValueError(f"expected three non-preview registry owner exclusions, found {owner_count}")
    return "".join(result)


def swift_fixture_member(source, signature):
    """Locate one known preview-only member, refusing missing/ambiguous inputs."""
    if source.count(signature) != 1:
        raise ValueError(f"expected one preview fixture member: {signature}")
    start = source.rfind("\n", 0, source.index(signature)) + 1
    opening = source.index("{", source.index(signature))
    depth = 1
    cursor = opening + 1
    while cursor < len(source) and depth:
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
        cursor += 1
    if depth:
        raise ValueError(f"unclosed preview fixture member: {signature}")
    return start, cursor


def shared_capture_transport(before_capture, after_capture):
    """Share capture methods without transplanting revision-specific readiness or metadata."""
    receipts = []
    for signature in [
        "private func captureSettledPNG(",
        "private func captureWindowPNG(",
        "private func encodePNG(",
        "private func assertBitmapDimensions(",
        "private func assertCGImageDimensions(",
        "private nonisolated static func captureRenderedWindow(",
    ]:
        start, end = swift_fixture_member(after_capture, signature)
        replacement = after_capture[start:end]
        old_start, old_end = swift_fixture_member(before_capture, signature)
        original = before_capture[old_start:old_end]
        before_capture = before_capture[:old_start] + replacement + before_capture[old_end:]
        receipts.append({
            "path": "macos/Sources/PreviewHostApp.swift", "member": signature,
            "originalSha256": hashlib.sha256(original.encode()).hexdigest(),
            "sha256": hashlib.sha256(replacement.encode()).hexdigest(),
            "scope": "identical preview-only PNG/compositor capture transport; revision-local readiness and metadata preserved",
        })
    return before_capture, receipts


def shared_capture_support(before_registry, after_registry, before_fixtures, after_fixtures):
    """Share only capture-owned fixture members, not the base's production views."""
    receipts = []
    property_line = "    private(set) static var captureAppState: AppState?"
    if property_line not in before_registry:
        if before_registry.count("enum PreviewRegistry {") != 1:
            raise ValueError("base has no unique PreviewRegistry owner for capture support")
        before_registry = before_registry.replace("enum PreviewRegistry {", f"enum PreviewRegistry {{\n{property_line}", 1)
    for filename, signatures in [
        ("PreviewRegistry.swift", [
            "static func productionPreviewAppState(", "static func previewEditorNSView(",
            "static func previewThemeSlots(", "static func previewFailureView(",
            "static func commitPreviewEditorFrame(",
        ]),
        ("PreviewFixtures.swift", [
            "static var themeSlots:", "static func applyPreviewTheme(", "static func statusBarUpdate(",
        ]),
    ]:
        current = before_registry if filename == "PreviewRegistry.swift" else before_fixtures
        proposed = after_registry if filename == "PreviewRegistry.swift" else after_fixtures
        for signature in signatures:
            start, end = swift_fixture_member(proposed, signature)
            replacement = proposed[start:end]
            if signature in current:
                old_start, old_end = swift_fixture_member(current, signature)
                original = current[old_start:old_end]
                current = current[:old_start] + replacement + current[old_end:]
            elif signature == "static var themeSlots:":
                insertion = current.index("public enum PreviewFixtures {") + len("public enum PreviewFixtures {")
                original = ""
                current = current[:insertion] + "\n" + replacement + "\n" + current[insertion:]
            else:
                raise ValueError(f"base lacks required capture fixture support: {signature}")
            receipts.append({
                "path": f"macos/Sources/{filename}", "member": signature,
                "originalSha256": hashlib.sha256(original.encode()).hexdigest(),
                "sha256": hashlib.sha256(replacement.encode()).hexdigest(),
                "scope": "identical preview-only capture ownership, complete Doom One palette, frozen fixture state and explicit failure",
            })
        if filename == "PreviewRegistry.swift":
            before_registry = current
        else:
            before_fixtures = current
    return before_registry, before_fixtures, receipts


def prepare_base(args):
    """Install identical fixtures and capture methods, preserving base production views and readiness."""
    if args.before_root.resolve() == args.after_root.resolve():
        raise ValueError("before and after must be separate checkouts")
    sources = Path("macos/Sources")
    registry_path = sources / "PreviewRegistry.swift"
    before_names = registry_names(args.before_root / registry_path)
    changes = []
    after_registry = (args.after_root / registry_path).read_text()
    has_capture_support = "private(set) static var captureAppState: AppState?" in after_registry
    support = None
    original_policy_hash = hashlib.sha256((args.before_root / sources / "PreviewSnapshotPolicy.swift").read_bytes()).hexdigest()
    if has_capture_support:
        fixture_path = sources / "PreviewFixtures.swift"
        # Validate every required member before mutating the baseline.
        support = shared_capture_support(
            (args.before_root / registry_path).read_text(), after_registry,
            (args.before_root / fixture_path).read_text(),
            (args.after_root / fixture_path).read_text())
    capture = sources / "PreviewHostApp.swift"
    original_capture_hash = hashlib.sha256((args.before_root / capture).read_bytes()).hexdigest()
    capture_source, capture_receipts = shared_capture_transport(
        (args.before_root / capture).read_text(),
        (args.after_root / capture).read_text())
    for filename, kind, signature in [
        ("PreviewRegistry.swift", "cases", "static func view(named name: String)"),
        ("PreviewSnapshotPolicy.swift", "sizes", "static func size(named name: String)"),
    ]:
        path = sources / filename
        block = preview_block((args.after_root / path).read_text(), kind)
        destination = args.before_root / path
        destination.write_text(install_preview_block(destination.read_text(), block, kind, signature))
        changes.append({"path": str(path), "scope": f"preview {kind} block only",
                        "sha256": hashlib.sha256(block.encode()).hexdigest()})
    fixture = sources / "PreviewRegistry+ChromeMigration.swift"
    shutil.copyfile(args.after_root / fixture, args.before_root / fixture)
    changes.append({"path": str(fixture), "scope": "identical preview-only fixture definitions",
                    "sha256": hashlib.sha256((args.before_root / fixture).read_bytes()).hexdigest()})
    (args.before_root / capture).write_text(capture_source)
    changes.append({"path": str(capture), "scope": "shared preview-only capture methods; base readiness and metadata remain revision-local",
                    "originalSha256": original_capture_hash,
                    "sha256": hashlib.sha256((args.before_root / capture).read_bytes()).hexdigest()})
    changes.extend(capture_receipts)
    if support is not None:
        registry, fixtures, receipts = support
        registry = install_preview_block(
            registry, preview_block(after_registry, "cases"), "cases", "static func view(named name: String)")
        (args.before_root / registry_path).write_text(registry)
        fixture_path = sources / "PreviewFixtures.swift"
        (args.before_root / fixture_path).write_text(fixtures)
        changes.extend(receipts)
        for relative in [sources / "PreviewSnapshotPolicy.swift"]:
            destination = args.before_root / relative
            shutil.copyfile(args.after_root / relative, destination)
            changes.append({"path": str(relative), "scope": "identical complete screenshot dimensions and failure policy",
                            "originalSha256": original_policy_hash,
                            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()})
        changes.append({"path": str(registry_path), "scope": "retained preview AppState for actual renderer/font/readiness receipts",
                        "sha256": hashlib.sha256(registry.encode()).hexdigest()})
    project = Path("macos/project.yml")
    destination = args.before_root / project
    destination.write_text(isolate_preview_extensions(destination.read_text()))
    changes.append({"path": str(project), "scope": "exclude PreviewRegistry+*.swift alongside the owner in the three non-preview targets",
                    "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()})
    manifest = {
        "baseRevision": revision(args.before_root),
        "fixtureRevision": revision(args.after_root),
        "scope": "Only preview dispatch, capture policy/transport members, explicitly hashed preview fixture support, and target membership exclusions are installed. Production Views sources and capture readiness/metadata remain those of the base checkout.",
        "originalBaseNames": before_names,
        "comparisonNames": registry_names(args.before_root / registry_path),
        "fixtureChanges": changes,
        "evidenceLimit": (
            "AgentChromeView on both revisions uses the corrected complete Doom One fixture palette, retained production renderer, "
            "visible file-tree registration and immutable completed transcript. This compares production views under the same repaired "
            "fixture, not the old unreadable neutral-gray baseline or live editor behavior. Capture readiness and metadata remain revision-local."
            if has_capture_support else "Additional preview fixtures and shared capture transport only."),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n")


def preview_sources(name, supplemental=None):
    """Source-level candidates, not a claim that a particular fixture displays every state."""
    if name in (supplemental or {}):
        return [supplemental[name]["file"]]
    tree = ["Sidebar/FileTreeView.swift", "Sidebar/FileTreeRowView.swift", "Sidebar/FileTreeHeaderView.swift",
            "Sidebar/SidebarHeaderButton.swift"]
    git = ["Sidebar/GitStatusView.swift", "Sidebar/GitStatusHeaderView.swift", "Sidebar/SidebarHeaderButton.swift"]
    chat = [f"Agent/{view}.swift" for view in
            ["AgentChatView", "AgentChatHeaderView", "AgentPromptView", "AgentToolCallCard", "AgentApprovalCard"]]
    shell = tree + [f"EditorChrome/{view}.swift" for view in
                    ["TabBarView", "StatusBarView", "BreadcrumbBar", "WorkspaceHeaderView", "BottomPanelView", "EmptyStateView"]]
    shell += [f"Overlays/{view}.swift" for view in
              ["CompletionOverlay", "HoverPopupOverlay", "SignatureHelpOverlay", "NotificationCenterView"]]
    if name in {"EditorChromeView", "AgentChromeView", "DiagnosticsEditorView", "InsertModeEditorView",
                "HoverEditorView", "SignatureHelpEditorView"}:
        return shell + (chat if name == "AgentChromeView" else [])
    if name.startswith("FileTree"):
        return tree
    if name.startswith("GitStatus"):
        return git
    if name.startswith("AgentChat"):
        return chat
    if name.startswith("Notification"):
        return ["Overlays/NotificationCenterView.swift"]
    if name.startswith("TabBar"):
        return ["EditorChrome/TabBarView.swift"]
    if name.startswith("EmptyState"):
        return ["EditorChrome/EmptyStateView.swift"]
    if name.startswith("BottomPanel"):
        return ["EditorChrome/BottomPanelView.swift", "Overlays/MessagesContentView.swift"]
    if name == "SettingsView":
        return ["Settings/AppearanceSettingsView.swift", "Settings/EditorSettingsView.swift", "Settings/KeybindingsSettingsView.swift"]
    if name in {"LatencyHUDOverlay", "LatencyHUDEmpty"}:
        return ["Overlays/LatencyHUDOverlay.swift"]
    return [f"{directory}/{name}.swift" for directory in ["Overlays", "EditorChrome", "Sidebar"]]


def compare(args):
    from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageOps

    inventory = json.loads(args.inventory.read_text())
    before_names = registry_names(args.before_root / "macos/Sources/PreviewRegistry.swift")
    after_names = registry_names(args.after_root / "macos/Sources/PreviewRegistry.swift")
    names = sorted(set(before_names) | set(after_names))
    args.output.mkdir(parents=True, exist_ok=True)
    records = []
    sheets = []
    font = ImageFont.load_default(size=15)
    tile_width, tile_height, label_height, rows_per_page = 420, 250, 48, 6

    for offset, name in enumerate(names):
        images = []
        for directory, registered in [(args.before, before_names), (args.after, after_names)]:
            path = directory / f"{name}.png"
            if name in registered and not path.is_file():
                raise FileNotFoundError(f"registered preview was not captured: {path}")
            images.append(Image.open(path).convert("RGBA") if name in registered else None)
        before, after = images
        width = max(image.width for image in images if image is not None)
        height = max(image.height for image in images if image is not None)
        normalized = []
        for image in images:
            canvas = Image.new("RGBA", (width, height))
            if image is not None:
                canvas.paste(image, (0, 0))
            normalized.append(canvas)
        difference = ImageChops.difference(*normalized)
        mask = difference.getchannel("R")
        for channel in ["G", "B", "A"]:
            mask = ImageChops.lighter(mask, difference.getchannel(channel))
        changed_pixels = width * height - mask.histogram()[0]
        identical = before is not None and after is not None and before.size == after.size and changed_pixels == 0
        sources = preview_sources(name, inventory.get("supplementalPreviews"))
        candidates = [snap for snap in inventory["snaps"] if snap["file"] in sources]
        record = {
            "view": name,
            "beforeSize": list(before.size) if before is not None else None,
            "afterSize": list(after.size) if after is not None else None,
            "pixelIdentical": identical,
            "changedPixels": changed_pixels,
            "comparedPixels": width * height,
            "differenceBounds": mask.getbbox(),
            "candidateTokenChanges": candidates if not identical else [],
            "needsInvestigation": not identical and not candidates,
        }
        records.append(record)

        row = offset % rows_per_page
        if row == 0:
            sheets.append(Image.new("RGB", (tile_width * 3, (tile_height + label_height) * rows_per_page), "#202124"))
        sheet = sheets[-1]
        draw = ImageDraw.Draw(sheet)
        status = "identical" if identical else f"{changed_pixels:,} changed pixels"
        heatmap = ImageOps.colorize(mask.point(lambda value: min(255, value * 4)), "black", "#ff7547")
        for column, (image, label) in enumerate([(before, "before"), (after, "after"), (heatmap, "absolute difference x4")]):
            x, y = column * tile_width, row * (tile_height + label_height)
            draw.text((x + 8, y + 4), f"{name} / {label}", fill="white", font=font)
            draw.text((x + 8, y + 24), status, fill="#c4c4c4", font=font)
            if image is not None:
                thumbnail = ImageOps.contain(image.convert("RGB"), (tile_width - 16, tile_height - 8))
                sheet.paste(thumbnail, (x + 8, y + label_height))
            else:
                draw.text((x + 8, y + label_height + 8), "not registered in this revision", fill="white", font=font)

    for index, sheet in enumerate(sheets, 1):
        sheet.save(args.output / f"contact-sheet-{index:02}.png")
    manifest = {
        "beforeRevision": revision(args.before_root),
        "afterRevision": revision(args.after_root),
        "comparison": "exact decoded RGBA pixels on the same macOS runner; no tolerance or pixel gate",
        "attribution": "candidateTokenChanges are source-level review candidates, not automatic causal proof",
        "changedViews": [record["view"] for record in records if not record["pixelIdentical"]],
        "pixelIdenticalViews": [record["view"] for record in records if record["pixelIdentical"]],
        "unexpectedPixelChanges": [record["view"] for record in records if record["needsInvestigation"]],
        "changedFiles": inventory.get("changedFiles", []),
        "unregisteredViewFiles": inventory.get("unregisteredViewFiles", []),
        "unpreviewedViews": inventory["unpreviewedViews"],
        "supplementalPreviews": inventory.get("supplementalPreviews", {}),
        "baselineFixtureSupplement": (
            json.loads((args.output / "baseline-fixture-supplement.json").read_text())
            if (args.output / "baseline-fixture-supplement.json").is_file() else None
        ),
        "derivedValues": inventory["derivedValues"],
        "views": records,
    }
    (args.output / "pixel-change-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    lines = ["# Chrome preview evidence", "",
             f"Before: `{manifest['beforeRevision']}`. After: `{manifest['afterRevision']}`.", "",
             "Contact sheets show real captures, before / after / absolute difference x4. Full-size originals are in the artifact's before/ and after/ directories. Pixel equality refers to decoded RGBA, not PNG metadata.", "",
             "## Changed views", ""]
    for record in records:
        if record["pixelIdentical"]:
            continue
        tokens = sorted({snap["to"] for snap in record["candidateTokenChanges"]})
        attribution = "; ".join(tokens) if tokens else "NO RECORDED SNAP: investigate before approval"
        lines.append(f"- **{record['view']}**: {record['changedPixels']:,} changed pixels. Source-level candidates: {attribution}.")
    lines += ["", "## Pixel-identical views", "", ", ".join(manifest["pixelIdenticalViews"]) or "None.",
              "", "## Unpreviewed surfaces", ""]
    lines += [f"- {view}" for view in inventory["unpreviewedViews"]]
    if not inventory["unpreviewedViews"]:
        lines.append("None of the independent migration surfaces remain without a registered representative fixture.")
    if manifest["baselineFixtureSupplement"] is not None:
        lines += ["", "## Baseline fixture supplement", "",
                  "The same additional fixture definitions, registry cases, screenshot sizes, and non-preview target membership exclusions were installed in the base checkout. Its production Views sources were not replaced. See baseline-fixture-supplement.json for paths, source hashes, and registry inventories.", ""]
    if inventory.get("supplementalPreviews"):
        lines += ["", "## Additional representative fixtures", ""]
        lines += [f"- **{name}** ({fixture['file']}): {fixture['state']}"
                  for name, fixture in inventory["supplementalPreviews"].items()]
    lines += ["", "Every changed view needs human review against the per-site snap inventory. Any unexpected change must be explained before approval. This evidence does not itself grant preview approval.", ""]
    (args.output / "review.md").write_text("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    names = subparsers.add_parser("names")
    names.add_argument("registry", type=Path)
    baseline = subparsers.add_parser("prepare-base")
    for option in ["before-root", "after-root", "output"]:
        baseline.add_argument(f"--{option}", required=True, type=Path)
    evidence = subparsers.add_parser("compare")
    for option in ["before", "after", "before-root", "after-root", "inventory", "output"]:
        evidence.add_argument(f"--{option}", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "names":
        print("\n".join(registry_names(args.registry)))
    elif args.command == "prepare-base":
        prepare_base(args)
    else:
        compare(args)


if __name__ == "__main__":
    main()
