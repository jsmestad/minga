# ADR-0008: The built-in terminal runs libghostty-vt in a helper process, and the BEAM owns the terminal buffer

**Status:** Proposed (2026-11-23). Not implemented. Answers the open question in [ADR-0006](0006-the-spine.md#open-questions). Issue: #4029. Implementation: #4060 (12b) and #4061 (12c). Supersedes the Developer Notes on #19 and #122.

## Decision

Each built-in terminal runs in its own native helper process, `minga-terminal`, built in Zig on [libghostty-vt](https://github.com/ghostty-org/ghostty). The helper owns the PTY and the emulator. The BEAM owns everything the editor does with the terminal: the committed rows, the scrollback you navigate, command blocks, modes, cursor and selection in Normal mode, and the decision of what to show. Frontends render a terminal like any other buffer, from the resident row store. Neither frontend embeds a terminal emulator.

1. **The helper owns the PTY and the VT state.** `Minga.Terminal.Session` (a Layer 1 GenServer) starts one helper per terminal as an Erlang Port, framed `{:packet, 4}` like `minga-parser`. The helper calls `forkpty` for the shell, always drains the PTY into a `GhosttyTerminal`, and encodes keys, mouse events and pastes with libghostty-vt's encoders against the terminal's current modes. A helper crash ends one shell, not the editor or the other terminals.
2. **The BEAM owns the terminal buffer.** The session keeps the committed projection: history rows as they leave the active screen, the current screen rows, the cursor, title, cwd (OSC 7), and prompt, command and exit events (OSC 133) with timestamps. Vim motions, search, yank, the `ic`/`ac` text objects, `]]`/`[[`, authorship and approvals all run against this projection. When the shell exits, the projection stays, so "Shell exited" keeps its scrollback and `↩` restarts.
3. **Layout splits at the active screen.** The active screen is the running program's grid, so its rows arrive as the engine laid them out, at the PTY size the BEAM set from the frontend's reported row fit ([ADR-0001](0001-frontend-owns-row-fit.md)). History is different: the session joins soft-wrapped rows into logical lines, assigns their row identities, and wraps them with the editor's own wrapping, as it does for any buffer. On resize the engine reflows the screen and the BEAM rewraps history; nobody reflows twice, and `yic` never copies a hard newline at a wrap point.
4. **Rows reach both frontends through the existing semantic path.** `MingaEditor` presents a session as a terminal buffer through `gui_window_content` (0x80) and row deltas (0xA2), keyed by `row_id + content_hash`. History rows never change once committed, so new output is an append and trimming is a head splice. SGR colours become the pre-resolved RGB spans the row encoding already carries; the 16 ANSI colours resolve through theme roles, so terminals use the editor's theme. Frontends gain no VT code and no terminal-specific renderer.
5. **The helper coalesces and the BEAM paces it.** The helper never blocks the shell. It folds dirty rows into the next update and sends one update per acknowledgement from the session. Screen state is level-triggered, so intermediate frames can be skipped safely. History rows are edge-triggered and are never skipped; only the configured cap trims them, oldest first.
6. **The helper protocol is engine-neutral.** Its opcodes live in `docs/protocol_schema.toml` under their own category and describe rows, spans, cursor, modes and shell events, not libghostty types. If libghostty-vt fails the first-slice checks below, libvterm can replace it inside the helper without changing the BEAM side or either frontend.

## Context

#19 and #122 planned libvterm inside the Zig renderer, and #122 later proposed native terminal widgets per frontend (SwiftTerm, VTE, libvterm in Zig). The Zig renderer was removed in #2223; Zig now builds only the parser Port and two small helpers (`minga-hook-runner`, `minga-shell-output-reader`). ADR-0006 then made a terminal a buffer ([`terminal.md`](../design/terminal.md)), which changes the question. The engine must feed BEAM-owned semantics, not just draw a grid:

- Normal mode moves a Vim cursor over the scrollback, searches it, yanks from it and holds the view still while output arrives ("↓ 12 new lines").
- OSC 133 command blocks give `]]`/`[[`, the `ic`/`ac` text objects, state glyphs with exit code and duration, and a failed-block menu that sends output to Minga or quickfix.
- The authorship column marks who ran each command, and Minga's own commands show read-only with approval blocks. (Amended by [ADR-0010](0010-runs.md): they are blocks in `*run*`, not a `*minga-shell*` buffer.)
- The modeline shows cwd and the last exit status, and "Shell exited" keeps scrollback.

The AGENTS.md ownership rules decide where those features live: cursor motion, selection, search and text objects are BEAM semantics, and frontends must not duplicate them. The resident-store principle says the BEAM ships the whole navigable model and frontends present it. So the BEAM must hold the terminal's text and structure. The engine choice is about who parses the VT stream and how the result reaches the BEAM.

## Options compared

| | libvterm in a helper | Go VT in the TUI + Swift VT on macOS | libghostty-vt in a helper | BEAM-side parser |
|---|---|---|---|---|
| Screen state | Helper holds the live screen only; scrollback goes to the host | Each frontend | Helper holds screen and scrollback | BEAM |
| PTY owner | Helper | Each frontend (or a BEAM helper passing descriptors) | Helper | A native helper anyway; Erlang ports cannot allocate a PTY |
| Frames to frontends | Helper rows to BEAM, then the existing resident row store | Local to each frontend; the BEAM never sees the content | Same as libvterm, with per-row dirty tracking from the engine | BEAM rows through the resident row store |
| 10k lines of scrollback | Host-stored; fine | Fine in memory, but invisible to BEAM semantics | Paged scrollback with line and byte limits; fine | Storage fine; parsing floods on BEAM schedulers is the bottleneck |
| OSC 133 / OSC 7 | Not parsed; raw OSC fragments through a fallback callback | x/vt: OSC 7 only. SwiftTerm: OSC 7 delegate and an OSC 133 heuristic | Native: semantic prompt events with exit code, `pwd_changed`, per-row prompt marks | Whatever we write |
| Licensing | MIT | MIT (charmbracelet/x, SwiftTerm) | MIT | Ours (MIT) |
| Build cost | Low: a few C files in `zig/build.zig` on Zig 0.16 | Low per frontend, but two integrations to keep equal (three with GTK4) | Medium, once: needs Zig 0.17; Minga pins 0.16.0 | Very high: xterm compatibility in Elixir, plus the PTY helper |

### libvterm in a helper process

libvterm is small, MIT-licensed and proven inside Neovim and Vim. It keeps only the visible screen and hands each line that scrolls off to the host through `sb_pushline`, which suits a BEAM that wants to own scrollback. Neovim's terminal uses it with a default of 10,000 lines of scrollback.

Its weaknesses are age and scope. Upstream's last release is 0.3.3, developed in Bazaar on Launchpad, and Neovim now vendors its own fork in `src/nvim/vterm/`. It has no OSC 133 or OSC 7 semantics: the host receives raw OSC fragments and must parse them, and Neovim builds its prompt jumping on top of that. Minga would adopt a slow-moving library and own a fork in practice. It is the named fallback, not the choice.

### A Go VT in the TUI and a Swift VT on macOS

This gives the lowest echo latency, because output never crosses a process boundary on its way to the screen. [charmbracelet/x/vt](https://github.com/charmbracelet/x/tree/main/vt) has scrollback and damage tracking but no OSC 133 handler upstream; [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) handles OSC 7 and has an OSC 133 heuristic. Both are MIT.

It fails the design. The BEAM would not have the terminal's text, so Normal-mode motions, search, yank, text objects, blocks and authorship would be reimplemented in Swift and Go, or the text would be shipped back to the BEAM. Two emulators would drift, against principle 9 of ADR-0006 and the conformance transcripts. A terminal would die with its frontend, which breaks attach and restart, and the headless runtime would have no terminal for `*minga-shell*`.

### libghostty-vt in a helper process

libghostty-vt is Ghostty's emulator as a library. 1.0 shipped on 2026-11-06 with a stable C ABI, and 1.0.1 followed on 2026-11-11. It is MIT-licensed and depends only on libc. It does no rendering and no PTY handling, which is exactly the split Minga wants.

It covers the designed features directly. OSC 133 arrives as semantic prompt events (prompt start, input start, output start, command end with exit code), and rows carry prompt marks and soft-wrap flags, so the BEAM can join wrapped rows into logical lines and let its own wrapping handle width. OSC 7 arrives through `pwd_changed`. A render state reports dirty rows. Scrollback is paged, with line and byte limits and reflow on resize. Its key and mouse encoders follow the terminal's modes, including the Kitty keyboard protocol, so the BEAM never re-derives mode-dependent escape sequences.

The costs are the toolchain and a young ABI. libghostty-vt 1.0.1 requires Zig 0.17.0 or later, and Minga pins Zig 0.16.0, so the parser and helpers move to 0.17 first. The previous minor bump (#1507) was a 16-file change that also carried the since-removed libvaxis. A Hex package wraps libghostty-vt as a Zigler NIF; Minga does not use NIFs ([ARCHITECTURE.md](../ARCHITECTURE.md#why-not-a-nif)), so the helper links the library directly.

### A BEAM-side parser

This puts all state in the BEAM, which is attractive on ownership alone. It still needs a native PTY helper, so it removes no process. It then adds an xterm-compatible emulator written in Elixir: DEC modes, the alternate screen, scroll regions, wide and combining characters, reflow, mouse and keyboard protocols. A `cat` of a large log would be parsed byte by byte on BEAM schedulers next to the editor. It is the most work for the least compatibility.

## Why libghostty-vt

The design needs the BEAM to own the terminal's text and structure, and needs OSC 133 and OSC 7 to be first-class. Every option except the frontend emulators can feed the BEAM; among those, libghostty-vt is the only one that already speaks shell integration, tracks dirty rows, encodes input against live modes and is actively maintained with a stable ABI. libvterm would give the same process shape with more code on our side and an older engine underneath.

The helper-plus-BEAM shape also matches what Minga already does. The parser Port holds tree-sitter trees and sends spans; the BEAM holds the buffer. The terminal helper holds the emulator and sends rows; the BEAM holds the terminal buffer. External program state (what the shell drew) lives with the program's process; editor state lives in the BEAM.

## Performance budget

Ten thousand lines of scrollback is well inside the resident row store's 65,536-row ceiling. Committed history rows never change, so each burst of output is an O(new rows) append through 0xA2, and the cap trims with one head splice. Opening a drawer over a full 10,000-line history is a first build of the same size as opening a 10,000-line file, which the first-paint-then-promote path already keeps off first paint. A resize rewraps history in the BEAM at the cost of rewrapping a soft-wrapped buffer of the same length.

Two costs are new and must be measured, not assumed. Keystroke echo now crosses frontend, BEAM, helper, PTY, helper, BEAM and frontend; ADR-0005 does not let a frontend predict the echo, so the budget is the round trip. Full-screen programs such as `htop` and `vim` redraw most rows at their own frame rate, which exercises row deltas far harder than editing does. The first slice of #4060 measures both and adds budgets to `bench/latency_budgets.json`.

## Checks that could reverse this

The first slice of #4060 proves the decision before the terminal buffer is built on it. If any check fails and cannot be fixed inside the helper, switch the helper to libvterm and keep the rest of this decision.

- `minga-terminal` builds with libghostty-vt on macOS and Linux CI after the Zig 0.17 bump, and the release bundle ships it next to `minga-parser`.
- After `seq 1 200000` and a `cat` of a 10 MB log, the session's history equals the source text exactly: no gap, no duplicate, no row reported twice after the engine prunes. This is the riskiest assumption. The helper finds rows that left the active screen with a tracked grid reference (`grid_ref_tracked.h`) to the first unreported row, and harvests after every `ghostty_terminal_vt_write`, with the engine's own line limit set above the most rows one read can produce.
- Keystroke to echo p95 on both frontends stays within a budget set against the editor's own keystroke latency.
- `seq 1 1000000` finishes with the Editor responsive (its input latency budget holds), with exactly the capped number of history rows, and without skipped history rows.
- `htop` at its default refresh and scrolling in nested `vim` keep the frame budget.
- OSC 133 events arrive with exit codes and correct row positions for zsh, bash and fish, and an unintegrated shell still works.

## Alternatives rejected

- **libvterm in a helper process.** Same shape, older engine. No native OSC 133 or OSC 7, upstream releases are rare, Neovim maintains its own fork, and Minga would likely maintain one too. Kept as the fallback.
- **A Go VT in the TUI and a Swift VT on macOS.** The BEAM would not see terminal content, so Vim semantics, blocks and authorship would be duplicated per frontend; two engines drift; terminals would die with their frontend and not exist headless.
- **Native terminal widgets per frontend (#122's GUI plan).** The same problems as the previous option, plus GTK4's VTE as a third engine.
- **A BEAM-side parser.** Still needs a PTY helper, and adds an xterm emulator in Elixir with the worst flood performance of any option.
- **libghostty-vt as a NIF.** A crash in the emulator would take down the VM. The Port boundary costs little and isolates each shell.

## Consequences

- Zig moves from 0.16 to 0.17 for the parser, `minga-hook-runner` and `minga-shell-output-reader` before the helper lands. `zig/build.zig.zon` gains its first external dependency, Ghostty pinned to a `vt-1.x` tag.
- A new release artifact, `minga-terminal`, joins `@native_release_artifacts` in `mix.exs`. Tests that spawn it start OS processes and must be `async: false` with a timeout, per AGENTS.md.
- The helper protocol gets a category in `docs/protocol_schema.toml`, generated into Zig and Elixir like the parser opcodes. It never reaches a frontend.
- `Minga.Terminal.*` is a Layer 1 service, so terminals work headless and in the agent runtime. `MingaEditor` presents sessions as terminal buffers. Themes gain roles for the 16 ANSI colours, resolved on the BEAM like every other span colour; the frontends' only new work is the block gutter's state column from 12c, through the existing semantic path.
- Minga ships its own shell integration scripts for zsh, bash and fish that emit OSC 133 and OSC 7, injected at spawn. libghostty-vt parses the sequences; it does not install integration.
- libghostty-vt's default scrollback limit is 10,000 bytes, so the helper sets a line limit explicitly and the BEAM applies the user-facing cap (`:terminal_scrollback`, default 10,000 lines).
- Echo latency is a budgeted, benchmarked path from the first slice, like keystroke latency.
- When the helper lands, the AGENTS.md ownership section gains one line: the active screen of a terminal is the running program's layout, produced by the helper at the size the BEAM set; history follows the normal BEAM layout rules. Until then this record is the reference.
- [`terminal.md`](../design/terminal.md) no longer lists the engine as open, and ADR-0006's open question points here.
