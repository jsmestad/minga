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


def prepare_base(args):
    """Install identical preview fixtures and capture transport, never proposed production views, in the base."""
    if args.before_root.resolve() == args.after_root.resolve():
        raise ValueError("before and after must be separate checkouts")
    sources = Path("macos/Sources")
    registry_path = sources / "PreviewRegistry.swift"
    before_names = registry_names(args.before_root / registry_path)
    changes = []
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
    capture = sources / "PreviewHostApp.swift"
    shutil.copyfile(args.after_root / capture, args.before_root / capture)
    changes.append({"path": str(capture), "scope": "identical preview-only capture transport; non-Sendable ScreenCaptureKit objects remain outside MainActor",
                    "sha256": hashlib.sha256((args.before_root / capture).read_bytes()).hexdigest()})
    project = Path("macos/project.yml")
    destination = args.before_root / project
    destination.write_text(isolate_preview_extensions(destination.read_text()))
    changes.append({"path": str(project), "scope": "exclude PreviewRegistry+*.swift alongside the owner in the three non-preview targets",
                    "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()})
    manifest = {
        "baseRevision": revision(args.before_root),
        "fixtureRevision": revision(args.after_root),
        "scope": "Only preview dispatch, preview sizes, the additional fixture file, identical PreviewHost capture transport, and non-preview target membership exclusions are installed. Production Views sources remain those of the base checkout.",
        "originalBaseNames": before_names,
        "comparisonNames": registry_names(args.before_root / registry_path),
        "fixtureChanges": changes,
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
