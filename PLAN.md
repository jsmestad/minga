# Plan: Minga — BEAM-Powered Modal Editor

## Goal

Build a usable modal text editor with Doom Emacs-style keybindings and which-key
discovery, running on the BEAM with a Zig terminal renderer. Opens files, edits
with Vim-style modal input, provides leader key sequences with which-key popups,
and saves — all with full fault isolation between editor logic and terminal
rendering.

## Architecture

Two OS processes, fully isolated:

- **BEAM (Elixir)**: Buffer state, modal FSM, keybinding dispatch, command
  execution, layout computation. Zero NIFs.
- **Zig (libvaxis)**: Terminal ownership, raw input capture, screen rendering.
  Runs as a BEAM Port. If it crashes, the supervisor restarts it and re-renders
  — no data loss.

```
┌─────────────────────────┐        Port (stdin/stdout)         ┌──────────────────────┐
│     BEAM (Elixir)       │ ◄─── input events (keys, mouse) ── │    Zig (libvaxis)    │
│                         │                                    │                      │
│  Buffer (GenServer)     │ ── render commands (draw, etc.) ──►│  Terminal ownership  │
│  Mode FSM               │                                    │  Raw mode / input    │
│  Keymap (trie)          │                                    │  Screen rendering    │
│  Command registry       │                                    │  Floating panels     │
│  Which-Key              │                                    └──────────────────────┘
│  Editor (orchestration) │
│  Port Manager           │
│  Supervisor (Stamm)     │
└─────────────────────────┘
```

### Technology Choices

| Component | Choice | Why |
|-----------|--------|-----|
| Buffer | Pure Elixir gap buffer | Simple, zero deps, fast enough for MVP |
| TUI | libvaxis via Zig Port | Proven (Flow editor, Ghostty), full-featured, fault-isolated |
| Types | Elixir 1.19 `@spec`/`@type` everywhere | Set-theoretic inference catches bugs at compile time |
| Protocol | Length-prefixed binary over Port stdin/stdout | Zig uses `/dev/tty` for terminal I/O |
| Packaging | Burrito | Single self-extracting binary, bundles ERTS + Zig renderer |
| Testing | ExUnit + StreamData + Zig test | Unit, property-based, and Zig-side tests |
| Linting | Credo (strict) + Dialyxir + mix format | Enforced in CI |
| CI/CD | GitHub Actions | Lint/test/dialyzer on PR, Burrito builds on tag |

### Terminal I/O vs Port I/O

libvaxis opens `/dev/tty` directly for terminal input/output (standard pattern
for TUI programs that need stdin/stdout free — same as `fzf`, `dialog`). The
Port protocol uses stdin/stdout exclusively for BEAM⟷Zig communication.

### Port Protocol

Simple binary opcodes — not ETF:

```
Message = <<length::32-big, opcode::8, payload::binary>>

Input events (Zig → BEAM):
  0x01 key_press:  <<0x01, codepoint::32, modifiers::8>>
  0x02 resize:     <<0x02, width::16, height::16>>
  0x03 ready:      <<0x03, width::16, height::16>>

Render commands (BEAM → Zig):
  0x10 draw_text:        <<0x10, row::16, col::16, fg::24, bg::24, attrs::8, text_len::16, text::binary>>
  0x11 set_cursor:       <<0x11, row::16, col::16>>
  0x12 clear:            <<0x12>>
  0x13 batch_end:        <<0x13>>
  0x14 draw_panel:       <<0x14, row::16, col::16, width::16, height::16,
                           border::8, content_len::16, content::binary>>
  0x15 set_cursor_shape: <<0x15, shape::8>>

Cursor shapes: BLOCK=0x00, BEAM=0x01, UNDERLINE=0x02

Modifier flags: SHIFT=0x01, CTRL=0x02, ALT=0x04, SUPER=0x08
Style attrs:    BOLD=0x01, ITALIC=0x02, UNDERLINE=0x04, REVERSE=0x08
```

### Supervision Tree

```
Minga.Supervisor (rest_for_one)
├── Minga.Buffer.Supervisor (DynamicSupervisor)
├── Minga.Port.Manager
└── Minga.Editor
```

`rest_for_one`: if Port Manager crashes, Editor restarts too (depends on
renderer). Buffer processes survive independently.

---

## Current Status

### ✅ Completed

| # | Commit | What | Tests |
|---|--------|------|-------|
| 1 | Project scaffolding | Mix project, Zig project, custom compiler, GitHub repo | 1 |
| 2 | Gap buffer | Pure Elixir gap buffer with Unicode support | 57 + 3 props |
| 3 | Buffer GenServer | File I/O, dirty tracking, GenServer wrapper | 22 |
| 4 | Port protocol | Binary encode/decode (Elixir + Zig) | 30 + Zig tests |
| 5 | Port Manager | GenServer, subscriber pattern, supervision | 5 |
| 6 | Editor + viewport | Orchestration, scrolling, render pipeline | 21 |
| 7 | Zig renderer module | libvaxis draw calls, style support | Zig tests |
| 8 | CLI entry point | `mix minga`, arg parsing | — |
| 9 | Command registry + keymap trie | Agent registry, prefix tree | 37 |
| 10 | Vim FSM | Normal/Insert modes, count prefix, mode display | 94 |
| 11 | Motions + operators | word/line/doc motions, delete/change/yank | 59 |
| 12 | Visual mode | Characterwise + linewise selection | 42 |
| 13 | Command mode | `:w`, `:q`, `:wq`, `:q!`, `:e`, `:<N>` | 34 |
| 14 | Which-key + leader keys | SPC leader, Doom-style bindings, popup data | 34 |
| 15 | Text objects | `iw`/`aw`, quotes, parens, brackets | 50+ |
| — | Tooling | Credo, Dialyxir, formatter, `mix lint` alias | — |
| — | Burrito packaging | Single binary for macOS/Linux | — |
| — | GitHub Actions | CI (lint/test/dialyzer) + release pipeline | — |

**Total: 592 tests (535 Elixir + 3 properties + 54 Zig), 0 failures**

### ✅ Recently Completed (formerly critical/important gaps)

| Item | What was done |
|------|--------------|
| Zig event loop | Full concurrent loop in `main.zig`: `/dev/tty` via libvaxis, poll() on stdin+tty, signal handlers (SIGWINCH/SIGTERM/SIGINT), panic handler with terminal restore |
| Supervisor wiring | Port.Manager and Editor start conditionally via `Application.get_env(:minga, :start_editor)` |
| Renderer validation | `renderer.zig` updated to match libvaxis 0.15 API: `writeCell(col, row, cell)`, `showCursor()`, arena allocator for grapheme lifetime management |
| Terminal restoration | `defer vx.deinit()` + `defer tty.deinit()` + `vaxis.recover()` panic handler covers all exit paths |
| Undo/redo | Snapshot stack in Buffer.Server (capped at 1000), `u` / `Ctrl+R` in Normal mode |
| Paste | `p` (after) / `P` (before) in Normal mode, register stored in Editor state |
| Integration test | `test/minga/integration_test.exs` — full pipeline: navigation, insert, delete, undo, command mode |
| Zig test coverage | Expanded from 18 → 54 tests across protocol, renderer, and main |

### 🟡 Remaining — needs manual testing

#### 1. End-to-end manual testing

**Status**: All logic is implemented and unit-tested, but the full editor
has not been launched in a real terminal yet.
**Needed**: Run `mix minga README.md` and verify:
- Terminal enters raw/alternate screen mode
- File content displays correctly
- hjkl navigation works
- `i` enters insert, typing works, `Esc` returns to normal
- `:w` saves, `:q` quits
- Terminal restores cleanly on exit
- Ctrl+C / kill doesn't leave terminal in raw mode

#### 2. Port protocol end-to-end

**Status**: `{:packet, 4}` framing tested in unit tests on both sides,
but never tested through a real Erlang Port connection.
**Needed**: Verify the 4-byte length prefix handling works correctly
when BEAM spawns the Zig binary. This is the most likely failure point
on first real launch.

### 🟢 Post-V1 / V2

- **Syntax highlighting** — tree-sitter via Zig
- **Multiple windows / splits** — `SPC w v`, `SPC w s`
- **File finder** — `SPC f f` (currently a stub)
- **Buffer switcher** — `SPC b b` (currently a stub)
- **LFE extension layer** — scripting/config in Lisp Flavored Erlang
- **Rope data structure** — large file support
- **Windows support** — libvaxis has Windows backend, needs `/dev/tty`
  alternative and cross-compiled Zig binary
- **Mouse support** — libvaxis supports it, needs protocol opcodes
- **Search / replace** — `/pattern`, `:%s/old/new/g`
- **Marks** — `m{a-z}`, `'{a-z}`
- **Macros** — `q{a-z}`, `@{a-z}`
- **Line numbers** — absolute + relative
- **Soft wrap** — long lines
- **Autoindent** — language-aware indentation
- **GUI renderer** — second Zig binary (`minga-gui`) using WebGPU/wgpu or
  similar, same Port protocol; zero Elixir changes needed

---

## Alternatives Considered

| Alternative | Why rejected |
|-------------|-------------|
| ExRatatui (Rust NIF) | NIF crash risk, contradicts fault-tolerance goals |
| Ratatouille | Abandoned since 2020, built on abandoned ExTermbox |
| Raw ANSI from Elixir | 2-3 weeks of terminal plumbing before building the actual editor |
| JSON/msgpack protocol | Verbose or extra deps; simple binary opcodes are sufficient |
| Rust instead of Zig | Heavier toolchain, no advantage for a rendering Port |
| Rope NIF for buffer | Complexity; gap buffer is fast enough for normal files |

## Risks

1. **`/dev/tty` in libvaxis** — Unverified. If libvaxis can't open `/dev/tty`
   directly, fallback is fd 3 via a wrapper script that does
   `exec 3<>/dev/tty ./minga-renderer`.

2. **Port `{:packet, 4}` framing** — Erlang adds 4-byte length headers
   automatically. Zig side must match. Tested in protocol tests but not
   end-to-end through a real Port.

3. **Zig build caching with Mix** — Custom Mix compiler checks timestamps.
   Works but could miss edge cases with Zig's dependency cache.

4. **Burrito + Zig renderer architecture** — The Zig binary in `priv/`
   is architecture-specific. Cross-platform releases need per-target Zig
   builds, which is handled by building on native GitHub Actions runners.

---

## Build & Run

```bash
# Development
mix deps.get
mix compile          # builds Elixir + Zig
mix test             # runs all tests (--warnings-as-errors)
mix lint             # format + credo + compile warnings
mix dialyzer         # static type analysis

# Run the editor (once Zig event loop is implemented)
mix minga README.md

# Build release binary
MIX_ENV=prod mix release minga
./burrito_out/minga_macos_aarch64 README.md

# Tag a release (triggers GitHub Actions build)
git tag v0.1.0
git push --tags
```
