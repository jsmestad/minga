# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Minga is a BEAM-powered modal text editor. The Elixir/OTP process owns all editor state; native frontends (Swift/Metal macOS, Zig TUI, planned GTK4 Linux) are "dumb" renderers connected via a binary port protocol on stdin/stdout. Read `AGENTS.md` for the full developer guide, coding standards, and architectural rules. This file covers what you need to be productive quickly.

## Commands

```bash
# Build and run
mix deps.get                          # First time / after dep changes
mix compile                           # Compile (also builds Zig renderer via custom compiler)
bin/minga                             # Run the editor

# Lint (run all before committing)
make lint                             # Format + credo + compile warnings + dialyzer (all steps, even on failure)
make lint.fix                         # Auto-fix formatting, then run credo

# Tests
mix test.llm                          # Default for LLM agents: module summary, max 5 failures, excludes :heavy
mix test.debug test/path/file_test.exs       # Single file, verbose (--trace), max 3 failures
mix test.llm test/path/file_test.exs:42      # Single test by line number
mix test.quick                        # Only stale tests, max 5 failures
mix test --failed                     # Re-run only previously failed tests
mix test                              # Full suite

# Zig (only if you touched .zig files)
mix zig.lint                          # zig fmt --check + zig build test
cd zig && zig build test              # Zig tests directly
```

## Architecture at a glance

Two OS processes, one protocol:
- **BEAM (Elixir)**: all state, all logic, all decisions
- **Frontend (Zig/Swift/GTK4)**: renders commands, sends input events, no state

### Three-layer dependency rule (enforced by Credo check)

Dependencies flow downward only. A custom Credo check (`DependencyDirectionCheck`) flags violations.

- **Layer 0** (pure functions, no deps): `Buffer.Document`, `Editing.Motion.*`, `Editing.TextObject`, `Core.*`, `Mode.*` FSM modules
- **Layer 1** (stateful services, depends on Layer 0): `Buffer.Server`, `Config.*`, `LSP.*`, `Git.*`, `Agent.*`, `Keymap.*`, `Parser.Manager`, `Frontend.Manager`
- **Layer 2** (orchestration, depends on everything): `Editor.*`, `Shell.*`, `Input.*`, `Workspace.State`, `Editor.Commands.*`, `Editor.RenderPipeline.*`

### State hierarchy

```
EditorState (Editor GenServer state)
+-- workspace: WorkspaceState        # per-tab, snapshotted on tab/card switch
|   +-- editing: VimState            # mode + mode_state (the Mode FSM)
|   +-- buffers: Buffers             # buffer list, active pid
|   +-- windows: Windows             # window tree, active id
|   +-- keymap_scope: atom           # :editor | :agent | :file_tree | :git_status
|   +-- agent_ui: UIState            # agent panel/view (per-tab)
+-- shell_state: ShellState          # presentation, NOT snapshotted per tab
|   +-- picker_ui, prompt_ui, whichkey, hover_popup...  # overlay state
|   +-- agent: Agent.State           # session pid/status (global singleton)
+-- shell: module                    # Shell.Traditional | Shell.Board
```

### Key contracts

- **Shell behaviour** (`lib/minga/shell.ex`): abstracts presentation. Callbacks: `render/1`, `build_chrome/4`, `compute_layout/1`, `input_handlers/1`, `handle_event/3`
- **Mode FSM** (`lib/minga/mode.ex`): 14 vim modes. `handle_key/2` returns `{:continue | :transition | :execute | :execute_then_transition, ...}`. All transitions go through `VimState.transition/3` (enforced by Credo check `NoDirectStateMachineWriteCheck`)
- **Input handlers** (`lib/minga/input.ex`): overlay handlers checked first (Interrupt, Picker, Completion), then surface handlers (Scoped, GlobalBindings, ModeFSM). Each returns `{:handled, state}` or `{:passthrough, state}`
- **Effects pattern** (`lib/minga/editor.ex:1365`): agent events already use `{state, [effect]}`. New handler extractions should follow this pattern

### Render pipeline

7 stages, all pure functions of state: Invalidation -> Layout -> Scroll -> Content -> Chrome -> Compose -> Emit. Entry point: `lib/minga/editor/render_pipeline.ex`. Each frame: `clear -> N x draw_text -> set_cursor -> cursor_shape -> batch_end`.

### Supervision tree (abbreviated)

```
Minga.Supervisor (rest_for_one)
+-- Foundation.Supervisor (Events, Config, Keymap, Language registries)
+-- Buffer.Supervisor (DynamicSupervisor, one process per open file)
+-- Services.Supervisor (Git, Extensions, LSP, Diagnostics, Agent.Supervisor)
+-- Runtime.Supervisor
    +-- Editor.Supervisor (rest_for_one)
        +-- Parser.Manager (tree-sitter Port)
        +-- Frontend.Manager (renderer Port)
        +-- Editor (main orchestration GenServer)
```

## Rules that matter most

These are the ones LLM agents violate most often. The full list is in `AGENTS.md`.

1. **`@spec` on every public function.** No exceptions. Elixir 1.19's set-theoretic type system catches real bugs.
2. **State ownership (Rule 2):** Each struct has one owning module that constructs and updates it. Never do `%{thing | field: value}` on a struct you don't own. Add a function to the owning module instead.
3. **No `cond` blocks.** Use multi-clause functions with pattern matching and guards. `cond` defeats BEAM JIT optimizations.
4. **No `Process.sleep/1` in production code.** Use `Process.send_after/3` or state machines.
5. **No direct `Logger` calls.** Use `Minga.Log.{level}(:subsystem, msg)` for filtered logging, or `log_message(state, text)` for unconditional `*Messages*` buffer entries.
6. **Test at the lightest layer.** Pure function -> GenServer -> EditorCase -> snapshot. Don't boot 3 GenServers to test a pure function.
7. **All new test files must use `async: true`** unless they mutate global state or spawn OS processes. HeadlessPort is NOT a reason for `async: false`.

## Commit messages

```
type(scope): short description
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`. Scopes: `buffer`, `editing`, `ui`, `port`, `editor`, `mode`, `keymap`, `config`, `lsp`, `command`, `git`, `agent`, `input`, `language`, `session`, `project`, `zig`, `macos`.

## Active plans

- `docs/PLAN-ui-stability.md` — Coordinated plan for Board zoom fixes, test stabilization, and shell-owned state transitions
- `docs/PROPOSAL-shell-state-transitions.md` — Shell behaviour gaining lifecycle callbacks for buffer/agent events
- `docs/PROPOSAL-deterministic-editor-testing.md` — Extracting pure `{state, effects}` functions from the Editor GenServer
- `docs/UI-STATE-ANALYSIS.md` — Analysis of why overlay state gets stuck (bag of nullable fields vs state machine)
