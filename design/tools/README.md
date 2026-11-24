# Design board generators

These scripts generate the design boards in [`design/boards/`](../boards/README.md): the macOS and terminal UI screens referenced by [`docs/design/`](../../docs/design/README.md) and [ADR-0006](../../docs/adr/0006-the-spine.md). They are not part of the build and nothing in `lib/`, `macos/` or `go/` depends on them. CI runs two of them in the site workflow: `site_check.py` and `storyboard/check.py --final`.

## Rebuild the boards

You need Python 3.11 or newer. No packages are required.

```bash
sh design/tools/rebuild_boards.sh
```

This regenerates every generated board and writes the standalone copies to `design/boards/`. Set `BOARDS_DIR` to write somewhere else, for example to compare a change with the committed boards before you overwrite them:

```bash
BOARDS_DIR=/tmp/minga-boards sh design/tools/rebuild_boards.sh
```

The pipeline has two steps. Each generator writes canvas boards (`.dc.html` files that load the design canvas runtime) to `OUT_DIR`, which defaults to `out/` next to the script and is ignored by git. Then `export_boards.py` drops the canvas script tag, maps the colours onto a theme when asked (`--theme frappe`), and writes the result to `design/boards/`. The theme mapping is not idempotent, so it runs once, on generator output, never on a committed board.

To work on one generator, run it from its own directory, because the scripts load their helpers by relative path:

```bash
cd design/tools/tuigen
OUT_DIR=/tmp/minga-out python3 edit.py
```

## What is here

| Path | Generates |
|---|---|
| `tuigen/` | Terminal UI boards drawn on a real cell grid, the way Lip Gloss and Bubble Tea render: `edit.py` (editing and which-key), `tasks.py`, `review.py`, `talkopen.py` (conversation and find file), `powers.py` (terminal capabilities), `subagent.py`. `grid.py` holds the cell grid, borders, colour downgrades to 256 and 16 colours, and the two-tone twist. |
| `v4gen/` | macOS boards: `gen41.py` (editing, which-key, tasks, keys), `gen_shell.py` (the built-in terminal on macOS and in the TUI). `gen.py` is the earlier V4 round, kept for comparison and not published. |
| `subagentgen/` | `mac.py`, the macOS subagent peek. It reads the committed `V41Talk.dc.html` as its page template. |
| `batch1/` to `batch8/` | The storyboard batches, one script each (`b1.py` to `b8.py`). Batch 1 holds the shared macOS and TUI frame helpers that the later batches load. Batch 7 is the act menu and hover; batch 8 reuses it for the TUI diagnostic hover and the macOS focus-lost window. |
| `actbrand/` | The act menu designs. `dira.py` holds the Direction A menu helpers, shared by batch 7 and the mouse boards; `ab.py` draws the comparison. |
| `mouse/`, `mousevid/` | The seven mouse patterns: `mouse.py` draws stills, `vid.py` draws CSS animations of them. `snap.sh` captures frames from an animation with headless Chrome. |
| `retheme/` | `retheme.py THEME IN OUT` maps the dark generator palette onto Catppuccin Frappé or Latte by colour role. |
| `storyboard/` | The storyboard inventory tools, which read [`docs/design/scenarios.toml`](../../docs/design/scenarios.toml): `check.py` (flow invariants, and that every designed scenario has a board per frontend), `inventory.py` (the inventory board) and `flowmap.py` (the flow map). `renders.py` draws the built scenarios on both frontends, diffs them against their baselines and builds the storyboard page. Run them from the repository root. See [storyboard.md](../../docs/design/storyboard.md#running-the-inventory-checks). |
| `export_boards.py`, `rebuild_boards.sh` | The publish step described above. |
| `site_check.py` | The marketing site check. It reads `site/*.html` and fails when the copy drifts from the shipped keymap, [`docs/design/keys.md`](../../docs/design/keys.md), the six state words, the voice, the Twist placement or the default theme. Text inside `data-status="planned"` is a claim about the design; everything else is a claim about today's build. `site_retired_keys.txt` lists keys the site must never teach, and `site_claims.toml` ties feature phrases to the code that proves them. Run `python3 design/tools/site_check.py` from the repository root. See [The site check](#the-site-check). |

## The site check

The staged site describes v0.1.0 before v0.1.0 exists, so a reader needs to see which features are built. `site_check.py` keeps the markup honest, and the CSS turns the markup into a label.

**The label.** `data-status="planned"` is the only marker; any other value fails the check. The wording is CSS only, in `site/styles.css`:

- A planned block draws a pill that reads "In development", or "In development · v0.1.0" when the block names its release in `data-since`.
- A page that is wholly about an unreleased version shows one banner instead of a pill on every item. Put `<div class="status-banner">` first in `<main>`, with one planned paragraph inside it; the paragraph's pill is the banner's label. The `<main>` carries `data-status="planned"` and `data-pill="off"`.
- `data-pill="off"` hides a pill. Use it only on a block that sits under a banner or that holds its own pill. No planned block is left with neither.

**Page metadata.** Search results and link previews show copy that is not in the page body. The check reads the `description`, `og:description` and `twitter:description` meta tags and every `description` in a JSON-LD block, and applies the same key and claim rules. Metadata is a claim about today's build unless `<head>` carries `data-status="planned"`. A JSON-LD block that does not parse fails.

**Lab copy in TypeScript.** The check does not read what a lab renders from TypeScript, so lab captions, legends and step text live in the page HTML. To stop new copy from hiding in the labs, the check counts two things across `site/ts/src/**/*.ts`:

- a leader sequence: `SPC` plus at least one key, such as `SPC a y` or the range legend `SPC 1-4`. A bare `SPC` is not counted; it is a shipped key and a common state value.
- a phrase from `site_claims.toml`, matched as whole words. A one-word phrase matches only as written, so `Twist` in a sentence counts and a `"twist"` state tag does not. A phrase of several words ignores case.

The scan reads each file as plain text. It does not know what a string literal is, so **a comment counts too**. Before it counts, it turns escapes such as `\"` and `\n` into a space, drops HTML tags (keeping `aria-label`, `title`, `alt` and `placeholder` text), decodes entities and collapses spaces. `<kbd>SPC</kbd> <kbd>a</kbd>` and `SPC&nbsp;a` both read `SPC a`.

`site_ts_copy_baseline.tsv` lists what was there when the check landed. A row is kind, value and one count for the whole of `site/ts/src`:

```
key	SPC a y	9
claim	Twist	9
```

The count has no file name, so renaming, moving or splitting a lab needs no baseline edit, and deleting a lab only lowers counts. The baseline only shrinks:

- A value that is not listed fails. So does one more occurrence than the row allows. Move the copy into the page HTML.
- A row whose count is above the sources fails as stale. Prune it in the same pull request:

```bash
python3 design/tools/site_check.py --prune-ts-baseline
```

The writer keeps only rows that are already listed and never raises a count, so it cannot add debt. It takes no other argument.

This check runs only on a full run. `python3 design/tools/site_check.py site/index.html` checks that page and skips the lab sources.

**Where lab copy goes instead.** Every lab is built on the lab kit in `site/ts/src/lab/`, and the kit reads its words from the page. A lab root holds one ordered list of steps:

```html
<ol data-lab-steps>
  <li data-step="open">
    <p data-lab-instruction>Open the file</p>
    <p data-lab-caption="open">The file is open.</p>
    <p data-lab-caption="open_wrong">That key does nothing here.</p>
  </li>
</ol>
```

- `data-step` is the step id. Steps keep their document order.
- `data-lab-instruction` is the step's short label, which the stepper shows.
- `data-lab-caption="id"` is one caption. A step holds one or more, and caption ids are unique in the lab. Lab state names a caption by id; the caption line under the stage shows a copy of that element's content, links included.
- `data-lab-text="id"` marks a named string used elsewhere in the stage, such as a prompt that the lab types out. It may sit anywhere in the lab root.

The list is ordinary visible HTML, never a `<template>`, a `<script>` or an attribute value, so this check reads it. It is also what a reader sees with JavaScript off, so write it to read well as a plain list. A mounted lab adds the class `lab-live` to its root, and the stylesheet then hides the list. Words that belong to the stage itself (a button label, the text of a specimen) sit in the stage markup. `site/ts/src/lab/copy.ts` documents the same contract next to the code that reads it; the home page demo (`[data-spec-board-demo]` in `site/index.html`) is the reference use.

The checker's own tests are in `test/scripts/site_check_test.py`:

```bash
python3 -m unittest discover -s test/scripts -p 'site_check_test.py'
```

## Rules for changes

- Shapes and colours come from [`docs/design/marks.md`](../../docs/design/marks.md). Paste the exact SVGs; do not redraw marks.
- Change a generator, then run `rebuild_boards.sh` and commit the changed boards with it. Never edit a generated board by hand.
- When a board changes a rule, change the rule in `docs/design/` in the same pull request.
