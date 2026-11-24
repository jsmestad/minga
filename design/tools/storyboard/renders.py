"""Storyboard renders: draw every built scenario on both frontends, diff against the baselines, build the page.

Usage, from the repository root:

  python3 design/tools/storyboard/renders.py render [--out DIR]
      Records every built scenario through the real editor (test/storyboard/render_test.exs) and draws the
      TUI frames with the Go renderer. Writes DIR/manifest.json, DIR/transcripts/ and DIR/renders/.
  python3 design/tools/storyboard/renders.py render-macos [--out DIR]
      macOS only. Builds PreviewHost and draws every macOS transcript in DIR/transcripts to DIR/renders
      (a PNG for people and an accessibility export that is the baseline).
  python3 design/tools/storyboard/renders.py diff [--out DIR] [--base REF] [--frontends tui,macos]
      Compares the renders with the committed baselines (a mismatch fails) and with the baselines on REF
      (default origin/main) to list the changed scenarios, and checks the parity rule. Writes DIR/diff.json
      and DIR/diff.md. Exit status 1 when a render does not match its committed baseline, a built scenario
      has no baseline, or a scenario changed on one frontend only without a platform-specific reason.
  python3 design/tools/storyboard/renders.py page [--out DIR]
      Writes DIR/page/index.html: scenarios in rows, frontends in columns, journeys as frame strips.
  python3 design/tools/storyboard/renders.py promote [--out DIR] [--macos DIR] [--scenario ID ...]
                                                     [--platform-specific FRONTEND:REASON] [--no-render]
      Accepts the renders as the new baselines: renders the TUI again (and accepts the text-grid snapshots),
      then copies the renders into test/storyboard/baselines with the commit that produced them. --macos names
      a directory with macOS renders (the storyboard-macos CI artifact), because macOS baselines come from CI.

The baseline store is test/storyboard/baselines/<scenario>/: one file per frontend, theme and size, and
promotion.json with the commit that produced them. Boards are never a diff target.
See docs/design/storyboard.md, "Renders and baselines". Python 3.11+, standard library only.
"""

import argparse
import difflib
import hashlib
import html
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASELINES = ROOT / "test" / "storyboard" / "baselines"
BOARDS = ROOT / "design" / "boards"
DEFAULT_OUT = ROOT / "_build" / "storyboard"
FRONTENDS = ("tui", "macos")
JOURNEY_PREFIX = "journey."


class Failure(Exception):
    pass


def run(command, cwd=ROOT, env=None):
    print("+ " + " ".join(str(part) for part in command), flush=True)
    result = subprocess.run(command, cwd=cwd, env=env)
    if result.returncode != 0:
        raise Failure(f"command failed ({result.returncode}): {' '.join(str(part) for part in command)}")


def load_manifest(out):
    path = out / "manifest.json"
    if not path.is_file():
        raise Failure(f"{path} is missing; run `renders.py render` first")
    return json.loads(path.read_text())


# -- render ------------------------------------------------------------------


def cmd_render(args, update_snapshots=False):
    out = args.out
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    env = dict(os.environ, MIX_ENV="test", MINGA_STORYBOARD_OUT=str(out))
    if update_snapshots:
        # The text-grid snapshots are the same scenarios through the existing snapshot system; accept them together.
        env["UPDATE_SNAPSHOTS"] = "1"
        run(["mix", "test", "--only", "storyboard", "test/storyboard/render_test.exs"], env=env)
    else:
        run(["mix", "test", "--only", "storyboard_export", "test/storyboard/render_test.exs"], env=env)
    renders = out / "renders"
    env = dict(os.environ, MINGA_STORYBOARD_TRANSCRIPTS=str(out / "transcripts"), MINGA_STORYBOARD_RENDERS=str(renders))
    run(["go", "test", "./internal/ui/", "-run", "^TestStoryboardRenders$", "-count=1"], cwd=ROOT / "go" / "tui", env=env)
    count = len(list(renders.glob("*/tui-*.txt")))
    print(f"rendered {count} TUI frames into {renders}")


def cmd_render_macos(args):
    out = args.out
    transcripts = sorted((out / "transcripts").glob("*/macos-*.json"))
    if not transcripts:
        raise Failure(f"no macOS transcripts under {out / 'transcripts'}; run `renders.py render` first")
    renders = out / "renders"
    jobs = [{"transcript": str(path), "output": str(renders / path.parent.name / path.stem)} for path in transcripts]
    jobs_path = out / "macos-jobs.json"
    jobs_path.write_text(json.dumps(jobs, indent=2) + "\n")
    derived = Path(os.environ.get("STORYBOARD_DERIVED_DATA", out / "DerivedData"))
    if not args.skip_build:
        run(["mix", "protocol.gen"])
        run(["xcodegen", "generate", "--quiet"], cwd=ROOT / "macos")
        run(["xcodebuild", "build", "-project", "macos/Minga.xcodeproj", "-scheme", "PreviewHost",
             "-configuration", "Debug", "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "-quiet"])
    binary = derived / "Build/Products/Debug/PreviewHost.app/Contents/MacOS/PreviewHost"
    if not binary.is_file():
        raise Failure(f"PreviewHost executable missing: {binary}")
    env = dict(os.environ, PREVIEW_VIEW="Storyboard", PREVIEW_STORYBOARD_JOBS=str(jobs_path),
               LC_ALL="en_US.UTF-8", TZ="UTC")
    run([str(binary)], env=env)
    missing = [job["output"] for job in jobs if not Path(job["output"] + ".json").is_file()]
    if missing:
        raise Failure(f"PreviewHost did not write {len(missing)} renders, first {missing[0]}")
    print(f"rendered {len(jobs)} macOS frames into {renders}")


# -- baselines and diff ------------------------------------------------------


def render_files(scenario_dir, frontend):
    """The baseline files a frontend renders for one scenario: TUI text grids, macOS accessibility exports."""
    pattern = "tui-*.txt" if frontend == "tui" else "macos-*.json"
    return sorted(path.name for path in scenario_dir.glob(pattern)) if scenario_dir.is_dir() else []


def comparable(frontend, text):
    """The part of a render a baseline pins. macOS exports drop facts that describe the machine, not the frame."""
    if frontend == "tui":
        return text
    data = json.loads(text)
    return json.dumps({key: data.get(key) for key in ("scenario", "theme", "size", "window", "grid", "parts", "elements")},
                      sort_keys=True, indent=1)


def git_show(ref, path):
    relative = path.relative_to(ROOT).as_posix()
    result = subprocess.run(["git", "show", f"{ref}:{relative}"], cwd=ROOT, capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def resolve_ref(ref):
    for candidate in (ref, f"origin/{ref}"):
        if subprocess.run(["git", "rev-parse", "--verify", "--quiet", candidate], cwd=ROOT,
                          capture_output=True).returncode == 0:
            return candidate
    return None


def expected_frontends(scenario):
    return [frontend for frontend in FRONTENDS if frontend in scenario.get("frontends", FRONTENDS)]


def load_promotion(scenario_id):
    path = BASELINES / scenario_id / "promotion.json"
    return json.loads(path.read_text()) if path.is_file() else {}


# Inputs that change macOS frames without changing what the BEAM sends: the renderer's own tools, the window grid, and
# the baselines themselves.
MACOS_INPUT_PATHS = ("design/tools/storyboard", "test/storyboard/macos_geometry.json", "test/storyboard/baselines")


def macos_required(out, manifest, base):
    """True when macOS must draw: a macOS transcript differs from the one its baseline was promoted from, a built
    scenario has no macOS baseline yet, or a macOS-only input changed against the base revision. Native sources are
    decided by the CI path detector."""
    if base is None:
        return True
    changed = subprocess.run(["git", "diff", "--quiet", base, "HEAD", "--", *MACOS_INPUT_PATHS], cwd=ROOT).returncode != 0
    if changed:
        return True
    for scenario in manifest["scenarios"]:
        if scenario["status"] != "built" or "macos" not in expected_frontends(scenario):
            continue
        promoted = load_promotion(scenario["id"]).get("macos", {}).get("transcripts", {})
        for path in sorted((out / "transcripts" / scenario["id"]).glob("macos-*.json")):
            if promoted.get(path.name) != json.loads(path.read_text()).get("digest"):
                return True
    return False


def cmd_diff(args):
    out = args.out
    manifest = load_manifest(out)
    renders = out / "renders"
    frontends = [frontend for frontend in args.frontends.split(",") if frontend]
    base = resolve_ref(args.base)
    report = {"base": base, "frontends": frontends, "stale": [], "missing_baseline": [], "missing_render": [],
              "orphan_baseline": [], "changed": [], "parity_violations": [], "platform_specific": [], "pending": [],
              "macos_required": macos_required(out, manifest, base)}
    built = [scenario for scenario in manifest["scenarios"] if scenario["status"] == "built"]
    report["pending"] = [{"scenario": s["id"], "issue": s.get("issue"), "reason": s.get("reason")}
                         for s in manifest["scenarios"] if s["status"] != "built"]
    for scenario in built:
        sid = scenario["id"]
        changed_on = {}
        for frontend in expected_frontends(scenario):
            if frontend not in frontends:
                continue
            rendered = render_files(renders / sid, frontend)
            if not rendered:
                report["missing_render"].append({"scenario": sid, "frontend": frontend})
                continue
            for orphan in sorted(set(render_files(BASELINES / sid, frontend)) - set(rendered)):
                report["orphan_baseline"].append({"scenario": sid, "frontend": frontend, "file": orphan})
            targets = []
            for name in rendered:
                current = comparable(frontend, (renders / sid / name).read_text())
                baseline_path = BASELINES / sid / name
                if not baseline_path.is_file():
                    report["missing_baseline"].append({"scenario": sid, "frontend": frontend, "file": name})
                elif comparable(frontend, baseline_path.read_text()) != current:
                    report["stale"].append({"scenario": sid, "frontend": frontend, "file": name})
                previous = git_show(base, baseline_path) if base else None
                if previous is None:
                    targets.append({"file": name, "kind": "new"})
                elif comparable(frontend, previous) != current:
                    targets.append({"file": name, "kind": "changed"})
            if targets:
                changed_on[frontend] = targets
        if changed_on:
            report["changed"].append({"scenario": sid, "frontends": changed_on})
        # A frontend CI did not draw because none of its inputs changed is unchanged by construction.
        judged = set(frontends) | set(args.assume_unchanged.split(",") if args.assume_unchanged else [])
        both = set(expected_frontends(scenario)) == set(FRONTENDS) and judged >= set(FRONTENDS)
        if both and len(changed_on) == 1:
            (only,) = changed_on
            tag = load_promotion(sid).get("platform_specific")
            if tag and tag.get("frontend") == only and tag.get("reason"):
                report["platform_specific"].append({"scenario": sid, "frontend": only, "reason": tag["reason"]})
            else:
                report["parity_violations"].append({"scenario": sid, "frontend": only})
    (out / "diff.json").write_text(json.dumps(report, indent=2) + "\n")
    summary = diff_markdown(report)
    (out / "diff.md").write_text(summary)
    print(summary)
    if args.github_output:
        with open(args.github_output, "a") as handle:
            ui_changed = bool(report["changed"] or report["stale"] or report["missing_baseline"])
            handle.write(f"ui_changed={'true' if ui_changed else 'false'}\n")
            handle.write(f"macos_required={'true' if report['macos_required'] else 'false'}\n")
            handle.write(f"changed_count={len(report['changed'])}\n")
    failed = report["stale"] or report["missing_baseline"] or report["orphan_baseline"] or report["parity_violations"]
    if args.check and failed:
        return 1
    if args.check and report["missing_render"]:
        return 1
    return 0


def diff_markdown(report):
    lines = ["## Storyboard renders", ""]
    base = report["base"] or "no base revision"
    lines.append(f"Compared with the baselines on `{base}` for: {', '.join(report['frontends'])}.")
    lines.append("")
    lines.append(f"**Changed scenarios: {len(report['changed'])}**")
    for entry in report["changed"]:
        parts = ", ".join(f"{frontend} ({len(targets)} frames)" for frontend, targets in entry["frontends"].items())
        lines.append(f"- `{entry['scenario']}`: {parts}")
    sections = [
        ("stale", "Renders that do not match the committed baseline (accept with `renders.py promote`)"),
        ("missing_baseline", "Built scenarios without a baseline (promote them once the layout audit and visual review pass)"),
        ("missing_render", "Expected renders that were not produced"),
        ("orphan_baseline", "Baselines with no render (a target or scenario went away; promote to remove them)"),
        ("parity_violations", "Changed on one frontend only, without a platform-specific reason"),
        ("platform_specific", "Changed on one frontend only, tagged platform-specific"),
    ]
    for key, title in sections:
        if report[key]:
            lines += ["", f"**{title}: {len(report[key])}**"]
            for entry in report[key]:
                detail = entry.get("file") or entry.get("reason") or ""
                lines.append(f"- `{entry['scenario']}` {entry['frontend']} {detail}".rstrip())
    lines += ["", f"Pending scenarios (not rendered, never failures): {len(report['pending'])}", ""]
    return "\n".join(lines)


# -- promote -----------------------------------------------------------------


def commit_identity():
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = subprocess.run(["git", "diff", "--quiet", "HEAD", "--", ".", ":!test/storyboard/baselines",
                            ":!test/snapshots"], cwd=ROOT).returncode != 0
    return sha + ("-dirty" if dirty else "")


def cmd_promote(args):
    out = args.out
    if not args.no_render:
        cmd_render(args, update_snapshots=True)
    manifest = load_manifest(out)
    sources = {"tui": out / "renders", "macos": Path(args.macos) / "renders" if args.macos else None}
    if args.macos and not sources["macos"].is_dir():
        sources["macos"] = Path(args.macos)
    tag = None
    if args.platform_specific:
        frontend, _, reason = args.platform_specific.partition(":")
        if frontend not in FRONTENDS or not reason.strip():
            raise Failure("--platform-specific takes FRONTEND:REASON, for example 'macos:the hosting view now clips to the safe area'")
        tag = {"frontend": frontend, "reason": reason.strip()}
    commit = commit_identity()
    wanted = set(args.scenario or [])
    promoted = 0
    for scenario in manifest["scenarios"]:
        sid = scenario["id"]
        if scenario["status"] != "built" or (wanted and sid not in wanted):
            continue
        target = BASELINES / sid
        promotion = load_promotion(sid)
        changed = False
        for frontend in expected_frontends(scenario):
            source = sources[frontend]
            if source is None:
                continue
            names = render_files(source / sid, frontend)
            if not names:
                continue
            target.mkdir(parents=True, exist_ok=True)
            for stale in render_files(target, frontend):
                if stale not in names:
                    (target / stale).unlink()
            hashes = {}
            transcripts = {}
            for name in names:
                data = (source / sid / name).read_text()
                if frontend == "macos":
                    transcripts[name] = json.loads(data).get("transcript_digest")
                    data = comparable(frontend, data) + "\n"
                (target / name).write_text(data)
                hashes[name] = hashlib.sha256(data.encode()).hexdigest()
            entry = {"commit": commit, "files": hashes}
            if transcripts:
                # What the BEAM sent for each frame, so CI knows when macOS must draw again (macos_required).
                entry["transcripts"] = transcripts
            if {k: v for k, v in promotion.get(frontend, {}).items() if k != "commit"} != {k: v for k, v in entry.items() if k != "commit"}:
                promotion[frontend] = entry
                changed = True
        if tag is not None and (not wanted or sid in wanted):
            promotion["platform_specific"] = tag
            changed = True
        elif changed:
            promotion.pop("platform_specific", None)
        if changed:
            promotion["scenario"] = sid
            (target / "promotion.json").write_text(json.dumps(promotion, indent=2, sort_keys=True) + "\n")
            promoted += 1
            print(f"promoted {sid}")
    print(f"{promoted} scenarios promoted into {BASELINES}")
    return 0


# -- page --------------------------------------------------------------------

PAGE_CSS = """
:root { color-scheme: light dark; --bg: #f6f6f4; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --card: #ffffff;
        --changed: #c2410c; --pending: #8e8e93; }
@media (prefers-color-scheme: dark) { :root { --bg: #161618; --fg: #f2f2f7; --muted: #a1a1a6; --line: #3a3a3c;
        --card: #1f1f22; --changed: #fb923c; --pending: #8e8e93; } }
body { margin: 0; padding: 24px; background: var(--bg); color: var(--fg); font: 14px/1.45 -apple-system, system-ui, sans-serif; }
h1 { font-size: 20px; margin: 0 0 4px; } h2 { font-size: 16px; margin: 32px 0 8px; }
.meta { color: var(--muted); margin-bottom: 16px; }
.themes { position: sticky; top: 0; background: var(--bg); padding: 8px 0; z-index: 2; border-bottom: 1px solid var(--line); }
.themes label { margin-right: 16px; cursor: pointer; }
table { border-collapse: collapse; }
th, td { border-bottom: 1px solid var(--line); padding: 8px; vertical-align: top; text-align: left; }
th { font-weight: 600; font-size: 12px; color: var(--muted); }
.scenario { min-width: 220px; max-width: 260px; }
.scenario code { font-weight: 600; }
.badge { display: inline-block; font-size: 11px; padding: 0 6px; border-radius: 4px; border: 1px solid currentColor; margin: 2px 4px 0 0; }
.changed { color: var(--changed); } .pending { color: var(--pending); }
pre.tui { margin: 0; font: 7px/1.25 ui-monospace, Menlo, monospace; white-space: pre; border-radius: 4px; overflow: hidden; }
pre.tui.wide { font-size: 6px; }
img.mac { width: 360px; border-radius: 6px; border: 1px solid var(--line); display: block; }
.frame { display: none; } body[data-theme] .frame.on { display: block; }
.strip { display: flex; gap: 16px; overflow-x: auto; padding-bottom: 8px; }
.strip figure { margin: 0; } figcaption { font-size: 12px; color: var(--muted); margin-top: 4px; }
details pre { font-size: 11px; max-height: 320px; overflow: auto; background: var(--card); padding: 8px; }
a { color: inherit; }
"""

PAGE_JS = """
for (const input of document.querySelectorAll('input[name=theme]')) {
  input.addEventListener('change', () => select(input.value));
}
function select(theme) {
  document.body.dataset.theme = theme;
  for (const frame of document.querySelectorAll('.frame')) frame.classList.toggle('on', frame.dataset.theme === theme);
}
select(document.querySelector('input[name=theme]:checked').value);
"""


def parse_tui(path):
    """Reads a TUI frame file: the text rows and the style runs per row."""
    rows, styles, section = [], {}, None
    size = (0, 0)
    for line in path.read_text().splitlines():
        if line.startswith("# size: "):
            cols, rows_count = line[len("# size: "):].split("x")
            size = (int(cols), int(rows_count))
        if line.startswith("## text"):
            section = "text"
            continue
        if line.startswith("## styles"):
            section = "styles"
            continue
        if section == "text":
            rows.append(line)
        elif section == "styles" and line:
            row, span, fg, bg, attrs = line.split(" ")
            start, end = (int(part) for part in span.split("-"))
            styles.setdefault(int(row), []).append((start, end, fg, bg, attrs))
    return size, rows, styles


def tui_html(path):
    (cols, _), rows, styles = parse_tui(path)
    out = []
    for index, text in enumerate(rows):
        cells = list(text) + [" "] * max(0, cols - len(text))
        runs = styles.get(index) or [(0, cols - 1, "#000000", "#ffffff", "-")]
        position = 0
        for start, end, fg, bg, attrs in runs:
            # A wide glyph takes two cells but one character, so walk characters against cell spans approximately.
            width = end - start + 1
            chunk = "".join(cells[position:position + width])
            position += width
            style = f"color:{fg};background:{bg}"
            if "bold" in attrs:
                style += ";font-weight:700"
            if "underline" in attrs:
                style += ";text-decoration:underline"
            if "faint" in attrs:
                style += ";opacity:.7"
            out.append(f'<span style="{style}">{html.escape(chunk)}</span>')
        out.append("\n")
    wide = " wide" if cols > 120 else ""
    return f'<pre class="tui{wide}">{"".join(out)}</pre>'


def copy_asset(source, page_dir, relative):
    target = page_dir / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    return relative


def frame_cell(sid, frontend, theme, size, renders, page_dir):
    name = f"{frontend}-{theme}-{size}"
    if frontend == "tui":
        path = renders / sid / f"{name}.txt"
        if not path.is_file():
            return '<span class="pending">not rendered</span>'
        return tui_html(path)
    png = renders / sid / f"{name}.png"
    if not png.is_file():
        return '<span class="pending">not rendered in this run</span>'
    relative = copy_asset(png, page_dir, f"macos/{sid}/{name}.png")
    return f'<a href="{relative}"><img class="mac" src="{relative}" alt="{html.escape(sid)} on macOS at {size} pt, {theme}"></a>'


def board_links(scenario, page_dir):
    links = []
    for frontend, board in sorted((scenario.get("boards") or {}).items()):
        source = BOARDS / board
        if source.is_file():
            relative = copy_asset(source, page_dir, f"boards/{board}")
            links.append(f'<a href="{relative}">{html.escape(frontend)} board</a>')
    return " · ".join(links) or '<span class="pending">no board</span>'


def cmd_page(args):
    out = args.out
    manifest = load_manifest(out)
    renders = out / "renders"
    page_dir = out / "page"
    if page_dir.exists():
        shutil.rmtree(page_dir)
    page_dir.mkdir(parents=True)
    report = json.loads((out / "diff.json").read_text()) if (out / "diff.json").is_file() else None
    changed = {entry["scenario"]: entry for entry in (report or {}).get("changed", [])}
    themes = manifest["themes"]
    targets = manifest["targets"]
    built = [s for s in manifest["scenarios"] if s["status"] == "built"]
    pending = [s for s in manifest["scenarios"] if s["status"] != "built"]

    parts = ["<!doctype html><html lang=en><meta charset=utf-8>",
             '<meta name=viewport content="width=device-width, initial-scale=1">',
             "<title>Minga storyboard</title>", f"<style>{PAGE_CSS}</style><body>",
             "<h1>Minga storyboard</h1>",
             f'<div class="meta">{len(built)} scenarios rendered, {len(pending)} pending, '
             f'{len(changed)} changed against {html.escape(str((report or {}).get("base") or "no base"))}. '
             "Boards are structural references; renders are the baselines.</div>",
             '<div class="themes">Theme: ']
    for index, theme in enumerate(themes):
        checked = " checked" if index == 0 else ""
        parts.append(f'<label><input type=radio name=theme value="{theme}"{checked}> {html.escape(theme)}</label>')
    parts.append("</div>")

    parts.append("<h2>Scenarios</h2><table><tr><th>Scenario</th>")
    for target in targets:
        unit = "" if target["frontend"] == "tui" else " pt"
        parts.append(f"<th>{'TUI' if target['frontend'] == 'tui' else 'macOS'} {target['size']}{unit}</th>")
    parts.append("</tr>")
    for scenario in built:
        sid = scenario["id"]
        badges = ""
        if sid in changed:
            badges += '<span class="badge changed">changed: ' + ", ".join(changed[sid]["frontends"]) + "</span>"
        parts.append(f'<tr><td class="scenario"><code>{html.escape(sid)}</code>{badges}<br>'
                     f'{html.escape(scenario["title"])}<br>{board_links(scenario, page_dir)}</td>')
        for target in targets:
            if target["frontend"] not in expected_frontends(scenario):
                parts.append(f'<td class="pending">{html.escape(scenario.get("platform_only_reason") or "not on this frontend")}</td>')
                continue
            cells = "".join(
                f'<div class="frame" data-theme="{theme}">'
                f'{frame_cell(sid, target["frontend"], theme, target["size"], renders, page_dir)}</div>'
                for theme in themes)
            parts.append(f"<td>{cells}</td>")
        parts.append("</tr>")
    parts.append("</table>")

    parts.append("<h2>Journeys</h2>")
    strip_theme = manifest["strip_theme"]
    for journey in manifest["journeys"]:
        outcome = journey["outcome"]
        note = "" if outcome == "complete" else f' <span class="pending">stops at {html.escape(journey.get("pending_scenario", ""))}, pending #{journey.get("issue")}</span>'
        parts.append(f"<h3>{html.escape(journey['name'])}{note}</h3>")
        if not journey["frames"]:
            parts.append('<p class="pending">No frame is built yet.</p>')
            continue
        parts.append('<div class="strip">')
        for frame in journey["frames"]:
            label = html.escape(frame["keys"] or "start")
            for target in targets:
                if target["size"] not in ("120x40", "1440"):
                    continue
                cell = frame_cell(frame["name"], target["frontend"], strip_theme, target["size"], renders, page_dir)
                parts.append(f"<figure>{cell}<figcaption>{label} → {html.escape(frame['scenario'])}, "
                             f"{'TUI' if target['frontend'] == 'tui' else 'macOS'}</figcaption></figure>")
        parts.append("</div>")

    parts.append(f"<h2>Pending ({len(pending)})</h2><table><tr><th>Scenario</th><th>Waits on</th><th>Board</th></tr>")
    for scenario in pending:
        issue = f"#{scenario['issue']}" if scenario.get("issue") else ""
        parts.append(f'<tr><td><code>{html.escape(scenario["id"])}</code><br>{html.escape(scenario["title"])}</td>'
                     f'<td class="pending">{issue} {html.escape(scenario.get("reason") or "")}</td>'
                     f"<td>{board_links(scenario, page_dir)}</td></tr>")
    parts.append("</table>")

    if report:
        parts.append("<h2>Diff report</h2><details open><pre>" + html.escape(diff_markdown(report)) + "</pre></details>")
        for entry in report["changed"]:
            for frontend, frames in entry["frontends"].items():
                if frontend != "tui":
                    continue
                for frame in frames:
                    if frame["kind"] != "changed":
                        continue
                    current = (renders / entry["scenario"] / frame["file"]).read_text().splitlines()
                    previous = (git_show(report["base"], BASELINES / entry["scenario"] / frame["file"]) or "").splitlines()
                    text = "\n".join(difflib.unified_diff(previous, current, "baseline", "render", lineterm="", n=1))
                    parts.append(f"<details><summary>{html.escape(entry['scenario'])} {html.escape(frame['file'])}</summary>"
                                 f"<pre>{html.escape(text)}</pre></details>")
    parts.append(f"<script>{PAGE_JS}</script></body></html>")
    (page_dir / "index.html").write_text("".join(parts))
    print(f"wrote {page_dir / 'index.html'}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def add(name):
        command = sub.add_parser(name)
        command.add_argument("--out", type=Path, default=DEFAULT_OUT)
        return command

    add("render")
    macos = add("render-macos")
    macos.add_argument("--skip-build", action="store_true", help="reuse the PreviewHost in STORYBOARD_DERIVED_DATA")
    diff = add("diff")
    diff.add_argument("--base", default="main")
    diff.add_argument("--frontends", default="tui,macos")
    diff.add_argument("--check", action="store_true", help="exit 1 on a stale render, a missing baseline or a parity violation")
    diff.add_argument("--github-output", default=None)
    diff.add_argument("--assume-unchanged", default="", help="frontends CI skipped because none of their inputs changed")
    add("page")
    promote = add("promote")
    promote.add_argument("--macos", default=None, help="directory with macOS renders, such as the downloaded storyboard-macos artifact")
    promote.add_argument("--scenario", action="append")
    promote.add_argument("--no-render", action="store_true", help="promote the renders already in --out instead of rendering again")
    promote.add_argument("--platform-specific", default=None, metavar="FRONTEND:REASON")
    args = parser.parse_args(argv)
    args.out = args.out.resolve()
    handlers = {"render": cmd_render, "render-macos": cmd_render_macos, "diff": cmd_diff, "page": cmd_page,
                "promote": cmd_promote}
    try:
        return handlers[args.command](args) or 0
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
