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
  0x10 draw_text:  <<0x10, row::16, col::16, fg::24, bg::24, attrs::8, text_len::16, text::binary>>
  0x11 set_cursor: <<0x11, row::16, col::16>>
  0x12 clear:      <<0x12>>
  0x13 batch_end:  <<0x13>>
  0x14 draw_panel: <<0x14, row::16, col::16, width::16, height::16,
                     border::8, content_len::16, content::binary>>

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

**Total: 517 tests (514 + 3 properties), 0 failures**

### 🔴 Critical — Must fix before the editor actually runs

These are the gaps between "all Elixir logic works in tests" and "you can
actually open a terminal and edit a file":

#### 1. Zig event loop (`main.zig`)

**Status**: Stub — prints version and exits.
**Needed**: Full concurrent event loop:

```
1. Open /dev/tty via libvaxis (NOT stdin/stdout)
2. Initialize vaxis with /dev/tty fd
3. Send ready event to BEAM (width, height) via stdout
4. Concurrent loop:
   a. Poll libvaxis for terminal events → encode → write to stdout (Port)
   b. Read stdin for render commands → decode → pass to Renderer
   c. Handle resize events → send to BEAM
5. On stdin EOF (BEAM closed port): restore terminal, exit cleanly
```

Key risk: libvaxis's API for opening `/dev/tty` instead of stdin needs
verification. Fallback: fd 3 via wrapper script.

**Files**: `zig/src/main.zig`

#### 2. Wire supervisor tree

**Status**: `application.ex` has Port.Manager and Editor commented out.
**Needed**: Uncomment and start them in the supervision tree. Editor needs
to subscribe to Port.Manager on init and start rendering.

**Files**: `lib/minga/application.ex`

#### 3. Validate Zig renderer against real libvaxis API

**Status**: `renderer.zig` compiles but API calls are based on libvaxis
docs/examples, not verified at runtime.
**Needed**: Test with a real vaxis instance. The `writeCell`, `setCursorPos`,
`window()`, `render()` calls may need adjustment for libvaxis 0.15's actual
API surface.

**Files**: `zig/src/renderer.zig`

#### 4. Terminal restoration on crash

**Status**: Not implemented.
**Needed**: If the BEAM process crashes or gets SIGTERM, the Zig renderer
must restore terminal state (disable raw mode, show cursor, etc.). libvaxis
handles this via its `deinit()`, but we need to ensure it's called on all
exit paths — including when stdin closes unexpectedly.

**Files**: `zig/src/main.zig`

### 🟡 Important — Needed for usable editor

#### 5. Undo/redo

**Status**: Not implemented, not in original plan.
**Needed**: Table stakes for any editor. Users expect `u` / `Ctrl+R`.

Design options:
- **A. Command history stack**: Store reverse operations for each edit.
  Simple, low memory, but complex for compound operations.
- **B. Snapshot stack**: Store full gap buffer states. Simple to implement
  with Elixir's immutable data (just push `t()` onto a list). Memory cost
  is manageable for normal files since Elixir shares unchanged binary
  segments.
- **Recommended**: Option B (snapshot stack) — Elixir's structural sharing
  makes this nearly free. Cap at ~1000 undo levels.

**Files**: `lib/minga/buffer/server.ex`, `lib/minga/mode/normal.ex`

#### 6. Paste (`p` / `P`)

**Status**: Yank (`y`) stores text, but there's no paste command.
**Needed**: `p` pastes after cursor, `P` pastes before cursor. Register
storage is already implicit in the operator module.

**Files**: `lib/minga/mode/normal.ex`, `lib/minga/editor.ex`

#### 7. End-to-end integration test

**Status**: No test that starts the full OTP app and sends simulated
keystrokes through the Port protocol.
**Needed**: At minimum, a test that verifies:
- App starts without crash
- Open file → buffer has content
- Simulate key events → buffer changes
- Save → file written

Can use a mock Zig binary (echo script) instead of real terminal.

**Files**: `test/minga/integration_test.exs`

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
