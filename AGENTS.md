# Minga — Agent & Developer Guide

## Project Overview

Minga is a BEAM-powered modal text editor with a Zig terminal renderer. Read `PLAN.md` for full architecture and implementation roadmap. Read `ROADMAP.md` for the current feature grid and planned work. Read `docs/ARCHITECTURE.md` for the two-process design and its benefits.

## Tech Stack

- **Elixir 1.19** / OTP 28 — editor core (buffers, modes, commands, orchestration)
- **Zig 0.15** with libvaxis — terminal rendering (runs as BEAM Port)
- **ExUnit** + **StreamData** — testing
- Pinned versions in `.tool-versions`

## Project Structure

```
lib/
  minga.ex                    # Root module
  minga/
    application.ex            # OTP application / supervisor tree
    foundation/
      supervisor.ex           # Foundation supervisor (Events, Config, Keymap, etc.)
    services/
      supervisor.ex           # Services supervisor (Git, Extensions, LSP, Diagnostics, etc.)
    runtime/
      supervisor.ex           # Runtime supervisor (Watchdog, FileWatcher, Editor.Supervisor)
    buffer/
      document.ex           # Pure data structure (no GenServer)
      server.ex               # GenServer wrapper for gap buffer
      edit_delta.ex           # Edit delta struct for incremental sync
      state.ex                # Buffer GenServer internal state
    port/
      protocol.ex             # Port protocol encoder/decoder
      manager.ex              # GenServer managing the Zig renderer Port
      frontend.ex             # Behaviour for pluggable rendering backends
      capabilities.ex         # Frontend capabilities struct
    parser/
      manager.ex              # GenServer managing the tree-sitter parser Port
    editor.ex                 # Editor orchestration GenServer
    editor/
      supervisor.ex           # Editor supervisor (Parser, Port, Editor)
      layout.ex               # Pure layout computation (single source of truth for all rects)
      viewport.ex             # Viewport scrolling logic
    mode/
      normal.ex               # Vim normal mode
      insert.ex               # Vim insert mode
      visual.ex               # Vim visual mode
      operator_pending.ex     # Operator-pending mode (d, c, y + motion)
      command.ex              # : command mode
    motion.ex                 # Cursor motion functions
    operator.ex               # Operator functions (delete, change, yank)
    text_object.ex            # Text objects (iw, aw, i", etc.)
    command.ex                # Command struct
    command/
      registry.ex             # Named command lookup
      parser.ex               # :command parsing
    comment.ex                 # Line comment toggling per filetype (tree-sitter injection-aware)
    git.ex                     # Git delegator (resolves backend via app config)
    git/
      backend.ex             # Behaviour for git operations (9 callbacks)
      system.ex              # Production backend (shells out to git CLI)
      buffer.ex              # Per-buffer GenServer: caches HEAD, computes diffs
      diff.ex                # Pure in-memory line diffing via List.myers_difference/2
    config.ex                 # Config DSL (use Minga.Config)
    config/
      options.ex              # Typed option registry with per-filetype overrides
      loader.ex               # Config file discovery and evaluation
      hooks.ex                # Lifecycle hook registry (after_save, after_open, etc.)
      advice.ex               # Before/after command advice (ETS-backed, read_concurrency)
    keymap.ex                 # Mode-specific keymap management
    keymap/
      bindings.ex             # Key sequence to command mappings
      defaults.ex             # Default Doom-style keybindings
      active.ex               # Live merged keymap (defaults + user overrides)
      key_parser.ex           # Human-readable key string parser
    which_key.ex              # Which-key popup logic
    cli.ex                    # CLI entry point
  mix/
    compilers/
      zig.ex                  # Custom Mix compiler for Zig builds

zig/
  build.zig                   # Zig build configuration
  build.zig.zon               # Zig package manifest (libvaxis dep)
  src/
    main.zig                  # Entry point, event loop
    protocol.zig              # Port protocol encoder/decoder
    renderer.zig              # libvaxis render command handler

test/                         # Mirrors lib/ structure
```

## Git Branching

**`main` is protected.** All changes must go through feature branches and pull requests. Never commit directly to main.

- **Always create a feature branch** before making changes. Use descriptive names: `feat/release-pipeline`, `fix/viewport-scroll`, `refactor/layout-compute`.
- **Never switch branches if another agent session is active on a branch.** Multiple LLM agents may be working in this repo concurrently. If you see uncommitted changes or a branch that isn't yours, leave it alone. Create a new branch from `main` instead.
- **Check your current branch** before starting work: `git branch --show-current`. If you're on `main`, create a branch. If you're on someone else's feature branch, switch to `main` and branch from there.
- **Push your branch and open a PR** when the work is ready. Always open the PR; don't just push and leave it. CI must pass before merging.

### Git Worktrees (trial)

We're trying git worktrees so multiple agents can work on different features at the same time. **The user is new to worktrees, so walk them through every step.** Don't assume they know the commands.

When starting a new feature, offer to use a worktree:

> "Want me to set this up as a worktree so you can keep working on other things in the main checkout? I'll walk you through it."

If they say yes:

1. Create the worktree directory and branch:
   ```bash
   git worktree add ../minga-worktrees/<branch-name> -b <branch-name>
   ```
2. Tell the user to point the next agent session at `../minga-worktrees/<branch-name>` as its working directory.
3. Remind them the first build will be slower (cold `_build` and `deps` cache).

When a feature is done and the PR is merged:
1. Clean up: `git worktree remove ../minga-worktrees/<branch-name>`
2. Prune stale refs: `git worktree prune`

**After the first worktree experience, ask the user:** "How did the worktree workflow feel? Worth keeping, or would you rather go back to one branch at a time?" Update this section based on their answer.

## Iterative Fixes (especially TUI/rendering)

When a fix improves visible behavior (user confirms it's better), **commit it and stop**. Do not immediately try to "refine" or "optimize" the fix in the same session. The TUI rendering pipeline has race conditions between the BEAM, the Zig Port, and the physical terminal that are impossible to fully reason about without seeing real output. What looks like an obvious improvement in theory (e.g., "skip the stale frame") can make things worse because your mental model of the frame ordering is wrong.

Rules:
1. Make one change. Rebuild. Have the user test.
2. If the user says it's better, commit. If there's a remaining glitch, ask the user to describe it before writing more code.
3. Never stack a second speculative fix on top of an untested first fix.
4. Never revert or replace a working fix with a "cleaner" version without user confirmation that the new version also works.

## Build It Right or Don't Build It

Never scope foundational infrastructure to a "V1" that deliberately skips known requirements. If a data structure needs to handle 10,000 entries in production (e.g., LSP diagnostics), build it with the right algorithm from the start (interval tree, not linear scan). If a system needs incremental updates, don't ship clear-and-reapply and plan to "optimize later." The optimization never happens, and every feature built on top inherits the limitation.

This applies to internal infrastructure like data structures, coordinate mapping systems, rendering pipelines, and protocol layers. It does not apply to user-facing features, where shipping a subset of functionality (e.g., keyboard selection before mouse selection) is a legitimate scoping choice.

The test: if cutting the corner means the next team building on this code has to work around the limitation or refactor the foundation, it's not a valid shortcut. Build the foundation once, correctly.

## Coding Standards

### Elixir Types (mandatory)

Elixir 1.19's set-theoretic type system catches real bugs at compile time. Help it by being explicit:

- **`@spec`** on every public function — no exceptions
- **`@type` / `@typep`** for all custom types in every module
- **`@enforce_keys`** on structs for required fields
- **Guards** in function heads where they aid type inference
- **Pattern matching** over `if/cond` — helps type narrowing across clauses
- **No `cond` blocks** — use multi-clause functions with pattern matching and guards instead. `cond` defeats BEAM JIT optimizations and hides control flow that the type system and compiler can reason about. Extract a private helper with multiple `defp` clauses rather than inlining a `cond`.
- **List append strategy depends on context.** When credo (or your instincts) flags a `list ++ [item]`, don't reflexively reach for `Enum.reverse([item | Enum.reverse(list)])`. That double-reverse is *worse* than `++` for a single append (two O(n) traversals vs one). Evaluate each case:
  - **Small list, infrequent appends** (e.g., chat messages, UI indicator lines, anything bounded by human interaction speed or terminal height): `list ++ [item]` is fine. Readability wins. The `AppendSingleItem` credo check is disabled project-wide for this reason.
  - **Accumulating in a loop/reduce** (building a list item by item): prepend with `[item | acc]` inside the loop, then `Enum.reverse(acc)` once at the end. This is O(n) total vs O(n²) for repeated `++`. This is the one case where the pattern is correct.
  - **Frequent appends AND frequent ordered reads on a large list**: use `:queue` (Erlang's double-ended queue) for O(1) amortized operations on both ends.
  - **Never use `Enum.reverse([item | Enum.reverse(list)])`** as a substitute for `list ++ [item]`. It's strictly worse: same O(n) complexity, 2x the constant factor, and much harder to read.
- **Bulk text operations** — when inserting or replacing multi-character text in a `Document`, always use bulk operations (`Document.insert_text/2`, `Buffer.Server.apply_text_edit/6`). Never decompose a string into graphemes and reduce over `insert_char` in a loop. Character-by-character insertion is O(n²) on the gap buffer's binary and creates pathological undo stack growth.
- **Structs over tuples for data that crosses module boundaries.** Tuples are fine for small, fixed-shape, positional data inside one module. When a data shape is used across multiple modules (e.g., returned from a behaviour callback and consumed by a renderer), use a struct with `@enforce_keys`. The signals that you've outgrown tuples: adding optional positions (3-tuple vs 4-tuple), writing normalization functions to convert between sizes, or pattern matches that silently break when a field is added. Structs let you add optional fields with defaults without touching every consumer. Name the struct after the concept it represents (`Picker.Item`, not `Picker.Tuple`).
- **No `Process.sleep/1`** — never use `Process.sleep` anywhere in production code. It blocks the calling process, defeats the BEAM's concurrency model, and hides real timing bugs. Use `Process.send_after/3`, GenServer state machines, or `receive` with `after` clauses instead. If you need to defer work until a resource is ready, store the intent in state and act on it when the ready signal arrives (e.g., set a pending field and apply it in the `handle_info` that confirms the resource is up). `Process.sleep` in tests is acceptable only in integration tests that interact with external processes.
- `mix compile --warnings-as-errors` must pass clean

### Common Elixir Footguns

LLM agents hit these repeatedly. Read before writing any Elixir:

- **Lists don't support index access.** `mylist[0]` doesn't work. Use `Enum.at(mylist, 0)`, `hd/1`, or pattern matching.
- **Bind the result of block expressions.** Variables can't be rebound inside `if`/`case`/`with` and have the change leak out. Always bind: `state = if condition, do: new_state, else: state`.
- **Never nest multiple modules in one file.** It causes cyclic compilation dependencies. One `defmodule` per `.ex` file.
- **Don't use `String.to_atom/1` on user input.** Atoms are never garbage collected. Use `String.to_existing_atom/1` or keep it as a string.
- **Predicate functions end in `?`, not `is_`.** Reserve `is_` prefix for guard-compatible functions only.
- **`DynamicSupervisor` and `Registry` require names.** Always pass `name:` in the child spec: `{DynamicSupervisor, name: Minga.Buffer.Supervisor, strategy: :one_for_one}`.
- **Don't use map access syntax on structs.** `my_struct[:field]` doesn't work (structs don't implement Access). Use `my_struct.field` or pattern match.
- **`mix deps.clean --all` is almost never needed.** Don't nuke deps as a first troubleshooting step. Try `mix deps.get` or `mix compile --force` first.

### Pre-commit Checks (enforced by commit-gate extension)

The `commit-gate` extension blocks every `git commit` until `mix lint` has passed. You don't need to remember this; the extension catches it automatically. But you should still run all relevant checks proactively, not just wait for the gate to yell at you.

**Run `mix precommit` when you're done with all changes.** This runs lint + tests in one shot. Fix any failures before committing.

```bash
mix precommit                     # Runs: format, credo, compile, dialyzer, test
```

For targeted checks:

```bash
mix lint                          # Format + credo + compile + dialyzer (no tests)
mix test --warnings-as-errors     # Tests only
mix test test/minga/foo_test.exs  # Single file (faster iteration)
mix test --failed                 # Re-run only previously failed tests
```

**Zig changes:**

```bash
mix zig.lint                      # zig fmt --check + zig build test
```

If any check fails, fix it before committing. No exceptions.

Example:

```elixir
@type position :: {line :: non_neg_integer(), col :: non_neg_integer()}

@spec move(t(), :left | :right | :up | :down) :: t()
def move(%__MODULE__{} = buffer, direction) when direction in [:left, :right, :up, :down] do
  # ...
end
```

### Elixir Testing

- Test files mirror `lib/` structure: `lib/minga/buffer/document.ex` → `test/minga/buffer/document_test.exs`
- **Descriptive names**: `"deleting at start of line joins with previous line"` not `"test delete_before/1"`
- **Property-based tests** with StreamData for data structure modules
- **Edge cases always tested**: empty state, boundaries, unicode
- **Screen snapshot tests** for UI regression detection. See [docs/SNAPSHOT_TESTING.md](docs/SNAPSHOT_TESTING.md) for how to write, update, and review snapshot tests. When your change modifies the rendered UI, run `UPDATE_SNAPSHOTS=1 mix test test/minga/integration/` to regenerate baselines, then review the diffs before committing.
- Run with `mix test --warnings-as-errors`

**Process synchronization in tests:**

- **Use `start_supervised!/1`** to start processes in tests. It guarantees cleanup between tests.
- **Avoid `Process.sleep/1` in tests.** Use `:sys.get_state/1` as a synchronization barrier (ensures the process has handled prior messages), or `Process.monitor/1` + `assert_receive {:DOWN, ...}` to wait for process exit. Sleep is acceptable only in integration tests that interact with external OS processes.
- **Avoid `Process.alive?/1` in assertions.** It's a race condition. Monitor the process instead.

**Debugging test failures:**

```bash
mix test test/minga/foo_test.exs          # Run one file
mix test test/minga/foo_test.exs:42       # Run one test (line number)
mix test --failed                         # Re-run only failures from last run
mix test --seed 12345                     # Reproduce a specific run order
```

**DI stubs for OS processes:**

Tests must not spawn OS processes during concurrent (async) execution. The BEAM's `erl_child_setup` has a race condition that causes EPIPE errors under concurrency. Modules that shell out (`Minga.Git`, `Minga.FileFind`, `Minga.ProjectSearch`) use a backend behaviour pattern so tests can inject stubs:

- `Minga.Git` → `Minga.Git.Backend` behaviour, `Minga.Git.Stub` in tests (configured in `config/test.exs`)
- `Git.Stub` is ETS-backed and configurable per-test via `Git.Stub.set_root/2`, `set_status/2`, etc.
- Tests that genuinely need OS processes (e.g., `Extension.GitIntegrationTest`) must be `async: false` with `@moduletag timeout:` to prevent hangs

### Zig

- Doc comments (`///`) on all public functions
- Explicit error handling — no `catch unreachable` outside tests
- `std.log` for debug output (stderr), never stdout (that's the Port channel)
- `zig fmt` for all formatting (no manual style debates)
- `mix zig.lint` must pass (`zig fmt --check` + `zig build test`)

### Logging and the `*Messages*` Buffer

Minga has a `*Messages*` buffer (viewable via `SPC b m`) that acts as the editor's runtime log, similar to Emacs's `*Messages*`. Use it liberally to surface information that helps users understand what the editor is doing and to aid debugging when things go wrong.

**When to log to `*Messages*`:**
- State transitions the user should know about: file opened, file saved, LSP server connected/disconnected, agent session started, config reloaded.
- Errors and warnings that don't warrant a hard failure: clipboard write failed, formatter returned non-zero, file watcher couldn't watch a path.
- Diagnostic context: which LSP server was chosen for a buffer, why a filetype was detected a certain way, what config file was loaded.
- Performance-relevant events during development: parse times, highlight setup duration, port restart recovery.

**How to log (Elixir side):**

**Always use `Minga.Log` instead of calling `Logger` directly.** `Minga.Log` routes through per-subsystem log levels so users can turn debug output on/off per subsystem without drowning in noise from everywhere else. Direct `Logger.debug/info/warning/error` calls bypass this filtering and should not be used in application code.

```elixir
# Good: subsystem-aware, respects per-subsystem log level config
Minga.Log.debug(:render, "[render:content] 24µs")
Minga.Log.warning(:lsp, "LSP server crashed: #{inspect(reason)}")

# Bad: bypasses subsystem filtering, don't do this
Logger.debug("[render:content] 24µs")
```

Current subsystems: `:render`, `:lsp`, `:agent`, `:editor`. If your code doesn't fit any of these, add a new subsystem:

1. Add `:log_level_<name>` to the `option_name` type union in `Minga.Config.Options`
2. Add a `{:log_level_<name>, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default}` entry to `@option_specs`
3. Add the subsystem atom to the `@subsystem_options` map in `Minga.Log`
4. Add the subsystem to the `@type subsystem` union in `Minga.Log`
5. Document the new subsystem in `docs/CONFIGURATION.md` under the Logging section

For direct writes to `*Messages*` without Logger (e.g., inside the Editor GenServer), call `log_message(state, "your message")`. Outside the Editor, call `Minga.Editor.log_to_messages("your message")` (async cast to avoid deadlocks).

**Zig side:** Use `std.log` for debug output. The Port.Manager captures log messages from the Zig process's stderr and forwards them to `*Messages*` prefixed with `[ZIG/{level}]`.

**Guidelines:**
- Keep messages concise and actionable. `"LSP: elixir-ls connected (pid 42031)"` is better than `"The language server process has successfully been started."`
- Include relevant context (file paths, server names, error reasons) so the user doesn't have to guess.
- Don't log per-keystroke or per-frame events to `*Messages*`. Those belong in the log file only (via `Minga.Log.debug`).
- When in doubt, log it. A message the user never reads costs nothing. A missing message when debugging costs time.

### Telemetry and Performance Debugging

The keystroke-to-render critical path is instrumented with `:telemetry` spans via `Minga.Telemetry`. When diagnosing performance issues or adding new instrumented code paths, use these spans instead of ad-hoc timing.

**Viewing timing data:** Set `:log_level_render` to `:debug` to see per-stage render timing in `*Messages*`. The `Minga.Telemetry.DevHandler` (always attached at startup) routes span durations through `Minga.Log.debug`.

**Available spans:**

| Event | Metadata | What it measures |
|-------|----------|------------------|
| `[:minga, :render, :pipeline]` | `window_count` | Full render frame |
| `[:minga, :render, :stage]` | `stage` atom | Individual render stage (invalidation, layout, scroll, content, agent_content, chrome, compose, emit) |
| `[:minga, :input, :dispatch]` | | Keystroke dispatch through input router |
| `[:minga, :command, :execute]` | `command` atom | Named command execution |
| `[:minga, :port, :emit]` | `byte_count` | Protocol encoding + port write |

**Adding new spans:** Use `Minga.Telemetry.span/3` (not raw `:telemetry.span/3`). It handles the metadata passthrough correctly for telemetry 1.3:

```elixir
result = Minga.Telemetry.span([:minga, :my_domain, :operation], %{key: :value}, fn ->
  do_expensive_work()
end)
```

For fire-and-forget measurements (no duration), use `Minga.Telemetry.execute/3`.

**Do not** add ad-hoc `System.monotonic_time` timing or `Minga.Log.debug` timing strings. Use telemetry spans so all performance data is structured and aggregatable.

See [CONTRIBUTING.md](CONTRIBUTING.md#performance-debugging-with-telemetry) for the full usage guide including custom handler examples.

### Commit Messages

```
type(scope): short description

Longer body if needed.
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore` Scopes: `buffer`, `port`, `editor`, `mode`, `keymap`, `zig`, `cli`

Examples:
- `feat(buffer): implement gap buffer with cursor movement`
- `feat(zig): scaffold libvaxis renderer with port protocol`
- `test(buffer): add property-based tests for insert/delete`

## Port Protocol

BEAM ↔ Zig communication uses length-prefixed binary messages over stdin/stdout of the Zig process. The Zig process uses `/dev/tty` for terminal I/O (not stdout).

See `PLAN.md` § "Port Protocol" for the full message specification.

## Rendering Architecture

The rendering pipeline is being refactored to support multiple frontends (TUI, macOS GUI, Linux GUI). Read `docs/RENDERING_GAPS.md` for the full analysis and ticket links.

Key design decisions:
- **Display list IR:** The BEAM side owns a display list of styled text runs (not a cell grid) that sits between editor state and protocol encoding. All frontends consume this shared IR. See `docs/ARCHITECTURE.md` § "Display List (Rendering IR)" for the type definitions.
- **Styled text runs over cell grids:** GUIs don't think in terminal cells. The IR uses `{col, text, style}` tuples organized by line within positioned rectangles. The TUI quantizes runs to cells; a GUI renders runs with its font engine.
- **Per-window render state:** Each `Window` carries cached draw commands and a dirty-line set for incremental rendering.
- **Pipeline stages:** The renderer is being split into named stages (Invalidation, Layout, Scroll, Content, Chrome, Compose, Emit) for debuggability and per-stage caching.

## Mouse Support (first-class citizen)

Mouse support is not optional or secondary to keyboard input. Minga ships two frontends (TUI via Zig/libvaxis, macOS GUI via Swift/Metal), and both must handle mouse interactions properly. The bar is **Doom Emacs**: if Doom supports a mouse interaction, Minga should too.

See [#217](https://github.com/jsmestad/minga/issues/217) for the full tracker.

### Architecture

Mouse events flow through the same protocol as keyboard events. Both frontends encode mouse events as `mouse_event` messages (opcode `0x04`) with row, col, button, modifiers, event type, and click count. The BEAM side decodes them in `Minga.Port.Protocol` and dispatches them to `Minga.Editor.Mouse`.

Key rules for mouse work:

1. **Mouse events must flow through the Input.Router focus stack** (once #217 lands), not bypass it. The file tree, picker, completion menu, and agent panel all need to intercept clicks in their regions. Add `handle_mouse` callbacks to `Input.Handler` implementations when building mouse-interactive UI components.

2. **Always pass modifiers through.** The `Editor.handle_info` clause for mouse events must pass modifiers to the mouse handler. Modifier+click combinations (Shift+click, Cmd+click, Ctrl+click) are meaningful interactions, not noise to discard.

3. **Hit-test against `Layout.get(state)` rects.** Every UI region has a computed rect from `Minga.Editor.Layout`. Mouse handlers determine which region a click landed in by checking these rects. Never hardcode pixel/cell offsets.

4. **GUI and TUI may diverge on capture, but the BEAM handler is shared.** The Swift GUI captures `NSEvent.clickCount` natively; the Zig TUI infers multi-click from timing. Both send the same protocol message. The BEAM handler doesn't care which frontend produced the event.

5. **When adding new clickable UI elements** (panels, popups, modeline segments), always add mouse interaction alongside keyboard interaction. Don't ship a keyboard-only UI and plan to "add mouse later." Mouse is not a follow-up.

### Reference: what Doom Emacs supports

Use this as the minimum bar. If Doom does it, we should do it:

- Left click to position cursor
- Click + drag for visual selection
- Double-click to select word
- Triple-click to select line
- Scroll wheel (vertical)
- Middle-click paste
- File tree clicking (treemacs)
- Modeline segment clicking (doom-modeline)
- Shift+click to extend selection
- GUI: hover tooltips for diagnostics and LSP hover
- GUI: Cmd+click go-to-definition
- GUI: right-click context menu
- GUI: smooth trackpad scrolling

## Keeping Documentation Updated

When implementing features, completing planned work, or changing architecture:

- **`ROADMAP.md`** — Update the feature grid status (📋→🚧→✅) when starting or finishing work. Add new rows for features not yet listed.
- **`docs/ARCHITECTURE.md`** — Update when adding new process types, protocol opcodes, or changing supervision structure.
- **`docs/PERFORMANCE.md`** — Mark optimizations as completed when done.

## Adding New Features

### New command
1. Add the command to the appropriate `Commands.*` sub-module's `__commands__/0` (implements `Minga.Command.Provider` behaviour). Include name, description, `requires_buffer` flag, and execute function. If no existing sub-module fits, create a new one and add it to the `@command_modules` list in `Minga.Command.Registry`.
2. Add keybinding in `Minga.Keymap.Defaults`
3. Test the command function and the keybinding lookup

### New motion
1. Add function to `Minga.Motion` with `@spec`
2. Register in `Minga.Mode.Normal` and `Minga.Mode.OperatorPending`
3. Test against known buffer content

### New text object
1. Add function to `Minga.TextObject` with `@spec`
2. Register in `Minga.Mode.OperatorPending`
3. Test with edge cases (cursor outside delimiters, nested, empty)

### New or modified agent tool
Agent tools live in `lib/minga/agent/tools/`. When adding or modifying a tool that reads or writes file content:

1. **Prefer `Buffer.Server` over filesystem I/O.** If a buffer is open for the file, route through it. Use `Buffer.Server.content/1` instead of `File.read/1`, and `Buffer.Server.apply_text_edits/2` instead of `File.write/2`. This gives you undo integration, tree-sitter sync, instant visibility, and no file watcher noise. Fall back to filesystem I/O only when no buffer exists for the file. See [BUFFER-AWARE-AGENTS.md](docs/BUFFER-AWARE-AGENTS.md) for the full rationale.
2. **Batch edits into a single `apply_text_edits/2` call** rather than making N separate GenServer calls. One call = one undo entry, one version bump.
3. **Test the tool function** in `test/minga/agent/tools/`.

> **Note:** Buffer routing is being implemented in phases. Today, tools still use `File.read/write` directly. When wiring a tool to use buffers, follow the pattern in `BUFFER-AWARE-AGENTS.md` Phase 1.

### New render command (requires both sides)
1. Add opcode constant and encoder in `Minga.Port.Protocol`
2. Add decoder and handler in `zig/src/protocol.zig` + `zig/src/renderer.zig`
3. Test encode/decode round-trip on both sides

### New tree-sitter grammar
Adding syntax highlighting for a new language touches four places:

1. **Vendor the grammar** — clone or copy the tree-sitter grammar's `src/` directory into `zig/vendor/grammars/{lang}/src/`. You need `parser.c` and optionally `scanner.c`. Add a `VERSION` file with the grammar version.
2. **Add the highlight query** — place a `highlights.scm` file at `zig/src/queries/{lang}/highlights.scm`. You can start with the query from the grammar's repo and trim capture names to the set Minga supports (keyword, string, comment, function, type, number, operator, punctuation, variable, constant, etc.).
3. **Register in the Zig build** — add a `Grammar` entry to the `grammars` array in `zig/build.zig`. Set `has_scanner: true` if the grammar has a `scanner.c`.
4. **Register in the Zig highlighter** — in `zig/src/highlighter.zig`, add an `extern fn tree_sitter_{lang}()` declaration and an entry in the `languages` array with the grammar function and `@embedFile` for the query.
5. **Register the filetype** (if new) — add extension/filename mappings in `lib/minga/filetype.ex` so the BEAM detects the filetype and sends the correct language name to Zig.

After rebuilding (`zig build` or `mix compile`), the grammar is compiled into the binary and available immediately. No runtime loading needed.

Users can override highlight queries without recompiling by placing `.scm` files at `~/.config/minga/queries/{lang}/highlights.scm`.
