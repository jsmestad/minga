"""Layout audit: measures every rendered storyboard scenario against docs/design/anatomy.md (#4036, AC 5).

Usage, from the repository root, after `renders.py render` (and `render-macos` for macOS):

  python3 design/tools/storyboard/audit.py [--out DIR] [--frontends tui,macos] [--check]

It reads the parts each frontend measured in its renders (macOS: the views tagged with `anatomyPart`; TUI: the parts
the Go renderer found in its cell grid by their semantic text), the cell colours of every TUI frame, and the pixel
colours macOS sampled under each text part and in the editor. It reads every measurement it expects from the token
scales, `macos/Sources/Views/Shared/ChromeTokens.swift` and `go/tui/internal/ui/chrome_tokens.go`, and the row pitch
and contrast targets from `docs/design/anatomy.md` and `docs/design/themes.md`, so it carries no numbers of its own.

It writes DIR/audit.json, one row per finding:

  {"scenario", "frontend", "theme", "size", "part", "rule", "expected", "actual", "exception"}

and exits 1 with --check when a finding has no exception. Exceptions live in test/storyboard/audit_exceptions.toml,
each with a scenario, frontend, part, rule, reason and the issue that removes it; an exception that matches nothing
fails too, so the list only shrinks. Python 3.11+, standard library only.
"""

import argparse
import json
import re
import sys
import tomllib
import unicodedata
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
# A colour sampled from pixels can move by a step or two through Metal, capture and colour conversion.
PIXEL_STEP = 6
DEFAULT_OUT = ROOT / "_build" / "storyboard"
SWIFT_TOKENS = ROOT / "macos/Sources/Views/Shared/ChromeTokens.swift"
GO_TOKENS = ROOT / "go/tui/internal/ui/chrome_tokens.go"
ANATOMY = ROOT / "docs/design/anatomy.md"
THEMES = ROOT / "docs/design/themes.md"
EXCEPTIONS = ROOT / "test/storyboard/audit_exceptions.toml"
MAC_TOLERANCE = 0.5


class Failure(Exception):
    pass


# -- the scales -------------------------------------------------------------------------------------------------


class Scale:
    """Every measurement the audit expects, read from the two token sources and the anatomy."""

    def __init__(self):
        swift = SWIFT_TOKENS.read_text()
        spacing = re.search(r"enum Spacing \{(.*?)\n\}", swift, re.S).group(1)
        self.points = {name: float(value) for name, value in re.findall(r"static let (\w+): CGFloat = ([\d.]+)", spacing)}
        go = GO_TOKENS.read_text()
        self.cell_width = int(re.search(r"cellWidthPoints = (\d+)", go).group(1))
        self.cell_height = int(re.search(r"cellHeightPoints = (\d+)", go).group(1))
        self.go_steps = {name.lower(): int(value) for name, value in re.findall(r"\bspace(\w+) space = (\d+)", go)}
        self.metrics = {}
        for name, value in re.findall(r"^\t(\w+)\s+= (space\w+|\d+)", go, re.M):
            self.metrics[name] = value
        anatomy = ANATOMY.read_text()
        self.row_pitch = float(re.search(r"every clickable row is (\d+) pt", anatomy).group(1))
        themes = THEMES.read_text()
        self.text_contrast = float(re.search(r"at least \*\*([\d.]+):1\*\* for text", themes).group(1))
        self.glyph_contrast = float(re.search(r"at least \*\*([\d.]+):1\*\* for glyphs", themes).group(1))
        if set(self.go_steps) != set(self.points):
            raise Failure(f"the macOS and TUI spacing scales name different steps: {sorted(set(self.points) ^ set(self.go_steps))}")

    def step(self, metric):
        """The spacing step a part metric names in chrome_tokens.go (whichKeyColumnGap -> panel)."""
        value = self.metrics[metric]
        if not value.startswith("space"):
            raise Failure(f"{metric} is not a spacing step")
        return value[len("space"):].lower()

    def mac(self, metric):
        return self.points[self.step(metric)]

    def cols(self, metric):
        literal = self.metrics[metric]
        if literal.isdigit():
            return int(literal)
        points = self.go_steps[self.step(metric)]
        cols = points // self.cell_width
        return 1 if cols == 0 and points >= self.go_steps["xs"] else cols

    def rows(self, metric):
        literal = self.metrics[metric]
        if literal.isdigit():
            return int(literal)
        return self.go_steps[self.step(metric)] // self.cell_height


# -- colour ----------------------------------------------------------------------------------------------------------


def luminance(hex_color):
    value = int(hex_color.lstrip("#"), 16)
    channels = [(value >> shift & 255) / 255 for shift in (16, 8, 0)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(fg, bg):
    high, low = sorted((luminance(fg), luminance(bg)), reverse=True)
    return round((high + 0.05) / (low + 0.05), 2)


def rgb(hex_color):
    value = int(hex_color.lstrip("#"), 16)
    return (value >> 16 & 255, value >> 8 & 255, value & 255)


def near(a, b, step=PIXEL_STEP):
    """True when two colours differ by at most `step` in every channel: the same colour sampled on another runner."""
    return all(abs(x - y) <= step for x, y in zip(rgb(a), rgb(b)))


def faint(fg, bg):
    """A faint cell's ink, which terminals draw about halfway toward the surface."""
    return "#%02x%02x%02x" % tuple((x + y) // 2 for x, y in zip(rgb(fg), rgb(bg)))


def cells(text):
    """A TUI text row as cells: a wide character takes two, and the frame file leaves out its continuation cell."""
    out = []
    for char in text:
        out.append(char)
        if unicodedata.east_asian_width(char) in ("W", "F"):
            out.append("")
    return out


# Box drawing, block and geometric shapes, arrows, dingbats, bullets and Nerd Font private-use icons are glyphs (3:1).
GLYPH = re.compile("[\\u2500-\\u25ff\\u2190-\\u21ff\\u2700-\\u27bf\\u2022\\u203a\\u2039\\u00b7~\\ue000-\\uf8ff\\U000f0000-\\U000fffff]")


# -- findings --------------------------------------------------------------------------------------------------------


class Audit:
    def __init__(self, scale):
        self.scale = scale
        self.findings = []
        self.index = {}
        self.metrics = defaultdict(dict)

    def check(self, frame, part, rule, expected, actual, tolerance=0):
        if actual is not None and abs(actual - expected) > tolerance:
            self.flag(frame, part, rule, expected, actual)

    def flag(self, frame, part, rule, expected, actual, pair=None):
        """One finding per frame, part and rule (and colour pair, for contrast); every distinct value it measured is kept."""
        key = (frame["scenario"], frame["frontend"], frame["theme"], frame["size"], part, rule, pair)
        finding = self.index.get(key)
        if finding is None:
            finding = {**frame, "part": part, "rule": rule, "expected": expected, "actual": [], "count": 0}
            if pair:
                finding["pair"] = pair
            self.index[key] = finding
            self.findings.append(finding)
        finding["count"] += 1
        if actual not in finding["actual"]:
            finding["actual"].append(actual)

    def record(self, frame, part, rule, value):
        """Remembers a measurement so the same part can be compared across scenarios."""
        key = (frame["frontend"], frame["theme"], frame["size"], part, rule)
        self.metrics[key][frame["scenario"]] = value


def by_part(parts, name):
    return [p for p in parts if p["part"] == name]


def which_key(audit, frame, parts, mac):
    panel = by_part(parts, "whichKey.panel")
    keys, labels = by_part(parts, "whichKey.entryKey"), by_part(parts, "whichKey.entryLabel")
    if not panel or not keys:
        return
    panel = panel[0]["frame"]
    scale = audit.scale
    tolerance = MAC_TOLERANCE if mac else 0
    trailing = by_part(parts, "whichKey.entryCount") + by_part(parts, "whichKey.platformKey")
    headings = by_part(parts, "whichKey.groupName")
    cols = cluster_columns(keys, labels, mac)
    pitch = scale.row_pitch if mac else scale.rows("whichKeyEntryRows")
    key_to_label = scale.mac("whichKeyKeyToLabel") if mac else scale.cols("whichKeyKeyToLabel")
    column_gap = scale.mac("whichKeyColumnGap") if mac else scale.cols("whichKeyColumnGap")
    inset = scale.mac("whichKeyInsetH") if mac else scale.cols("whichKeyInsetH")
    for index, column in enumerate(cols):
        key_edge = max(k["frame"][0] + k["frame"][2] for k, _ in column)
        label_edges = {l["frame"][0] for _, l in column}
        label_edge = min(label_edges)
        audit.check(frame, "whichKey.entry", "key to label", key_to_label, label_edge - key_edge, tolerance)
        audit.record(frame, "whichKey.entry", "key to label", label_edge - key_edge)
        if max(label_edges) - label_edge > tolerance:
            audit.flag(frame, "whichKey.entryLabel", "one leading edge per key column", label_edge, max(label_edges))
        for (key, _), (next_key, _) in zip(column, column[1:]):
            if heading_between(headings, key, next_key):
                # A new band of columns starts under its own group names (the TUI wraps sections that do not fit).
                continue
            step = next_key["frame"][1] - key["frame"][1]
            audit.check(frame, "whichKey.entry", "entry pitch", pitch, step, tolerance)
            audit.record(frame, "whichKey.entry", "entry pitch", step)
        if mac:
            for key, label in column:
                if key.get("baseline") is not None and label.get("baseline") is not None:
                    audit.check(frame, "whichKey.entry", "one baseline per row", key["baseline"], label["baseline"], MAC_TOLERANCE)
        if index + 1 < len(cols):
            next_left = min(k["frame"][0] for k, _ in cols[index + 1])
            # The column ends after its longest entry: the label and, when shown, its count and ⌘ key.
            right = max(row_right(label, trailing, next_left, mac) for _, label in column)
            audit.check(frame, "whichKey.column", "column gap", column_gap, next_left - right, tolerance)
    first = min(k["frame"][0] for k, _ in cols[0])
    border = 0 if mac else 1
    audit.check(frame, "whichKey.panel", "inset", inset, first - panel[0] - border, tolerance)
    for part in keys + labels + trailing:
        x, y, w, h = part["frame"]
        if x < panel[0] or y < panel[1] or x + w > panel[0] + panel[2] or y + h > panel[1] + panel[3]:
            audit.flag(frame, part["part"], "nothing clips", "inside the panel", part["frame"])
    for label in labels:
        if label.get("truncated") and not label.get("ellipsis"):
            audit.flag(frame, "whichKey.entryLabel", "truncates with …", label.get("text", ""), "cut without …")


def row_right(label, trailing, before, mac):
    """The right edge of an entry: its label, or the count or ⌘ key after it on the same row, before the next column."""
    x, y, w, _ = label["frame"]
    right = x + w
    for part in trailing:
        px, py, pw, _ = part["frame"]
        if abs(py - y) <= (2 if mac else 0) and right <= px < before:
            right = max(right, px + pw)
    return right


def heading_between(headings, key, next_key):
    """Whether a group name sits between two entries of one column, which starts a new band of columns."""
    top, bottom = key["frame"][1], next_key["frame"][1]
    left = key["frame"][0]
    return any(top < h["frame"][1] < bottom and h["frame"][0] <= left + key["frame"][2] for h in headings)


def cluster_columns(keys, labels, mac):
    entries = []
    for key in keys:
        same_row = [l for l in labels if abs(l["frame"][1] - key["frame"][1]) <= (2 if mac else 0) and l["frame"][0] > key["frame"][0]]
        if same_row:
            entries.append((key, min(same_row, key=lambda l: l["frame"][0])))
    entries.sort(key=lambda e: e[1]["frame"][0])
    groups = []
    for entry in entries:
        # A new column starts where a label's leading edge is past the previous column's widest label.
        if groups and entry[0]["frame"][0] < max(l["frame"][0] + l["frame"][2] for _, l in groups[-1]):
            groups[-1].append(entry)
        else:
            groups.append([entry])
    return [sorted(group, key=lambda e: e[0]["frame"][1]) for group in groups]


def modeline(audit, frame, parts, mac):
    bar = by_part(parts, "modeline")
    segments = sorted(by_part(parts, "modeline.segment"), key=lambda p: p["frame"][0])
    controls = by_part(parts, "modeline.control")
    if not bar or not segments:
        return
    bar = bar[0]["frame"]
    scale = audit.scale
    tolerance = MAC_TOLERANCE if mac else 0
    inset = scale.mac("modelineInset") if mac else scale.cols("modelineInset")
    gap = scale.mac("modelineSegmentGap") if mac else scale.cols("modelineSegmentGap")
    leading = min(p["frame"][0] for p in segments + controls)
    audit.check(frame, "modeline", "leading inset", inset, leading - bar[0], tolerance)
    left = [s for s in segments if s["frame"][0] < bar[0] + bar[2] / 2]
    for this, following in zip(left, left[1:]):
        step = following["frame"][0] - (this["frame"][0] + this["frame"][2])
        audit.check(frame, "modeline.segment", "gap between segments", gap, step, tolerance)
    if mac:
        audit.record(frame, "modeline", "height", bar[3])
        for target in [{"frame": bar, "part": "modeline"}] + controls:
            if target["frame"][3] < scale.row_pitch:
                audit.flag(frame, target["part"], "hit target at least one row pitch", scale.row_pitch, target["frame"][3])
    for segment in segments:
        x, y, w, h = segment["frame"]
        if x < bar[0] or x + w > bar[0] + bar[2] + tolerance:
            audit.flag(frame, "modeline.segment", "nothing clips", "inside the modeline", segment["frame"])


def tui_contrast(audit, frame, path):
    from renders import parse_tui  # noqa: E402

    (_, _), rows, styles = parse_tui(path)
    for row, runs in styles.items():
        row_cells = cells(rows[row]) if row < len(rows) else []
        for start, end, fg, bg, attrs in runs:
            chars = "".join(row_cells[start:end + 1]).strip()
            if not chars:
                continue
            ink = faint(fg, bg) if "faint" in attrs.split(",") else fg
            glyph_only = all(GLYPH.match(c) for c in chars)
            target = audit.scale.glyph_contrast if glyph_only else audit.scale.text_contrast
            ratio = contrast(ink, bg)
            if ratio < target:
                audit.flag(frame, "text" if not glyph_only else "glyph", "contrast", target,
                           f"{ratio} ('{chars[:12]}' at row {row})", pair=f"{ink} on {bg}")


def mac_contrast(audit, frame, export):
    """Text parts against the 4.5:1 text target; every syntax ink in the editor against the same target."""
    # A frame without an editor (the project home) samples no code; one with an editor must sample its inks.
    code_shown = bool(export.get("code"))
    if not export.get("samples") or (code_shown and not export["code"].get("inks")):
        audit.flag(frame, "editor.code", "pixels sampled", "colours under the text parts and in the editor", "none")
    for sample in export.get("samples", []):
        for ink in sample["inks"]:
            ratio = contrast(ink, sample["bg"])
            if ratio < audit.scale.text_contrast:
                audit.flag(frame, sample["part"], "contrast", audit.scale.text_contrast,
                           f"{ratio} ('{sample['text'][:16]}')", pair=f"{ink} on {sample['bg']}")
    code = export.get("code") or {}
    cursor = code.get("cursor")
    for ink in code.get("inks", []):
        if cursor and near(ink, cursor):
            continue
        ratio = contrast(ink, code["bg"])
        if ratio < audit.scale.text_contrast:
            audit.flag(frame, "editor.code", "contrast", audit.scale.text_contrast, ratio, pair=f"{ink} on {code['bg']}")


def same_component(audit):
    for (frontend, theme, size, part, rule), values in audit.metrics.items():
        if len(set(values.values())) > 1:
            for scenario, value in sorted(values.items()):
                audit.flag({"scenario": scenario, "frontend": frontend, "theme": theme, "size": size}, part,
                           f"same metrics everywhere ({rule})", sorted(set(values.values())), value)


# -- driver ------------------------------------------------------------------------------------------------------


def load_exceptions():
    if not EXCEPTIONS.is_file():
        return []
    exceptions = tomllib.loads(EXCEPTIONS.read_text()).get("exception", [])
    for exception in exceptions:
        missing = [key for key in ("scenario", "frontend", "part", "rule", "reason", "issue") if not exception.get(key)]
        if exception.get("rule") == "contrast" and not (exception.get("theme") and exception.get("pairs")):
            missing += ["theme", "pairs"]
        if missing:
            raise Failure(f"an audit exception needs {', '.join(missing)}: {exception}")
    return exceptions


def listed(value):
    return value if isinstance(value, list) else [value]


def same_pair(a, b):
    """Colour pairs "#fg on #bg", equal within a sampling step."""
    (fa, ba), (fb, bb) = a.split(" on "), b.split(" on ")
    return near(fa, fb) and near(ba, bb)


def matches(exception, finding):
    """An exception names its scenarios (one id, a list, or "*"), frontend, part and rule, and optionally a theme.

    A contrast exception also lists the colour pairs it excuses, so a new failing colour is a new finding."""
    for key in ("scenario", "frontend", "part", "rule", "theme"):
        wanted = exception.get(key, "*")
        if wanted == "*":
            continue
        if finding[key] not in listed(wanted):
            return False
    if "pairs" in exception:
        return "pair" in finding and any(same_pair(finding["pair"], pair) for pair in exception["pairs"])
    return True


def stale_entries(exceptions, used, frontends):
    """Each listed scenario and colour pair of an exception that excused nothing, so a partial fix shrinks the list.

    An exception for a frontend this run did not audit (macOS skipped because none of its inputs changed) is not stale."""
    stale = []
    for index, exception in enumerate(exceptions):
        if exception["frontend"] not in list(frontends) + ["*"]:
            continue
        hits = used.get(index, [])
        scenarios = [] if exception["scenario"] == "*" else listed(exception["scenario"])
        unused = [s for s in scenarios if not any(f["scenario"] == s for f in hits)]
        if exception["scenario"] == "*" and not hits:
            unused = ["*"]
        pairs = [p for p in exception.get("pairs", []) if not any(same_pair(f["pair"], p) for f in hits)]
        if unused or pairs:
            stale.append({**exception, "unused_scenarios": unused, "unused_pairs": pairs})
    return stale


def run_audit(out, frontends):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    scale = Scale()
    audit = Audit(scale)
    manifest = json.loads((out / "manifest.json").read_text())
    renders = out / "renders"
    for scenario in manifest["scenarios"]:
        if scenario["status"] != "built":
            continue
        sid = scenario["id"]
        exports = sorted((renders / sid).glob("macos-*.json")) + sorted((renders / sid).glob("tui-*.parts.json"))
        for path in exports:
            export = json.loads(path.read_text())
            frontend = export["frontend"]
            if frontend not in frontends:
                continue
            frame = {"scenario": sid, "frontend": frontend, "theme": export["theme"], "size": export["size"]}
            parts = export.get("parts", [])
            mac = frontend == "macos"
            for part in parts:
                if part.get("missing"):
                    audit.flag(frame, part["part"], "part located", "located in the frame", part.get("text", ""))
            which_key(audit, frame, parts, mac)
            modeline(audit, frame, parts, mac)
            if mac:
                mac_contrast(audit, frame, export)
            else:
                tui_contrast(audit, frame, path.with_name(path.name.replace(".parts.json", ".txt")))
    same_component(audit)
    return audit.findings


def evaluate(out, frontends):
    """Runs the audit and applies the exceptions: every finding with its exception or None, and the stale exceptions."""
    findings = run_audit(out, frontends)
    exceptions = load_exceptions()
    used = defaultdict(list)
    for finding in findings:
        finding["exception"] = None
        for index, exception in enumerate(exceptions):
            if matches(exception, finding):
                finding["exception"] = f"#{exception['issue']}: {exception['reason']}"
                used[index].append(finding)
                break
    return findings, stale_entries(exceptions, used, frontends)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--frontends", default="tui,macos")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    out = args.out.resolve()
    try:
        findings, stale = evaluate(out, args.frontends.split(","))
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    (out / "audit.json").write_text(json.dumps({"findings": findings, "stale_exceptions": stale}, indent=2) + "\n")
    open_findings = [f for f in findings if f["exception"] is None]
    lines = [f"## Layout audit", "", f"{len(findings)} findings, {len(open_findings)} without an exception, "
             f"{len(stale)} stale exceptions (rules: docs/design/anatomy.md, \"The layout audit\").", ""]
    for finding in open_findings:
        lines.append(f"- `{finding['scenario']}` {finding['frontend']} {finding['theme']} {finding['size']} "
                     f"{finding['part']}: {finding['rule']}: expected {finding['expected']}, got {finding['actual']}")
    for exception in stale:
        lines.append(f"- stale exception #{exception['issue']} {exception['frontend']} {exception['part']} "
                     f"{exception['rule']}: remove scenarios {exception['unused_scenarios']} and colour pairs "
                     f"{exception['unused_pairs']} (all of them: remove the entry)")
    summary = "\n".join(lines) + "\n"
    (out / "audit.md").write_text(summary)
    print(summary)
    return 1 if args.check and (open_findings or stale) else 0


if __name__ == "__main__":
    sys.exit(main())
