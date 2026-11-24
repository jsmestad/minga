#!/usr/bin/env python3
"""Check the marketing site (site/*.html) against the shipped keymap and the design docs.

The site makes two kinds of claims. Text inside an element with data-status="planned" describes something that has not shipped yet. Every other piece of visible text is a claim about today's build. This script fails when either kind of claim drifts:

- Keys outside planned blocks must exist in the shipped keymap. Keys inside planned blocks must exist in docs/design/keys.md.
- Keys listed in design/tools/site_retired_keys.txt always fail.
- State words next to an Orbit glyph are one of the six (Working, Needs you, Waiting, Stopped, Failed, Done).
- Which-key groups never read "+group".
- The only Bavarian voice is "Servus.", "Passt." and "Ciao.".
- Twist glyphs appear only inside an element with data-surface="gutter".
- A claim about the default theme names Catppuccin Frappé.
- Each phrase in design/tools/site_claims.toml that appears outside a planned block needs its code pattern to exist.
- Page metadata follows the same rules as visible text: the `description`, `og:description` and `twitter:description` meta tags and every JSON-LD `description`. Metadata has no planned blocks of its own, so it is a claim about today's build unless `<head>` carries data-status="planned".
- Lab copy belongs in the page HTML, where the rules above can read it. The check counts every leader sequence (`SPC` plus at least one key) and every phrase from site_claims.toml in site/ts/src/**/*.ts, and fails when a count is above the one design/tools/site_ts_copy_baseline.tsv allows. It reads each file as plain text, so comments count too. The baseline only shrinks: a row whose count is above the sources fails as well. This check runs only on a full run, with no page arguments.

The visible label is CSS only (site/styles.css). A planned block draws an "In development" pill, or "In development · v0.1.0" when it names its release in data-since. A page that is wholly about an unreleased version shows one `.status-banner` under the site header instead, and its container carries data-pill="off".

Run it from the repository root with Python 3.11 or newer. It needs no packages:

    python3 design/tools/site_check.py
    python3 design/tools/site_check.py site/index.html   # only some pages

Each failure prints one line, `page:line kind phrase reason`, and the exit status is 1.

Key notation. Keys are compared in one canonical form: tokens separated by single spaces, leader sequences start with `SPC`, and chords are written `C-` (⌃ control), `M-` (⌥ option), `S-` (⇧ shift) and `D-` (⌘ command), in that order, followed by the key. A letter after a modifier is lower case unless ⇧ is part of the chord, so the Mac glyph ⌃J and the keymap source `~k(C-j)` both become `C-j`. Named keys: ↩ is `RET`, ⎋ is `ESC`, ⇥ is `TAB`, ⌫ is `DEL`. Two chords separated by one space are one sequence (`⌃\\ ⌃N` is `C-\\ C-n`).

Where the shipped keys come from:

- `~k(...)` and `~K(...)` in lib/minga/keymap/defaults.ex, normal_prefixes.ex, shared_groups.ex, prompt_keys.ex and scope/*.ex. Entries inside `@leader_bindings` and `@group_prefixes` get the `SPC` prefix; entries inside `filetype_bindings/0` get `SPC m`.
- Raw tuples such as `[{@enter, @ctrl}]` in the same files.
- ⌘ chords from `keyboardShortcut(...)` and `keyEquivalent:` in macos/Sources (Swift menu commands).
- Ex commands from `do_parse("...")` heads in lib/minga/command/parser.ex; slash commands from `name: "..."` in lib/minga_editor/agent/slash_command.ex.

Ex commands are only recognised inside <code> or <kbd> when the name is a shipped or designed command; any other `:word` is treated as an Elixir atom (`:cua`, `:eager`) and ignored. Slash commands inside <code> or <kbd> must be shipped (or designed, inside a planned block). Text inside <pre> is user code (config examples bind their own keys), so keys there are not checked. An element with data-check="off" opts its text out of key checks; use it only when quoting another product (Claude Code's /rewind).
"""

from __future__ import annotations

import html
import json
import re
import sys
import tomllib
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "site"
KEYS_MD = ROOT / "docs" / "design" / "keys.md"
DESIGN_DIR = ROOT / "docs" / "design"
RETIRED = Path(__file__).with_name("site_retired_keys.txt")
CLAIMS = Path(__file__).with_name("site_claims.toml")
TS_SRC = SITE / "ts" / "src"
TS_BASELINE = Path(__file__).with_name("site_ts_copy_baseline.tsv")

KEYMAP_DIR = ROOT / "lib" / "minga" / "keymap"
KEYMAP_FILES = [
    KEYMAP_DIR / "defaults.ex",
    KEYMAP_DIR / "normal_prefixes.ex",
    KEYMAP_DIR / "shared_groups.ex",
    KEYMAP_DIR / "prompt_keys.ex",
    *sorted((KEYMAP_DIR / "scope").glob("*.ex")),
]
EX_PARSER = ROOT / "lib" / "minga" / "command" / "parser.ex"
SLASH_REGISTRY = ROOT / "lib" / "minga_editor" / "agent" / "slash_command.ex"
MACOS_SOURCES = ROOT / "macos" / "Sources"

SKIP_TAGS = {"script", "style", "svg", "template"}
META_DESCRIPTIONS = {"description", "og:description", "twitter:description"}
VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
BLOCK_TAGS = {
    "p", "li", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "dd", "dt", "figcaption", "pre",
    "blockquote", "div", "section", "header", "footer", "nav", "figure", "ul", "ol", "table", "tr",
    "main", "article", "aside", "button",
}

STATE_WORDS = ("Working", "Needs you", "Waiting", "Stopped", "Failed", "Done")
ORBIT_GLYPHS = "◐◉○◆●"
WRONG_STATE_WORDS = {
    "running", "pending", "busy", "error", "errored", "complete", "completed", "finished",
    "idle", "active", "paused", "succeeded", "success", "blocked", "in-progress",
}
TWIST_GLYPHS = "▚▐▞▌"
VOICE_OK = ("Servus.", "Passt.", "Ciao.")
VOICE_DENY = [
    r"Grüß Gott", r"Griaß", r"Pfiat", r"Habe die Ehre", r"\bMoin\b", r"\bJawohl\b", r"\bProst\b",
    r"\bObacht\b", r"\bJa mei\b", r"\bFreilich\b", r"\bTschüss\b", r"\bMahlzeit\b", r"\bGaudi\b",
    r"\bOida\b", r"\bSauber!", r"\bFertig!",
]

MOD_GLYPHS = {"⌃": "C", "⌥": "M", "⇧": "S", "⌘": "D"}
MOD_ORDER = "CMSD"
NAMED_KEYS = {"↩": "RET", "⎋": "ESC", "⇥": "TAB", "⌫": "DEL", "←": "LEFT", "→": "RIGHT", "↑": "UP", "↓": "DOWN"}

SPC_RE = re.compile(r"(?<![\w-])SPC((?:[  ](?:TAB|RET|ESC|[!-~])(?=[\s,;:)< ]|$|[.?!](?:\s|$)))*)")
BRACKET_RE = re.compile(r"(?<![\w\[\]\\])([\[\]])([\[\]]|[A-Za-z])(?![\w\[\]])")
CHORD_RE = re.compile(r"([⌃⌥⇧⌘]+)(↩|⎋|⇥|⌫|←|→|↑|↓|[!-~])")
CHORD_SEQ_RE = re.compile(r"[⌃⌥⇧⌘]+(?:↩|⎋|⇥|⌫|←|→|↑|↓|[!-~])(?: [⌃⌥⇧⌘]+(?:↩|⎋|⇥|⌫|←|→|↑|↓|[!-~]))*")
EX_RE = re.compile(r"^:(?:%|'<,'>)?([A-Za-z][\w-]*)!?(?:\s|$)")
SLASH_RE = re.compile(r"^/([a-z][\w-]*)(?:\s|$)")
PLUS_GROUP_RE = re.compile(r"(?<![\w+\-])\+[A-Za-z][\w-]*")


# ---------------------------------------------------------------------------
# Key normalisation
# ---------------------------------------------------------------------------


def chord(mods: set[str], key: str) -> str:
    if len(key) == 1 and key.isalpha() and "S" not in mods and mods:
        key = key.lower()
    prefix = "".join(f"{m}-" for m in MOD_ORDER if m in mods)
    return prefix + key


def glyph_chord(text: str) -> str:
    match = CHORD_RE.fullmatch(text)
    mods = {MOD_GLYPHS[g] for g in match.group(1)}
    key = NAMED_KEYS.get(match.group(2), match.group(2))
    return chord(mods, key)


def parser_token(token: str) -> str:
    """Normalise one KeyParser token (`C-d`, `M-:`, `SPC`, `a`) to the canonical form."""
    parts = token.split("-")
    if len(parts) > 1 and parts[-1] == "" and token.endswith("-"):
        parts = parts[:-2] + ["-"]
    if len(parts) == 1:
        return token
    mods = set(parts[:-1])
    return chord(mods, parts[-1])


def sigil_keys(body: str) -> list[str]:
    return [parser_token(t) for t in body.split()]


# ---------------------------------------------------------------------------
# Shipped and designed key sets
# ---------------------------------------------------------------------------


@dataclass
class KeySets:
    shipped: set[str] = field(default_factory=set)
    designed: set[str] = field(default_factory=set)
    ex_shipped: set[str] = field(default_factory=set)
    ex_designed: set[str] = field(default_factory=set)
    slash_shipped: set[str] = field(default_factory=set)
    slash_designed: set[str] = field(default_factory=set)


SIGIL_RE = re.compile(r"~[kK]\(([^)]*)\)")
TUPLE_RE = re.compile(r"\{(@\w+|\?.|0x[0-9A-Fa-f]+|\d[\d_]*),\s*(@\w+|0x[0-9A-Fa-f]+|0)\}")
TUPLE_KEYS = {"@enter": "RET", "13": "RET", "@arrow_up": "UP", "@arrow_down": "DOWN", "@arrow_up_mac": "UP", "@arrow_down_mac": "DOWN", "0xF700": "UP", "0xF701": "DOWN", "57_352": "UP", "57_353": "DOWN", "0x0A": "LF"}
TUPLE_MODS = {"@ctrl": {"C"}, "@alt": {"M"}, "@shift": {"S"}, "@cmd": {"D"}, "0": set(), "0x01": {"S"}, "0x02": {"C"}, "0x04": {"M"}, "0x08": {"D"}}


def shipped_keys(keys: KeySets) -> None:
    for path in KEYMAP_FILES:
        prefix = ""
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if path.name == "defaults.ex":
                if stripped in ("@leader_bindings [", "@group_prefixes ["):
                    prefix = "SPC"
                elif stripped.startswith("def filetype_bindings"):
                    prefix = "SPC m"
                elif prefix == "SPC" and line.startswith("  ]"):
                    prefix = ""
                elif prefix == "SPC m" and re.match(r"  (def|defp|@doc|@spec) ", line) and "filetype_bindings" not in line:
                    prefix = ""
            for body in SIGIL_RE.findall(line):
                seq = sigil_keys(body)
                if len(seq) == 2 and seq[0] in ("]", "["):
                    seq = [seq[0] + seq[1]]
                full = ([prefix] if prefix else []) + seq
                keys.shipped.add(" ".join(full))
            for key, mod in TUPLE_RE.findall(line):
                name = TUPLE_KEYS.get(key, key[1:] if key.startswith("?") else None)
                mods = TUPLE_MODS.get(mod)
                if name and mods is not None:
                    keys.shipped.add(chord(set(mods), name))
    keys.shipped.add("SPC")

    swift_mods = {".command": "D", ".shift": "S", ".option": "M", ".control": "C"}
    for path in MACOS_SOURCES.rglob("*.swift"):
        text = path.read_text(encoding="utf-8", errors="replace")
        for key, mods in re.findall(r'keyboardShortcut\("([^"]+)",\s*modifiers:\s*(\[[^\]]*\]|\.\w+)\)', text):
            keys.shipped.add(chord({swift_mods[m] for m in re.findall(r"\.\w+", mods) if m in swift_mods}, key))
        for key in re.findall(r'keyEquivalent:\s*"([^"]+)"', text):
            keys.shipped.add(chord({"D"}, key))

    for name in re.findall(r'defp do_parse\("([^"]+)"', EX_PARSER.read_text(encoding="utf-8")):
        word = name.split(" ")[0].rstrip("!=")
        if word:
            keys.ex_shipped.add(word)
    keys.slash_shipped.update(re.findall(r'name: "([a-z][\w-]*)"', SLASH_REGISTRY.read_text(encoding="utf-8")))


def text_keys(text: str) -> list[tuple[int, str]]:
    """Return (offset, canonical key) for every key named in a run of prose."""
    found: list[tuple[int, str]] = []
    for m in SPC_RE.finditer(text):
        tokens = m.group(1).replace(" ", " ").split()
        while len(tokens) > 1 and tokens[-1] in ("/", ".", ",", ";", ":", "?", ")"):
            tokens.pop()
        found.append((m.start(), " ".join(["SPC", *tokens])))
    for m in BRACKET_RE.finditer(text):
        found.append((m.start(), m.group(1) + m.group(2)))
    for m in CHORD_SEQ_RE.finditer(text):
        found.append((m.start(), " ".join(glyph_chord(part) for part in m.group(0).split(" "))))
    return found


def designed_keys(keys: KeySets) -> None:
    """Keys from docs/design/keys.md: every table cell except the Status column, skipping retired rows, plus prose after the Leader heading."""
    in_scope = False
    status_col = None
    for line in KEYS_MD.read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            in_scope = line.strip() != "## The key grammar" and line.strip() != "## Rules"
            status_col = None
            continue
        if not in_scope:
            continue
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if all(set(c) <= set("-: ") for c in cells):
                continue
            if "Status" in cells and status_col is None and cells[0] in ("Keys", "Buffer"):
                status_col = cells.index("Status")
                continue
            if status_col is not None and status_col < len(cells) and cells[status_col].startswith("retired"):
                continue
            usable = [c for i, c in enumerate(cells) if i != status_col]
            chunks = usable
        else:
            chunks = [line]
        for chunk in chunks:
            for span in re.findall(r"`([^`]+)`", chunk) or [chunk]:
                for _, key in text_keys(span):
                    keys.designed.add(key)
                ex = EX_RE.match(span.strip())
                if ex:
                    keys.ex_designed.add(ex.group(1))
            for _, key in text_keys(re.sub(r"`", "", chunk)):
                keys.designed.add(key)
    for md in DESIGN_DIR.glob("*.md"):
        keys.slash_designed.update(re.findall(r"`/([a-z][\w-]*)", md.read_text(encoding="utf-8")))


# ---------------------------------------------------------------------------
# HTML extraction
# ---------------------------------------------------------------------------


@dataclass
class Flags:
    planned: bool = False
    gutter: bool = False
    off: bool = False
    pre: bool = False
    today: bool = False


@dataclass
class Chunk:
    """Consecutive visible text sharing one block element and one set of flags."""

    line: int
    flags: Flags
    text: str = ""
    lines: list[tuple[int, int]] = field(default_factory=list)  # (offset, line)

    def line_at(self, offset: int) -> int:
        line, start = self.line, 0
        for off, ln in self.lines:
            if off <= offset:
                line, start = ln, off
        return line + self.text.count("\n", start, offset)


@dataclass
class Element:
    tag: str
    flags: Flags
    line: int
    block_id: int
    text: str = ""


class SiteParser(HTMLParser):
    def __init__(self, page: str, report):
        super().__init__(convert_charrefs=True)
        self.page = page
        self.report = report
        self.stack: list[Element] = []
        self.skip_depth = 0
        self.chunks: list[Chunk] = []
        self.inline_elements: list[Element] = []
        self._block_counter = 0
        self._chunk_key = None
        self._json_ld: tuple[int, Flags, list[str]] | None = None

    def _flags(self) -> Flags:
        return self.stack[-1].flags if self.stack else Flags()

    def _metadata(self, line: int, flags: Flags, text: str) -> None:
        """Add one metadata value as its own chunk, so the rules for visible text apply to it."""
        self.chunks.append(Chunk(line, flags, text))
        self._chunk_key = None

    def _json_ld_descriptions(self, node, described: bool = False) -> list[str]:
        """Every description in a JSON-LD value: a string, a list of them, or a `{"@value": ...}` object, at any depth."""
        if isinstance(node, str):
            return [node] if described else []
        if isinstance(node, list):
            return [d for v in node for d in self._json_ld_descriptions(v, described)]
        if isinstance(node, dict):
            return [d for k, v in node.items() for d in self._json_ld_descriptions(v, k == "description" or (described and k == "@value"))]
        return []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if self.skip_depth or tag in SKIP_TAGS:
            if tag == "script" and not self.skip_depth and (a.get("type") or "").split(";")[0].strip().lower() == "application/ld+json":
                self._json_ld = (self.getpos()[0], self._flags(), [])
            if tag not in VOID_TAGS:
                self.skip_depth += 1
            return
        if tag == "meta" and {(a.get("name") or "").lower(), (a.get("property") or "").lower()} & META_DESCRIPTIONS:
            self._metadata(self.getpos()[0], self._flags(), a.get("content") or "")
        if tag in VOID_TAGS:
            return
        parent = self._flags()
        status = a.get("data-status")
        line = self.getpos()[0]
        if status is not None and status != "planned":
            self.report(self.page, line, "markup", f'data-status="{status}"', 'the only status is "planned"')
        planned = parent.planned or status == "planned"
        today = parent.today or a.get("data-build") == "today"
        if status == "planned" and today and "data-since" not in a:
            self.report(self.page, line, "markup", "data-status=\"planned\"", 'planned asides in a data-build="today" page need data-since')
        flags = Flags(
            planned=planned,
            gutter=parent.gutter or a.get("data-surface") == "gutter",
            off=parent.off or a.get("data-check") == "off",
            pre=parent.pre or tag == "pre",
            today=today,
        )
        if tag in BLOCK_TAGS or not self.stack:
            self._block_counter += 1
            block_id = self._block_counter
        else:
            block_id = self.stack[-1].block_id
        self.stack.append(Element(tag, flags, line, block_id))

    def handle_startendtag(self, tag, attrs):
        if self.skip_depth:
            return
        self.handle_starttag(tag, attrs)
        if tag not in VOID_TAGS:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if self.skip_depth:
            if tag not in VOID_TAGS:
                self.skip_depth -= 1
            if tag == "script" and not self.skip_depth and self._json_ld is not None:
                line, flags, parts = self._json_ld
                self._json_ld = None
                try:
                    descriptions = self._json_ld_descriptions(json.loads("".join(parts)))
                except json.JSONDecodeError as error:
                    self.report(self.page, line, "markup", "application/ld+json", f"JSON-LD does not parse, so its descriptions are unchecked: {error.msg}")
                    return
                for text in descriptions:
                    self._metadata(line, flags, text)
            return
        if tag in VOID_TAGS:
            return
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i].tag == tag:
                closed = self.stack[i:]
                del self.stack[i:]
                for el in closed:
                    if el.tag in ("code", "kbd"):
                        self.inline_elements.append(el)
                return

    def handle_data(self, data):
        if self._json_ld is not None:
            self._json_ld[2].append(data)
        if self.skip_depth or not self.stack:
            return
        for el in self.stack:
            if el.tag in ("code", "kbd"):
                el.text += data
        top = self.stack[-1]
        key = (top.block_id, top.flags.planned, top.flags.gutter, top.flags.off, top.flags.pre)
        if key != self._chunk_key or not self.chunks:
            self.chunks.append(Chunk(self.getpos()[0], top.flags))
            self._chunk_key = key
        chunk = self.chunks[-1]
        chunk.lines.append((len(chunk.text), self.getpos()[0]))
        chunk.text += data


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------


@dataclass
class Retired:
    key: str
    context: re.Pattern | None
    reason: str

    def matches(self, key: str) -> bool:
        if self.key.endswith(" *"):
            return key.startswith(self.key[:-1])
        return key == self.key


def load_retired() -> list[Retired]:
    entries = []
    for raw in RETIRED.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.startswith("#"):
            continue
        key, context, reason = (part.strip() for part in raw.split("\t"))
        entries.append(Retired(key, None if context == "*" else re.compile(context, re.I), reason))
    return entries


@dataclass
class Claim:
    phrase: str
    pattern: re.Pattern
    paths: list[str]
    reason: str


def load_claims() -> list[Claim]:
    data = tomllib.loads(CLAIMS.read_text(encoding="utf-8"))
    return [Claim(c["phrase"], re.compile(c["pattern"]), c["paths"], c.get("reason", "")) for c in data["claim"]]


_corpus: dict[str, list[str]] = {}


def corpus(path: str) -> list[str]:
    if path not in _corpus:
        root = ROOT / path
        files = [root] if root.is_file() else [p for p in root.rglob("*") if p.is_file()]
        texts = []
        for f in files:
            try:
                texts.append(f.read_text(encoding="utf-8"))
            except (UnicodeDecodeError, OSError):
                continue
        _corpus[path] = texts
    return _corpus[path]


_claim_found: dict[str, bool] = {}


def claim_backed(claim: Claim) -> bool:
    if claim.phrase not in _claim_found:
        _claim_found[claim.phrase] = any(claim.pattern.search(t) for p in claim.paths for t in corpus(p))
    return _claim_found[claim.phrase]


def sentences(text: str) -> list[tuple[int, str]]:
    out, start = [], 0
    for m in re.finditer(r"[.!?](?=\s|$)", text):
        out.append((start, text[start : m.end()]))
        start = m.end()
    if start < len(text):
        out.append((start, text[start:]))
    return out


def check_page(path: Path, keys: KeySets, retired: list[Retired], claims: list[Claim], findings: list[str]) -> None:
    page = path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else str(path)
    seen = set()

    def report(pg, line, kind, phrase, reason):
        entry = f"{pg}:{line} {kind} {phrase!r} {reason}"
        if entry not in seen:
            seen.add(entry)
            findings.append(entry)

    parser = SiteParser(page, report)
    parser.feed(path.read_text(encoding="utf-8"))
    parser.close()

    def check_key(line, key, flags, context_text):
        for r in retired:
            if r.matches(key) and (r.context is None or r.context.search(context_text)):
                report(page, line, "key", key, f"retired: {r.reason}")
                return
        if flags.off:
            return
        if flags.planned:
            if key not in keys.designed and key not in keys.shipped:
                report(page, line, "key", key, "planned key is not in docs/design/keys.md")
        elif key not in keys.shipped:
            reason = "not in the shipped keymap"
            if key in keys.designed:
                reason += "; it is designed, so wrap the claim in data-status=\"planned\""
            report(page, line, "key", key, reason)

    for chunk in parser.chunks:
        text, flags = chunk.text, chunk.flags
        if not flags.pre:
            for off, key in text_keys(text):
                check_key(chunk.line_at(off), key, flags, text)

            for m in re.finditer(f"[{ORBIT_GLYPHS}]", text):
                tail = re.split(f"[{ORBIT_GLYPHS}·]", text[m.end() :], maxsplit=1)[0]
                words = [w for w in re.findall(r"[A-Za-z][\w-]*", tail)][:3]
                for w in words:
                    if w.lower() in WRONG_STATE_WORDS:
                        report(page, chunk.line_at(m.start()), "state", w, f"state words are {', '.join(STATE_WORDS)}")
            for m in re.finditer(r"\b\d+ (" + "|".join(WRONG_STATE_WORDS) + r")\b", text, re.I):
                report(page, chunk.line_at(m.start()), "state", m.group(0), f"state words are {', '.join(STATE_WORDS)}")

            for m in PLUS_GROUP_RE.finditer(text):
                report(page, chunk.line_at(m.start()), "group", m.group(0), 'which-key groups read "Name ›", never "+group"')

            for pattern in VOICE_DENY:
                for m in re.finditer(pattern, text):
                    report(page, chunk.line_at(m.start()), "voice", m.group(0), f"the only Bavarian voice is {' '.join(VOICE_OK)}")
            for m in re.finditer(r"\b(Servus|Passt|Ciao)\b(?!\.)", text, re.I):
                report(page, chunk.line_at(m.start()), "voice", m.group(0), f"write it as {' '.join(VOICE_OK)}")

            for off, sentence in sentences(text):
                if re.search(r"\bdefault", sentence, re.I) and re.search(r"\btheme\b", sentence, re.I) and "Catppuccin Frappé" not in sentence:
                    report(page, chunk.line_at(off), "theme", sentence.strip()[:60], "a default theme claim names Catppuccin Frappé")
            for m in re.finditer(r"Frappe\b", text):
                report(page, chunk.line_at(m.start()), "theme", m.group(0), "write Catppuccin Frappé")

            if not flags.planned:
                lowered = text.lower()
                for claim in claims:
                    idx = lowered.find(claim.phrase.lower())
                    if idx >= 0 and not claim_backed(claim):
                        report(page, chunk.line_at(idx), "claim", claim.phrase, f"pattern /{claim.pattern.pattern}/ not found in {', '.join(claim.paths)}; mark it data-status=\"planned\" ({claim.reason})")

        if not flags.gutter:
            for m in re.finditer(f"[{TWIST_GLYPHS}]", text):
                report(page, chunk.line_at(m.start()), "twist", m.group(0), 'the twist appears only in the code gutter (data-surface="gutter")')

    for el in parser.inline_elements:
        text = el.text.strip()
        flags = el.flags
        if flags.pre:
            continue
        for r in retired:
            if r.matches(text) and r.context is None:
                report(page, el.line, "key", text, f"retired: {r.reason}")
        if flags.off:
            continue
        ex = EX_RE.match(text)
        if ex:
            name = ex.group(1)
            if name in keys.ex_shipped:
                pass
            elif name in keys.ex_designed and not flags.planned:
                report(page, el.line, "ex", text, 'designed but not shipped; wrap the claim in data-status="planned"')
        slash = SLASH_RE.match(text)
        if slash:
            name = slash.group(1)
            if name in keys.slash_shipped:
                pass
            elif flags.planned and name in keys.slash_designed:
                pass
            else:
                report(page, el.line, "slash", text, "not a shipped slash command" + ("" if flags.planned else " (or designed, inside a planned block)"))


# ---------------------------------------------------------------------------
# Lab copy in TypeScript
# ---------------------------------------------------------------------------

TS_ESCAPE_RE = re.compile(r"""\\["'`ntr]""")
TS_TAG_RE = re.compile(r"</?[A-Za-z][^<>]*>")
TS_COPY_ATTR_RE = re.compile(r"""\b(?:aria-label|title|alt|placeholder)=(["'])(.*?)\1""", re.S)
TS_KEY = r"(?:TAB|RET|ESC|(?![\"'`])[!-~])"  # a quote ends the sequence: `"SPC " + key` is a bare SPC
TS_LEADER_RE = re.compile(r"(?<![\w-])SPC((?: " + TS_KEY + r"(?=[\s,;:)<\"'`]|$|[.?!](?:[\s\"'`]|$)))*)")
TS_RANGE_RE = re.compile(r" ([!-~])[-–]([!-~])(?![\w-])")

TsCopy = dict[tuple[str, str], list[tuple[str, int]]]  # (kind, value) -> [(file, line)]


def ts_text(source: str) -> str:
    """Reduce a TypeScript source to the prose a reader could see, keeping its line breaks.

    The scan does not know what a string literal is, so comments and code count too. Escapes that end a word (`\\"`, `\\n`) become a space, HTML tags go, entities are decoded and runs of spaces collapse, so `<kbd>SPC</kbd> <kbd>a</kbd>` and `SPC&nbsp;a` both read `SPC a`. A tag keeps the attributes a reader meets (aria-label, title, alt, placeholder).
    """

    def tag_copy(m: re.Match) -> str:
        copy = " ".join(value for _, value in TS_COPY_ATTR_RE.findall(m.group(0)))
        return f" {copy} " + "\n" * m.group(0).count("\n")

    text = TS_ESCAPE_RE.sub(" ", source)
    text = TS_TAG_RE.sub(tag_copy, text)
    text = html.unescape(text)
    return re.sub(r"[^\S\n]+", " ", text)


def ts_claim_pattern(phrase: str) -> re.Pattern:
    """Whole words only. A one-word phrase matches as written, so `Twist` in prose counts and a `"twist"` state tag does not."""
    words = phrase.split()
    body = r"\s+".join(re.escape(word) for word in words)
    return re.compile(r"(?<![\w-])" + body + r"(?![\w-])", 0 if len(words) == 1 else re.I)


def ts_copy(source: str, claims: list[Claim]) -> list[tuple[int, str, str]]:
    """Return (line, kind, value) for each leader sequence and claim phrase in one source.

    A leader sequence is `SPC` plus at least one key. A bare `SPC` is a shipped key and a common state value, so it is not counted. A range legend such as `SPC 1-4` is one sequence.
    """
    text = ts_text(source)
    found: list[tuple[int, str, str]] = []
    for number, line in enumerate(text.split("\n"), start=1):
        for m in TS_LEADER_RE.finditer(line):
            tokens = m.group(1).split()
            while len(tokens) > 1 and tokens[-1] in ("/", ".", ",", ";", ":", "?", ")"):
                tokens.pop()
            legend = TS_RANGE_RE.match(line, m.end())
            if legend:
                tokens.append(f"{legend.group(1)}-{legend.group(2)}")
            if tokens:
                found.append((number, "key", " ".join(["SPC", *tokens])))
    for claim in claims:
        for m in ts_claim_pattern(claim.phrase).finditer(text):
            found.append((text.count("\n", 0, m.start()) + 1, "claim", claim.phrase))
    return found


def scan_ts_copy(src: Path, claims: list[Claim]) -> TsCopy:
    seen: TsCopy = {}
    for path in sorted(src.rglob("*.ts")):
        try:
            source = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line, kind, value in ts_copy(source, claims):
            seen.setdefault((kind, value), []).append((path.relative_to(src).as_posix(), line))
    return seen


def read_ts_baseline(path: Path, report) -> dict[tuple[str, str], tuple[int, int]]:
    """Read the baseline as {(kind, value): (count, row line)}."""
    rows: dict[tuple[str, str], tuple[int, int]] = {}
    if not path.exists():
        return rows
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw.strip() or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 3 or not (parts[2].isascii() and parts[2].isdigit()) or int(parts[2]) < 1 or (parts[0], parts[1]) in rows:
            report(display_path(path), number, "ts-baseline", raw, "a row is kind, value and a count of 1 or more, tab separated, once per value")
            continue
        rows[(parts[0], parts[1])] = (int(parts[2]), number)
    return rows


def display_path(path: Path) -> str:
    return path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else str(path)


def check_ts_copy(src: Path, baseline: Path, claims: list[Claim], findings: list[str]) -> None:
    """Fail on lab copy in the TypeScript sources that the baseline does not allow, and on baseline rows the sources no longer reach."""

    def report(page, line, kind, phrase, reason):
        findings.append(f"{page}:{line} {kind} {phrase!r} {reason}")

    allowed = read_ts_baseline(baseline, report)
    seen = scan_ts_copy(src, claims)
    for (kind, value), places in seen.items():
        count = allowed.get((kind, value), (0, 0))[0]
        if len(places) > count:
            files = sorted({name for name, _ in places})
            name, line = places[-1]
            what = "key legend" if kind == "key" else "claim phrase"
            reason = (
                f"{what} in the lab TypeScript: {len(places)} in {', '.join(files)}, the baseline allows {count}. "
                f"Move the copy into the page HTML; never add or raise rows in {display_path(baseline)}"
            )
            report(display_path(src / name), line, "ts-copy", value, reason)
    for (kind, value), (count, number) in allowed.items():
        actual = len(seen.get((kind, value), []))
        if actual < count:
            reason = f"stale row: the sources have {actual} of this {kind}, the row says {count}; run python3 design/tools/site_check.py --prune-ts-baseline"
            report(display_path(baseline), number, "ts-baseline", value, reason)


def write_ts_baseline(src: Path, baseline: Path, claims: list[Claim]) -> None:
    """Rewrite the baseline from the sources. It keeps only rows that are already listed and never raises a count, so it cannot add debt. It lists everything only when the file does not exist."""
    current = {key: len(places) for key, places in scan_ts_copy(src, claims).items()}
    header: list[str] = []
    if baseline.exists():
        header = [line for line in baseline.read_text(encoding="utf-8").splitlines() if line.startswith("#")]
        old = read_ts_baseline(baseline, lambda *_: None)
        current = {key: min(count, old[key][0]) for key, count in current.items() if key in old}
    rows = ["\t".join([*key, str(count)]) for key, count in sorted(current.items())]
    baseline.write_text("\n".join([*header, *rows]) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    options = [arg for arg in args if arg.startswith("--")]
    if options and args != ["--prune-ts-baseline"]:
        print("usage: site_check.py [page.html ...] | site_check.py --prune-ts-baseline (the prune takes no other argument)", file=sys.stderr)
        return 2
    if options:
        write_ts_baseline(TS_SRC, TS_BASELINE, load_claims())
        print(f"site check: pruned {display_path(TS_BASELINE)}")
        return 0
    pages = [Path(arg).resolve() for arg in args] or sorted(p for p in SITE.rglob("*.html") if "ts" not in p.relative_to(SITE).parts)
    keys = KeySets()
    shipped_keys(keys)
    designed_keys(keys)
    retired = load_retired()
    claims = load_claims()
    findings: list[str] = []
    for page in pages:
        check_page(page, keys, retired, claims, findings)
    if not args:
        check_ts_copy(TS_SRC, TS_BASELINE, claims, findings)
    def order(entry: str) -> tuple[str, int]:
        location = entry.split(" ", 1)[0]
        page, _, line = location.rpartition(":")
        return (page, int(line))

    for f in sorted(findings, key=order):
        print(f)
    if findings:
        print(f"site check: {len(findings)} problem(s) in {len(pages)} page(s)", file=sys.stderr)
        return 1
    print(f"site check: {len(pages)} pages match the shipped keymap and docs/design")
    return 0


if __name__ == "__main__":
    sys.exit(main())
