# Design boards

These are the accepted design boards for the Spine ([ADR-0006](../../docs/adr/0006-the-spine.md)): the target picture of every designed screen on macOS and in the terminal UI. They are the acceptance target for a migration change, for people and for agents. When a pull request changes a surface, the reviewer compares the rendered frame with the board that [`scenarios.toml`](../../docs/design/scenarios.toml) names for that scenario.

Each board is one self-contained HTML file. Open it in any browser; it needs no server, no script and no network except Google Fonts for one display face. Boards are drawn at real editor metrics (13 px text on 18 px lines on macOS, the cell grid in the TUI), so a screenshot of a board is a fair comparison with a screenshot of the app.

## Which board is which

| Files | What they show |
|---|---|
| `V41*` | The core of the design: editing, which-key, the tasks drawer, review, talk and find file, the terminal, the subagent peek, and the TUI version of each. `V41Keys` is the key map at a glance. |
| `V3Diagnostics`, `V3NeedsYou` | Diagnostics in the code and the native notification. They come from an earlier round and still match the rules in [`marks.md`](../../docs/design/marks.md). |
| `Batch1_*` to `Batch8_*` | The storyboard batches: every screen the inventory found missing, named after its scenario id (`Batch4_git_blame` is `git.blame`). `Batch7_*` holds the act menu and hover. `Batch8_*` completes the two scenarios whose boards covered one frontend only. |
| `Mouse_*` | The seven mouse patterns as stills. `Mouse_Video_*` are CSS animations of the same patterns playing. |
| `ActMenu_DirectionA`, `ActMenu_Compare` | The chosen act menu design and the comparison that chose it. |
| `Theme_frappe_*`, `Theme_latte_*` | Four core boards in Catppuccin Frappé (the default) and Latte, to show every colour is a theme role. |
| `StoryboardInventory`, `StoryboardFlow` | The scenario inventory as a grid, and the design-time flow map. Both are generated from `scenarios.toml`. |

Most boards are in Frappé, the default theme. The `V41*` boards keep the darker palette they were drawn in; their Frappé versions are the `Theme_frappe_*` boards.

## Changing a board

Do not edit a generated board by hand. Change its generator in [`design/tools/`](../tools/README.md) and run:

```bash
sh design/tools/rebuild_boards.sh
```

The script regenerates every board, themes it, and writes the standalone copy here. The six hand-made boards (`V41Review`, `V41Open`, `V41Talk`, `V41Terminal`, `V3Diagnostics`, `V3NeedsYou`) have no generator; edit those files directly.

When a board changes a rule, change the rule in [`docs/design/`](../../docs/design/README.md) in the same pull request. `python3 design/tools/storyboard/check.py` fails when a scenario names a board that is not in this folder, and when a designed scenario has no board for a frontend it lists.

Boards are structural references: which parts a surface has, their order and their words. Nobody measures them; measurements come from [`docs/design/anatomy.md`](../../docs/design/anatomy.md), and the real renders of each scenario, not the boards, are the diff baselines (see [storyboard.md](../../docs/design/storyboard.md#renders-and-baselines)).
