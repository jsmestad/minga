"""Visual review inputs and records for storyboard renders (#4036, AC 6 to AC 8).

The visual review is run by the Minga ticket runner before a UI pull request is marked ready, after CI has rendered
the storyboard; see docs/recipes/visual-review.md. This script does the mechanical parts around the reviewer agents:

  python3 design/tools/storyboard/review.py inputs --run RUN_ID [--out DIR] [--all]
      Downloads the storyboard artifacts of a CI run, and writes one folder per changed scenario with every frame as
      a PNG (TUI frames drawn from their text grid and colours, macOS frames as rendered), the scenario's boards
      rendered with headless Chrome, and DIR/review.json listing them. --all reviews every built scenario, for first
      renders. Without changed scenarios there is nothing to review.
  python3 design/tools/storyboard/review.py comment --pr N --record FILE [--review review.json] [--dry-run]
      Posts the "Visual review" comment on the pull request from a review record (format below), or replaces the
      one an earlier run posted.
  python3 design/tools/storyboard/review.py followups --pr N --record FILE --comment URL [--review review.json]
                                                      [--issue 4071] [--dry-run]
      Writes every concern, reviewer disagreement and open critic item to the visual follow-ups issue, in one section
      per pull request that a rerun replaces.

Both refuse a record that misses a changed scenario or a reviewer's verdict, or has more than three critic rounds.
When the run has no macOS renders (no macOS input changed), review.json says so and the inputs are TUI only.

A review record is JSON ("note" is optional and heads the follow-up section, for example items fixed before filing):

  {"scenarios": ["edit.plain", ...], "note": "...",
   "verdicts": [{"scenario": ..., "reviewer": ..., "verdict": "pass" | "concern", "notes": ...}, ...],
   "critic": [{"round": 1, "items": [{"scenario", "part", "issue", "suggested", "status": "fixed" | "declined" | "open",
                                     "reason": ...}]}]}

Python 3.11+, standard library only. `gh` and Google Chrome are needed for the commands that use them.
"""

import argparse
import html
import json
import os
import re
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
# GitHub rejects an issue or comment body over 65536 characters.
BODY_LIMIT = 65536
SCENARIO_ID = re.compile(r"^[a-z0-9_]+(\.[a-z0-9_]+)*$")


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


def macos_job(run_id):
    """The conclusion of the run's macOS render job: "success", "skipped" (no macOS input changed) or another state."""
    jobs = json.loads(run(["gh", "run", "view", str(run_id), "--json", "jobs"]))["jobs"]
    return next((j.get("conclusion") or j.get("status") for j in jobs if j["name"] == "Storyboard renders (macOS)"), "absent")


def cmd_inputs(args):
    out = args.out
    if out.exists():
        # Only ever replace a folder this command wrote, never a directory named by mistake.
        if any(out.iterdir()) and not (out / "review.json").is_file():
            raise Failure(f"{out} exists and is not a visual review folder; pass an empty or new --out")
        shutil.rmtree(out)
    artifacts = out / "artifacts"
    macos = "rendered"
    for name in ("storyboard-tui", "storyboard-macos", "storyboard-page"):
        target = artifacts / name
        result = subprocess.run(["gh", "run", "download", str(args.run), "-n", name, "-D", str(target)],
                                capture_output=True, text=True)
        if result.returncode == 0:
            continue
        if name != "storyboard-macos":
            raise Failure(f"cannot download {name} from run {args.run}: {result.stderr.strip()}")
        conclusion = macos_job(args.run)
        if conclusion == "success":
            raise Failure(f"the macOS renders of run {args.run} exist but did not download: {result.stderr.strip()}")
        macos = f"not rendered in run {args.run} (macOS render job: {conclusion})"
        print(f"warning: {macos}; reviewers see TUI frames only", file=sys.stderr)
    manifest = json.loads((artifacts / "storyboard-tui" / "manifest.json").read_text())
    report = json.loads((artifacts / "storyboard-page" / "diff.json").read_text())
    built = {s["id"]: s for s in manifest["scenarios"] if s["status"] == "built"}
    changed = sorted(built) if args.all else [entry["scenario"] for entry in report["changed"]]
    review = {"run": args.run, "base": report.get("base"), "count": len(changed), "macos": macos, "scenarios": []}
    for sid in changed:
        if not SCENARIO_ID.match(sid):
            raise Failure(f"unexpected scenario id {sid!r} in the run's artifacts")
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
            source = (renders.BOARDS / board).resolve()
            if not source.is_relative_to(renders.BOARDS.resolve()):
                raise Failure(f"board {board!r} of {sid} is outside design/boards")
            png = folder / f"board-{frontend}-{Path(board).stem}.png"
            if source.is_file() and not png.exists():
                screenshot(source, png, 1460, 920)
            boards.append({"frontend": frontend, "board": f"design/boards/{board}", "file": str(png)})
        review["scenarios"].append({"id": sid, "title": scenario["title"], "macos": macos, "frames": frames,
                                    "boards": boards})
    (out / "review.json").write_text(json.dumps(review, indent=2) + "\n")
    print(f"{len(changed)} scenarios to review; inputs in {out}")
    return 0


def flat(text):
    """Model-written notes on one line, so they cannot end a list item or start a heading."""
    return " ".join(str(text).split())


def validate(record, review=None):
    """A review record is model output; refuse one that would post or file less than the review found."""
    problems = []
    scenarios = record.get("scenarios") or []
    if not scenarios:
        problems.append("no scenarios")
    if review is not None and sorted(scenarios) != sorted(s["id"] for s in review["scenarios"]):
        problems.append(f"scenarios {sorted(scenarios)} differ from review.json {sorted(s['id'] for s in review['scenarios'])}")
    for sid in scenarios:
        verdicts = [v for v in record.get("verdicts", []) if v.get("scenario") == sid]
        if len({v.get("reviewer") for v in verdicts}) != 2 or len(verdicts) != 2:
            problems.append(f"{sid} needs one verdict from each of two reviewers, has {len(verdicts)}")
        problems += [f"{sid}: verdict {v.get('verdict')!r} is not pass or concern" for v in verdicts
                     if v.get("verdict") not in ("pass", "concern")]
    rounds = record.get("critic", [])
    if len(rounds) > 3:
        problems.append(f"{len(rounds)} critic rounds; the loop stops after three")
    problems += [f"critic item status {i.get('status')!r} is not fixed, declined or open"
                 for r in rounds for i in r.get("items", []) if i.get("status") not in ("fixed", "declined", "open")]
    if problems:
        raise Failure("the review record is incomplete: " + "; ".join(problems))
    return record


def load_record(args):
    record = json.loads(Path(args.record).read_text())
    review = json.loads(Path(args.review).read_text()) if getattr(args, "review", None) else None
    return validate(record, review)


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
            note = flat(verdict.get("notes", "")).replace("|", "\\|")
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
                items.append({"scenario": sid, "source": verdict["reviewer"], "note": flat(verdict.get("notes", ""))})
    for round_ in record.get("critic", []):
        for item in round_["items"]:
            if item.get("status") in ("open", "declined"):
                note = f"{item.get('part', '')}: {item['issue']}"
                if item.get("status") == "declined":
                    note += f" (declined: {item.get('reason', 'no reason given')})"
                items.append({"scenario": item["scenario"], "source": f"critic round {round_['round']}", "note": flat(note)})
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
            reason = f" ({flat(item['reason'])})" if item.get("reason") else ""
            suggested = flat(item.get("suggested", "")).rstrip(".")
            lines.append(f"- `{item['scenario']}` {item.get('part', '')}: {flat(item['issue'])} Suggested: {suggested}. "
                         f"**{item.get('status', 'open')}**{reason}")
    items = open_items(record)
    lines += ["", f"Appended to the visual follow-ups issue (#{FOLLOWUPS_ISSUE}): {len(items)} item(s). "
              "Visual review never changes the merge decision."]
    return "\n".join(lines) + "\n"


def cmd_comment(args):
    """Posts the one Visual review comment, or replaces it when the review runs again."""
    body = comment_body(load_record(args))
    if len(body) > BODY_LIMIT:
        raise Failure(f"the comment is {len(body)} characters, over GitHub's {BODY_LIMIT}; shorten the notes")
    if args.dry_run:
        print(body)
        return 0
    existing = run(["gh", "api", "--paginate", f"repos/{{owner}}/{{repo}}/issues/{args.pr}/comments",
                    "-q", f'.[] | select(.body | contains("{COMMENT_MARKER}")) | .id']).split()
    if existing:
        payload = json.dumps({"body": body})
        url = json.loads(run(["gh", "api", "-X", "PATCH", f"repos/{{owner}}/{{repo}}/issues/comments/{existing[0]}",
                              "--input", "-"], input=payload))["html_url"]
    else:
        url = run(["gh", "pr", "comment", str(args.pr), "--body-file", "-"], input=body).strip()
    print(url)
    return 0


def followup_entries(record, pr, comment):
    lines = []
    for item in open_items(record):
        lines.append(f"- [ ] `{item['scenario']}` in #{pr}: {item['note']} ({item['source']}; notes: {comment})")
    return lines


def replace_section(body, heading, section):
    """The issue body with this pull request's section replaced, or appended when it has none, so a rerun of the
    review never files the same entries twice."""
    lines = body.rstrip().split("\n")
    if heading in lines:
        start = lines.index(heading)
        end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
        lines = lines[:start] + section + ([""] + lines[end:] if end < len(lines) else [])
        return "\n".join(lines).rstrip() + "\n"
    return "\n".join(lines) + "\n\n" + "\n".join(section) + "\n"


def cmd_followups(args):
    record = load_record(args)
    entries = followup_entries(record, args.pr, args.comment)
    if not entries:
        print("nothing to append")
        return 0
    heading = f"## From #{args.pr} (visual review)"
    section = [heading, f"Reasoning: {args.comment}"]
    if record.get("note"):
        section.append(flat(record["note"]))
    section += entries
    if args.dry_run:
        print("\n".join(section))
        return 0
    body = run(["gh", "issue", "view", str(args.issue), "--json", "body", "-q", ".body"])
    updated = replace_section(body, heading, section)
    if len(updated) > BODY_LIMIT:
        raise Failure(f"#{args.issue} would be {len(updated)} characters, over GitHub's {BODY_LIMIT}; "
                      "close the done entries or start a new follow-ups issue")
    run(["gh", "issue", "edit", str(args.issue), "--body-file", "-"], input=updated)
    # Another review can edit the issue at the same time; check that this section survived.
    after = run(["gh", "issue", "view", str(args.issue), "--json", "body", "-q", ".body"])
    if heading not in after.split("\n"):
        raise Failure(f"#{args.issue} changed while this review wrote to it; run followups again")
    print(f"wrote {len(entries)} entries to #{args.issue}")
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
    comment.add_argument("--review", help="review.json from inputs, to check the record covers every changed scenario")
    comment.add_argument("--dry-run", action="store_true")
    followups = sub.add_parser("followups")
    followups.add_argument("--pr", required=True)
    followups.add_argument("--record", required=True)
    followups.add_argument("--comment", required=True)
    followups.add_argument("--review", help="review.json from inputs, to check the record covers every changed scenario")
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
