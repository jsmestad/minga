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
| `batch1/` to `batch7/` | The storyboard batches, one script each (`b1.py` to `b7.py`). Batch 1 holds the shared macOS and TUI frame helpers that the later batches load. Batch 7 is the act menu and hover. |
| `actbrand/` | The act menu designs. `dira.py` holds the Direction A menu helpers, shared by batch 7 and the mouse boards; `ab.py` draws the comparison. |
| `mouse/`, `mousevid/` | The seven mouse patterns: `mouse.py` draws stills, `vid.py` draws CSS animations of them. `snap.sh` captures frames from an animation with headless Chrome. |
| `retheme/` | `retheme.py THEME IN OUT` maps the dark generator palette onto Catppuccin Frappé or Latte by colour role. |
| `storyboard/` | The storyboard inventory tools, which read [`docs/design/scenarios.toml`](../../docs/design/scenarios.toml): `check.py` (flow invariants, and that every board a scenario names exists), `inventory.py` (the inventory board) and `flowmap.py` (the flow map). Run them from the repository root. See [storyboard.md](../../docs/design/storyboard.md#running-the-inventory-checks). |
| `export_boards.py`, `rebuild_boards.sh` | The publish step described above. |
| `site_check.py` | The marketing site check. It reads `site/*.html` and fails when the copy drifts from the shipped keymap, [`docs/design/keys.md`](../../docs/design/keys.md), the six state words, the voice, the Twist placement or the default theme. Text inside `data-status="planned"` is a claim about the design; everything else is a claim about today's build. `site_retired_keys.txt` lists keys the site must never teach, and `site_claims.toml` ties feature phrases to the code that proves them. Run `python3 design/tools/site_check.py` from the repository root. |

## Rules for changes

- Shapes and colours come from [`docs/design/marks.md`](../../docs/design/marks.md). Paste the exact SVGs; do not redraw marks.
- Change a generator, then run `rebuild_boards.sh` and commit the changed boards with it. Never edit a generated board by hand.
- When a board changes a rule, change the rule in `docs/design/` in the same pull request.
