# Minga design

This directory is the working reference for how Minga looks and behaves on every frontend. [ADR-0006](../adr/0006-the-spine.md) records the decision and why it was made; these files hold the rules a builder needs.

Start with [principles](principles.md). They are short, and every other file follows from them.

| File | What it answers |
|---|---|
| [principles.md](principles.md) | The eleven rules every surface follows |
| [marks.md](marks.md) | The twist and the orbit: exact SVGs, terminal glyphs, colour roles, the gutter, diagnostics |
| [themes.md](themes.md) | Every colour is a theme role: the roles, where they live in the Theme struct, the reference themes and their contrast |
| [keys.md](keys.md) | Every key by context, and how it compares with today's keymap |
| [surfaces.md](surfaces.md) | Modeline, which-key, drawers, tasks, review, composer, switcher, diagnostics, subagent peek, background alerts |
| [anatomy.md](anatomy.md) | The measurements of every surface part in tokens, for macOS and the TUI: insets, gaps, row pitch, text steps. Boards fix structure; this file fixes polish |
| [terminal.md](terminal.md) | The built-in terminal |
| [runs.md](runs.md) | Commands you start and do not type into: `:!`, tests, builds. The run buffer, its drawer, errors and `]q` (proposed; [terminal.md](terminal.md) governs until ADR-0010 is accepted) |
| [tui.md](tui.md) | How the Go TUI draws all of this with Lip Gloss and Bubble Tea, and what needs a modern terminal |
| [storyboard.md](storyboard.md) | How we keep macOS and the TUI consistent: scenarios, storyboards and flow-graph checks |
| [scenarios.toml](https://github.com/jsmestad/minga/blob/main/docs/design/scenarios.toml) | The scenario inventory that the storyboard and the flow map are built from |
| [marks/](https://github.com/jsmestad/minga/tree/main/docs/design/marks) | Standalone SVG files for the marks |
| [../design_tokens.toml](https://github.com/jsmestad/minga/blob/main/docs/design_tokens.toml) | The one source for colour roles, state words and shapes, twist variants and voice lines; `mix codegen` generates the Elixir, Swift and Go tokens from it |

## How these relate to the code

The rules here describe the target. Today's UI does not match them yet; the migration happens surface by surface, and each change lands with its scenarios in the storyboard. When code and these files disagree after a surface has migrated, the files are wrong or the code is wrong, and the fix is to make them agree in the same change.

The accepted design boards live in [`design/boards/`](https://github.com/jsmestad/minga/blob/main/design/boards/README.md): one standalone HTML file per screen, the acceptance target for each migration change. The scripts in [`design/tools/`](https://github.com/jsmestad/minga/blob/main/design/tools/README.md) generate them. Neither is part of the build.

## Changing the design

1. If the change affects how something looks or flows, change its board first: edit the generator, run `sh design/tools/rebuild_boards.sh`, and commit the changed boards.
2. Update the rule here in the same pull request that changes behavior, and add or update its scenarios in `scenarios.toml`.
3. If the change renames or adds a colour role, a state word or shape, a twist variant or a voice line, edit `docs/design_tokens.toml` and run `mix codegen`; never hand-edit the generated token files.
4. If the change contradicts a principle or a decision in ADR-0006, write a new ADR instead of editing these files quietly.

Keep these files to current rules. History belongs in ADRs and pull requests.
