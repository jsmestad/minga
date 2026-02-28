# Plan: Minga V1 — BEAM-Powered Modal Editor

## Goal

Build a usable modal text editor with Doom Emacs-style keybindings and which-key
discovery, running on the BEAM with a Zig terminal renderer. V1 opens files,
edits with Vim-style modal input, provides leader key sequences with which-key
popups, and saves — all with full fault isolation between editor logic and
terminal rendering.

## Context

### Architecture: Zig Port + Pure Elixir Core

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

### Key Technology Choices

| Component | Choice | Why |
|-----------|--------|-----|
| Buffer | Pure Elixir gap buffer | Simple, zero deps, fast enough for MVP |
| TUI | libvaxis via Zig Port | 1,649⭐, proven (Flow editor, Ghostty), full-featured, fault-isolated |
| Types | Elixir 1.19 `@spec`/`@type` everywhere | Set-theoretic inference catches bugs at compile time |
| Protocol | Length-prefixed binary over Port stdin/stdout | Zig uses `/dev/tty` for terminal I/O, keeping stdin/stdout free for Port |
| Testing | ExUnit + Zig test | Comprehensive unit tests, property-based tests for buffer |

### Terminal I/O vs Port I/O

libvaxis opens `/dev/tty` directly for terminal input/output (this is standard
for TUI programs that need stdin/stdout free — same pattern as `fzf`, `dialog`).
The Port protocol uses stdin/stdout exclusively for BEAM⟷Zig communication.
No fd contention.

### What's Deferred to Post-V1

- **LFE extension layer** — editor needs to be usable first
- **Rope / large file support** — optimization, not needed for normal files
- **Multiple windows / splits** — V2 feature
- **Syntax highlighting** — V2 (likely tree-sitter via Zig)
- **Burrito single-binary packaging** — distribution concern

## Approach

Work is structured as **15 commits across 2 phases**. Each commit is a logical
unit that compiles, passes tests, and can be pushed. Phase 1 builds the editing
foundation. Phase 2 adds the modal/Doom layer that makes it feel like home.

### Alternatives Considered

| Alternative | Why rejected |
|-------------|-------------|
| ExRatatui (Rust NIF) | NIF crash risk, 5-day-old library, contradicts fault-tolerance goals |
| Ratatouille | Abandoned since 2020, built on abandoned ExTermbox |
| Raw ANSI from Elixir | 2-3 weeks of terminal plumbing before building the actual editor |
| JSON/msgpack protocol | Verbose or extra deps; simple binary opcodes are sufficient |
| Rust instead of Zig | Heavier toolchain, no advantage for a rendering Port; Zig aligns with future cross-compilation plans |

---

## Phase 1: Walking Skeleton

Goal: Open a file, display it, move cursor, insert/delete text, save.

### Commit 1: Project scaffolding + GitHub repo

- **Files**: `mix.exs`, `config/config.exs`, `lib/minga.ex`,
  `lib/minga/application.ex`, `zig/build.zig`, `zig/build.zig.zon`,
  `zig/src/main.zig`, `.gitignore`, `.formatter.exs`, `AGENTS.md`, `README.md`
- **Changes**:
  - `mix new minga --sup`
  - Zig project in `zig/` with libvaxis dependency
  - Mix compiler hook: `System.cmd("zig", ["build"])` in `zig/` during
    `mix compile`
  - `.gitignore`: `_build/`, `deps/`, `zig/zig-out/`, `zig/.zig-cache/`
  - `AGENTS.md`: Project conventions — module structure, typing requirements,
    testing expectations, naming conventions, commit message format
  - `README.md`: Project description, architecture overview, build instructions
  - Create GitHub repo (`gh repo create minga --public`), initial push
  - Elixir 1.19 / OTP 28 version pinned in `mix.exs` and `.tool-versions`
- **Tests**: `mix compile` succeeds, `zig build` succeeds

### Commit 2: Gap buffer data structure + tests

- **Files**: `lib/minga/buffer/gap_buffer.ex`,
  `test/minga/buffer/gap_buffer_test.exs`
- **Changes**:
  - `Minga.Buffer.GapBuffer` — pure functional module, no GenServer:
    - Types: `@type t`, `@type position :: {line :: non_neg_integer(), col :: non_neg_integer()}`
    - `@spec new(String.t()) :: t()`
    - `@spec insert_char(t(), String.t()) :: t()` — insert at cursor
    - `@spec delete_before(t()) :: t()` — backspace
    - `@spec delete_at(t()) :: t()` — delete forward
    - `@spec move(t(), :left | :right | :up | :down) :: t()`
    - `@spec move_to(t(), position()) :: t()`
    - `@spec cursor(t()) :: position()`
    - `@spec line_count(t()) :: non_neg_integer()`
    - `@spec line_at(t(), non_neg_integer()) :: String.t() | nil`
    - `@spec lines(t(), non_neg_integer(), non_neg_integer()) :: [String.t()]`
    - `@spec to_string(t()) :: String.t()`
    - `@spec empty?(t()) :: boolean()`
  - Internal representation: `before` (binary, reversed) + `after_` (binary)
    with line index cache for O(1) line lookups
  - `@spec` on every public function
- **Tests**: Insert, delete, cursor movement (all directions), line extraction,
  empty buffer, single char buffer, unicode (emoji, CJK, combining marks),
  moving past boundaries (start/end of line/file), multi-line operations.
  Property-based tests with StreamData for insert/delete round-trips.

### Commit 3: Buffer GenServer + file I/O

- **Files**: `lib/minga/buffer/server.ex`, `test/minga/buffer/server_test.exs`
- **Changes**:
  - `Minga.Buffer.Server` — GenServer wrapping the gap buffer:
    - Types: `@type state :: %{gap_buffer: GapBuffer.t(), file_path: String.t() | nil, dirty: boolean()}`
    - `@spec start_link(keyword()) :: GenServer.on_start()`
    - `@spec open(GenServer.server(), String.t()) :: :ok | {:error, term()}`
    - `@spec insert_char(GenServer.server(), String.t()) :: :ok`
    - `@spec delete_before(GenServer.server()) :: :ok`
    - `@spec move(GenServer.server(), :left | :right | :up | :down) :: :ok`
    - `@spec save(GenServer.server()) :: :ok | {:error, term()}`
    - `@spec get_lines(GenServer.server(), non_neg_integer(), non_neg_integer()) :: [String.t()]`
    - `@spec cursor(GenServer.server()) :: GapBuffer.position()`
    - `@spec dirty?(GenServer.server()) :: boolean()`
  - File read on `open/2`, file write on `save/1`
  - Sets dirty flag on any mutation, clears on save
- **Tests**: Open real file (via tmp_dir), edit, save, re-read. Error cases
  (missing file, permission denied). Dirty flag transitions.

### Commit 4: Port protocol + Zig scaffold

- **Files**: `lib/minga/port/protocol.ex`, `test/minga/port/protocol_test.exs`,
  `zig/src/main.zig`, `zig/src/protocol.zig`, `zig/src/test_protocol.zig`
- **Changes**:
  - **Protocol design** — simple binary opcodes, not ETF:
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
      0x13 batch_end:  <<0x13>>  (sent after a group of draw commands to trigger render)
    ```
  - `Minga.Port.Protocol` — Elixir encoder/decoder module:
    - `@spec encode_draw(non_neg_integer(), non_neg_integer(), String.t(), keyword()) :: binary()`
    - `@spec encode_cursor(non_neg_integer(), non_neg_integer()) :: binary()`
    - `@spec encode_clear() :: binary()`
    - `@spec encode_batch_end() :: binary()`
    - `@spec decode_event(binary()) :: {:key, integer(), integer()} | {:resize, integer(), integer()} | {:ready, integer(), integer()}`
  - `zig/src/protocol.zig` — Zig decoder/encoder (mirror of Elixir side)
  - `zig/src/main.zig` — libvaxis init, opens `/dev/tty` for terminal,
    reads stdin for BEAM commands, writes stdout for input events.
    Basic event loop: capture key → encode → write to stdout.
    Read stdin → decode → (no-op render for now).
  - Modifier flags: `SHIFT=0x01, CTRL=0x02, ALT=0x04, SUPER=0x08`
- **Tests**: Elixir: encode/decode round-trips for every message type.
  Zig: unit tests for protocol parsing. Integration: spawn Zig binary from
  Elixir, send a clear+batch_end, verify no crash.

### Commit 5: Port Manager + supervision

- **Files**: `lib/minga/port/manager.ex`, `lib/minga/application.ex`,
  `test/minga/port/manager_test.exs`
- **Changes**:
  - `Minga.Port.Manager` — GenServer:
    - Spawns Zig binary via `Port.open({:spawn_executable, path}, [:binary, :exit_status, {:packet, 4}])`
    - Waits for `{:ready, w, h}` on init
    - `@spec send_commands(GenServer.server(), [binary()]) :: :ok`
    - `@spec subscribe(GenServer.server()) :: :ok` — processes subscribe to
      receive input events
    - Forwards decoded input events to subscribers via `send/2`
    - On port exit: logs reason, supervisor handles restart
  - Update `Minga.Application` supervisor tree:
    ```
    Minga.Supervisor (rest_for_one)
    ├── Minga.Buffer.Supervisor (DynamicSupervisor)
    ├── Minga.Port.Manager
    └── (Editor added in next commit)
    ```
  - `rest_for_one` strategy: if Port Manager crashes, Editor restarts too
- **Tests**: Start manager with mock Zig binary (simple echo script),
  verify command sending and event receiving. Test port crash recovery.

### Commit 6: Editor server + rendering pipeline

- **Files**: `lib/minga/editor.ex`, `lib/minga/editor/viewport.ex`,
  `test/minga/editor_test.exs`, `test/minga/editor/viewport_test.exs`
- **Changes**:
  - `Minga.Editor.Viewport` — pure module:
    - Types: `@type t :: %{top: non_neg_integer(), left: non_neg_integer(), rows: pos_integer(), cols: pos_integer()}`
    - `@spec scroll_to_cursor(t(), GapBuffer.position()) :: t()`
    - `@spec visible_range(t()) :: {first_line :: non_neg_integer(), last_line :: non_neg_integer()}`
  - `Minga.Editor` — GenServer:
    - State: buffer pid, viewport, terminal dimensions, mode (`:insert` for
      now — modal FSM in Phase 2)
    - Subscribes to Port.Manager for input events
    - On key event: dispatch to buffer (insert/delete/move)
    - After mutation: pull visible lines from buffer, build render commands,
      send to Port.Manager
    - Renders: buffer lines + cursor + status line (filename, line:col, dirty)
    - Ctrl+S → save, Ctrl+Q → clean shutdown
  - Add Editor to supervisor tree
  - `@spec` on all public and callback functions
- **Tests**: Mock buffer and port manager. Verify: key events produce correct
  buffer calls and render commands, viewport scrolls when cursor moves off
  screen, status line content updates.

### Commit 7: Zig renderer implementation

- **Files**: `zig/src/renderer.zig`, `zig/src/main.zig`
- **Changes**:
  - `renderer.zig`: Processes render commands from BEAM:
    - `draw_text`: write text with styles to vaxis window at (row, col)
    - `set_cursor`: position the vaxis cursor
    - `clear`: clear the vaxis window
    - `batch_end`: call `vaxis.render()` to flush to terminal
  - Style support: foreground/background colors (24-bit), bold/underline/italic
    via attribute flags
  - `main.zig`: wire renderer into the event loop — two concurrent activities:
    1. Poll libvaxis for terminal events → encode → write to stdout
    2. Read stdin for render commands → decode → pass to renderer
  - Handle graceful shutdown (BEAM closes stdin → Zig exits cleanly, restoring
    terminal state)
- **Tests**: Manual — open a file with `mix minga <file>`, verify display,
  edit, save, quit. Zig unit tests for renderer command processing.

### Commit 8: CLI entry point + end-to-end polish

- **Files**: `lib/minga/cli.ex`, `lib/mix/tasks/minga.ex`
- **Changes**:
  - `mix minga <filename>` — opens the editor
  - `mix minga` (no args) — opens empty buffer
  - `Minga.CLI` module: arg parsing, error handling (file not found, etc.)
  - Clean terminal restoration on crash (trap exits, ensure Zig process
    terminates and restores terminal)
  - Handle edge cases: terminal resize mid-edit, empty files, files with
    no trailing newline, long lines (horizontal scrolling)
- **Tests**: Integration test that starts the full app, sends simulated
  keystrokes, verifies buffer state. Test file-not-found error path.

---

## Phase 2: Modal Editing + Which-Key

Goal: Vim-style modal editing with Doom Emacs leader keys and which-key popups.

### Commit 9: Command registry + keymap trie

- **Files**: `lib/minga/command.ex`, `lib/minga/command/registry.ex`,
  `lib/minga/keymap.ex`, `lib/minga/keymap/trie.ex`,
  `test/minga/command/registry_test.exs`, `test/minga/keymap/trie_test.exs`
- **Changes**:
  - `Minga.Command` — struct: `%{name: atom(), description: String.t(), execute: (Editor.t() -> Editor.t())}`
  - `Minga.Command.Registry` — named command lookup:
    - `@spec register(atom(), String.t(), function()) :: :ok`
    - `@spec lookup(atom()) :: {:ok, Command.t()} | :error`
    - `@spec all() :: [Command.t()]`
    - Register built-in commands: `:save`, `:quit`, `:force_quit`,
      `:move_left`, `:move_right`, `:move_up`, `:move_down`, etc.
  - `Minga.Keymap.Trie` — prefix tree for key sequences:
    - Types: `@type key :: {codepoint :: integer(), modifiers :: integer()}`
    - `@type node :: %{children: %{key() => node()}, command: atom() | nil, description: String.t() | nil}`
    - `@spec new() :: node()`
    - `@spec bind(node(), [key()], atom(), String.t()) :: node()`
    - `@spec lookup(node(), key()) :: {:command, atom()} | {:prefix, node()} | :not_found`
    - `@spec children(node()) :: [{key(), String.t() | atom()}]` — for which-key display
  - `Minga.Keymap` — mode-specific keymap management:
    - `@spec keymap_for(:normal | :insert | :visual | :command) :: Trie.node()`
    - Default keymaps defined as data (no code in the keybinding definitions)
- **Tests**: Trie: insert, lookup, prefix navigation, overwrite, children
  listing. Registry: register, lookup, duplicate handling.

### Commit 10: Vim FSM — Normal and Insert modes

- **Files**: `lib/minga/mode.ex`, `lib/minga/mode/normal.ex`,
  `lib/minga/mode/insert.ex`, `test/minga/mode_test.exs`
- **Changes**:
  - `Minga.Mode` — behaviour + FSM:
    - Types: `@type mode :: :normal | :insert | :visual | :operator_pending | :command`
    - `@type result :: {:continue, state} | {:transition, mode(), state} | {:execute, atom(), state}`
    - `@callback handle_key(key(), state()) :: result()`
    - `@spec process(mode(), key(), state()) :: {mode(), [atom()], state()}`
    - Tracks count prefix (e.g., `3j` = move down 3 times)
  - `Minga.Mode.Normal`:
    - `i` → transition to Insert
    - `a` → move right + transition to Insert
    - `o` → new line below + transition to Insert
    - `O` → new line above + transition to Insert
    - `A` → end of line + transition to Insert
    - `I` → start of line + transition to Insert
    - `hjkl` → movement
    - Count prefix: `[0-9]` accumulates, next key repeats
  - `Minga.Mode.Insert`:
    - `Esc` → transition to Normal
    - All other keys → insert character
  - Update `Minga.Editor` to use Mode FSM for key dispatch
  - Status line shows current mode: `-- NORMAL --`, `-- INSERT --`
- **Tests**: Mode transitions (Normal→Insert→Normal), count prefixes,
  key dispatch produces correct commands.

### Commit 11: Motions and operators

- **Files**: `lib/minga/mode/normal.ex`, `lib/minga/motion.ex`,
  `lib/minga/operator.ex`, `lib/minga/mode/operator_pending.ex`,
  `test/minga/motion_test.exs`, `test/minga/operator_test.exs`
- **Changes**:
  - `Minga.Motion` — pure functions that compute target positions:
    - `@spec word_forward(GapBuffer.t(), position()) :: position()`
    - `@spec word_backward(GapBuffer.t(), position()) :: position()`
    - `@spec end_of_word(GapBuffer.t(), position()) :: position()`
    - `@spec line_start(GapBuffer.t(), position()) :: position()`
    - `@spec line_end(GapBuffer.t(), position()) :: position()`
    - `@spec file_start() :: position()`
    - `@spec file_end(GapBuffer.t()) :: position()`
    - `w`, `b`, `e`, `0`, `$`, `gg`, `G`
  - `Minga.Operator` — operators that act on ranges:
    - `@spec delete(GapBuffer.t(), position(), position()) :: GapBuffer.t()`
    - `@spec change(GapBuffer.t(), position(), position()) :: GapBuffer.t()`
    - `@spec yank(GapBuffer.t(), position(), position()) :: {GapBuffer.t(), String.t()}`
    - `d`, `c`, `y` + a register/clipboard for yanked text
  - `Minga.Mode.OperatorPending`:
    - Entered when `d`, `c`, or `y` is pressed in Normal mode
    - Waits for a motion key, then executes operator over the range
    - `dd`, `cc`, `yy` — line-wise variants
    - `p`, `P` — paste from register
  - Count works across both: `3dw` = delete 3 words
- **Tests**: Each motion against known buffer content. Each operator
  (delete, change, yank) with various motions. Line-wise operators.
  Count multiplication. Edge cases (operator at end of file, empty line).

### Commit 12: Visual mode

- **Files**: `lib/minga/mode/visual.ex`, `test/minga/mode/visual_test.exs`
- **Changes**:
  - `Minga.Mode.Visual`:
    - `v` from Normal → enter Visual (character-wise)
    - `V` from Normal → enter Visual (line-wise)
    - Tracks selection anchor + cursor (the moving end)
    - All motion keys work (hjkl, w, b, etc.)
    - `d` / `c` / `y` → operate on selection → return to Normal
    - `Esc` → cancel selection → return to Normal
  - Render selection highlight: send style info (reversed fg/bg) for
    selected range in render commands
  - Status line: `-- VISUAL --` or `-- VISUAL LINE --`
- **Tests**: Enter visual, extend selection with motions, apply operators,
  cancel. Line-wise selection. Selection wrapping across lines.

### Commit 13: Command mode

- **Files**: `lib/minga/mode/command.ex`, `lib/minga/command/parser.ex`,
  `test/minga/mode/command_test.exs`, `test/minga/command/parser_test.exs`
- **Changes**:
  - `Minga.Mode.Command`:
    - `:` from Normal → enter Command mode
    - Renders command line at bottom of screen (replaces status line)
    - Captures text input for the command string
    - `Enter` → parse and execute → return to Normal
    - `Esc` → cancel → return to Normal
    - `Backspace` on empty → cancel
  - `Minga.Command.Parser`:
    - `@spec parse(String.t()) :: {:ok, atom(), [term()]} | {:error, String.t()}`
    - `:w` → save, `:q` → quit, `:wq` → save + quit, `:q!` → force quit
    - `:e <filename>` → open file (stretch)
  - Error display: invalid command shows error message briefly
- **Tests**: Parse known commands, unknown command error, execute via
  command mode key sequence.

### Commit 14: Leader keys + which-key popup

- **Files**: `lib/minga/which_key.ex`, `lib/minga/keymap/defaults.ex`,
  `zig/src/renderer.zig`, `test/minga/which_key_test.exs`
- **Changes**:
  - `Minga.WhichKey`:
    - `@spec start_timeout(non_neg_integer()) :: reference()` — start popup timer
    - `@spec cancel_timeout(reference()) :: :ok`
    - `@spec format_bindings([{Trie.key(), String.t() | atom()}]) :: [{String.t(), String.t()}]`
      — format key + description pairs for display
    - Timer: after `SPC` (or other leader), wait 300ms. If no follow-up key,
      show popup with available bindings. Each subsequent key narrows the trie
      and resets the timer.
    - Popup renders as a floating panel at bottom of screen
  - `Minga.Keymap.Defaults` — Doom-style default bindings:
    - `SPC f f` → find file (stub: echoes "not yet implemented")
    - `SPC f s` → save file
    - `SPC b b` → switch buffer (stub)
    - `SPC b d` → close buffer (stub)
    - `SPC w v` → vertical split (stub)
    - `SPC w s` → horizontal split (stub)
    - `SPC q q` → quit
    - `SPC h k` → describe key (stub)
    - Groups: `f → file`, `b → buffer`, `w → window`, `q → quit`, `h → help`
  - Zig renderer: new opcode for floating panel:
    ```
    0x14 draw_panel: <<0x14, row::16, col::16, width::16, height::16,
                       border::8, content_len::16, content::binary>>
    ```
    Renders a bordered box with text content at the specified position.
  - Update Normal mode: `SPC` enters leader key sequence mode, dispatches
    through the trie with which-key integration
- **Tests**: Which-key timer fires and produces correct binding list.
  Leader key sequence walks the trie correctly. Partial sequence shows
  which-key, completion executes command. Unknown sequence cancels cleanly.

### Commit 15: Text objects + V1 polish

- **Files**: `lib/minga/text_object.ex`, `test/minga/text_object_test.exs`,
  `AGENTS.md`, `README.md`
- **Changes**:
  - `Minga.TextObject` — select ranges for operator-pending mode:
    - `@spec inner_word(GapBuffer.t(), position()) :: {position(), position()}`
    - `@spec around_word(GapBuffer.t(), position()) :: {position(), position()}`
    - `@spec inner_delimited(GapBuffer.t(), position(), String.t(), String.t()) :: {position(), position()} | nil`
    - `@spec around_delimited(GapBuffer.t(), position(), String.t(), String.t()) :: {position(), position()} | nil`
    - `iw` / `aw` — inner/around word
    - `i"` / `a"`, `i'` / `a'` — inner/around quotes
    - `i(` / `a(`, `i{` / `a{`, `i[` / `a[` — inner/around brackets
    - `ip` / `ap` — inner/around paragraph
  - Wire text objects into operator-pending mode: `di"`, `ci(`, `yaw`, etc.
  - Update `AGENTS.md` with full project conventions learned during development
  - Update `README.md` with current feature set, keybinding reference, build
    instructions, architecture diagram
  - Final pass: ensure all public functions have `@spec`, all modules have
    `@moduledoc`, `mix compile --warnings-as-errors` passes clean
- **Tests**: Each text object against varied buffer content. Text objects
  with operators. Edge cases: cursor not inside delimiters, nested delimiters,
  empty content between delimiters.

---

## Coding Standards

### Typing (Elixir 1.19)

- **Every public function** gets a `@spec`
- **Every module** defines its core types with `@type` / `@typep`
- **Structs** use `@enforce_keys` for required fields
- **Guards** in function heads where they aid type inference (the set-theoretic
  type checker uses them)
- **Pattern matching** over `if/cond` — helps type narrowing across clauses
- Run `mix compile --warnings-as-errors` — treat type warnings as failures

### Testing

- **Unit tests** for every module with meaningful logic
- **Property-based tests** (StreamData) for the gap buffer — random
  insert/delete sequences should never corrupt state
- **Mocked integration tests** for GenServer interactions
- **Zig unit tests** for protocol parsing and renderer command handling
- Test names describe behavior, not implementation: `"deleting at start of
  line joins with previous line"` not `"test delete_before/1"`

### AGENTS.md

Created in Commit 1, refined throughout, finalized in Commit 15. Covers:

- Project structure and module naming conventions
- Type annotation requirements
- Testing expectations and patterns
- Commit message format
- How the Port protocol works (for anyone touching Zig code)
- How to add new commands, motions, operators, text objects
- How keybindings are defined (data-driven, in the trie)

---

## Risks & Open Questions

1. **`/dev/tty` availability**: libvaxis should support opening `/dev/tty`
   directly (most TUI libraries do). Needs verification in the libvaxis API
   during Commit 4. Fallback: use fd 3 via a wrapper script.

2. **Port `{:packet, 4}` framing**: Erlang's packet mode adds 4-byte length
   headers automatically. Need to ensure the Zig side reads/writes the same
   framing. Test early in Commit 4.

3. **Zig build caching with Mix**: `zig build` is fast and has its own caching,
   but Mix needs to know when to trigger it. A custom Mix compiler that checks
   `zig/src/**/*.zig` timestamps should work.

4. **Which-key timer in GenServer**: Using `Process.send_after/3` for the
   300ms timeout. Need to cancel correctly when a key arrives before the timer.
   Standard GenServer pattern, low risk.

5. **Operator + count + motion composition**: The `3d2w` grammar (3 × delete
   2 words = delete 6 words) requires careful count multiplication in the FSM.
   Well-documented in Vim's source, but needs thorough testing.
