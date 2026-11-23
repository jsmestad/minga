# Design board generators

These scripts generate mockup boards for Minga's design canvas: the macOS and terminal UI screens referenced by [`docs/design/`](../../docs/design/README.md) and [ADR-0006](../../docs/adr/0006-the-spine.md). They exist to explore and review designs. They are not part of the build, nothing in `lib/`, `macos/` or `go/` depends on them, and CI does not run them.

## Run one

You need Python 3.11 or newer. No packages are required.

```bash
cd design/tools/tuigen
OUT_DIR=/tmp/minga-boards python3 edit.py
```

Each script writes `.dc.html` board files to `OUT_DIR`, which defaults to `./out` next to the script. Run a script from its own directory, because the scripts load their helpers by relative path.

## What is here

| Directory | Generates |
|---|---|
| `tuigen/` | Terminal UI boards drawn on a real cell grid, the way Lip Gloss and Bubble Tea render: `edit.py` (editing and which-key), `tasks.py`, `review.py`, `talkopen.py` (conversation and find file), `powers.py` (terminal capabilities), `subagent.py`. `grid.py` holds the cell grid, borders, colour downgrades to 256 and 16 colours, and the two-tone twist. |
| `v4gen/` | macOS boards: `gen41.py` (editing, which-key, tasks, keys), `gen_shell.py` (the built-in terminal on macOS and in the TUI). `gen.py` is the earlier V4 round, kept for comparison. |
| `storyboard/` | The storyboard inventory tools, which read [`docs/design/scenarios.toml`](../../docs/design/scenarios.toml): `check.py` (flow invariants), `inventory.py` (the inventory board) and `flowmap.py` (the flow map). Run them from the repository root. See [storyboard.md](../../docs/design/storyboard.md#running-the-inventory-checks). |
| `subagentgen/` | `mac.py`, the macOS subagent peek. It reads `V41Talk.dc.html` from `OUT_DIR` as its page template, so that board must exist there first. |

## Rules for changes

- Shapes and colours come from [`docs/design/marks.md`](../../docs/design/marks.md). Paste the exact SVGs; do not redraw marks.
- Keep generated boards out of the repository. Publish them to the design canvas instead.
- When a board changes a rule, change the rule in `docs/design/` in the same pull request.
