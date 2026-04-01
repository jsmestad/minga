# Minga — Agent & Developer Guide

## Project Overview

Minga is a BEAM-powered modal text editor with native GUI frontends. The editor core runs on the Erlang VM (Elixir), and platform-native frontends handle rendering and input. Read `docs/ARCHITECTURE.md` for the multi-frontend design and its benefits.

## Strategic Direction: GUI-First

Native GUI experiences lead the design. The macOS frontend (Swift/Metal) is the most mature and sets the quality bar. A Linux frontend (GTK4) is planned. The TUI frontend (Zig/libvaxis) continues to ship features, but new work is designed for GUI frontends first. Think Emacs: the GUI is the primary experience, the terminal mode is a capable fallback that benefits from the same core improvements.

When building new features, design for the GUI rendering path first, then ensure the TUI has a reasonable equivalent.

### Frontend-specific guides

Each frontend has its own AGENTS.md with architecture, coding standards, and conventions specific to that platform. **Read the relevant frontend guide before working on frontend code.**

- **macOS (Swift/Metal):** `macos/AGENTS.md` — CoreText rendering pipeline, State+View pattern, Metal shader conventions, protocol sync rules
- **TUI + Parser (Zig/libvaxis):** `zig/AGENTS.md` — two-binary architecture, Surface abstraction, arena-per-frame memory, tree-sitter grammar registration

## Tech Stack

- **Elixir 1.19** / OTP 28 — editor core (buffers, modes, commands, orchestration)
- **Swift 6 / Metal 3.1** — macOS native GUI frontend (primary)
- **GTK4** — Linux native GUI frontend (planned)
- **Zig 0.15** with libvaxis — TUI frontend + tree-sitter parser
- **ExUnit** + **StreamData** — testing
- Pinned versions in `.tool-versions`

## Logs

Runtime logs are written to `~/.local/share/minga/minga.log`. macOS crash reports land in `~/Library/Logs/DiagnosticReports/` as `.ips` files (look for `minga-mac-*.ips`). Check both when investigating crashes.

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
      protocol/gui.ex         # GUI chrome protocol encoder (native frontends only)
      manager.ex              # GenServer managing the frontend Port
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

macos/                        # macOS native GUI frontend (primary)
  project.yml                 # XcodeGen project definition
  Sources/
    MingaApp.swift            # App entry point, SwiftUI wiring
    Protocol/                 # Binary protocol decoder/encoder
    Renderer/                 # Metal cell grid renderer
    Font/                     # CoreText font loading, glyph atlas
    Views/                    # SwiftUI + NSView wrappers
  Tests/                      # Protocol round-trip tests

zig/                          # TUI frontend + tree-sitter parser
  build.zig                   # Zig build configuration
  build.zig.zon               # Zig package manifest (libvaxis dep)
  src/
    main.zig                  # Entry point, event loop
    protocol.zig              # Port protocol encoder/decoder
    renderer.zig              # libvaxis render command handler
    highlighter.zig           # Tree-sitter highlighter (shared by all frontends via parser Port)

test/                         # Mirrors lib/ structure
```

## Git Branching

**`main` is protected.** All changes must go through feature branches and pull requests. Never commit directly to main.

- **Always create a feature branch** before making changes. Use descriptive names: `feat/release-pipeline`, `fix/viewport-scroll`, `refactor/layout-compute`.
- **Never switch branches if another agent session is active on a branch.** Multiple LLM agents may be working in this repo concurrently. If you see uncommitted changes or a branch that isn't yours, leave it alone. Create a new branch from `main` instead.
- **Check your current branch** before starting work: `git branch --show-current`. If you're on `main`, create a branch. If you're on someone else's feature branch, switch to `main` and branch from there.
- **Push your branch and open a PR** when the work is ready. Always open the PR; don't just push and leave it. CI must pass before merging.

### Git Worktrees

All feature branches use git worktrees. This keeps the main checkout clean and lets multiple agent sessions work on different features concurrently without stepping on each other.

**Starting work:**

1. Create the worktree and branch:
   ```bash
   git worktree add ../minga-worktrees/<branch-name> -b <branch-name>
   ```
2. Do all work inside `../minga-worktrees/<branch-name>`. The agent's working directory must be set to the worktree, not the main checkout.
3. The first build in a new worktree needs `mix deps.get` and a full compile. This is a one-time cost.

**After the PR is merged:**

1. Clean up: `git worktree remove ../minga-worktrees/<branch-name>`
2. Prune stale refs: `git worktree prune`
3. Pull main in the primary checkout: `cd <your-main-checkout> && git pull origin main`

## Iterative Fixes (especially rendering)

When a fix improves visible behavior (user confirms it's better), **commit it and stop**. Do not immediately try to "refine" or "optimize" the fix in the same session. The rendering pipeline has timing dependencies between the BEAM, the frontend Port, and the display surface that are impossible to fully reason about without seeing real output. What looks like an obvious improvement in theory (e.g., "skip the stale frame") can make things worse because your mental model of the frame ordering is wrong.

Rules:
1. Make one change. Rebuild. Have the user test.
2. If the user says it's better, commit. If there's a remaining glitch, ask the user to describe it before writing more code.
3. Never stack a second speculative fix on top of an untested first fix.
4. Never revert or replace a working fix with a "cleaner" version without user confirmation that the new version also works.

## Build It Right or Don't Build It

Never scope foundational infrastructure to a "V1" that deliberately skips known requirements. If a data structure needs to handle 10,000 entries in production (e.g., LSP diagnostics), build it with the right algorithm from the start (interval tree, not linear scan). If a system needs incremental updates, don't ship clear-and-reapply and plan to "optimize later." The optimization never happens, and every feature built on top inherits the limitation.

This applies to internal infrastructure like data structures, coordinate mapping systems, rendering pipelines, and protocol layers. It does not apply to user-facing features, where shipping a subset of functionality (e.g., keyboard selection before mouse selection) is a legitimate scoping choice.

The test: if cutting the corner means the next team building on this code has to work around the limitation or refactor the foundation, it's not a valid shortcut. Build the foundation once, correctly.

## Code Organization

Minga's code is organized by **dependency direction** and **state ownership**, not by domain-driven design bounded contexts. The goal is a stable core that doesn't change when we experiment with different UX patterns (traditional editor, Board, future shells). These rules are designed to be mechanically verifiable: you can check them by looking at imports and struct updates without understanding architectural philosophy.

### Rule 1: Dependencies flow one way

Code is organized in three layers. Dependencies flow downward only. A module in Layer 0 never imports from Layer 1 or 2. A module in Layer 1 never imports from Layer 2. If you find yourself adding an upward dependency, you're putting logic in the wrong layer.

**Layer 0 — Pure foundations (no dependencies on other Minga modules):**
`Buffer.Document`, `Editing.Motion`, `Editing.TextObject`, `Editing.Operator`, `Editing.Search`, `Editing.AutoPair`, `Core.IntervalTree`, `Core.Face`, `Core.Decorations`, `Core.Diff`, `Core.Unicode`, `Core.IndentGuide`, `Editing.Text.Readable` (protocol), `Mode.*` (FSM modules)

These are pure functions and data structures. They take values in and return values out. They don't call GenServers, don't subscribe to events, don't log. They're the stable core that everything else builds on.

**Layer 1 — Stateful services (depend on Layer 0 only):**
`Buffer.Server`, `Config.*`, `Events`, `Language.*`, `LSP.*`, `Git.*`, `Project.*`, `Agent.*` (session management, tool execution), `Keymap.*`, `Parser.Manager`, `Frontend.Manager`, `Frontend.Protocol`

These are GenServers, registries, and OTP processes. They manage state and coordinate work. They use Layer 0 data structures and algorithms but don't know anything about how the editor presents itself.

**Layer 2 — Orchestration and presentation (depends on everything):**
`Editor.*`, `Shell.*`, `Input.*`, `Editor.Commands.*`, `Editor.RenderPipeline.*`, `Workspace.State`

This is where editing state, input dispatch, layout, rendering, and chrome live. It consumes everything from Layers 0 and 1. This layer changes the most because it's where UX experiments happen.

**Cross-cutting modules** (used by all layers): `Minga.Events`, `Minga.Log`, `Minga.Telemetry`, `Minga.Clipboard`. These are infrastructure, not domain logic.

**How to check:** look at the `alias`/`import` lines in a module. If a Layer 0 module aliases something from `Minga.Editor.*`, that's a violation. Fix it by moving the logic to the right layer or passing the needed data as a function argument.

### Rule 2: State ownership (one writer per struct)

Each struct has **one module** that's allowed to construct and update it. Other modules may read fields but never do `%{thing | field: value}` on a struct they don't own. This is the single most important rule for preventing spaghetti code.

```elixir
# Good: VimState owns its own transitions
new_editing = Minga.Editor.VimState.transition(state.workspace.editing, :insert, mode_state)

# Bad: random module reaches in and mutates VimState
new_editing = %{state.workspace.editing | mode: :insert, mode_state: mode_state}
```

If you need to change a struct's field from outside its owning module, add a function to the owning module and call that instead. If no suitable function exists, add one. The function name should describe the domain operation, not the field being changed: `VimState.transition(vim, :insert, ms)` not `VimState.set_mode(vim, :insert)`.

**The test:** grep for `%{thing |` and `%Module{thing |` across the codebase. Every instance should be in the struct's owning module. Violations mean someone is scattering mutation logic that should be centralized.

**No struct may have more than ~15 fields.** If a struct is growing beyond that, it's accumulating unrelated concerns. Group related fields into sub-structs with their own modules and mutation functions. `Editor.State` is the biggest offender here and is being decomposed into `Workspace.State`, `Shell.Traditional.State`, and focused sub-structs (`State.Buffers`, `State.Windows`, `State.Search`, etc.).

### Rule 3: Extract, don't branch

When you need different behavior based on a condition, don't add an `if` or `case` at the call site. Extract the varying behavior into a function on the module that owns the condition. The caller should not know *why* the behavior differs.

```elixir
# Bad: scattered conditional in 12 input handlers
if state.editing_model == :cua do
  handle_cua(key, state)
else
  handle_vim(key, state)
end

# Good: one dispatch point, callers don't know about editing models
Minga.Editing.active_model(state).handle_key(key, model_state)
```

The smell: if the same condition appears in 3+ files, it should be a function or behaviour dispatch in one place. Every new `if gui?` or `if vim?` or `if agent_active?` scattered across the codebase is a future maintenance burden.

### Rule 4: Module grouping (directories, not facades)

Directories under `lib/minga/` group related modules. Some have a top-level entry-point module (e.g., `Minga.Buffer` delegates to `Buffer.Server`), others don't (e.g., `core/` is just a collection of pure data structures). Both patterns are fine. The entry-point module is a convenience for callers, not an access-control gate.

The practical rule: **prefer the entry-point module when one exists**, because it gives you a stable API if the internals are reorganized. But reaching into `Buffer.Document` directly from `Editing.Motion` is fine when you need the data structure, not the GenServer. The Layer rules (Rule 1) are what actually prevent bad coupling, not module access.


Minga uses three namespaces that enforce dependency direction: `Minga.*` (Layer 0), `MingaAgent.*` (Layer 1), `MingaEditor.*` (Layer 2). Dependencies flow downward only. A credo check enforces this at compile time. See `docs/ARCHITECTURE.md` for the full rationale.

#### Layer 0: `lib/minga/` (Minga.*)

| Directory | Entry point | What lives here |
|-----------|------------|------------------|
| `buffer/` | `Minga.Buffer` | Document storage, gap buffer, undo/redo, edit deltas |
| `editing/` | `Minga.Editing` | Motions, operators, text objects, search, auto-pair, completion, formatting |
| `core/` | (none) | Pure data structures: IntervalTree, Decorations, Face, Diff, Unicode |
| `mode/` | `Minga.Mode` | Vim modal FSM behaviour + mode implementations |
| `config/` | `Minga.Config` | Options, hooks, advice, per-filetype overrides |
| `keymap/` | `Minga.Keymap` | Key bindings, mode tries, scope management |
| `lsp/` | `Minga.LSP` | Language server client, document sync, workspace edits |
| `command/` | `Minga.Command` | Command struct, registry, provider behaviour |
| `git/` | `Minga.Git` | Git operations, diff, blame, status |
| `language/` | `Minga.Language` | Language definitions, filetype detection, tree-sitter, grammar registry, devicons |
| `parser/` | `Minga.Parser.Manager` | Tree-sitter parser Port management, `Minga.Parser.Protocol` (wire format) |
| `popup/` | `Minga.Popup.Registry` | Popup rules and ETS registry (used by Config DSL, read by Editor) |
| `session/` | `Minga.Session` | Session persistence, swap files, event recording |
| `project/` | `Minga.Project` | Project root, file finding, project search, file tree, test detection |
| `events.ex` | `Minga.Events` | Cross-cutting event bus (Registry-backed pub/sub) |

#### Layer 1: `lib/minga_agent/` (MingaAgent.*)

| Directory | Entry point | What lives here |
|-----------|------------|------------------|
| (root) | `MingaAgent.Runtime` | Public API facade for external clients |
| `session*.ex` | `MingaAgent.SessionManager` | Agent session lifecycle, metadata |
| `tool/` | `MingaAgent.Tool.Registry` | Tool specs, ETS registry, executor with advice integration |
| `tools/` | (none) | Individual tool implementations (read_file, write_file, shell, etc.) |
| `gateway/` | `MingaAgent.Gateway.Server` | WebSocket + JSON-RPC API gateway (Bandit/WebSock) |
| `introspection.ex` | `MingaAgent.Introspection` | Runtime self-description for external clients |
| `providers/` | (none) | LLM provider implementations (native, pi_rpc) |

#### Layer 2: `lib/minga_editor/` (MingaEditor.*)

| Directory | Entry point | What lives here |
|-----------|------------|------------------|
| (root) | `MingaEditor` | Editor GenServer, commands, rendering, layout, viewport, windows |
| `shell/` | `MingaEditor.Shell` | Shell behaviour + implementations (Traditional, Board) |
| `input/` | `MingaEditor.Input` | Input handler behaviour, focus stack, all handler modules |
| `frontend/` | `MingaEditor.Frontend` | Frontend communication, protocol encoding, capabilities |
| `ui/` | `MingaEditor.UI` | Themes, faces, highlighting, picker, prompts, which-key |
| `workspace/` | `MingaEditor.Workspace.State` | Shared editing state across shells |
| `agent/` | `MingaEditor.Agent.Events` | Agent UI state, view renderers, slash commands |

### Shell architecture

The `Minga.Shell` behaviour is the plug-in point for different UX models. Each shell owns its own layout, chrome, input routing, and rendering. The workspace (core editing state) is shared; the shell decides how to present it.

- `Minga.Shell.Traditional` — tab-based editor with file tree, modeline, picker, agent panel
- `Minga.Shell.Board` — agent supervisor card view with zoom-in editing

Shells should be as independent as possible. The ideal: a new shell can be built by implementing the Shell behaviour and using only Layer 0 + Layer 1 modules, without importing anything from another shell's implementation. We're not there yet (both shells currently depend on Editor internals), but that's the direction.

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
- **Structs over bare maps and tuples for data that crosses module boundaries.** Tuples and bare `%{}` maps are fine for small, fixed-shape data inside one module. When a data shape is used across 3+ modules (returned from a behaviour callback and consumed by a renderer, constructed in one GenServer and mutated in another), use a struct. Name the struct after the domain concept it represents (`Agent.ToolCall`, not `Agent.ToolCallMap`). Signals you need a struct: the same `%{key: ..., key: ...}` shape is constructed in multiple files, consumers do `%{tc | status: :error, result: "aborted"}` mutations in scattered places, or adding a field silently breaks pattern matches elsewhere. Put the struct in its own file under the domain it belongs to (`lib/minga/agent/tool_call.ex`).
  - **Co-locate mutations on the struct module.** When a struct has domain transitions (e.g., a tool call completing, erroring, or being aborted), put those methods on the struct itself: `ToolCall.complete(tc, result)`, `ToolCall.abort(tc)`. This replaces scattered `%{tc | status: :error, result: "aborted", is_error: true}` updates with a single call that encodes the business rules. The test: if 3+ files do `%{thing | field: value}` on the same struct, extract a method.
  - **`@enforce_keys` should list genuinely required fields, or be omitted entirely.** Don't add `@enforce_keys []` as documentation; it's noise. If a struct has fields that must always be provided at construction time (e.g., `id`, `name`), enforce those. If every field has a meaningful default, skip `@enforce_keys`.
  - **`| nil` belongs on the field or spec, not the type alias.** Write `@type approval :: ToolApproval.t()` and then `pending_approval: approval() | nil` on the field that can be nil. Baking nullability into the type alias hides it from every consumer.
  - **`@derive JSON.Encoder`** on any struct that gets serialized to disk or over the wire. Without it, `JSON.encode!/1` raises at runtime.
- **No `Process.sleep/1`** — never use `Process.sleep` anywhere in production code. It blocks the calling process, defeats the BEAM's concurrency model, and hides real timing bugs. Use `Process.send_after/3`, GenServer state machines, or `receive` with `after` clauses instead. If you need to defer work until a resource is ready, store the intent in state and act on it when the ready signal arrives (e.g., set a pending field and apply it in the `handle_info` that confirms the resource is up). `Process.sleep` in tests is acceptable only in integration tests that interact with external processes.
- **Handling dead GenServer dependencies** — when one GenServer (e.g., the Editor) holds a PID to another GenServer (e.g., an Agent Session) that might crash or stop independently, use the idiomatic OTP pattern: `Process.monitor` + `:DOWN` handler. Do not build wrapper modules, adapter layers, or blanket try/catch around every call site. The correct approach:
  1. **Monitor the dependency.** Call `Process.monitor(pid)` when you store the PID. Store the monitor ref alongside it so you can `Process.demonitor(ref, [:flush])` cleanly when switching or clearing.
  2. **Handle `:DOWN` in the dependent process.** Add a `handle_info({:DOWN, ref, :process, pid, reason}, state)` clause that clears the stale PID from state. Match on both the stored ref and PID to avoid swallowing unrelated `:DOWN` messages.
  3. **Existing nil-checks become sufficient.** Once the monitor clears the PID, code like `if session == nil do ... end` correctly short-circuits on all subsequent calls.
  4. **Targeted `catch :exit` only on user-facing hot paths.** There's a real (but narrow) race window: the dependency dies while you're mid-`GenServer.call`, before the `:DOWN` message is processed. Add `catch :exit, _` only on the specific functions where this race matters (e.g., "user presses Enter to send prompt"). Do not add catches to every call site; let the monitor handle the common case.
  5. **Never build a "safe client" wrapper module** that mirrors another module's API with nil-handling and exit-catching added. That's just indirection. The monitor is the real fix; the wrapper hides the problem behind a layer that every caller must remember to use.
- `mix compile --warnings-as-errors` must pass clean

### Module-Level Type Aliases

Define `@type` aliases at the top of any module where a type appears in 3+ specs. This turns noisy specs into readable ones:

```elixir
# Before: repeating GenServer.server() and EditorState.t() in 80+ specs
@spec open_file(GenServer.server(), String.t()) :: :ok | {:error, term()}
@spec switch_buffer(GenServer.server(), non_neg_integer()) :: :ok

# After: aliases at module top, specs read like English
@type server :: GenServer.server()
@type editor_state :: EditorState.t()

@spec open_file(server(), String.t()) :: :ok | {:error, term()}
@spec switch_buffer(server(), non_neg_integer()) :: :ok
```

Name the alias after the domain concept (`@type user :: User.t()`, not `@type u :: User.t()`). This is a readability choice, not a correctness choice; both compile identically.

### Module Decomposition

Entry-point modules (like `Minga.Buffer`, `Minga.Editing`) should be mostly `defdelegate`, `@spec`, and `@doc`, with short glue logic where needed. If removing all `defdelegate` lines and all typespecs leaves more than ~100 lines of actual logic, the module is doing too much. Extract to an internal module and delegate.

**GenServer modules specifically** should contain OTP callbacks (`init`, `handle_call`, `handle_cast`, `handle_info`, `terminate`) and route to handler modules for the actual logic. Each `handle_info` or `handle_call` clause should be 1-3 lines that extract data and call a handler function in a dedicated module. The GenServer is the process wrapper; the handler module is where the logic lives.

```elixir
# Good: GenServer clause routes to handler
def handle_info({:buffer_saved, path}, state) do
  {:noreply, SaveHandler.process(state, path)}
end

# Bad: GenServer clause contains 40 lines of business logic
def handle_info({:buffer_saved, path}, state) do
  # ... 40 lines of formatting, git refresh, LSP notify, etc.
  {:noreply, new_state}
end
```

Minga already follows this pattern in places (`Editor.KeyDispatch`, `Editor.CompletionHandling`, `Editor.Startup`). Apply it consistently: when a GenServer module exceeds ~500 lines, look for `handle_info` and `handle_call` clauses with inline logic and extract them to handler modules.

### Protocols vs Behaviours

Use the right abstraction for the dispatch pattern. Getting this wrong creates boilerplate (protocol for one implementation) or loses compile-time guarantees (behaviour where a protocol fits).

- **Protocol** when you have a value and don't know its type at the call site. The caller writes `MyProtocol.do_thing(some_value)` and dispatch happens on the value's struct type. Examples: serialization, text access across different document types, rendering different content kinds.
- **Behaviour** when you know the contract and want to swap the implementation module. The caller writes `impl_module.do_thing(args)` where `impl_module` is chosen at configuration time or stored in state. Examples: git backend (`System` vs `Stub`), rendering backend (`Port.Frontend`), storage adapters.
- **Neither** when there's only one implementation (just call the function directly) or when you're doing simple value validation (pattern match, don't wrap it in a protocol).

The diagnostic: if the call site stores a module atom and calls it dynamically, that's a behaviour. If the call site receives a value and dispatches on its type, that's a protocol. If you find yourself using `function_exported?/3` to check for optional callbacks, you probably want a protocol with a fallback `Any` implementation instead.

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

The `commit-gate` extension blocks every `git commit` until all checks pass. You don't need to remember this; the extension catches it automatically. But you should still run all relevant checks proactively, not just wait for the gate to yell at you. Running checks proactively is faster than getting blocked and re-running the review cycle.

**Before requesting review, do this self-check:**

1. **Run `make lint`** (format + credo + compile + dialyzer). All four steps run even if one fails, so dialyzer is never skipped. Fix any failures.
2. **Run `mix test.llm`**. Fix any failures.
3. **Check every touched `.ex` file:** does every public function have `@spec`? Does the module have `@moduledoc`? Do structs have `@enforce_keys`?
4. **If you touched `.zig` files**, run `mix zig.lint`.
5. **If you touched `.swift` files**, run `mix swift.build` and Swift tests.

```bash
make lint                         # Format + credo + compile + dialyzer (all steps, even on failure)
mix test.llm                      # Tests with LLM-optimized output (excludes :heavy)
mix test.heavy                    # Only :heavy tests (OS process, timeout, multi-turn)
mix test.debug test/minga/foo_test.exs  # Single file, verbose (faster iteration)
mix test --failed                 # Re-run only previously failed tests
mix zig.lint                      # zig fmt --check + zig build test (only if .zig changed)
```

If any check fails, fix it before committing. No exceptions.

**Handling test failures (no escape hatches):**

When a test fails, you have exactly two options:
1. **Fix the code** so the test passes.
2. **Fix the test** if it's genuinely wrong (outdated assertion, testing removed behavior).

You do NOT have the option to:
- Claim the failure is "flaky" and move on. If it's flaky, fix the flakiness.
- Claim "not caused by my changes." If it fails on your branch, it's your problem. Prove it by running the test on `main` if you believe it's pre-existing.
- Re-run and hope it passes. If it failed once, understand why before re-running.
- Skip the test suite because "I only changed one file."

**Before commit: one reviewer, one verdict.** The reviewer subagent is the single gate. It runs CI checks, reviews code quality, and verifies acceptance criteria. One call:

```
subagent({ agent: "reviewer", task: "Review for commit. Ticket: #{N}. Run: git diff main", agentScope: "both", confirmProjectAgents: false })
```

The reviewer runs `make lint` and `mix test.llm` itself and blocks on any failure. It also checks each acceptance criterion against the diff. If it returns BLOCKED, fix the issues and re-run. The reviewer always starts from scratch to avoid confirmation bias on re-review.

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

#### Test Layer Selection

Pick the lightest test layer that covers the behavior. Heavier tests are slower, flakier, and more sensitive to unrelated changes. Use this decision tree:

**1. Pure function?** (Motion, TextObject, Operator, Document operations) → Test the function directly with `Document.new()` + assertion. No GenServer, no Editor, no HeadlessPort.

```elixir
# ✅ Good: pure function test (microseconds, never flakes)
test "word_forward moves to start of next word" do
  doc = Document.new("hello world")
  assert Motion.word_forward(doc, {0, 0}) == {0, 6}
end

# ❌ Bad: booting 3 GenServers to test a pure function
test "w moves cursor to next word" do
  ctx = start_editor("hello world")
  send_keys_sync(ctx, "w")
  state = editor_state(ctx)
  assert state.workspace.buffers.active.cursor == {0, 6}
end
```

**2. Single GenServer operation?** (Buffer.Server insert, delete, undo) → Start the GenServer, call the function, assert. No Editor or HeadlessPort needed.

```elixir
# ✅ Good: test the GenServer directly
test "insert_text adds text at cursor" do
  {:ok, buf} = start_supervised({BufferServer, content: "hello"})
  BufferServer.insert_text(buf, " world")
  assert BufferServer.content(buf) == "hello world"
end
```

**3. Input dispatch wiring?** (key X reaches command Y) → Use EditorCase with `send_key_sync` + `editor_state()`. Screen assertions are unnecessary here since you're verifying wiring, not rendering.

```elixir
# ✅ Good: verifying wiring through EditorCase
test "dd deletes current line" do
  ctx = start_editor("line one\nline two\nline three")
  send_keys_sync(ctx, "dd")
  assert buffer_content(ctx) == "line two\nline three"
end
```

**4. Rendered output?** (screen shows correct text after an action) → Use EditorCase with `send_key` + `assert_row_contains` or snapshot. This is the heaviest layer; use it only when verifying what the user actually sees on screen.

```elixir
# ✅ Good: verifying rendered output
test "status line shows mode after ESC" do
  ctx = start_editor("hello")
  send_keys_sync(ctx, "i")
  send_keys_sync(ctx, "<Esc>")
  assert_row_contains(ctx, last_row(ctx), "NORMAL")
end
```

**Reference patterns:** `test/minga/editing/motion/word_test.exs` (pure function tests), `test/minga/editing/text_object_test.exs` (pure text objects), `test/minga/mode/operator_pending_test.exs` (FSM dispatch without GenServer). These are the gold standard.

#### `:sys.get_state` Usage in Tests

EditorCase tests must not assert on internal state fields via `:sys.get_state` unless the test is specifically verifying state machine transitions. Use EditorCase query helpers instead:

- `buffer_content(ctx)` instead of `:sys.get_state(editor).workspace.buffers.active.document |> Document.content()`
- `buffer_cursor(ctx)` instead of `:sys.get_state(editor).workspace.buffers.active.cursor`
- `editor_mode(ctx)` instead of `:sys.get_state(editor).workspace.editing.mode`
- `screen_row(ctx, n)` / `assert_row_contains(ctx, n, text)` for rendered output

`:sys.get_state/1` remains valid as a **synchronization barrier** (ensuring messages are processed before asserting). Just don't pattern-match on the returned state fields.

**Running tests (prefer these aliases over raw `mix test`):**

```bash
mix test.llm                              # Default for LLM agents. Module-level summary, stops at 5 failures.
mix test.llm test/minga/buffer/           # Scoped to a directory
mix test.debug test/minga/foo_test.exs    # Verbose per-test names (--trace), stops at 3 failures. Use when iterating on a specific file.
mix test.quick                            # Only runs tests affected by changed modules (--stale), stops at 5 failures.
mix test                                  # Full suite, default ExUnit output. Use for CI or final verification.
mix test --failed                         # Re-run only tests that failed last time.
```

`mix test.llm` uses a custom formatter (`Minga.Test.LLMFormatter` in `test/support/llm_formatter.ex`) that outputs one line per module with the file path, and groups all failure locations at the end with copy-pasteable `mix test file:line` commands. No dots, no ANSI colors.

**Process synchronization in tests:**

- **Use `start_supervised!/1`** to start processes in tests. It guarantees cleanup between tests.
- **Avoid `Process.sleep/1` in tests.** Use `:sys.get_state/1` as a synchronization barrier (ensures the process has handled prior messages), or `Process.monitor/1` + `assert_receive {:DOWN, ...}` to wait for process exit. Sleep is acceptable only in integration tests that interact with external OS processes.
- **Avoid `Process.alive?/1` in assertions.** It's a race condition. Monitor the process instead.
- **For timer-triggered callbacks** (e.g., `Process.send_after(self(), :timeout, 200)`), send the timer message directly in tests (`send(pid, :timeout)`) followed by `:sys.get_state/1`, instead of sleeping for the timer duration.
- **For async events** the test needs to wait for, use `Minga.Events.subscribe(topic)` in setup and `assert_receive {:minga_event, topic, payload}` after the action. Pin unique fields (e.g., `^dir`, `^buf`) to avoid matching events from concurrent tests.

**Test concurrency (`async: true` by default):**

All new test files must use `async: true` unless they have a documented reason for serialization. Every `async: false` must have a comment on the line above explaining the specific global resource that forces serialization.

Legitimate reasons for `async: false`:
- Mutates global state that cannot be parameterized (Application env, Logger config, global telemetry handlers, `persistent_term`)
- Spawns real OS processes (`System.cmd`, `Port.open`) that hit the BEAM's `erl_child_setup` EPIPE race
- Uses `capture_io(:stderr)` which replaces the global `:standard_error` registered process

These are NOT legitimate reasons for `async: false`:
- **HeadlessPort.** `Minga.Test.HeadlessPort` is a pure Elixir GenServer. It does not spawn OS processes, does not touch `:standard_error`, and is safe for concurrent use. Tests using `EditorCase` should be `async: true`.
- **"Tests are flaky when async."** That means the test has a synchronization bug. Fix the synchronization, don't serialize.
- **Global ETS table.** Parameterize the table (see below) instead of forcing serialization.

**ETS singletons must accept a table parameter:**

When a module uses a module-level `@table __MODULE__` ETS table, expose the table name as a parameter on all public functions (with `@table` as the default). Follow the pattern in `Minga.Config.Advice` and `Minga.Popup.Registry`: production callers pass no argument (uses the default), tests pass a private table name created via `start_supervised!` with a unique name.

**async: false submodules must live in separate files:**

Never embed an `async: false` module inside an `async: true` test file. ExUnit applies `async` at the module level. An `async: false` submodule drags the entire file into the sync queue. Extract to a separate file and keep `async: false` on the extracted module.

**Assert on content, not position:**

When testing UI state that can shift under concurrency (file tree entries, picker results, completion items), assert on presence or content, not index position. `FileTree.selected_entry(tree)` rescans the filesystem and can return a different entry if concurrent tests create/delete files. Use `assert Enum.any?(entries, fn e -> e.name == "target.txt" end)` instead of `assert Enum.at(entries, 3).name == "target.txt"`.

**Design for event-based synchronization:**

When production code performs an async operation that tests need to wait for, add a broadcast event via `Minga.Events` if one doesn't exist. Events like `:project_rebuilt` and `:command_done` have genuine production value (other subsystems react to them) and give tests a clean synchronization point. Don't force tests to poll with `Process.sleep` when an event would be the right production design anyway.

**Debugging test failures:**

```bash
mix test.debug test/minga/foo_test.exs    # One file, verbose names, stops at 3 failures
mix test.llm test/minga/foo_test.exs:42   # One test (line number)
mix test --failed                         # Re-run only failures from last run
mix test --seed 12345                     # Reproduce a specific run order
```

**DI stubs for OS processes:**

Tests must not spawn OS processes during concurrent (async) execution. The BEAM's `erl_child_setup` has a race condition that causes EPIPE errors under concurrency. Modules that shell out (`Minga.Git`, `Minga.FileFind`, `Minga.ProjectSearch`) use a backend behaviour pattern so tests can inject stubs:

- `Minga.Git` → `Minga.Git.Backend` behaviour, `Minga.Git.Stub` in tests (configured in `config/test.exs`)
- `Git.Stub` is ETS-backed and configurable per-test via `Git.Stub.set_root/2`, `set_status/2`, etc.
- Tests that genuinely need OS processes (e.g., `Extension.GitIntegrationTest`) must be `async: false` with `@moduletag timeout:` to prevent hangs

### Zig

See `zig/AGENTS.md` for the full Zig developer guide. Quick reference:

- `zig fmt` for all formatting, `mix zig.lint` must pass
- Doc comments (`///`) on all public functions
- Explicit error handling, no `catch unreachable` outside tests
- `std.log` for debug output, never write to stdout (that's the Port channel)

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

**Two-tier logging model:** These are two distinct tiers of the same pipeline, not competing mechanisms.

- **`log_message(state, text)` / `Minga.Editor.log_to_messages(text)`** is the unconditional tier. Use it for user-visible lifecycle events that should always appear in `*Messages*` regardless of log level settings: file open/save/close, config reload, format-on-save, editor startup. Inside the Editor GenServer, call `log_message(state, text)`. Outside, call `Minga.Editor.log_to_messages(text)` (async cast to avoid deadlocks).
- **`Minga.Log.{level}(:subsystem, text)`** is the filterable tier. Use it for diagnostic output gated by per-subsystem log levels: LSP traces, render timing, debug context.

Decision rule: if the user would be confused by its absence, use `log_to_messages`. If it's noise unless you're debugging, use `Minga.Log`.

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

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore` Scopes: `buffer`, `editing`, `ui`, `port`, `editor`, `mode`, `keymap`, `config`, `lsp`, `command`, `git`, `agent`, `input`, `language`, `session`, `project`, `zig`, `macos`, `gtk`, `cli`

Examples:
- `feat(buffer): implement gap buffer with cursor movement`
- `feat(macos): add native hover tooltips for LSP content`
- `feat(zig): scaffold libvaxis renderer with port protocol`
- `test(buffer): add property-based tests for insert/delete`

## Port Protocol

BEAM ↔ frontend communication uses length-prefixed binary messages over stdin/stdout of the frontend process. All frontends (Swift, GTK4, Zig TUI) speak the same protocol. The TUI's Zig process uses `/dev/tty` for terminal I/O (not stdout).

See `docs/PROTOCOL.md` for the full message specification and `docs/GUI_PROTOCOL.md` for the additional GUI chrome opcodes sent only to native GUI frontends.

## Rendering Architecture

The rendering pipeline supports multiple frontends through a shared display list IR and a binary port protocol. The BEAM owns all rendering decisions; frontends are "dumb" renderers.

Key design decisions:
- **Display list IR:** The BEAM side owns a display list of styled text runs (not a cell grid) that sits between editor state and protocol encoding. All frontends consume this shared IR. See `docs/ARCHITECTURE.md` § "Display List (Rendering IR)" for the type definitions.
- **Styled text runs over cell grids:** GUIs don't think in terminal cells. The IR uses `{col, text, style}` tuples organized by line within positioned rectangles. The TUI quantizes runs to cells; a GUI renders runs with its font engine.
- **GUI chrome protocol:** Native GUI frontends receive structured data opcodes (0x70-0x78) for chrome elements like tab bars, file trees, status bars, and popups. These are rendered with platform-native widgets (SwiftUI, GTK4), not painted as cells. See `docs/GUI_PROTOCOL.md`.
- **Per-window render state:** Each `Window` carries cached draw commands and a dirty-line set for incremental rendering.
- **Pipeline stages:** Seven named stages (Invalidation, Layout, Scroll, Content, Chrome, Compose, Emit) with per-stage timing via telemetry.

## Keymap Architecture

Minga follows the Neovim/which-key model: flat, explicit, debuggable. This is a deliberate choice over Emacs's deep keymap hierarchy. The guiding principle is transparency: when you press a key, you should be able to look at one scope module and know exactly what will happen. No invisible stacks of keymaps silently shadowing each other.

### Three rules

**1. The keymap is the single authority for "should this command run here."** If a key resolves to a command through the scope trie, the command runs. Period. Commands never contain internal guards that re-check whether the context is appropriate (no `no_agent_ui?` patterns). If a command shouldn't run in a context, don't bind it in that context's scope. The dispatch layer is the gate; commands trust their caller.

**2. Scopes are flat, explicit declarations.** Each scope module (`Keymap.Scope.Agent`, `Keymap.Scope.Editor`, etc.) declares its own trie. No automatic composition, no implicit inheritance, no minor-mode-style stacking. Shared bindings (SPC leader sequences, Ctrl+S) use bulk registration helpers that merge named binding groups into a scope's trie at compile time. A scope declares which groups it includes; the helper merges them. Scope-specific bindings override group bindings on conflict. See #1278 for the bulk registration design.

**3. Derived scope, not managed scope.** The active scope should follow from what's on screen (window content type, focused panel), not from a field that activation code manually sets and command code manually checks. When the scope is derived, you can't forget to set it and you can't forget to check it. (This is the target architecture. Today `workspace.keymap_scope` is still a manually managed field. Move toward derived scope when touching this code.)

### Why flat over composed

Emacs's keymap hierarchy is powerful but opaque. With 15 minor mode keymaps stacked, "why doesn't my keybinding work?" requires mentally simulating the entire stack. Neovim's ecosystem moved away from this toward explicit which-key registration because debuggability matters more than automatic composition. Minga makes the same bet: a slightly less flexible system that's transparent beats a powerful system that's invisible.

The tradeoff: scopes can't automatically inherit bindings from a parent scope. If the agent scope needs the same SPC leader keys as the editor scope, those bindings come in through a shared group, not through implicit fallback. The bulk registration helper (#1278) makes this low-cost. The payoff: you can read one scope module and know exactly what keys do in that context. No surprises from implicit composition.

### What this means in practice

- **Adding a new keybinding:** Add it to the scope trie where it should be active. If it should work in multiple scopes, add it to a shared binding group.
- **Adding a new command:** Register it in the command provider. Bind it in the appropriate scope trie. Don't add context guards inside the command function.
- **Adding a new scope:** Create a new `Keymap.Scope.*` module implementing the `Keymap.Scope` behaviour. Declare its tries. Include shared groups for common bindings. Register it in `Scope.@scope_modules`.
- **Debugging "key does nothing":** Look at the active scope module's trie for that vim state. If the key isn't there, it's not bound. No need to trace through handler stacks or check command guards.

## Mouse Support (first-class citizen)

Mouse support is not optional or secondary to keyboard input. Minga ships multiple frontends (macOS GUI via Swift/Metal, TUI via Zig/libvaxis, Linux GUI via GTK4 planned), and all must handle mouse interactions properly. The bar is **Doom Emacs**: if Doom supports a mouse interaction, Minga should too.

See [#217](https://github.com/jsmestad/minga/issues/217) for the full tracker.

### Architecture

Mouse events flow through the same protocol as keyboard events. All frontends encode mouse events as `mouse_event` messages (opcode `0x04`) with row, col, button, modifiers, event type, and click count. The BEAM side decodes them in `Minga.Port.Protocol` and dispatches them to `Minga.Editor.Mouse`.

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

- **`docs/ARCHITECTURE.md`** — Update when adding new process types, protocol opcodes, or changing supervision structure.
- **`docs/PERFORMANCE.md`** — Mark optimizations as completed when done.

### Documentation voice and style

All files in `docs/` follow the project's writing style (load the `writing` skill for the full guide). Before writing or rewriting a doc, read at least two existing docs (e.g., `EXTENSIBILITY.md`, `FOR-EMACS-USERS.md`, `CONFIGURATION.md`) to absorb the voice. Key rules:

- **Why before how.** Lead each section with the problem it solves, not the API signature. The reader should understand why they'd want this before they see the code.
- **Teach, don't list.** Write like an upperclassman showing a freshman around, not a generated API dump. Use progressive disclosure: simple case first, then layers of complexity.
- **Concrete examples that tell a story.** Every API section needs a copy-pasteable example that solves a real problem (org-mode TODO cycling, not `do_thing(x)`). Show the extension author's actual workflow, not abstract signatures.
- **Cross-reference related docs.** The docs form a connected web. For example, EXTENSIBILITY.md explains the conceptual foundation, CONFIGURATION.md covers user-facing config, and FOR-EMACS-USERS.md draws the Emacs comparison. Don't repeat what's covered elsewhere; link to it.
- **Short paragraphs, plain language, no em-dashes.** Same rules as everywhere else in the project.

If a doc reads like a dry API reference with no narrative, it needs a rewrite. The bar is: would someone switching from Emacs or Neovim feel welcomed and oriented by this page?

## Adding New Features

### New feature in an existing module group
1. Implement the logic in a module under the appropriate `lib/minga/{group}/` directory
2. If the group has an entry-point module, add a `defdelegate` or short wrapper there
3. Verify the new module sits in the correct layer (Rule 1): pure logic in Layer 0, stateful services in Layer 1, presentation in Layer 2
4. Verify struct mutations follow Rule 2: updates go through the owning module

### Dual-surface rule for status/chrome features
Any new modeline data (diagnostic counts, indent info, selection size, etc.) must appear in **both** the cell-painted TUI modeline (`Chrome.TUI`) and the GUI status bar (`ProtocolGUI.encode_gui_status_bar/1`). The GUI status bar opcode (0x76) uses structured data with explicit fields, so adding new data means extending the wire format in `docs/PROTOCOL.md` and updating `gui_protocol_test.exs`. Design the GUI status bar fields first, then map them into TUI modeline cells. Forgetting to update one surface is a common mistake.

### New command
1. Add the command to the appropriate `Commands.*` sub-module's `__commands__/0` (implements `Minga.Command.Provider` behaviour). Include name, description, `requires_buffer` flag, and execute function. If no existing sub-module fits, create a new one and add it to the `@command_modules` list in `Minga.Command.Registry`.
2. Add keybinding in `Minga.Keymap.Defaults`
3. Test the command function and the keybinding lookup

### New motion
1. Add the implementation in the appropriate `Minga.Editing.Motion.*` sub-module (e.g., `Motion.Word`, `Motion.Line`)
2. Add a `defdelegate` in `Minga.Editing.Motion` (entry point for motions)
3. Add a `defdelegate` in `Minga.Editing` (entry point for the editing group) so callers can use `Minga.Editing.my_motion/2`
4. Register in `Minga.Mode.Normal` and `Minga.Mode.OperatorPending`
5. Test against known buffer content

### New text object
1. Add the implementation in `Minga.Editing.TextObject` with `@spec`
2. Add a `defdelegate` in `Minga.Editing` (entry point) so callers can use `Minga.Editing.my_text_object/2`
3. Register in `Minga.Mode.OperatorPending`
4. Test with edge cases (cursor outside delimiters, nested, empty)

### New or modified agent tool
Agent tools live in `lib/minga/agent/tools/`. When adding or modifying a tool that reads or writes file content:

1. **Prefer `Minga.Buffer` over filesystem I/O.** If a buffer is open for the file, route through `Minga.Buffer`. Use `Minga.Buffer.content/1` instead of `File.read/1`, and `Minga.Buffer.apply_edit/6` instead of `File.write/2`. This gives you undo integration, tree-sitter sync, instant visibility, and no file watcher noise. Fall back to filesystem I/O only when no buffer exists for the file. See [BUFFER-AWARE-AGENTS.md](docs/BUFFER-AWARE-AGENTS.md) for the full rationale.
2. **Batch edits into a single call** rather than making N separate calls. One call = one undo entry, one version bump.
3. **Test the tool function** in `test/minga/agent/tools/`.

> **Note:** Buffer routing is being implemented in phases. Today, tools still use `File.read/write` directly. When wiring a tool to use buffers, follow the pattern in `BUFFER-AWARE-AGENTS.md` Phase 1.

### New render command (requires BEAM + frontend changes)
1. Add opcode constant and encoder in `Minga.Port.Protocol` (BEAM side, canonical source of truth)
2. **macOS GUI:** Add decoder in `macos/Sources/Protocol/ProtocolDecoder.swift`, constant in `ProtocolConstants.swift`, handler in `CommandDispatcher.swift`
3. **TUI:** Add decoder and handler in `zig/src/protocol.zig` + `zig/src/renderer.zig`
4. **Linux GUI:** (when it exists) Add decoder and handler in the GTK4 frontend
5. Test encode/decode round-trip on all sides. GUI chrome opcodes (0x70-0x78) only need GUI frontend support; the TUI ignores them.

### New tree-sitter grammar

See `zig/AGENTS.md` § "Adding a New Tree-Sitter Grammar" for the full 5-step process (vendor grammar, add query, register in build.zig, register in highlighter.zig, register filetype in Elixir).
