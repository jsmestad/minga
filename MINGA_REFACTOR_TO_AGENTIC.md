# Refactoring Minga to Agentic-First

An incremental transformation plan. Every phase leaves the application working, tests passing, and Burrito/macOS releases intact. No multi-week branches. No rewrites. Each phase is a PR.

This document assumes you've read `MINGA_REWRITE_FOR_AGENTS.md` for the target vision. This document is how to get there from where the code is today.

---

## Table of Contents

1. [Current State Assessment](#1-current-state-assessment)
2. [Refactoring Principles](#2-refactoring-principles)
3. [Phase 1: Sever the Upward Dependencies](#3-phase-1-sever-the-upward-dependencies)
4. [Phase 2: Tool Registry and Executor](#4-phase-2-tool-registry-and-executor)
5. [Phase 3: Buffer Registry with Refcounts](#5-phase-3-buffer-registry-with-refcounts)
6. [Phase 4: Promote Agent.Supervisor to Peer](#6-phase-4-promote-agentsupervisor-to-peer)
7. [Phase 5: Extract Editor State](#7-phase-5-extract-editor-state)
8. [Phase 6: Agent Runtime Facade](#8-phase-6-agent-runtime-facade)
9. [Phase 7: API Gateway](#9-phase-7-api-gateway)
10. [Phase 8: Self-Description and Runtime Modification](#10-phase-8-self-description-and-runtime-modification)
11. [Phase 9: Buffer Forking](#11-phase-9-buffer-forking)
12. [Phase 10: Boundary Enforcement](#12-phase-10-boundary-enforcement)
13. [Migration Checklist Per Phase](#13-migration-checklist-per-phase)
14. [What NOT to Touch](#14-what-not-to-touch)
15. [Risk Register](#15-risk-register)

---

## 1. Current State Assessment

### What exists (125K lines of Elixir)

The codebase is a working text editor with agent support. The architecture is sound at the process level (supervision tree, process-per-buffer, event bus) but coupled at the module level (everything flows through `Editor.ex`).

### Actual upward dependency count

These are modules that should be Layer 0 (core) but reference Layer 2 (editor). Each one is a concrete coupling point to sever.

| Module | References to `Minga.Editor` | What it does |
|---|---|---|
| `Buffer.Server` | 1 | `Process.whereis(Minga.Editor)` to send face override notifications |
| `Config.Advice` | 1 | Docstring example references `Editor.State.set_status` |
| `LSP.Client` | 4 | Calls `Editor.log_to_warnings/1` for error logging |
| `Git.Tracker` | 1 | Calls `Editor.log_to_messages/1` for status logging |
| `Agent.*` | 37 | `Agent.Events` (16), `Agent.SlashCommand` (10), `Agent.UIState` (3), `Agent.ViewContext` (3), `Agent.Session` (1), misc (4) |

**Total: 44 upward references.** That's remarkably few for a 125K-line codebase. Most of the "damage" is in two files: `Agent.Events` (408 lines, deeply coupled to EditorState) and `Agent.SlashCommand` (transforms EditorState directly).

### What's already in good shape

- **Buffer.Server**: only 1 upward reference, already has `apply_text_edits/2`, `find_and_replace/3`, edit deltas, source tagging. Almost ready to be a standalone core module.
- **Events**: zero upward references. Clean pub/sub with typed payloads. Already Layer 0.
- **Config.Options, Config.Hooks, Config.Advice**: zero or 1 upward references (the 1 is a docstring). Already Layer 0.
- **Diagnostics**: zero upward references. Already Layer 0.
- **Agent.Tools.***: individual tool implementations reference Buffer, Git, LSP, Diagnostics (all correct Layer 0 deps). No Editor references. Already Layer 1.
- **Agent.Provider behaviour, Agent.Session**: Session has 1 reference to `Editor.log_to_messages`. Provider has zero.
- **Agent.ViewContext**: already exists as a decoupling struct between Agent views and EditorState. It's the right pattern, just needs to be pushed further.

### The two hard coupling points

1. **`Agent.Events`** (408 lines): Takes `EditorState.t()`, returns `{EditorState.t(), [effect()]}`. Handles agent status changes, streaming deltas, tool calls, errors. It directly mutates editor presentation state (agent spinners, tab labels, auto-scroll). This module is doing two things: updating agent domain state and updating editor presentation state. Those need to be split.

2. **`Agent.SlashCommand`** (694 lines): Takes EditorState, calls `Editor.State.set_status/2`, references `Editor.PickerUI`, delegates to `Editor.Commands.Agent`. Slash commands are a UI feature (editor presentation) that's been placed in the agent directory.

---

## 2. Refactoring Principles

**Every PR must pass `make lint` and `mix test.llm`.** No exceptions. If a refactoring breaks tests, fix them in the same PR.

**Move, then rename, then restructure.** When relocating a module, first move the file and update aliases everywhere (mechanical, low risk). Then rename the module in a separate commit (also mechanical). Then restructure the internals (requires thought). Never do all three at once.

**Use `defdelegate` bridges during migration.** When a module moves from `Minga.Foo` to `Minga.Core.Foo`, leave a `defdelegate` at the old path so existing callers keep working. Remove the delegates in a cleanup pass after all callers are updated.

**No namespace changes on the first pass.** Phases 1-6 keep the existing `Minga.*` namespace. The directory restructuring (adding `core/`, reorganizing `agent/`) happens in Phase 10 after all the behavioral changes are done and tested. Namespace changes are high-churn, low-value refactoring that shouldn't be mixed with behavioral changes.

**One concern per PR.** "Sever Buffer.Server's Editor dependency" is one PR. "Sever LSP.Client's Editor dependency" is another. Don't batch unrelated coupling fixes even if they're small.

---

## 3. Phase 1: Sever the Upward Dependencies

**Goal:** Make Buffer, Events, Config, LSP, Git, and Diagnostics independent of the Editor. After this phase, these modules can function without an Editor process running.

**Estimated effort:** 1-2 weeks, 6-8 small PRs.

### PR 1.1: Replace `Editor.log_to_messages` with Events

The LSP client and Git tracker call `Editor.log_to_messages/1` and `Editor.log_to_warnings/1` to write to the `*Messages*` buffer. This creates a hard dependency on the Editor process.

**Fix:** Use the existing event bus. Broadcast a `:log_message` event; let the Editor (or any subscriber) handle it.

```elixir
# Add to Minga.Events:

defmodule LogMessageEvent do
  @moduledoc "Payload for `:log_message` events."
  @enforce_keys [:text, :level]
  defstruct [:text, :level]
  @type t :: %__MODULE__{text: String.t(), level: :info | :warning | :error}
end

# Add :log_message to the topic/payload type unions
```

**In `LSP.Client`** (4 references):
```elixir
# Before:
Minga.Editor.log_to_warnings(msg)

# After:
Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{
  text: msg,
  level: :warning
})
```

**In `Git.Tracker`** (1 reference):
```elixir
# Before:
Minga.Editor.log_to_messages("Git: tracking #{rel_path}")

# After:
Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{
  text: "Git: tracking #{rel_path}",
  level: :info
})
```

**In `Agent.Session`** (1 reference):
```elixir
# Same pattern.
```

**In the Editor** (subscriber side):
```elixir
# In Editor.init or Startup:
Minga.Events.subscribe(:log_message)

# In Editor.handle_info:
def handle_info({:minga_event, :log_message, %LogMessageEvent{text: text, level: level}}, state) do
  state = case level do
    :warning -> MessageLog.log_warning(state, text)
    _ -> MessageLog.log_message(state, text)
  end
  {:noreply, state}
end
```

**Result:** LSP.Client, Git.Tracker, and Agent.Session have zero Editor references. The Editor subscribes to `:log_message` events. If no Editor is running (headless mode), the events are simply undelivered, which is correct.

**Files changed:** `lib/minga/events.ex`, `lib/minga/lsp/client.ex`, `lib/minga/git/tracker.ex`, `lib/minga/agent/session.ex`, `lib/minga/editor.ex` (add subscriber).

### PR 1.2: Replace Buffer.Server's Editor notification with Events

`Buffer.Server` line 1903 calls `Process.whereis(Minga.Editor)` to send face override changes. This is the only upward reference in the entire buffer module.

**Fix:** Broadcast a `:face_overrides_changed` event.

```elixir
# In Buffer.Server:
# Before:
if editor = Process.whereis(Minga.Editor) do
  send(editor, {:face_overrides_changed, self(), overrides})
end

# After:
Minga.Events.broadcast(:buffer_changed, %Minga.Events.BufferChangedEvent{
  buffer: self(),
  source: Minga.Buffer.EditSource.unknown()
})
# Or add a new :face_overrides_changed topic if the Editor needs to
# distinguish this from content changes.
```

**Files changed:** `lib/minga/buffer/server.ex`, `lib/minga/editor.ex` (update handler to subscribe).

### PR 1.3: Fix Config.Advice docstring

The one "reference" in Config.Advice is a docstring example that mentions `Editor.State.set_status`. Replace with a generic example that doesn't reference any specific module.

**Files changed:** `lib/minga/config/advice.ex` (docstring only).

### PR 1.4: Split Agent.Events into domain and presentation

This is the biggest PR in Phase 1. `Agent.Events` does two things:

1. **Domain state updates:** Setting agent status, tracking tool calls, managing conversation state. These are agent concerns.
2. **Presentation state updates:** Spinner timers, tab labels, auto-scroll, status bar text. These are editor concerns.

**Split into two modules:**

- `Minga.Agent.EventHandler` (new): Takes agent-domain inputs, returns agent-domain outputs. No EditorState. No AgentAccess. No tab bar mutations.
- `Minga.Agent.Events` (existing, narrowed): Stays in the editor layer. Takes EditorState, calls AgentEventHandler for domain updates, then applies presentation effects.

```elixir
# New module: lib/minga/agent/event_handler.ex
defmodule Minga.Agent.EventHandler do
  @moduledoc """
  Handles agent events at the domain level.

  Takes agent state and an event, returns updated agent state and
  a list of domain effects. No EditorState, no presentation concerns.
  """

  alias Minga.Agent.UIState

  @type domain_effect ::
    :render
    | {:log_message, String.t()}
    | {:log_warning, String.t()}
    | :sync_agent_buffer

  @spec handle(UIState.t(), term()) :: {UIState.t(), [domain_effect()]}

  def handle(ui_state, {:status_changed, status}) do
    # Update agent status, spinner state, etc.
    # Return updated ui_state and effects
  end

  def handle(ui_state, {:delta, delta}) do
    # Append streaming text
  end

  # ... etc for each event type
end
```

```elixir
# Existing Agent.Events becomes a thin wrapper:
defmodule Minga.Agent.Events do
  alias Minga.Agent.EventHandler
  alias Minga.Editor.State, as: EditorState

  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [effect()]}
  def handle(state, event) do
    # Extract agent UI state
    ui_state = state.workspace.agent_ui

    # Delegate domain logic
    {new_ui_state, domain_effects} = EventHandler.handle(ui_state, event)

    # Apply domain state back
    state = put_in(state.workspace.agent_ui, new_ui_state)

    # Apply presentation effects (tab labels, spinner, etc.)
    {state, presentation_effects} = apply_presentation(state, event)

    {state, domain_effects ++ presentation_effects}
  end
end
```

**Why this matters:** `Agent.EventHandler` has zero Editor dependencies. It can be called from headless mode, from a web dashboard, from any client. The Editor-coupled `Agent.Events` shrinks to a thin adapter that maps domain outputs to editor presentation.

**Files changed:** New `lib/minga/agent/event_handler.ex`, modified `lib/minga/agent/events.ex`, tests.

### PR 1.5: Move Agent.SlashCommand to the editor layer

`Agent.SlashCommand` references `Editor.State.set_status`, `Editor.PickerUI`, and `Editor.Commands.Agent`. It's presentation logic in the agent directory.

**Move it:** `lib/minga/agent/slash_command.ex` → `lib/minga/editor/commands/agent_slash.ex` (or `lib/minga/input/agent_slash.ex` depending on how it's dispatched).

Leave a `defdelegate` at the old path for any callers during migration.

**Files changed:** Move file, update aliases in callers.

### PR 1.6: Move Agent.ViewContext, Agent.View.* to editor layer

These modules exist solely to render agent state in the editor UI. They reference EditorState, themes, capabilities. They belong in the editor layer.

**Move:**
- `lib/minga/agent/view_context.ex` → `lib/minga/editor/agent/view_context.ex`
- `lib/minga/agent/view/` → `lib/minga/editor/agent/view/`
- `lib/minga/agent/ui_state/` → keep (UIState is domain state, the view modules reference it)

**Files changed:** Move files, update aliases.

### Phase 1 Verification

After all PRs in Phase 1:

```bash
# Zero upward references from core modules to Editor:
grep -rn "Minga\.Editor" lib/minga/buffer/ lib/minga/events.ex lib/minga/config/ \
  lib/minga/lsp/ lib/minga/git/ lib/minga/diagnostics.ex --include="*.ex" | wc -l
# Expected: 0

# Agent domain modules have zero Editor refs:
grep -rn "Minga\.Editor" lib/minga/agent/session.ex lib/minga/agent/provider.ex \
  lib/minga/agent/providers/ lib/minga/agent/tools/ lib/minga/agent/event_handler.ex \
  --include="*.ex" | wc -l
# Expected: 0

make lint    # passes
mix test.llm # passes
```

---

## 4. Phase 2: Tool Registry and Executor

**Goal:** Create a first-class tool system alongside the existing command system. Don't replace commands yet; add tools as a parallel path that agents and the future API gateway will use.

**Estimated effort:** 1 week, 3-4 PRs.

### PR 2.1: Create Tool.Spec struct

The existing tools use `ReqLLM.Tool` structs. Create a Minga-native spec that wraps the same information but adds metadata the runtime needs.

```elixir
# lib/minga/agent/tool/spec.ex
defmodule Minga.Agent.Tool.Spec do
  @enforce_keys [:name, :description, :parameter_schema, :callback]
  defstruct [
    :name,
    :description,
    :parameter_schema,
    :callback,
    destructive: false,
    category: :general,
    requires_project: false
  ]

  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    parameter_schema: map(),
    callback: (map() -> {:ok, term()} | {:error, term()}),
    destructive: boolean(),
    category: :buffer | :file | :git | :lsp | :shell | :runtime | :general,
    requires_project: boolean()
  }

  @doc "Converts to a ReqLLM.Tool for the provider."
  @spec to_req_llm(t()) :: ReqLLM.Tool.t()
  def to_req_llm(%__MODULE__{} = spec) do
    ReqLLM.Tool.new!(
      name: spec.name,
      description: spec.description,
      parameter_schema: spec.parameter_schema,
      callback: spec.callback
    )
  end
end
```

**Files changed:** New file only. Nothing existing changes.

### PR 2.2: Create Tool.Registry (ETS-backed)

```elixir
# lib/minga/agent/tool/registry.ex
defmodule Minga.Agent.Tool.Registry do
  @moduledoc """
  ETS-backed registry for tool specs. read_concurrency: true.
  Replaces Tools.all/1 as the canonical source of available tools.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  @spec register(Tool.Spec.t()) :: :ok
  @spec lookup(String.t()) :: {:ok, Tool.Spec.t()} | :error
  @spec all() :: [Tool.Spec.t()]
  @spec all_as_req_llm() :: [ReqLLM.Tool.t()]
  @spec unregister(String.t()) :: :ok
end
```

At startup, the registry calls `Minga.Agent.Tools.all/1` to get the existing tool list, converts each `ReqLLM.Tool` to a `Tool.Spec`, and inserts into ETS.

**Files changed:** New file. Add `Minga.Agent.Tool.Registry` to `Services.Independent` supervisor children.

### PR 2.3: Create Tool.Executor

```elixir
# lib/minga/agent/tool/executor.ex
defmodule Minga.Agent.Tool.Executor do
  @moduledoc """
  Validates args, checks approval, runs advice chain, executes tool.
  """

  @spec execute(String.t(), map(), keyword()) ::
    {:ok, term()} | {:error, term()} | {:needs_approval, map()}
  def execute(tool_name, args, opts \\ []) do
    with {:ok, spec} <- Tool.Registry.lookup(tool_name),
         :ok <- validate_args(spec, args),
         :ok <- check_approval(spec, args, opts) do
      # Run the advice chain (reuse Config.Advice)
      wrapped = Config.Advice.wrap(String.to_existing_atom(tool_name), spec.callback)
      wrapped.(args)
    end
  end
end
```

**Files changed:** New file only.

### PR 2.4: Wire Native provider to use Tool.Registry

Change `Providers.Native` to get tools from `Tool.Registry.all_as_req_llm()` instead of `Tools.all/1`. This is a one-line change:

```elixir
# Before:
base_tools = Keyword.get(opts, :tools) || Tools.all(project_root: project_root)

# After:
base_tools = Keyword.get(opts, :tools) || Tool.Registry.all_as_req_llm()
```

**Files changed:** `lib/minga/agent/providers/native.ex` (1 line).

### Phase 2 Verification

```bash
# Tool.Registry is populated and tools execute:
mix test test/minga/agent/tool/

make lint
mix test.llm
```

---

## 5. Phase 3: Buffer Registry with Refcounts

**Goal:** Make buffers globally addressable resources with reference counting, instead of being owned by the Editor's workspace.

**Estimated effort:** 1 week, 2-3 PRs.

### Current state

`Minga.Buffer.Registry` already exists as a `Registry` (`:unique` mode) mapping buffer names to PIDs. But it's used for name-based lookups, not lifecycle management. Buffer lifecycle is managed by whoever started the buffer (usually the Editor via `Buffer.Supervisor`).

`Minga.Buffer.ensure_for_path/1` already exists and handles "find or create a buffer." Agent tools already use it.

### PR 3.1: Add refcount tracking to Buffer module

Add an ETS table alongside the existing Registry that tracks `{path, pid, ref_count}`. Wrap it in a module:

```elixir
# lib/minga/buffer/ref_tracker.ex
defmodule Minga.Buffer.RefTracker do
  @moduledoc """
  Reference counting for buffer processes. Each consumer (editor tab,
  agent session, LSP client) that opens a buffer acquires a reference.
  When all references are released, the buffer is eligible for cleanup.
  """

  @spec acquire(String.t(), pid()) :: :ok
  @spec release(String.t(), pid()) :: :ok
  @spec ref_count(String.t()) :: non_neg_integer()
  @spec all_info() :: [%{path: String.t(), pid: pid(), ref_count: non_neg_integer()}]
end
```

**Key decision:** Don't auto-stop buffers when refcount reaches 0 yet. That's a behavior change that needs careful testing. For now, just track the counts. The cleanup policy comes later.

**Files changed:** New file. Add to Foundation or Services supervisor.

### PR 3.2: Wire Buffer.ensure_for_path to acquire refs

When `Buffer.ensure_for_path/1` creates or finds a buffer, call `RefTracker.acquire/2` with the caller's identity.

When the Editor closes a tab, call `RefTracker.release/2`.

**Files changed:** `lib/minga/buffer.ex` (or `buffer/server.ex`), `lib/minga/editor/buffer_lifecycle.ex`.

### PR 3.3: Expose buffer listing through RefTracker

```elixir
# In Minga.Buffer (entry point module):
@spec list_buffers() :: [buffer_info()]
defdelegate list_buffers(), to: Minga.Buffer.RefTracker, as: :all_info
```

This gives the future API gateway a way to list open buffers without going through the Editor.

**Files changed:** `lib/minga/buffer.ex`.

---

## 6. Phase 4: Promote Agent.Supervisor to Peer

**Goal:** Move Agent.Supervisor out of Services.Supervisor to sit alongside it in the top-level tree.

**Estimated effort:** 1-2 days, 1 PR.

### Current state

```
Minga.Supervisor (rest_for_one)
├── Foundation.Supervisor
├── Buffer.Registry + Buffer.Supervisor
├── Services.Supervisor (rest_for_one)
│   ├── ... other services ...
│   └── Minga.Agent.Supervisor  ← buried here
└── Runtime.Supervisor (optional)
```

### Target state

```
Minga.Supervisor (rest_for_one)
├── Foundation.Supervisor
├── Buffer.Registry + Buffer.Supervisor
├── Services.Supervisor (rest_for_one)
│   ├── ... other services ...
│   └── (no Agent.Supervisor)
├── Minga.Agent.Supervisor  ← peer of Services and Runtime
├── Runtime.Supervisor (optional)
└── SystemObserver
```

### The change

In `Services.Supervisor.init/1`, remove `Minga.Agent.Supervisor` from the children list.

In `Minga.Application.start/2`, add `Minga.Agent.Supervisor` to the top-level children after `Services.Supervisor`:

```elixir
base_children = [
  Minga.Foundation.Supervisor,
  {Registry, keys: :unique, name: Minga.Buffer.Registry},
  {DynamicSupervisor, name: Minga.Buffer.Supervisor, strategy: :one_for_one},
  Minga.Services.Supervisor,
  Minga.Agent.Supervisor     # ← moved here
]
```

**Why this is safe:** Agent.Supervisor is a DynamicSupervisor with `one_for_one` strategy. It has no dependencies on other Services children (it depends on Foundation and Buffer, which start earlier). Moving it doesn't change any runtime behavior.

**With `rest_for_one` at the top level:** A Services crash still cascades to Agent.Supervisor (it comes after). An Agent.Supervisor crash cascades to Runtime.Supervisor (acceptable: the editor re-subscribes to agent events on restart). A Runtime crash does NOT cascade to Agent.Supervisor (agents keep running if the editor dies). This is the correct dependency direction.

**Files changed:** `lib/minga/services/supervisor.ex`, `lib/minga/application.ex`.

---

## 7. Phase 5: Extract Editor State

**Goal:** Separate what the Editor needs for presentation from what the core/agent runtime needs for domain logic. This is the largest phase.

**Estimated effort:** 2-3 weeks, 5-8 PRs.

### The problem

`EditorState` (1,277 lines) and `WorkspaceState` contain both domain state and presentation state. The agent runtime needs access to domain state (which session is active, what's the agent status, which buffers are open) but currently has to go through EditorState to get it.

### Strategy: Extract, don't rewrite

Don't restructure EditorState. Instead, extract the domain state that agents need into standalone modules that EditorState *composes* rather than *owns*.

### PR 5.1: Extract AgentSessionManager

Currently, agent session lifecycle is managed by `Editor.AgentLifecycle` and scattered across EditorState fields (`session.active_session`, `session.group_sessions`, etc.).

Create `Minga.Agent.SessionManager` as a GenServer that owns session lifecycle independently of the Editor:

```elixir
# lib/minga/agent/session_manager.ex
defmodule Minga.Agent.SessionManager do
  @moduledoc """
  Manages agent session lifecycle independently of any UI.

  Tracks active sessions, handles start/stop, routes prompts.
  The Editor subscribes to events from sessions it cares about.
  """

  use GenServer

  @spec start_session(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  @spec active_sessions() :: [{String.t(), pid(), Minga.Agent.SessionMetadata.t()}]
  @spec send_prompt(String.t(), String.t()) :: :ok | {:error, term()}
end
```

The Editor's `AgentLifecycle` becomes a thin wrapper that calls `SessionManager` and updates presentation state (tab associations, UI flags).

**Files changed:** New `lib/minga/agent/session_manager.ex`. Add to Agent.Supervisor children. Modify `Editor.AgentLifecycle` to delegate. Keep EditorState fields for now (they'll reference the SessionManager's data).

### PR 5.2: Make Agent.UIState independent of Editor.State sub-structs

`Agent.UIState` currently references `Editor.State.FileTree` and `Editor.State.Windows`:

```elixir
alias Minga.Editor.State.FileTree, as: FileTreeState
alias Minga.Editor.State.Windows
```

These references exist because UIState carries file tree and window state for the agent view. The agent's file tree state should be its own struct, not a reference to the editor's.

**Fix:** Create `Minga.Agent.UIState.FileTree` and `Minga.Agent.UIState.Windows` as agent-specific structs. They can have the same shape but different modules.

Or, if the shapes are identical, extract them to a shared location under `Minga.UI` or `Minga.Workspace` that neither Editor nor Agent owns.

**Files changed:** `lib/minga/agent/ui_state.ex`, new sub-struct files.

### PR 5.3: Create Agent.State (domain-only)

Extract the agent-domain fields from `EditorState` into a standalone struct:

```elixir
# lib/minga/agent/runtime_state.ex
defmodule Minga.Agent.RuntimeState do
  @moduledoc """
  Agent runtime state accessible without an Editor.

  This is the domain state that agent sessions, tools, and the API
  gateway need. The Editor's AgentState composes this with presentation
  fields (spinner timers, tab associations, etc.).
  """

  defstruct [
    :active_session_id,
    :active_session_pid,
    :group_sessions,    # %{id => pid}
    :model_name,
    :provider_name,
    :status             # :idle, :thinking, :tool_executing, :error
  ]
end
```

The existing `Editor.State.Agent` composes this:

```elixir
defmodule Minga.Editor.State.Agent do
  defstruct [
    runtime: %Minga.Agent.RuntimeState{},   # domain state
    spinner_timer: nil,                       # presentation
    spinner_frame: 0,                         # presentation
    pending_approval: nil                     # shared (both domain and UI)
  ]
end
```

**Files changed:** New file. Modify `Editor.State.Agent` to compose it.

### PR 5.4-5.8: Incremental extraction

Continue extracting domain state from EditorState for each concern:

- **Buffer listing** (PR 5.4): `Workspace.State.buffers` currently holds active buffer, buffer list, etc. The RefTracker from Phase 3 provides buffer listing independently. The Editor reads from RefTracker for its presentation needs.

- **Search state** (PR 5.5): If agents need search state (they currently don't), extract. Otherwise, leave as editor-only.

- **LSP state** (PR 5.6): `Editor.State.LSP` holds LSP-related editor state. LSP Client already manages its own state independently. The editor LSP state is presentation-only (pending requests for UI feedback).

Each PR follows the same pattern: identify what's domain vs presentation, extract domain into a standalone module, have EditorState compose it.

---

## 8. Phase 6: Agent Runtime Facade

**Goal:** Create `Minga.Agent.Runtime` as the single entry point for all programmatic interaction.

**Estimated effort:** 3-5 days, 2-3 PRs.

### PR 6.1: Create the facade module

```elixir
# lib/minga/agent/runtime.ex
defmodule Minga.Agent.Runtime do
  @moduledoc """
  The agentic runtime. Primary API surface for Minga.
  """

  # Session management
  defdelegate start_session(opts), to: Minga.Agent.SessionManager
  defdelegate stop_session(id), to: Minga.Agent.SessionManager
  defdelegate send_prompt(id, text), to: Minga.Agent.SessionManager
  defdelegate abort(id), to: Minga.Agent.SessionManager
  defdelegate list_sessions(), to: Minga.Agent.SessionManager

  # Tool execution
  defdelegate execute_tool(name, args, opts \\ []), to: Minga.Agent.Tool.Executor, as: :execute
  defdelegate list_tools(), to: Minga.Agent.Tool.Registry, as: :all
  defdelegate register_tool(spec), to: Minga.Agent.Tool.Registry, as: :register

  # Introspection
  defdelegate describe(), to: Minga.Agent.Introspection.Describer

  # Events
  defdelegate subscribe(topic), to: Minga.Events
  defdelegate broadcast(topic, payload), to: Minga.Events

  # Buffers
  defdelegate list_buffers(), to: Minga.Buffer.RefTracker, as: :all_info
  defdelegate buffer_content(path_or_pid), to: Minga.Buffer

  # Runtime modification
  defdelegate register_hook(event, fun), to: Minga.Config.Hooks, as: :register
  defdelegate register_advice(phase, name, fun), to: Minga.Config.Advice, as: :register
end
```

This is mostly `defdelegate`. The power is in having a single module that an LLM or API client can read to understand "what can I do?"

**Files changed:** New file only.

### PR 6.2: Create Introspection.Describer

```elixir
# lib/minga/agent/introspection/describer.ex
defmodule Minga.Agent.Introspection.Describer do
  @moduledoc """
  Produces a machine-readable description of the runtime's capabilities.
  """

  @spec describe() :: map()
  def describe do
    %{
      tools: Minga.Agent.Tool.Registry.all() |> Enum.map(&tool_summary/1),
      sessions: Minga.Agent.SessionManager.active_sessions() |> Enum.map(&session_summary/1),
      buffers: Minga.Buffer.RefTracker.all_info(),
      event_topics: event_topic_descriptions(),
      health: health_summary()
    }
  end
end
```

**Files changed:** New file, tests.

### PR 6.3: Add runtime tools

Add tools that expose the runtime itself:

```elixir
# lib/minga/agent/tools/runtime_describe.ex
defmodule Minga.Agent.Tools.RuntimeDescribe do
  def spec do
    %Minga.Agent.Tool.Spec{
      name: "runtime_describe",
      description: "Describe the runtime's capabilities, open buffers, active sessions, and system health.",
      parameter_schema: %{"type" => "object", "properties" => %{}},
      callback: fn _args ->
        {:ok, Minga.Agent.Introspection.Describer.describe() |> inspect(pretty: true)}
      end,
      category: :runtime
    }
  end
end
```

Similarly for `runtime_eval`, `runtime_process_tree`, `runtime_register_tool`, `runtime_register_hook`.

**Files changed:** New tool files. Register in Tool.Registry startup.

---

## 9. Phase 7: API Gateway

**Goal:** External clients can connect and interact with the runtime.

**Estimated effort:** 2-3 weeks, 4-6 PRs.

### PR 7.1: Add Bandit dependency, create WebSocket handler

Add `{:bandit, "~> 1.0"}` to `mix.exs` deps.

Create a minimal WebSocket server:

```elixir
# lib/minga/gateway/server.ex
defmodule Minga.Gateway.Server do
  use Supervisor

  def init(opts) do
    port = Keyword.get(opts, :port, 4840)
    children = [
      {Bandit, plug: Minga.Gateway.Router, port: port, scheme: :http}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

# lib/minga/gateway/router.ex
defmodule Minga.Gateway.Router do
  use Plug.Router
  plug :match
  plug :dispatch

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(Minga.Gateway.WebSocket.Handler, %{}, [])
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

**Conditional startup** (same pattern as the Editor):

```elixir
# In application.ex:
gateway_children =
  if Application.get_env(:minga, :start_gateway, false) do
    [{Minga.Gateway.Server, port: Application.get_env(:minga, :gateway_port, 4840)}]
  else
    []
  end
```

The gateway starts only when explicitly enabled. Tests and the standalone editor don't start it by default.

**Files changed:** `mix.exs`, new gateway files, `lib/minga/application.ex`.

### PR 7.2: WebSocket message handling

Implement the request/response protocol over WebSocket:

```elixir
# lib/minga/gateway/websocket/handler.ex
defmodule Minga.Gateway.WebSocket.Handler do
  @behaviour WebSock

  @impl true
  def handle_in({message, [opcode: :text]}, state) do
    case JSON.decode(message) do
      {:ok, %{"method" => method, "params" => params, "id" => id}} ->
        result = dispatch(method, params)
        reply = JSON.encode!(%{id: id, result: result})
        {:push, {:text, reply}, state}
      _ ->
        {:ok, state}
    end
  end

  defp dispatch("tool.execute", %{"tool" => name, "args" => args}) do
    Minga.Agent.Runtime.execute_tool(name, args)
  end

  defp dispatch("session.start", params) do
    Minga.Agent.Runtime.start_session(Enum.map(params, fn {k, v} -> {String.to_existing_atom(k), v} end))
  end

  defp dispatch("runtime.describe", _) do
    Minga.Agent.Runtime.describe()
  end

  # ... etc
end
```

### PR 7.3: Event streaming over WebSocket

```elixir
# When client sends events.subscribe:
defp dispatch("events.subscribe", %{"topics" => topics}) do
  for topic <- topics do
    Minga.Events.subscribe(String.to_existing_atom(topic))
  end
  :ok
end

# In handle_info (events arrive as messages):
@impl true
def handle_info({:minga_event, topic, payload}, state) do
  event = JSON.encode!(%{type: "event", topic: topic, payload: serialize(payload)})
  {:push, {:text, event}, state}
end
```

### PR 7.4: JSON-RPC over stdio handler

For CLI tools and VS Code extensions:

```elixir
# lib/minga/gateway/jsonrpc/handler.ex
defmodule Minga.Gateway.JsonRpc.Handler do
  @moduledoc """
  JSON-RPC 2.0 over stdin/stdout. Same dispatch as WebSocket,
  different transport.
  """
end
```

This is a separate entry point (`minga --rpc`) that reads JSON lines from stdin and writes responses to stdout. Same `dispatch/2` function as the WebSocket handler.

### PR 7.5: Integrate existing Port protocol as a Gateway client

The existing `Frontend.Manager` already speaks the binary Port protocol to native frontends. Wire it as a Gateway client type that gets the same event subscriptions and tool execution as WebSocket clients, but over the binary protocol.

This is mostly organizational. The Port protocol continues to carry render commands (which WebSocket doesn't need). But agent events, tool results, and buffer changes can flow through the same subscription mechanism.

**Files changed:** Adapter module that bridges `Frontend.Manager` events to the Gateway's event subscription model.

---

## 10. Phase 8: Self-Description and Runtime Modification

**Goal:** An LLM can discover capabilities and modify the runtime through tools.

**Estimated effort:** 1 week, 3-4 PRs.

### PR 8.1: runtime_describe tool

Already scaffolded in Phase 6. Flesh out the implementation to include:
- All tools with full JSON Schema
- Active sessions with metadata
- Open buffers with path, dirty status, line count
- Event topics with payload field descriptions
- System health (uptime, process count, memory)

### PR 8.2: runtime_eval tool

```elixir
defmodule Minga.Agent.Tools.RuntimeEval do
  def execute(code) when is_binary(code) do
    try do
      {result, _binding} = Code.eval_string(code)
      {:ok, inspect(result, pretty: true, limit: :infinity)}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
```

Gated behind approval policy (always destructive).

### PR 8.3: runtime_register_tool tool

```elixir
defmodule Minga.Agent.Tools.RuntimeRegisterTool do
  def execute(args) do
    code = args["code"]
    {callback, _} = Code.eval_string(code)

    spec = %Tool.Spec{
      name: args["name"],
      description: args["description"],
      parameter_schema: args["parameter_schema"],
      callback: callback,
      category: :runtime
    }

    Tool.Registry.register(spec)
    {:ok, "Registered tool: #{args["name"]}"}
  end
end
```

### PR 8.4: runtime_process_tree tool

```elixir
defmodule Minga.Agent.Tools.RuntimeProcessTree do
  def execute(_args) do
    tree = build_tree(Minga.Supervisor)
    {:ok, format_tree(tree)}
  end

  defp build_tree(sup) do
    children = Supervisor.which_children(sup)
    Enum.map(children, fn {id, pid, type, _modules} ->
      info = Process.info(pid, [:memory, :message_queue_len, :reductions])
      child_tree = if type == :supervisor, do: build_tree(pid), else: []
      %{id: id, pid: pid, type: type, info: info, children: child_tree}
    end)
  end
end
```

---

## 11. Phase 9: Buffer Forking

**Goal:** Agents can fork a buffer and edit their copy concurrently. Merge back when done.

**Estimated effort:** 2 weeks, 3-4 PRs.

### PR 9.1: Buffer.Fork GenServer

```elixir
# lib/minga/buffer/fork.ex
defmodule Minga.Buffer.Fork do
  use GenServer

  @doc "Fork a buffer. Snapshots current content as the common ancestor."
  @spec fork(pid(), String.t()) :: {:ok, pid()}

  @doc "Merge fork back into parent. Returns :ok or {:conflict, hunks}."
  @spec merge(pid()) :: :ok | {:conflict, [hunk()]}

  @doc "Discard the fork without merging."
  @spec discard(pid()) :: :ok
end
```

The fork is a GenServer that holds:
- A `Document` snapshot (the common ancestor)
- A working `Document` (the fork's current state)
- The parent buffer's PID
- The session ID that owns this fork

It supports the same editing API as `Buffer.Server` (`apply_text_edits`, `find_and_replace`, `content`, etc.) so agent tools can use it transparently.

### PR 9.2: Three-way merge using Myers diff

```elixir
# lib/minga/buffer/merge.ex
defmodule Minga.Buffer.Merge do
  @doc """
  Three-way merge. Takes common ancestor, fork version, and current parent version.
  Returns merged content or conflict hunks.
  """
  @spec merge(String.t(), String.t(), String.t()) ::
    {:ok, String.t()} | {:conflict, [hunk()]}
end
```

Uses `List.myers_difference/2` (already used by `Git.Diff`).

### PR 9.3: Wire agent tools to use forks

When an agent session is in "fork mode," route its buffer tool calls to the fork instead of the parent:

```elixir
# In buffer_edit tool callback:
defp resolve_buffer(path, opts) do
  case Keyword.get(opts, :fork_pid) do
    nil -> Buffer.ensure_for_path(path)
    fork_pid -> {:ok, fork_pid}
  end
end
```

### PR 9.4: Selective flush before shell commands

When an agent runs `shell_exec`, flush dirty buffers (or forks) to disk first so builds see the latest content.

---

## 12. Phase 10: Boundary Enforcement

**Goal:** Make the layer boundaries permanent and machine-enforced.

**Estimated effort:** 3-5 days, 2-3 PRs.

### PR 10.1: Add Credo layer check

```elixir
# lib/mix/credo/check/layer_boundary.ex
defmodule Minga.Credo.Check.LayerBoundary do
  @moduledoc """
  Verifies that Layer 0 modules don't import from Layers 1-3,
  Layer 1 modules don't import from Layers 2-3, etc.
  """

  use Credo.Check, base_priority: :high

  @layer_0 ~w(Minga.Buffer Minga.Events Minga.Config Minga.LSP Minga.Git
              Minga.Project Minga.Editing Minga.Diagnostics Minga.Parser
              Minga.Core Minga.Language Minga.Log Minga.Telemetry)

  @layer_1 ~w(Minga.Agent)

  @layer_2 ~w(Minga.Gateway)

  @layer_3 ~w(Minga.Editor Minga.Input Minga.Frontend Minga.UI
              Minga.Shell Minga.Keymap Minga.Mode Minga.Command)

  # Layer 0 cannot alias anything from Layers 1, 2, 3
  # Layer 1 cannot alias anything from Layers 2, 3
  # Layer 2 cannot alias anything from Layer 3
end
```

Add to `.credo.exs` checks list. Runs in `make lint`.

### PR 10.2: Optional directory reorganization

If the team wants the directory structure to reflect layers, do the rename pass now. This is high-churn but mechanically simple:

```
lib/minga/buffer/ → lib/minga/core/buffer/   (with defdelegate bridges)
lib/minga/events.ex → lib/minga/core/events.ex
lib/minga/config/ → lib/minga/core/config/
# etc.
```

Use `defdelegate` bridges so existing callers keep working. Remove bridges in a follow-up cleanup PR.

**This is optional.** The Credo check enforces boundaries regardless of directory structure. Some teams prefer the flat namespace; the constraint is the Credo check, not the directory layout.

### PR 10.3: Documentation pass

Update `AGENTS.md` module organization table, `docs/ARCHITECTURE.md` diagrams, and supervision tree comments to reflect the new structure.

---

## 13. Migration Checklist Per Phase

Every PR must satisfy:

- [ ] `make lint` passes (format + credo + compile --warnings-as-errors + dialyzer)
- [ ] `mix test.llm` passes (all tests, excludes :heavy)
- [ ] No new `Process.sleep` in production code
- [ ] Every new public function has `@spec`
- [ ] Every new module has `@moduledoc`
- [ ] Every new struct has `@enforce_keys` for required fields
- [ ] Burrito release builds: `MIX_ENV=prod mix release minga`
- [ ] macOS release builds: `MIX_ENV=prod mix release minga_macos`
- [ ] If supervision tree changed: verify with `Supervisor.which_children/1` in iex

---

## 14. What NOT to Touch

These are working, well-designed systems. Refactoring them adds risk for no benefit.

**Don't touch:**
- `Buffer.Document` (gap buffer internals). It works. It's tested. Leave it alone.
- `Editing.Motion.*`, `Editing.Operator`, `Editing.TextObject`. Pure functions, already Layer 0.
- The binary Port protocol opcodes and encoding. Existing frontends depend on exact byte layouts.
- The Zig TUI or Swift frontends. They speak the protocol. The protocol doesn't change.
- `vm.args.eex` tuning. Already optimized for the editor workload.
- The test infrastructure (`HeadlessPort`, `EditorCase`, `LLMFormatter`). These are testing tools, not production code.
- `Minga.Mode.*` (vim FSM modules). These are editor-client-only. They don't need to move.
- `Minga.Keymap.*`. Editor-client-only.
- `Minga.UI.*` (themes, picker, which-key). Editor-client-only.
- Individual agent tool implementations (`Tools.EditFile`, `Tools.ReadFile`, etc.). They already have the right dependencies (Buffer, Git, LSP). They just need to be registered in the Tool.Registry.

**Don't rename the existing `Minga.*` namespace to `Minga.Core.*` until Phase 10.** Premature renaming creates massive diffs that obscure behavioral changes. Get the architecture right first, then clean up names.

---

## 15. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Phase 1 PR 1.4 (Agent.Events split) introduces subtle state bugs | Medium | High | Extensive before/after snapshot testing. Keep old module as fallback behind a config flag for one release cycle. |
| Burrito release breaks after supervision tree change (Phase 4) | Low | High | CI builds the Burrito release on every PR that touches `application.ex` or any supervisor. |
| Tool.Registry ETS table not populated in test env | Medium | Medium | `start_supervised!({Tool.Registry, ...})` in test setup. Add to ExUnit's `:setup_all` for affected suites. |
| WebSocket gateway (Phase 7) adds a Bandit dependency that conflicts with existing deps | Low | Medium | Bandit has minimal deps (Thousand Island, WebSock). Pin version. Test in CI before merging. |
| `Agent.Events` split (Phase 1) breaks agent chat rendering | Medium | Medium | Integration test: start headless editor, send agent prompt, verify events flow. Snapshot test the chat panel. |
| Buffer refcount cleanup policy (Phase 3) causes premature buffer GC | Low | High | Phase 3 only adds tracking, no cleanup. Cleanup policy is a separate PR with explicit tests for edge cases (agent releases ref, user still has tab open). |

---

## Summary: Phase Order and Effort

| Phase | What | Effort | Dependencies |
|---|---|---|---|
| **1** | Sever upward dependencies (6 PRs) | 1-2 weeks | None |
| **2** | Tool Registry and Executor (4 PRs) | 1 week | None (can parallel with Phase 1) |
| **3** | Buffer Registry with refcounts (3 PRs) | 1 week | Phase 1 PR 1.2 |
| **4** | Promote Agent.Supervisor (1 PR) | 1-2 days | Phase 1 |
| **5** | Extract Editor State (5-8 PRs) | 2-3 weeks | Phases 1, 3 |
| **6** | Agent Runtime facade (3 PRs) | 3-5 days | Phases 2, 4, 5 |
| **7** | API Gateway (5 PRs) | 2-3 weeks | Phase 6 |
| **8** | Self-description, runtime modification (4 PRs) | 1 week | Phases 6, 7 |
| **9** | Buffer Forking (4 PRs) | 2 weeks | Phases 3, 5 |
| **10** | Boundary enforcement (3 PRs) | 3-5 days | All above |

**Total: ~10-14 weeks, ~40 PRs.**

Phases 1 and 2 can run in parallel. Phases 3 and 4 are quick and can run in parallel. Phase 5 is the longest and should start as soon as Phase 1 is done. The gateway (Phase 7) is the first externally visible change, roughly 6-8 weeks in.

After Phase 6, you have a working agentic runtime with a facade API, a tool system, independent buffer management, and agent sessions that don't require an editor. That's the inflection point where external clients become possible, and it's roughly the halfway mark.
