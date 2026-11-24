"""Visual review inputs and records for storyboard renders (#4036, AC 6 to AC 8).

The visual review is run by the Minga ticket runner before a UI pull request is marked ready, after CI has rendered
the storyboard; see docs/recipes/visual-review.md. This script does the mechanical parts around the reviewer agents:

  python3 design/tools/storyboard/review.py inputs --run RUN_ID [--out DIR] [--all]
      Downloads the storyboard artifacts of a CI run, and writes one folder per changed scenario with every frame as
      a PNG (TUI frames drawn from their text grid and colours, macOS frames as rendered), the scenario's boards
      rendered with headless Chrome, and DIR/review.json listing them. --all reviews every built scenario, for first
      renders. Without changed scenarios there is nothing to review.
  python3 design/tools/storyboard/review.py comment --pr N --record FILE [--dry-run]
      Posts the "Visual review" comment on the pull request from a review record (format below).
  python3 design/tools/storyboard/review.py followups --pr N --record FILE --comment URL [--issue 4071] [--dry-run]
      Appends every concern, reviewer disagreement and open critic item to the visual follow-ups issue.

A review record is JSON:

  {"scenarios": ["edit.plain", ...],
   "verdicts": [{"scenario": ..., "reviewer": ..., "verdict": "pass" | "concern", "notes": ...}, ...],
   "critic": [{"round": 1, "items": [{"scenario", "part", "issue", "suggested", "status": "fixed" | "declined" | "open",
                                     "reason": ...}]}]}

Python 3.11+, standard library only. `gh` and Google Chrome are needed for the commands that use them.
"""

import argparse
import html
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import renders  # noqa: E402

CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
DEFAULT_OUT = ROOT / "_build" / "visual-review"
FOLLOWUPS_ISSUE = 4071
COMMENT_MARKER = "<!-- minga-visual-review -->"


class Failure(Exception):
    pass


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise Failure(f"{' '.join(map(str, command))} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def screenshot(html_path, png_path, width, height):
    if not Path(CHROME).exists():
        raise Failure(f"Google Chrome not found at {CHROME}; set CHROME")
    run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--window-size={width},{height}",
         f"--screenshot={png_path}", html_path.as_uri()])
    if not png_path.is_file():
        raise Failure(f"Chrome wrote no screenshot for {html_path}")


CELL_WIDTH, CELL_HEIGHT = 9, 18


def tui_page(frame):
    """A TUI frame as fixed cells: every cell is one 9 by 18 pixel box with its own colours, so a glyph from a
    fallback font can never shift the columns after it, and backgrounds fill the whole row."""
    (cols, rows), text_rows, styles = renders.parse_tui(frame)
    out = []
    for row in range(rows):
        text = text_rows[row] if row < len(text_rows) else ""
        cells = list(text) + [" "] * max(0, cols - len(text))
        for start, end, fg, bg, attrs in styles.get(row, []):
            for col in range(start, min(end + 1, cols)):
                weight = "font-weight:700;" if "bold" in attrs else ""
                line = "text-decoration:underline;" if "underline" in attrs else ""
                out.append(f'<i style="left:{col * CELL_WIDTH}px;top:{row * CELL_HEIGHT}px;color:{fg};background:{bg};'
                           f'{weight}{line}">{html.escape(cells[col]) if col < len(cells) else " "}</i>')
    return ("<!doctype html><meta charset=utf-8><style>body{margin:0;background:#000}"
            f"i{{position:absolute;width:{CELL_WIDTH}px;height:{CELL_HEIGHT}px;font:normal 14px/{CELL_HEIGHT}px "
            "Menlo,'Symbols Nerd Font Mono',monospace;text-align:center;overflow:hidden;white-space:pre}</style>"
            + "".join(out)), cols, rows


def tui_png(frame, png_path):
    page, cols, rows = tui_page(frame)
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "frame.html"
        source.write_text(page)
        screenshot(source, png_path, cols * CELL_WIDTH, rows * CELL_HEIGHT)


def cmd_inputs(args):
    out = args.out
    if out.exists():
        shutil.rmtree(out)
    artifacts = out / "artifacts"
    for name in ("storyboard-tui", "storyboard-macos", "storyboard-page"):
        target = artifacts / name
        result = subprocess.run(["gh", "run", "download", str(args.run), "-n", name, "-D", str(target)],
                                capture_output=True, text=True)
        if result.returncode != 0 and name != "storyboard-macos":
            raise Failure(f"cannot download {name} from run {args.run}: {result.stderr.strip()}")
    manifest = json.loads((artifacts / "storyboard-tui" / "manifest.json").read_text())
    report = json.loads((artifacts / "storyboard-page" / "diff.json").read_text())
    built = {s["id"]: s for s in manifest["scenarios"] if s["status"] == "built"}
    changed = sorted(built) if args.all else [entry["scenario"] for entry in report["changed"]]
    review = {"run": args.run, "base": report.get("base"), "count": len(changed), "scenarios": []}
    for sid in changed:
        scenario = built[sid]
        folder = out / sid
        folder.mkdir(parents=True)
        frames = []
        for frame in sorted((artifacts / "storyboard-tui" / "renders" / sid).glob("tui-*.txt")):
            png = folder / (frame.stem + ".png")
            tui_png(frame, png)
            frames.append({"frontend": "tui", "file": str(png), "grid": str(frame)})
        for png in sorted((artifacts / "storyboard-macos" / sid).glob("macos-*.png")):
            shutil.copyfile(png, folder / png.name)
            frames.append({"frontend": "macos", "file": str(folder / png.name)})
        boards = []
        for frontend, board in sorted((scenario.get("boards") or {}).items()):
            source = renders.BOARDS / board
            png = folder / f"board-{frontend}-{Path(board).stem}.png"
            if source.is_file() and not png.exists():
                screenshot(source, png, 1460, 920)
            boards.append({"frontend": frontend, "board": f"design/boards/{board}", "file": str(png)})
        review["scenarios"].append({"id": sid, "title": scenario["title"], "frames": frames, "boards": boards})
    (out / "review.json").write_text(json.dumps(review, indent=2) + "\n")
    print(f"{len(changed)} scenarios to review; inputs in {out}")
    return 0


def verdict_table(record):
    reviewers = sorted({v["reviewer"] for v in record["verdicts"]})
    lines = ["| Scenario | " + " | ".join(reviewers) + " |", "|---" * (len(reviewers) + 1) + "|"]
    for sid in record["scenarios"]:
        cells = []
        for reviewer in reviewers:
            found = [v for v in record["verdicts"] if v["scenario"] == sid and v["reviewer"] == reviewer]
            if not found:
                cells.append("missing")
                continue
            verdict = found[0]
            note = verdict.get("notes", "").replace("|", "\\|").replace("\n", " ")
            cells.append(f"**{verdict['verdict']}**: {note}" if note else f"**{verdict['verdict']}**")
        lines.append(f"| `{sid}` | " + " | ".join(cells) + " |")
    return lines


def open_items(record):
    """Every item that goes to the follow-ups issue: concerns, disagreements and critic items left open or declined."""
    items = []
    for sid in record["scenarios"]:
        verdicts = [v for v in record["verdicts"] if v["scenario"] == sid]
        if len({v["verdict"] for v in verdicts}) > 1:
            items.append({"scenario": sid, "source": "reviewers disagree",
                          "note": "; ".join(f"{v['reviewer']}: {v['verdict']}" for v in verdicts)})
        for verdict in verdicts:
            if verdict["verdict"] == "concern":
                items.append({"scenario": sid, "source": verdict["reviewer"], "note": verdict.get("notes", "")})
    for round_ in record.get("critic", []):
        for item in round_["items"]:
            if item.get("status") in ("open", "declined"):
                note = f"{item.get('part', '')}: {item['issue']}"
                if item.get("status") == "declined":
                    note += f" (declined: {item.get('reason', 'no reason given')})"
                items.append({"scenario": item["scenario"], "source": f"critic round {round_['round']}", "note": note})
    return items


def comment_body(record):
    rounds = record.get("critic", [])
    fixed = sum(1 for r in rounds for i in r["items"] if i.get("status") == "fixed")
    lines = [COMMENT_MARKER, "## Visual review", "",
             f"Changed scenarios reviewed: **{len(record['scenarios'])}** (the cost cap: reviewers and the critic see only these).",
             "", "Two reviewers checked structure against each scenario's board and polish against `docs/design/anatomy.md`, "
             "using `docs/design/visual_rubric.md`, without seeing each other's verdicts.", ""]
    lines += verdict_table(record)
    lines += ["", f"### Polish critic: {len(rounds)} round(s), {fixed} item(s) fixed"]
    for round_ in rounds:
        lines.append(f"**Round {round_['round']}**: {len(round_['items'])} item(s)")
        for item in round_["items"]:
            reason = f" ({item['reason']})" if item.get("reason") else ""
            suggested = item.get("suggested", "").rstrip(".")
            lines.append(f"- `{item['scenario']}` {item.get('part', '')}: {item['issue']} Suggested: {suggested}. "
                         f"**{item.get('status', 'open')}**{reason}")
    items = open_items(record)
    lines += ["", f"Appended to the visual follow-ups issue (#{FOLLOWUPS_ISSUE}): {len(items)} item(s). "
              "Visual review never changes the merge decision."]
    return "\n".join(lines) + "\n"


def cmd_comment(args):
    record = json.loads(Path(args.record).read_text())
    body = comment_body(record)
    if args.dry_run:
        print(body)
        return 0
    url = run(["gh", "pr", "comment", str(args.pr), "--body-file", "-"], input=body).strip()
    print(url)
    return 0


def followup_entries(record, pr, comment):
    lines = []
    for item in open_items(record):
        lines.append(f"- [ ] `{item['scenario']}` in #{pr}: {item['note']} ({item['source']}; notes: {comment})")
    return lines


def cmd_followups(args):
    record = json.loads(Path(args.record).read_text())
    entries = followup_entries(record, args.pr, args.comment)
    if not entries:
        print("nothing to append")
        return 0
    section = [f"## From #{args.pr} (visual review)", f"Reasoning: {args.comment}"] + entries
    if args.dry_run:
        print("\n".join(section))
        return 0
    body = run(["gh", "issue", "view", str(args.issue), "--json", "body", "-q", ".body"])
    updated = body.rstrip() + "\n\n" + "\n".join(section) + "\n"
    run(["gh", "issue", "edit", str(args.issue), "--body-file", "-"], input=updated)
    print(f"appended {len(entries)} entries to #{args.issue}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    inputs = sub.add_parser("inputs")
    inputs.add_argument("--run", required=True)
    inputs.add_argument("--out", type=Path, default=DEFAULT_OUT)
    inputs.add_argument("--all", action="store_true")
    comment = sub.add_parser("comment")
    comment.add_argument("--pr", required=True)
    comment.add_argument("--record", required=True)
    comment.add_argument("--dry-run", action="store_true")
    followups = sub.add_parser("followups")
    followups.add_argument("--pr", required=True)
    followups.add_argument("--record", required=True)
    followups.add_argument("--comment", required=True)
    followups.add_argument("--issue", default=FOLLOWUPS_ISSUE)
    followups.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    handlers = {"inputs": cmd_inputs, "comment": cmd_comment, "followups": cmd_followups}
    try:
        return handlers[args.command](args) or 0
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
