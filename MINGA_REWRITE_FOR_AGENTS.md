# Minga: Agentic-First Runtime for Developer Workflows

A specification for cold-starting Minga as a programmable BEAM runtime where AI agents are first-class citizens, not bolted-on features. External UIs connect as clients. The runtime is self-describing, runtime-modifiable, and process-isolated by default.

This document is written so that an LLM with no prior context can generate the project from scratch.

---

## Table of Contents

1. [Vision and Core Thesis](#1-vision-and-core-thesis)
2. [Architecture Overview](#2-architecture-overview)
3. [Layer 0: Core Runtime](#3-layer-0-core-runtime)
4. [Layer 1: Agent Runtime](#4-layer-1-agent-runtime)
5. [Layer 2: API Gateway](#5-layer-2-api-gateway)
6. [Layer 3: Clients](#6-layer-3-clients)
7. [Supervision Tree](#7-supervision-tree)
8. [Data Structures and Protocols](#8-data-structures-and-protocols)
9. [Tool System](#9-tool-system)
10. [Self-Description and Introspection](#10-self-description-and-introspection)
11. [Runtime Modification](#11-runtime-modification)
12. [Buffer Architecture](#12-buffer-architecture)
13. [Event System](#13-event-system)
14. [Configuration System](#14-configuration-system)
15. [Language Intelligence](#15-language-intelligence)
16. [Git Integration](#16-git-integration)
17. [Extension System](#17-extension-system)
18. [Agent Session Lifecycle](#18-agent-session-lifecycle)
19. [Agent Provider Behaviour](#19-agent-provider-behaviour)
20. [Multi-Agent Coordination](#20-multi-agent-coordination)
21. [Frontend Protocol](#21-frontend-protocol)
22. [Editor Client (Reference Implementation)](#22-editor-client-reference-implementation)
23. [Project Structure](#23-project-structure)
24. [Build Order](#24-build-order)
25. [Tech Stack and Dependencies](#25-tech-stack-and-dependencies)
26. [Design Principles](#26-design-principles)
27. [What This Enables](#27-what-this-enables)
28. [Coding Standards](#28-coding-standards)
29. [Testing Strategy](#29-testing-strategy)

---

## 1. Vision and Core Thesis

Minga is a BEAM-powered runtime that manages code buffers, language intelligence, git operations, and AI agent sessions as supervised Erlang processes. It is not a text editor. It is the programmable core that any developer tool (editor, CLI, web dashboard, CI pipeline) connects to as a client.

The core thesis: **the BEAM's process model (isolation, supervision, message passing, hot code reload, distribution) is the ideal foundation for a system where multiple AI agents and humans operate on code concurrently.**

Key properties:

- **Agents are first-class.** Agent sessions sit at the same level as the editor in the supervision tree, not underneath it. The agent runtime is the primary API surface, not an afterthought.
- **Tools are the universal API.** Everything that modifies state (open file, apply edit, run shell command, stage git changes) is a tool with a typed schema. Both agents and human UIs invoke the same tools through the same paths.
- **Self-describing.** The runtime can produce a machine-readable description of every tool, every event type, every buffer, every running process. When an LLM connects, it discovers capabilities programmatically.
- **Runtime-modifiable.** New tools, hooks, advice, and event handlers can be registered at runtime through the API. The BEAM's hot code reload makes this safe, not experimental.
- **BYO UX.** The runtime exposes a protocol-agnostic API. A Swift/Metal macOS editor, a Zig TUI, a web dashboard, a VS Code extension, or a headless CI runner are all equal clients. None is privileged.
- **Process-isolated by default.** Every buffer, every agent session, every LSP client runs as its own supervised BEAM process. Crashes are contained. The scheduler is preemptive. Nothing can starve the system.

### What Minga is NOT

- Not a text editor (though it ships one as a reference client)
- Not a VS Code extension host (tools run in-process on the BEAM, not in sandboxed subprocesses)
- Not a build system (it delegates to existing toolchains)
- Not an LLM provider (it connects to external providers via a behaviour)

---

## 2. Architecture Overview

Four layers with strict downward-only dependencies:

```
┌─────────────────────────────────────────────────────────┐
│  Layer 3: Clients (BYO UX)                              │
│  macOS editor, TUI, web dashboard, VS Code ext, CLI     │
│  ↕ API Gateway protocol (WebSocket, JSON-RPC, Port)     │
├─────────────────────────────────────────────────────────┤
│  Layer 2: API Gateway                                   │
│  Protocol translation, auth, streaming, sessions        │
│  ↕ Elixir function calls                                │
├─────────────────────────────────────────────────────────┤
│  Layer 1: Agent Runtime                                 │
│  Sessions, tools, providers, workflows, introspection   │
│  ↕ Elixir function calls                                │
├─────────────────────────────────────────────────────────┤
│  Layer 0: Core Runtime                                  │
│  Buffers, events, config, LSP, git, project, editing    │
│  No UI, no agents, no network. Pure BEAM services.      │
└─────────────────────────────────────────────────────────┘
```

**Layer 0 (Core Runtime)** knows nothing about agents, UIs, or network protocols. It manages code artifacts (buffers, files, projects) and developer services (LSP, git, tree-sitter, diagnostics). It is a library that can be depended on by any Elixir project.

**Layer 1 (Agent Runtime)** adds AI agent capabilities on top of the core. It manages sessions, executes tools, coordinates multi-agent workflows, and provides self-description. It depends on Layer 0 only.

**Layer 2 (API Gateway)** exposes Layers 0 and 1 over network protocols. WebSocket, JSON-RPC over stdio, Erlang distribution, or the binary Port protocol. It handles authentication, rate limiting, and streaming event subscriptions. It depends on Layers 0 and 1.

**Layer 3 (Clients)** are external processes that speak the API Gateway protocol. They are NOT part of the Minga codebase (except the reference editor client). They can be written in any language.

### Dependency Rule

A module in Layer N never imports from Layer N+1. If you find yourself adding an upward dependency, the logic is in the wrong layer. This is mechanically verifiable: check `alias`/`import` lines.

---

## 3. Layer 0: Core Runtime

The core runtime provides stateful services for operating on code. No rendering, no input handling, no agents. Every module here is either a pure function library or a supervised GenServer.

### 3.1 Module Map

```
lib/minga/core/
  buffer/
    document.ex           # Pure gap buffer data structure
    server.ex             # GenServer wrapping Document with file I/O
    edit_delta.ex          # Incremental edit descriptor
    edit_source.ex         # Who made the edit (:user, {:agent, id}, {:lsp, name}, etc.)
    state.ex               # Buffer GenServer internal state
    supervisor.ex          # DynamicSupervisor for buffer processes
    registry.ex            # ETS path→pid lookup with refcounts
    fork.ex                # Forked buffer for concurrent agent editing
  events/
    bus.ex                 # Registry-backed pub/sub
    payloads.ex            # Typed event structs with @enforce_keys
    recorder.ex            # Persistent ordered event log
  config/
    options.ex             # ETS-backed typed option store
    hooks.ex               # Lifecycle hook registry
    advice.ex              # Before/after/around/override command advice
    loader.ex              # Config file discovery and evaluation
  language/
    registry.ex            # Language definition lookup
    filetype.ex            # Filetype detection
  lsp/
    client.ex              # LSP client GenServer (one per language server)
    supervisor.ex          # DynamicSupervisor for LSP clients
    sync_server.ex         # Document sync coordination
    server_config.ex       # Server configuration and auto-discovery
    workspace_edit.ex      # Apply LSP workspace edits to buffers
  git/
    backend.ex             # Behaviour for git operations
    system.ex              # Production backend (shells out to git CLI)
    stub.ex                # Test backend (ETS-backed, no OS processes)
    tracker.ex             # Repo-level status tracking
    diff.ex                # Pure in-memory line diffing
    buffer.ex              # Per-buffer git sign tracking
  project/
    root.ex                # Project root detection
    file_find.ex           # Fast file finding (fd/find)
    search.ex              # Project-wide text search (rg/grep)
    file_tree.ex           # File tree model
  editing/
    motion/                # Cursor motion functions (word, line, char, document)
    operator.ex            # Operators (delete, change, yank)
    text_object.ex         # Text objects (iw, aw, i", etc.)
    search.ex              # Text search with regex
    auto_pair.ex           # Auto-close brackets/quotes
    formatter.ex           # External formatter integration
    comment.ex             # Line comment toggling
    snippet.ex             # Snippet expansion
    completion.ex          # Completion data structures
  diagnostics/
    store.ex               # Diagnostic storage (interval tree)
    decorations.ex         # Sign column / inline decoration data
  parser/
    manager.ex             # Tree-sitter parser Port GenServer
  core/
    interval_tree.ex       # Generic interval tree
    face.ex                # Text styling (fg, bg, attrs)
    decorations.ex         # Decoration types (highlight, virtual text, etc.)
    diff.ex                # Generic diffing utilities
    unicode.ex             # Unicode width, grapheme operations
```

### 3.2 Key Design Decisions

**Gap buffer for text storage.** The `Document` struct stores text as two binaries with a gap at the cursor. O(1) insert/delete at cursor, O(k) cursor movement where k is distance. This is the same data structure Emacs has used since the 1980s. It's simple, fast for the editing workload, and easy to snapshot for forking.

**Byte-indexed positions.** All positions are `{line, byte_col}`, not grapheme indices. O(1) slicing via `binary_part/3`. Tree-sitter returns byte offsets natively. Grapheme conversion happens only at the render boundary (visible lines, ~40-50 per frame).

**Process-per-buffer.** Each open file is a GenServer under a DynamicSupervisor. Processes don't share memory. Concurrent edits from agents and humans serialize through the GenServer mailbox. No locks, no mutexes, no races.

**Buffer Registry with refcounts.** An ETS table maps `file_path -> {pid, ref_count}`. Any component (editor tab, agent session, LSP client) that opens a buffer increments the refcount. Closing decrements. The buffer process is stopped when the refcount reaches zero. This replaces "the editor owns buffers" with "buffers are globally addressable resources."

**Edit source tagging.** Every edit carries an `EditSource` identifying who made it: `:user`, `{:agent, session_id, tool_call_id}`, `{:lsp, server_name}`, `{:formatter, name}`, `:undo`, `:redo`. This enables provenance tracking, selective undo ("undo everything agent X did"), and edit timeline visualization.

**Events are typed structs.** Each event topic has a dedicated struct with `@enforce_keys`. The compiler catches missing fields at construction time. Subscribers pattern-match on the struct.

---

## 4. Layer 1: Agent Runtime

The agent runtime is the primary programmatic interface to Minga. It manages AI agent sessions, exposes the tool API, orchestrates multi-agent workflows, and provides runtime introspection and modification.

### 4.1 Module Map

```
lib/minga/agent/
  runtime.ex              # Top-level API facade for the agent runtime
  session.ex              # GenServer managing one agent conversation
  supervisor.ex           # DynamicSupervisor for sessions
  provider.ex             # Behaviour for LLM backends
  providers/
    native.ex             # In-BEAM provider via ReqLLM (Anthropic, OpenAI, etc.)
    rpc.ex                # External process provider via JSON-RPC over stdio
  tool/
    registry.ex           # ETS-backed tool lookup (replaces Command.Registry for tools)
    spec.ex               # Tool specification struct (name, schema, callback, metadata)
    executor.ex           # Tool execution with sandboxing and approval workflows
    approval.ex           # Approval state machine (auto, ask, deny per tool)
  tools/                  # Built-in tool implementations
    buffer_read.ex
    buffer_write.ex
    buffer_edit.ex
    buffer_multi_edit.ex
    file_find.ex
    file_search.ex
    shell.ex
    git_status.ex
    git_diff.ex
    git_log.ex
    git_stage.ex
    git_commit.ex
    lsp_diagnostics.ex
    lsp_definition.ex
    lsp_references.ex
    lsp_hover.ex
    lsp_symbols.ex
    lsp_rename.ex
    lsp_code_actions.ex
    memory_write.ex
    runtime_describe.ex      # Self-description tool
    runtime_register_tool.ex # Register new tools at runtime
    runtime_register_hook.ex # Register hooks at runtime
    runtime_eval.ex          # Evaluate Elixir in the running VM
    runtime_process_tree.ex  # Inspect the supervision tree
  workflow/
    orchestrator.ex       # Multi-agent workflow coordination
    choreography.ex       # Reusable workflow templates
  introspection/
    describer.ex          # Produces machine-readable capability descriptions
    process_observer.ex   # Process tree metrics and health monitoring
    event_query.ex        # Query the event log
  memory/
    store.ex              # Persistent agent memory (learnings, preferences)
  message.ex              # Conversation message struct
  event.ex                # Agent event types (streaming, tool calls, status)
  cost.ex                 # Token usage and cost tracking
  compaction.ex           # Context window management
  config.ex               # Agent-specific configuration
  credentials.ex          # API key management
```

### 4.2 The Runtime Facade

`Minga.Agent.Runtime` is the single entry point for all programmatic interaction with Minga. It delegates to the appropriate subsystem:

```elixir
defmodule Minga.Agent.Runtime do
  @moduledoc """
  The agentic runtime. The primary API surface for Minga.

  All programmatic interaction with Minga goes through this module.
  Agent sessions, tool execution, introspection, runtime modification,
  and event subscriptions are all accessible here.
  """

  # ── Session Management ──────────────────────────────────────────────

  @doc "Starts a new agent session with the given provider and model."
  @spec start_session(keyword()) :: {:ok, session_id :: String.t()} | {:error, term()}
  defdelegate start_session(opts), to: Minga.Agent.SessionManager

  @doc "Stops an agent session."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  defdelegate stop_session(session_id), to: Minga.Agent.SessionManager

  @doc "Sends a user prompt to a session. Returns immediately; stream events via subscribe."
  @spec send_prompt(String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate send_prompt(session_id, text), to: Minga.Agent.SessionManager

  @doc "Aborts the current operation in a session."
  @spec abort(String.t()) :: :ok
  defdelegate abort(session_id), to: Minga.Agent.SessionManager

  @doc "Lists all active sessions with metadata."
  @spec list_sessions() :: [Minga.Agent.SessionMetadata.t()]
  defdelegate list_sessions(), to: Minga.Agent.SessionManager

  # ── Tool Execution ──────────────────────────────────────────────────

  @doc """
  Executes a tool by name with the given arguments.

  This is the universal API for modifying state. Both agents and human
  UIs call this. The tool registry validates arguments against the
  JSON Schema, checks approval policy, and delegates to the tool's
  callback.
  """
  @spec execute_tool(String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()} | {:needs_approval, Minga.Agent.Tool.Approval.t()}
  defdelegate execute_tool(tool_name, args, opts \\ []), to: Minga.Agent.Tool.Executor

  @doc "Returns all registered tools with their schemas."
  @spec list_tools() :: [Minga.Agent.Tool.Spec.t()]
  defdelegate list_tools(), to: Minga.Agent.Tool.Registry

  @doc "Registers a new tool at runtime."
  @spec register_tool(Minga.Agent.Tool.Spec.t()) :: :ok | {:error, term()}
  defdelegate register_tool(spec), to: Minga.Agent.Tool.Registry

  # ── Introspection ───────────────────────────────────────────────────

  @doc """
  Returns a machine-readable description of the runtime's capabilities.

  This is what an LLM reads when it first connects. Includes all tools
  with schemas, all event types, all buffer info, system health.
  """
  @spec describe() :: Minga.Agent.Introspection.Describer.capabilities()
  defdelegate describe(), to: Minga.Agent.Introspection.Describer

  @doc "Returns the supervision process tree with optional metrics."
  @spec process_tree(keyword()) :: Minga.Agent.Introspection.ProcessObserver.tree()
  defdelegate process_tree(opts \\ []), to: Minga.Agent.Introspection.ProcessObserver

  @doc "Queries the event log with filters."
  @spec query_events(keyword()) :: [Minga.Core.Events.recorded_event()]
  defdelegate query_events(filters \\ []), to: Minga.Agent.Introspection.EventQuery

  # ── Runtime Modification ────────────────────────────────────────────

  @doc "Registers a lifecycle hook."
  @spec register_hook(atom(), function()) :: :ok
  defdelegate register_hook(event, fun), to: Minga.Core.Config.Hooks, as: :register

  @doc "Registers advice on a tool."
  @spec register_advice(atom(), atom(), function()) :: :ok
  defdelegate register_advice(phase, tool_name, fun), to: Minga.Core.Config.Advice, as: :register

  @doc "Evaluates Elixir code in the running VM."
  @spec eval(String.t()) :: {:ok, term()} | {:error, term()}
  def eval(code) when is_binary(code) do
    Minga.Agent.Tools.RuntimeEval.execute(code)
  end

  # ── Event Subscriptions ─────────────────────────────────────────────

  @doc "Subscribes the calling process to an event topic."
  @spec subscribe(atom()) :: :ok
  defdelegate subscribe(topic), to: Minga.Core.Events.Bus

  @doc "Broadcasts an event to all subscribers of a topic."
  @spec broadcast(atom(), struct()) :: :ok
  defdelegate broadcast(topic, payload), to: Minga.Core.Events.Bus

  # ── Buffer Access (convenience delegates) ───────────────────────────

  @doc "Lists all open buffers with metadata."
  @spec list_buffers() :: [Minga.Core.Buffer.info()]
  defdelegate list_buffers(), to: Minga.Core.Buffer.Registry, as: :all_info

  @doc "Returns buffer content by path or pid."
  @spec buffer_content(String.t() | pid()) :: {:ok, String.t()} | {:error, :not_found}
  defdelegate buffer_content(path_or_pid), to: Minga.Core.Buffer
end
```

### 4.3 Tools Replace Commands as the Primary Abstraction

In the original Minga, the `Command` struct was the fundamental unit of action:

```elixir
# Old: commands take editor state, return editor state
%Command{
  name: :save,
  execute: fn editor_state -> ... end
}
```

In the agentic-first Minga, the `Tool.Spec` is the fundamental unit:

```elixir
defmodule Minga.Agent.Tool.Spec do
  @moduledoc """
  A tool specification: the atomic unit of action in Minga.

  Tools are stateless functions with typed inputs and outputs. Both
  agents and human UIs invoke the same tools through the same path.
  The schema enables self-description (LLMs discover capabilities
  programmatically) and validation (bad arguments are rejected before
  execution).
  """

  @enforce_keys [:name, :description, :parameter_schema, :callback]
  defstruct [
    :name,
    :description,
    :parameter_schema,
    :callback,
    :return_schema,
    destructive: false,
    requires_buffer: false,
    requires_project: false,
    category: :general,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    parameter_schema: map(),
    callback: (map() -> {:ok, term()} | {:error, term()}),
    return_schema: map() | nil,
    destructive: boolean(),
    requires_buffer: boolean(),
    requires_project: boolean(),
    category: :buffer | :file | :git | :lsp | :shell | :runtime | :general,
    metadata: map()
  }
end
```

**Why tools, not commands?**

Commands are editor state transformers: `state -> state`. They assume a running editor with modes, visual selections, and a render pipeline. An agent running headless has none of these.

Tools are stateless functions: `args -> result`. They validate against a JSON Schema, execute against the core runtime, and return a structured result. An agent, a CLI, a web API, and an editor command can all call the same tool.

Editor-specific commands (vim mode transitions, visual selection, cursor movement) still exist in the editor client. They are NOT tools. They are presentation-layer concerns that live in Layer 3.

**The relationship between tools and editor commands:**

```
Agent sends prompt
  → LLM returns tool_call("buffer_edit", {path, old_text, new_text})
    → Tool.Executor validates args against schema
      → Tool callback calls Buffer.Server.find_and_replace/3
        → Buffer emits :buffer_changed event
          → Editor client (subscribed) re-renders

User presses "dd" in the editor
  → Vim mode FSM produces :delete_line command
    → Editor command handler calls execute_tool("buffer_edit", ...)
      → Same tool, same path, same events
```

The convergence point is the tool. Both paths go through it.

---

## 5. Layer 2: API Gateway

The API Gateway makes "BYO UX" possible. It translates between network protocols and Elixir function calls to Layers 0 and 1.

### 5.1 Module Map

```
lib/minga/gateway/
  server.ex               # Top-level gateway supervisor
  websocket/
    handler.ex            # WebSocket connection handler
    session.ex            # Per-connection state (auth, subscriptions)
    encoder.ex            # Elixir terms → JSON
    decoder.ex            # JSON → validated Elixir terms
  jsonrpc/
    handler.ex            # JSON-RPC over stdio (for CLI tools, VS Code ext)
    codec.ex              # JSON-RPC 2.0 encoding/decoding
  port/
    handler.ex            # Binary Port protocol (for native frontends)
    protocol.ex           # Length-prefixed binary encoder/decoder
    gui_protocol.ex       # GUI-specific chrome opcodes
  distribution/
    handler.ex            # Erlang distribution (for multi-node setups)
  auth/
    token.ex              # Bearer token validation
    session.ex            # Client session management
  streaming/
    broadcaster.ex        # Fan-out events to subscribed clients
```

### 5.2 Protocol Design

All protocols expose the same capabilities. The Gateway translates between wire format and internal calls.

**Request types (client → server):**

| Method | Parameters | Description |
|---|---|---|
| `tool.execute` | `{tool, args, opts}` | Execute a tool |
| `tool.list` | `{}` | List available tools with schemas |
| `session.start` | `{provider, model, opts}` | Start an agent session |
| `session.prompt` | `{session_id, text}` | Send a prompt to a session |
| `session.abort` | `{session_id}` | Abort the current operation |
| `session.list` | `{}` | List active sessions |
| `buffer.list` | `{}` | List open buffers |
| `buffer.content` | `{path_or_id}` | Get buffer content |
| `events.subscribe` | `{topics}` | Subscribe to event topics |
| `events.query` | `{filters}` | Query the event log |
| `runtime.describe` | `{}` | Get capability description |
| `runtime.eval` | `{code}` | Evaluate Elixir code |
| `runtime.health` | `{}` | System health check |

**Event types (server → client, streaming):**

| Event | Payload | Description |
|---|---|---|
| `agent.streaming` | `{session_id, delta}` | Streaming text from LLM |
| `agent.tool_call` | `{session_id, tool, args}` | Agent is calling a tool |
| `agent.tool_result` | `{session_id, tool, result}` | Tool execution completed |
| `agent.status` | `{session_id, status}` | Session status change |
| `agent.approval_needed` | `{session_id, tool, args}` | Destructive tool needs approval |
| `buffer.changed` | `{path, delta, source}` | Buffer content changed |
| `buffer.saved` | `{path}` | Buffer written to disk |
| `diagnostics.updated` | `{uri, diagnostics}` | LSP diagnostics changed |
| `git.status_changed` | `{root, entries}` | Git status changed |
| `process.restarted` | `{name, reason}` | Supervised process restarted |

### 5.3 WebSocket as the Primary Protocol

WebSocket is the recommended protocol for new clients. It supports bidirectional streaming (essential for agent events), is widely supported across languages, and works through firewalls and proxies.

```
Client                          Minga Gateway
  │                                    │
  │── WS connect + auth token ────────→│
  │←── connection_ack {capabilities} ──│
  │                                    │
  │── events.subscribe ["agent.*"] ───→│
  │←── subscription_ack ──────────────│
  │                                    │
  │── session.start {anthropic, ...} ─→│
  │←── session.started {id: "abc"} ───│
  │                                    │
  │── session.prompt {id, "Fix bug"} ─→│
  │←── agent.streaming {id, "Let "} ──│
  │←── agent.streaming {id, "me "} ───│
  │←── agent.tool_call {id, edit} ────│
  │←── agent.tool_result {id, ok} ────│
  │←── agent.streaming {id, "Done"} ──│
  │←── agent.status {id, :idle} ──────│
```

### 5.4 Binary Port Protocol (for native frontends)

The existing binary Port protocol (`{:packet, 4}` length-prefixed, opcode-based) is preserved for native frontends (Swift, GTK4, Zig) where low latency matters. It carries render commands (display list frames) and input events. The Gateway translates between Port messages and internal events.

A native frontend connects via stdin/stdout of a spawned Port process (the existing pattern) or via a connected-mode fd (the GUI-launches-BEAM pattern).

The Port protocol is a specialized, performance-optimized path for rendering. It is NOT the general API. A Swift frontend uses both: the Port protocol for real-time rendering, and WebSocket (or in-process calls) for tool execution and agent interaction.

---

## 6. Layer 3: Clients

Clients are external programs that connect through the API Gateway. Minga ships a reference editor client. Others are third-party.

### 6.1 Reference Editor Client (macOS, TUI)

The editor is a rich client, not the core. It connects to Minga's runtime (either in-process via Elixir calls, or over the network via WebSocket) and handles:

- Input dispatch (keyboard, mouse)
- Vim mode FSM (normal, insert, visual, operator-pending, command)
- Rendering pipeline (display list IR, protocol encoding)
- Layout computation (window splits, tab bar, file tree, panels)
- Chrome (modeline, which-key, picker, completion menu)
- Shell behaviour (Traditional tab-based, Board card-based)

The editor owns NO state from Layers 0 or 1. It reads buffer content through the API. It applies edits through tools. It subscribes to events for reactive updates. If the editor process crashes, all buffers, agent sessions, and config survive.

```elixir
defmodule Minga.Editor do
  @moduledoc """
  Reference editor client. A GenServer that holds presentation state
  and delegates all core operations through the Agent Runtime API.
  """

  use GenServer

  # Editor state is ONLY presentation concerns
  defstruct [
    :port_manager,       # Frontend process handle
    :layout,             # Computed UI layout
    :theme,              # Active color theme
    :vim_state,          # Vim mode FSM state
    :shell,              # Active shell module
    :shell_state,        # Shell presentation state
    :capabilities,       # Frontend capabilities
    :render_timer,       # Debounced render timer
    :event_subscriptions # Active event subscriptions
  ]

  # The editor calls tools, not internal GenServers
  def handle_info({:key_event, codepoint, modifiers}, state) do
    {commands, vim_state} = VimFSM.process_key(state.vim_state, codepoint, modifiers)
    state = %{state | vim_state: vim_state}
    state = execute_commands(state, commands)
    {:noreply, schedule_render(state)}
  end

  defp execute_commands(state, commands) do
    Enum.reduce(commands, state, fn
      {:delete_line, _}, state ->
        # Editor calls a tool, not a buffer GenServer directly
        Minga.Agent.Runtime.execute_tool("buffer_edit", %{...})
        state

      {:insert_char, char}, state ->
        Minga.Agent.Runtime.execute_tool("buffer_insert", %{char: char})
        state

      # Presentation-only commands stay in the editor
      :toggle_file_tree, state ->
        update_layout(state, :toggle_file_tree)
    end)
  end
end
```

### 6.2 Third-Party Client Examples

**CLI agent runner:**
```bash
# Connect to a running Minga instance, start an agent session
minga-cli session start --provider anthropic --model claude-sonnet-4-20250514
minga-cli prompt "Refactor the auth module to use Guardian"
minga-cli events follow --session abc123
```

**VS Code extension:**
```typescript
// Connect via WebSocket, expose Minga tools as VS Code commands
const ws = new WebSocket("ws://localhost:4840/api");
ws.send(JSON.stringify({method: "session.start", params: {...}}));
ws.on("message", (msg) => {
  const event = JSON.parse(msg);
  if (event.type === "buffer.changed") {
    // Apply the edit delta to the VS Code document
    applyDelta(event.payload);
  }
});
```

**Web dashboard:**
```javascript
// React app showing agent sessions, buffer status, process tree
useEffect(() => {
  const ws = new WebSocket("ws://localhost:4840/api");
  ws.send(JSON.stringify({method: "events.subscribe", params: {topics: ["agent.*"]}}));
  ws.onmessage = (msg) => setEvents(prev => [...prev, JSON.parse(msg.data)]);
}, []);
```

---

## 7. Supervision Tree

The supervision tree reflects the layer hierarchy. Core starts first, Agent Runtime second, Gateway third, Editor (optional) fourth.

```
Minga.Supervisor (rest_for_one)
├── Minga.Core.Supervisor (rest_for_one)
│   ├── Minga.Core.Foundation.Supervisor (rest_for_one)
│   │   ├── Minga.Core.Language.Registry
│   │   ├── Minga.Core.Events.Bus (Registry, :duplicate)
│   │   ├── Minga.Core.Events.Recorder
│   │   ├── Minga.Core.Config.Options
│   │   ├── Minga.Core.Config.Hooks
│   │   ├── Minga.Core.Config.Advice
│   │   └── Minga.Core.Language.Filetype.Registry
│   ├── Minga.Core.Buffer.Registry (ETS, path→pid with refcounts)
│   ├── Minga.Core.Buffer.Supervisor (DynamicSupervisor, one_for_one)
│   ├── Minga.Core.Services.Supervisor (one_for_one)
│   │   ├── Minga.Core.Git.Tracker
│   │   ├── Minga.Core.Diagnostics.Store
│   │   ├── Minga.Core.LSP.Supervisor (DynamicSupervisor)
│   │   │   ├── LSP Client: elixir-ls
│   │   │   └── LSP Client: lua-ls
│   │   ├── Minga.Core.LSP.SyncServer
│   │   ├── Minga.Core.Project
│   │   └── Minga.Core.Parser.Manager
│   └── Minga.Core.Extension.Supervisor
│       ├── Minga.Core.Extension.Registry
│       └── (loaded extension processes)
│
├── Minga.Agent.Supervisor (one_for_one)
│   ├── Minga.Agent.Tool.Registry (ETS, tool_name→spec)
│   ├── Minga.Agent.Memory.Store
│   ├── Minga.Agent.SessionManager
│   ├── Minga.Agent.Session.Supervisor (DynamicSupervisor)
│   │   ├── Session "abc" (refactoring)
│   │   │   ├── Session GenServer
│   │   │   ├── Provider GenServer (Native/RPC)
│   │   │   └── (Buffer.Fork processes, if any)
│   │   └── Session "def" (tests)
│   │       ├── Session GenServer
│   │       └── Provider GenServer
│   ├── Minga.Agent.Workflow.Supervisor (DynamicSupervisor)
│   │   └── (active workflow orchestrators)
│   └── Minga.Agent.Introspection.ProcessObserver
│
├── Minga.Gateway.Supervisor (one_for_one)
│   ├── Minga.Gateway.WebSocket.Listener (Bandit/Cowboy)
│   ├── Minga.Gateway.Streaming.Broadcaster
│   └── Minga.Gateway.Auth.SessionStore
│
├── Minga.Editor.Supervisor (one_for_one, OPTIONAL)
│   ├── Minga.Editor.Watchdog
│   ├── Minga.Editor.FileWatcher
│   ├── Minga.Frontend.Manager (Port to Swift/Zig)
│   └── Minga.Editor (presentation GenServer)
│
└── Minga.SystemObserver (always-on process health monitor)
```

**Key differences from original Minga:**

1. Agent.Supervisor is a peer of Core.Supervisor, not a child of Services.
2. The Editor is optional. The runtime functions without it.
3. Buffer.Supervisor is under Core, not under the Editor.
4. The Gateway is its own supervisor tier.
5. Each agent session has its own sub-supervision tree (session + provider + forks).

---

## 8. Data Structures and Protocols

### 8.1 Core Structs

**Buffer.Document** (pure data structure, Layer 0):
```elixir
defmodule Minga.Core.Buffer.Document do
  @moduledoc """
  Gap buffer for text storage. Pure data, no GenServer.

  All operations are pure functions: Document in, Document out.
  The GenServer (Buffer.Server) wraps this with file I/O and eventing.
  """

  @enforce_keys [:before, :after]
  defstruct [:before, :after, line_count: 1, byte_size: 0]

  @type t :: %__MODULE__{
    before: binary(),
    after: binary(),
    line_count: pos_integer(),
    byte_size: non_neg_integer()
  }

  @type position :: {line :: non_neg_integer(), col :: non_neg_integer()}

  @spec new(String.t()) :: t()
  @spec insert_char(t(), String.t()) :: t()
  @spec insert_text(t(), String.t()) :: t()
  @spec delete_before(t()) :: t()
  @spec delete_after(t()) :: t()
  @spec move_cursor(t(), position()) :: t()
  @spec content(t()) :: String.t()
  @spec line(t(), non_neg_integer()) :: String.t()
  @spec line_count(t()) :: pos_integer()
  @spec cursor(t()) :: position()
  @spec slice(t(), position(), position()) :: String.t()
end
```

**EditDelta** (incremental edit descriptor):
```elixir
defmodule Minga.Core.Buffer.EditDelta do
  @enforce_keys [:range_start, :range_end, :text, :range_length]
  defstruct [:range_start, :range_end, :text, :range_length]

  @type position :: {non_neg_integer(), non_neg_integer()}
  @type t :: %__MODULE__{
    range_start: position(),
    range_end: position(),
    text: String.t(),
    range_length: non_neg_integer()
  }
end
```

**EditSource** (provenance tagging):
```elixir
defmodule Minga.Core.Buffer.EditSource do
  @type t ::
    :user
    | {:agent, session_id :: String.t(), tool_call_id :: String.t()}
    | {:lsp, server_name :: atom()}
    | {:formatter, name :: String.t()}
    | :undo
    | :redo
    | :unknown

  @spec user() :: t()
  @spec agent(String.t(), String.t()) :: t()
  @spec lsp(atom()) :: t()
end
```

**Agent.Message** (conversation history):
```elixir
defmodule Minga.Agent.Message do
  @enforce_keys [:role, :content, :timestamp]
  defstruct [:role, :content, :timestamp, :tool_calls, :tool_results, :thinking, :usage]

  @type role :: :user | :assistant | :system | :tool_result
  @type t :: %__MODULE__{
    role: role(),
    content: String.t() | [content_part()],
    timestamp: DateTime.t(),
    tool_calls: [Minga.Agent.ToolCall.t()] | nil,
    tool_results: [tool_result()] | nil,
    thinking: String.t() | nil,
    usage: token_usage() | nil
  }
end
```

**Agent.ToolCall** (in-flight tool execution):
```elixir
defmodule Minga.Agent.ToolCall do
  @enforce_keys [:id, :tool_name, :args, :status]
  defstruct [:id, :tool_name, :args, :status, :result, :is_error, :started_at, :completed_at]

  @type status :: :pending | :executing | :completed | :error | :aborted
  @type t :: %__MODULE__{
    id: String.t(),
    tool_name: String.t(),
    args: map(),
    status: status(),
    result: String.t() | nil,
    is_error: boolean(),
    started_at: integer() | nil,
    completed_at: integer() | nil
  }

  @spec complete(t(), String.t()) :: t()
  @spec error(t(), String.t()) :: t()
  @spec abort(t()) :: t()
end
```

### 8.2 Protocols (Elixir Protocol Dispatch)

**Readable** (uniform text access):
```elixir
defprotocol Minga.Core.Editing.Text.Readable do
  @doc "Returns the text content as a string."
  @spec content(t()) :: String.t()
  def content(readable)

  @doc "Returns a single line by index."
  @spec line(t(), non_neg_integer()) :: String.t()
  def line(readable, index)

  @doc "Returns the total line count."
  @spec line_count(t()) :: pos_integer()
  def line_count(readable)

  @doc "Returns the cursor position."
  @spec cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def cursor(readable)
end
```

Implementations: `Buffer.Document`, `Buffer.Snapshot` (frozen point-in-time for agent reads).

---

## 9. Tool System

The tool system is the heart of the agentic-first architecture. Every stateful operation goes through a tool.

### 9.1 Tool Registry

ETS-backed, `read_concurrency: true`. Tools are registered at startup from built-in modules and at runtime via the API.

```elixir
defmodule Minga.Agent.Tool.Registry do
  use GenServer

  @doc "Looks up a tool by name."
  @spec lookup(String.t()) :: {:ok, Tool.Spec.t()} | :error

  @doc "Returns all registered tools."
  @spec all() :: [Tool.Spec.t()]

  @doc "Registers a new tool. Replaces if name already exists."
  @spec register(Tool.Spec.t()) :: :ok | {:error, :invalid_schema}

  @doc "Unregisters a tool by name."
  @spec unregister(String.t()) :: :ok

  @doc "Returns tools grouped by category."
  @spec by_category() :: %{atom() => [Tool.Spec.t()]}
end
```

### 9.2 Tool Executor

Validates arguments, checks approval policy, runs advice chain, executes callback, emits events.

```elixir
defmodule Minga.Agent.Tool.Executor do
  @doc """
  Executes a tool through the full pipeline:

  1. Look up tool spec in registry
  2. Validate args against JSON Schema
  3. Check approval policy (auto/ask/deny)
  4. Run :before advice chain
  5. Execute the tool callback (or :override advice)
  6. Run :after advice chain
  7. Emit tool_executed event
  8. Return result
  """
  @spec execute(String.t(), map(), keyword()) ::
    {:ok, term()} | {:error, term()} | {:needs_approval, Approval.t()}
  def execute(tool_name, args, opts \\ [])
end
```

### 9.3 Built-in Tools

Every tool follows the same pattern: a module that exports a `spec/0` (returns `Tool.Spec.t()`) and an `execute/1` (takes validated args map, returns `{:ok, result} | {:error, reason}`).

**Buffer tools** (route through Buffer.Server, not filesystem):

| Tool | Category | Destructive | Description |
|---|---|---|---|
| `buffer_read` | buffer | no | Read buffer content (live in-memory if open, falls back to disk) |
| `buffer_write` | buffer | yes | Write/overwrite a file (creates buffer if needed) |
| `buffer_edit` | buffer | yes | Find-and-replace exact text in a buffer |
| `buffer_multi_edit` | buffer | yes | Multiple edits in one atomic operation |
| `buffer_insert` | buffer | yes | Insert text at a position |

**File tools** (project-scoped filesystem operations):

| Tool | Category | Destructive | Description |
|---|---|---|---|
| `file_find` | file | no | Find files by name/glob |
| `file_search` | file | no | Search file contents (ripgrep) |
| `file_list` | file | no | List directory contents |

**Git tools:**

| Tool | Category | Destructive | Description |
|---|---|---|---|
| `git_status` | git | no | Show changed files |
| `git_diff` | git | no | Show unified diff |
| `git_log` | git | no | Show recent commits |
| `git_stage` | git | yes | Stage files |
| `git_commit` | git | yes | Create a commit |

**LSP tools:**

| Tool | Category | Destructive | Description |
|---|---|---|---|
| `lsp_diagnostics` | lsp | no | Get diagnostics for a file |
| `lsp_definition` | lsp | no | Go to definition |
| `lsp_references` | lsp | no | Find all references |
| `lsp_hover` | lsp | no | Get type info and docs |
| `lsp_symbols` | lsp | no | List symbols in file/workspace |
| `lsp_rename` | lsp | yes | Semantic rename |
| `lsp_code_actions` | lsp | conditional | List/apply code actions |

**Shell tools:**

| Tool | Category | Destructive | Description |
|---|---|---|---|
| `shell_exec` | shell | yes | Run a shell command |

**Runtime tools** (self-modification and introspection):

| Tool | Category | Destructive | Description |
|---|---|---|---|
| `runtime_describe` | runtime | no | Describe all capabilities |
| `runtime_register_tool` | runtime | yes | Register a new tool |
| `runtime_register_hook` | runtime | yes | Register a lifecycle hook |
| `runtime_eval` | runtime | yes | Evaluate Elixir in the VM |
| `runtime_process_tree` | runtime | no | Inspect supervision tree |
| `runtime_buffers` | runtime | no | List all open buffers |
| `runtime_sessions` | runtime | no | List all agent sessions |
| `runtime_events` | runtime | no | Query the event log |
| `runtime_health` | runtime | no | System health check |

### 9.4 Tool Approval Pipeline

Destructive tools require approval before execution. The policy is configurable:

```elixir
# In config.exs
set :tool_approval, :destructive    # Ask for destructive tools (default)
set :tool_approval, :all            # Ask for all tools
set :tool_approval, :none           # Auto-approve everything

# Per-tool override
set :tool_approval_overrides, %{
  "shell_exec" => :always_ask,
  "buffer_edit" => :auto_approve,
  "git_commit" => :always_ask
}
```

When approval is needed, the executor returns `{:needs_approval, approval}` to the caller. The caller (agent session, API gateway) decides how to present the approval request. A GUI might show a dialog. A CLI might print a prompt. A headless runner might auto-approve based on policy.

---

## 10. Self-Description and Introspection

The killer feature of an agentic-first runtime: it can describe itself to an LLM.

### 10.1 Capability Description

When an LLM connects, it calls `runtime_describe` and gets:

```elixir
%{
  tools: [
    %{
      name: "buffer_edit",
      description: "Replace exact text in a buffer",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path relative to project root"},
          "old_text" => %{"type" => "string", "description" => "Exact text to find"},
          "new_text" => %{"type" => "string", "description" => "Replacement text"}
        },
        "required" => ["path", "old_text", "new_text"]
      },
      destructive: true,
      category: :buffer
    },
    # ... all registered tools
  ],
  event_types: [
    %{topic: :buffer_changed, fields: [:buffer, :source, :delta, :version]},
    %{topic: :agent_status, fields: [:session_id, :status]},
    # ...
  ],
  buffers: [
    %{path: "lib/app.ex", dirty: false, line_count: 42, filetype: :elixir},
    # ...
  ],
  sessions: [
    %{id: "abc", status: :idle, model: "claude-sonnet-4-20250514", message_count: 12},
    # ...
  ],
  health: %{
    uptime_seconds: 3600,
    process_count: 142,
    memory_mb: 48,
    supervisor_restarts: 0
  }
}
```

### 10.2 Process Observer

A GenServer that provides three tiers of introspection:

**Tier 1 (always-on):** Process.monitor on all named supervisors. Detects restarts and emits `:process_restarted` events. Negligible cost.

**Tier 2 (on-demand):** When a client requests the process tree, polls `Process.info/2` for memory, message_queue_len, and reductions on all processes under Minga.Supervisor. Returns a tree structure mirroring the supervision hierarchy with metrics at each node. Runs at most 1Hz to avoid overhead.

**Tier 3 (domain queries):** Application-level queries like "which agent sessions are active?", "which buffers are dirty?", "which LSP servers are connected?" These read from the existing registries and GenServers, not from process introspection.

### 10.3 Event Query

The Event Recorder (in Core) writes every event to a persistent ordered log (SQLite or compressed JSONL with configurable retention). The Event Query module (in Agent Runtime) provides filtered reads:

```elixir
# All buffer changes by agent "abc" in the last hour
Runtime.query_events(
  topic: :buffer_changed,
  source: {:agent, "abc", :_},
  since: DateTime.add(DateTime.utc_now(), -3600, :second)
)

# All tool executions that failed
Runtime.query_events(
  topic: :tool_executed,
  filter: fn e -> e.payload.status == :error end,
  limit: 50
)
```

---

## 11. Runtime Modification

Minga inherits Emacs's "living, mutable environment" philosophy through the BEAM. The runtime can be modified while it's running.

### 11.1 Register a New Tool

An LLM (or user) can define a new tool at runtime:

```elixir
# Via the runtime_register_tool tool
Runtime.execute_tool("runtime_register_tool", %{
  "name" => "count_todos",
  "description" => "Count TODO comments in a file",
  "parameter_schema" => %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string"}
    },
    "required" => ["path"]
  },
  "code" => """
  fn args ->
    path = args["path"]
    case File.read(path) do
      {:ok, content} ->
        count = content |> String.split("\\n") |> Enum.count(&String.contains?(&1, "TODO"))
        {:ok, "Found \#{count} TODOs in \#{path}"}
      {:error, reason} ->
        {:error, "Could not read \#{path}: \#{reason}"}
    end
  end
  """
})
```

The tool code is compiled via `Code.eval_string/1` into an anonymous function and registered in the Tool Registry. It's immediately available to all agents and clients. It persists for the lifetime of the VM (or until the runtime restarts). For persistence across restarts, it's saved to the config directory.

### 11.2 Register Hooks and Advice

```elixir
# Hook: run tests after every save of an Elixir file
Runtime.register_hook(:after_save, fn buffer_pid, path ->
  if String.ends_with?(path, ".ex") do
    Runtime.execute_tool("shell_exec", %{"command" => "mix test --failed"})
  end
end)

# Advice: log every git commit
Runtime.register_advice(:after, :git_commit, fn result ->
  IO.puts("Committed: #{inspect(result)}")
  result
end)
```

### 11.3 Hot Code Reload

The BEAM supports replacing running module code. The Editor client (or any client) can trigger a reload:

```elixir
# Recompile and reload a module
Runtime.execute_tool("runtime_eval", %{
  "code" => "r(Minga.Core.Buffer.Document)"
})
```

The BEAM maintains two versions of each module simultaneously. Running function calls complete on the old version; new calls use the updated version. This is the same mechanism that lets Erlang telecom systems upgrade without dropping calls.

### 11.4 Config Modification

```elixir
# Per-buffer options
Runtime.execute_tool("runtime_eval", %{
  "code" => """
  buffer = Minga.Core.Buffer.Registry.lookup("lib/app.ex")
  Minga.Core.Buffer.Server.set_option(buffer, :tab_width, 4)
  """
})

# Global options
Runtime.execute_tool("runtime_eval", %{
  "code" => "Minga.Core.Config.Options.set(:format_on_save, true)"
})
```

---

## 12. Buffer Architecture

Buffers are the core abstraction for code artifacts. Every file interaction goes through a buffer.

### 12.1 Buffer.Server (GenServer)

Each open file is a GenServer under `Buffer.Supervisor` (DynamicSupervisor). The server wraps a `Document` struct with file I/O, undo/redo, dirty tracking, edit deltas, and event broadcasting.

```elixir
defmodule Minga.Core.Buffer.Server do
  use GenServer

  # ── Client API ──

  @spec start_link(keyword()) :: GenServer.on_start()
  @spec content(server()) :: String.t()
  @spec line(server(), non_neg_integer()) :: String.t()
  @spec line_count(server()) :: pos_integer()
  @spec cursor(server()) :: Document.position()
  @spec dirty?(server()) :: boolean()
  @spec file_path(server()) :: String.t() | nil
  @spec filetype(server()) :: atom() | nil

  @spec insert_char(server(), String.t(), keyword()) :: :ok
  @spec insert_text(server(), String.t(), keyword()) :: :ok
  @spec delete_before(server(), keyword()) :: :ok
  @spec delete_after(server(), keyword()) :: :ok
  @spec move_cursor(server(), Document.position()) :: :ok

  @doc """
  Applies a list of text edits atomically. One GenServer call,
  one undo entry, one version bump. This is the primary API for
  programmatic editing (agent tools, LSP workspace edits, formatters).
  """
  @spec apply_text_edits(server(), [text_edit()], keyword()) :: :ok | {:error, term()}

  @doc """
  Find-and-replace: locates exact text and replaces it. Used by the
  buffer_edit tool. Returns error if text not found or ambiguous.
  """
  @spec find_and_replace(server(), String.t(), String.t(), boundary()) ::
    {:ok, EditDelta.t()} | {:error, term()}

  @spec save(server()) :: :ok | {:error, term()}
  @spec undo(server()) :: :ok | :nothing_to_undo
  @spec redo(server()) :: :ok | :nothing_to_redo

  @doc "Returns the buffer version (incremented on every edit)."
  @spec version(server()) :: non_neg_integer()

  @doc "Sets a buffer-local option."
  @spec set_option(server(), atom(), term()) :: :ok
end
```

Every edit:
1. Validates the operation
2. Applies it to the Document
3. Pushes an undo entry (with EditSource tagging)
4. Increments the version
5. Computes an EditDelta
6. Broadcasts `:buffer_changed` with the delta and source
7. If tree-sitter is active, sends the delta for incremental reparse

### 12.2 Buffer Registry (Global, Refcounted)

```elixir
defmodule Minga.Core.Buffer.Registry do
  @moduledoc """
  Global buffer registry. Maps file paths to buffer PIDs with reference
  counting. Buffers are shared resources, not owned by any single consumer.
  """

  @doc "Find or create a buffer for a path. Increments refcount."
  @spec ensure(String.t()) :: {:ok, pid()}

  @doc "Look up without creating. Does not change refcount."
  @spec lookup(String.t()) :: {:ok, pid()} | :error

  @doc "Decrement refcount. Stops the buffer when it reaches zero."
  @spec release(String.t()) :: :ok

  @doc "Returns metadata for all registered buffers."
  @spec all_info() :: [buffer_info()]

  @type buffer_info :: %{
    path: String.t(),
    pid: pid(),
    ref_count: pos_integer(),
    dirty: boolean(),
    line_count: pos_integer(),
    filetype: atom() | nil
  }
end
```

### 12.3 Buffer Forking (Multi-Agent)

When an agent session needs to edit files concurrently with the user or other agents, it forks the buffer:

```elixir
defmodule Minga.Core.Buffer.Fork do
  @moduledoc """
  A forked copy of a buffer for concurrent agent editing.

  The fork starts as a snapshot of the parent buffer's Document. The
  agent edits the fork freely. When done, the fork merges back via
  three-way merge (common ancestor + fork changes + parent changes
  since fork time).
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()

  @doc "Fork a buffer. Returns the fork's pid."
  @spec fork(parent :: pid(), session_id :: String.t()) :: {:ok, pid()}

  @doc "Merge the fork back into the parent."
  @spec merge(fork :: pid()) :: :ok | {:conflict, [hunk()]}

  @doc "Discard the fork without merging."
  @spec discard(fork :: pid()) :: :ok

  @doc "Returns the diff between the fork and its common ancestor."
  @spec diff(fork :: pid()) :: [hunk()]
end
```

The fork is a separate GenServer supervised under the agent session's tree. If the session crashes, the fork is cleaned up automatically.

Three-way merge uses `List.myers_difference/2` (same algorithm as `Git.Diff`):
1. Diff common ancestor vs fork (what the agent changed)
2. Diff common ancestor vs current parent (what the user changed)
3. Non-overlapping regions: apply both
4. Overlapping regions: conflict, present for review

---

## 13. Event System

The event system is the nervous system. Every state change produces an observable event. Every component can subscribe.

### 13.1 Event Bus

Registry-backed pub/sub. Typed struct payloads with `@enforce_keys`.

```elixir
defmodule Minga.Core.Events.Bus do
  @doc "Subscribe the calling process to a topic."
  @spec subscribe(topic()) :: :ok

  @doc "Subscribe with metadata (for filtered dispatch)."
  @spec subscribe(topic(), term()) :: :ok

  @doc "Broadcast a typed payload to all subscribers."
  @spec broadcast(topic(), struct()) :: :ok

  @doc "Unsubscribe from a topic."
  @spec unsubscribe(topic()) :: :ok
end
```

### 13.2 Event Topics

| Topic | Payload | Source |
|---|---|---|
| `:buffer_changed` | `{buffer, source, delta, version}` | Buffer.Server |
| `:buffer_saved` | `{buffer, path}` | Buffer.Server |
| `:buffer_opened` | `{buffer, path}` | Buffer.Registry |
| `:buffer_closed` | `{buffer, path}` | Buffer.Registry |
| `:agent_status` | `{session_id, old_status, new_status}` | Agent.Session |
| `:agent_streaming` | `{session_id, delta}` | Agent.Provider |
| `:agent_tool_call` | `{session_id, tool_call}` | Agent.Session |
| `:agent_tool_result` | `{session_id, tool_call, result}` | Agent.Session |
| `:tool_executed` | `{tool_name, args, result, duration}` | Tool.Executor |
| `:diagnostics_updated` | `{uri, source}` | Diagnostics.Store |
| `:lsp_status` | `{name, status}` | LSP.Client |
| `:git_status_changed` | `{root, entries, branch}` | Git.Tracker |
| `:mode_changed` | `{old, new}` | Editor client |
| `:config_changed` | `{key, old_value, new_value}` | Config.Options |
| `:process_restarted` | `{name, pid, reason}` | SystemObserver |
| `:hook_registered` | `{event, function}` | Config.Hooks |
| `:tool_registered` | `{tool_name, spec}` | Tool.Registry |
| `:extension_loaded` | `{name, version}` | Extension.Registry |

### 13.3 Event Recorder

Writes every event to persistent storage for query and replay.

```elixir
defmodule Minga.Core.Events.Recorder do
  use GenServer

  @type recorded_event :: %{
    id: pos_integer(),
    topic: atom(),
    payload: term(),
    timestamp: DateTime.t(),
    source: term()
  }

  @doc "Query recorded events with filters."
  @spec query(keyword()) :: [recorded_event()]
  # Filters: topic, source, since, until, limit, offset

  @doc "Returns event count per topic (for dashboards)."
  @spec counts_by_topic(keyword()) :: %{atom() => non_neg_integer()}
end
```

Storage: SQLite via `Exqlite` for structured queries. One table, indexed on `(topic, timestamp)` and `(source, timestamp)`. Configurable retention (default: 90 days). Older events are pruned by a periodic Task.

---

## 14. Configuration System

Real Elixir config files, not YAML. Typed options with per-context overrides.

### 14.1 Config File

`~/.config/minga/config.exs`:

```elixir
use Minga.Core.Config

# Global options
set :format_on_save, true
set :tab_width, 2
set :theme, :doom_one

# Per-filetype overrides
for_filetype :go do
  set :tab_width, 8
  set :indent_with, :tabs
end

for_filetype :python do
  set :tab_width, 4
end

# Agent configuration
set :default_provider, :anthropic
set :default_model, "claude-sonnet-4-20250514"
set :tool_approval, :destructive

# Hooks
on :after_save, fn _buffer, path ->
  if String.ends_with?(path, ".ex"), do: System.cmd("mix", ["format", path])
end

# Advice
advise :around, :buffer_edit, fn execute, args ->
  # Log all edits
  Minga.Core.Events.Bus.broadcast(:custom_edit_log, %{args: args})
  execute.(args)
end

# Custom tools
tool :count_lines, "Count lines in a file",
  params: %{"path" => %{"type" => "string"}},
  execute: fn args ->
    case File.read(args["path"]) do
      {:ok, content} -> {:ok, "#{length(String.split(content, "\n"))} lines"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

# Extensions
extension :minga_org, path: "~/.config/minga/extensions/minga-org"
extension :copilot, hex: "minga_copilot", version: "~> 0.1"

# Keybindings (editor client config, ignored by headless)
bind :normal, "SPC g s", :git_status, "Git status"
bind :normal, "SPC g d", :git_diff, "Git diff"
```

### 14.2 Options Store

ETS-backed with `read_concurrency: true`. Three resolution tiers:

1. **Buffer-local** (highest priority): per-process state in Buffer.Server
2. **Filetype defaults**: per-filetype overrides in Config.Options
3. **Global defaults**: base config in Config.Options

```elixir
defmodule Minga.Core.Config.Options do
  @spec get(option_name()) :: term()
  @spec get_for_filetype(option_name(), atom()) :: term()
  @spec set(option_name(), term()) :: :ok | {:error, :invalid_value}
  @spec set_for_filetype(atom(), option_name(), term()) :: :ok
end
```

### 14.3 Hooks

Lifecycle hooks run asynchronously under a TaskSupervisor. A slow or crashing hook never blocks editing.

```elixir
defmodule Minga.Core.Config.Hooks do
  @type event :: :after_save | :after_open | :on_mode_change | :on_buffer_close

  @spec register(event(), function()) :: :ok
  @spec run(event(), [term()]) :: :ok
end
```

### 14.4 Advice

Before/after/around/override advice on tools (replacing "commands" from the original).

```elixir
defmodule Minga.Core.Config.Advice do
  @type phase :: :before | :after | :around | :override

  @spec register(phase(), atom(), function()) :: :ok
  @spec wrap(atom(), function()) :: function()
end
```

The advice system uses ETS with `read_concurrency: true` for zero-contention reads on the hot path. Writes only happen at config load/reload.

---

## 15. Language Intelligence

LSP clients, tree-sitter parsing, diagnostics, and filetype detection. All live in Layer 0 and are consumed by both agents and editors.

### 15.1 LSP Client

One GenServer per language server, managed by a DynamicSupervisor.

```elixir
defmodule Minga.Core.LSP.Client do
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  @spec hover(server(), String.t(), position()) :: {:ok, hover()} | {:error, term()}
  @spec definition(server(), String.t(), position()) :: {:ok, [location()]} | {:error, term()}
  @spec references(server(), String.t(), position()) :: {:ok, [location()]} | {:error, term()}
  @spec completion(server(), String.t(), position()) :: {:ok, [completion_item()]} | {:error, term()}
  @spec diagnostics(server(), String.t()) :: {:ok, [diagnostic()]} | {:error, term()}
  @spec rename(server(), String.t(), position(), String.t()) :: {:ok, workspace_edit()} | {:error, term()}
  @spec code_actions(server(), String.t(), range()) :: {:ok, [code_action()]} | {:error, term()}
  @spec document_symbols(server(), String.t()) :: {:ok, [symbol()]} | {:error, term()}
  @spec workspace_symbols(server(), String.t()) :: {:ok, [symbol()]} | {:error, term()}
end
```

The LSP client communicates with the language server via JSON-RPC over stdio. Document sync uses incremental updates (`textDocument/didChange` with EditDeltas from the buffer).

### 15.2 Tree-sitter Parser

A separate OS process (Zig binary) managed via a Port. Grammars are compiled into the binary. The BEAM sends content, the parser returns highlight spans.

```elixir
defmodule Minga.Core.Parser.Manager do
  use GenServer

  @spec set_language(server(), String.t()) :: :ok
  @spec parse(server(), non_neg_integer(), String.t()) :: :ok
  @spec edit(server(), EditDelta.t()) :: :ok  # Incremental reparse
end
```

The parser process is shared across all consumers. Highlight spans are sent back via the Port protocol and cached in the buffer's associated state.

### 15.3 Diagnostics Store

Interval-tree-backed storage for LSP diagnostics, compiler warnings, and linter output.

```elixir
defmodule Minga.Core.Diagnostics.Store do
  use GenServer

  @spec publish(uri(), source(), [diagnostic()]) :: :ok
  @spec for_file(uri()) :: [diagnostic()]
  @spec for_range(uri(), range()) :: [diagnostic()]
  @spec clear(uri(), source()) :: :ok
end
```

---

## 16. Git Integration

Git operations via a backend behaviour (production shells out to git CLI, tests use an ETS stub).

### 16.1 Backend Behaviour

```elixir
defmodule Minga.Core.Git.Backend do
  @callback status(root :: String.t()) :: {:ok, [status_entry()]} | {:error, term()}
  @callback diff(root :: String.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback log(root :: String.t(), opts :: keyword()) :: {:ok, [commit()]} | {:error, term()}
  @callback stage(root :: String.t(), paths :: [String.t()]) :: :ok | {:error, term()}
  @callback commit(root :: String.t(), message :: String.t()) :: :ok | {:error, term()}
  @callback branch(root :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback show(root :: String.t(), ref :: String.t(), path :: String.t()) :: {:ok, String.t()} | {:error, term()}
end
```

### 16.2 Per-buffer Git Tracking

A `Git.Buffer` GenServer per open file computes the diff between HEAD and current content in pure Elixir (no shelling out). Produces a sign map for gutter rendering.

---

## 17. Extension System

Extensions are Elixir modules that hook into the runtime. They can register tools, hooks, advice, commands, and keybindings.

```elixir
defmodule Minga.Core.Extension.Registry do
  @spec register(atom(), keyword()) :: :ok
  @spec start(atom()) :: {:ok, pid()} | {:error, term()}
  @spec stop(atom()) :: :ok
  @spec list() :: [extension_info()]
end
```

Extensions are supervised under `Core.Extension.Supervisor`. A crashing extension is restarted without affecting the core.

Extension sources:
- **Path**: local directory containing a `mix.exs` with `Minga.Extension` use macro
- **Hex**: published package
- **Git**: repository URL

---

## 18. Agent Session Lifecycle

```
                    ┌──────┐
         start ───→│ idle │←───── prompt answered
                    └──┬───┘
                       │ send_prompt
                       ▼
                  ┌──────────┐
          ┌──────│ thinking  │──────┐
          │      └──────────┘      │
          │ tool_call               │ text response (no tools)
          ▼                         │
   ┌───────────────┐               │
   │tool_executing  │               │
   │ (may need     │               │
   │  approval)    │               │
   └───────┬───────┘               │
           │ tool_result            │
           ▼                        │
     ┌──────────┐                  │
     │ thinking  │←────────────────┘
     └──────────┘
           │ no more tool calls
           ▼
      ┌──────┐
      │ idle │
      └──────┘

  Any state can transition to :error on failure.
  abort() from any active state returns to :idle.
```

Each session is a GenServer holding:
- Conversation history (list of `Message.t()`)
- Provider reference (pid of the LLM backend)
- Status (`:idle`, `:thinking`, `:tool_executing`, `:error`)
- Token usage and cost tracking
- Active tool calls
- Pending approval (if a destructive tool needs consent)
- Edit boundaries (which files/regions the agent has touched)
- Subscribers (pids that receive events)

The session delegates LLM communication to the Provider and tool execution to the Tool.Executor. It's the coordination point, not the execution point.

---

## 19. Agent Provider Behaviour

Swappable LLM backends. Two built-in implementations.

```elixir
defmodule Minga.Agent.Provider do
  @callback start_link(keyword()) :: GenServer.on_start()
  @callback send_prompt(server(), String.t()) :: :ok | {:error, term()}
  @callback abort(server()) :: :ok
  @callback new_session(server()) :: :ok | {:error, term()}
  @callback get_state(server()) :: {:ok, session_state()} | {:error, term()}

  @optional_callbacks [
    get_available_models: 1,
    set_model: 2,
    cycle_model: 1,
    set_thinking_level: 2,
    cycle_thinking_level: 1
  ]
end
```

**Native provider** (`Minga.Agent.Providers.Native`): Runs entirely in the BEAM via ReqLLM. Supports Anthropic, OpenAI, Ollama, Groq, Bedrock, and any provider ReqLLM supports. Manages conversation context, handles streaming, executes tools locally. This is the primary provider.

**RPC provider** (`Minga.Agent.Providers.RPC`): Spawns an external process and communicates via JSON-RPC over stdio. Used to integrate CLI agents (like pi) as backends. The external process handles LLM calls and tool execution; Minga receives events.

Adding a new provider: implement the behaviour, register it in the provider resolver.

---

## 20. Multi-Agent Coordination

### 20.1 Concurrent Sessions

Multiple agent sessions run concurrently under `Agent.Session.Supervisor` (DynamicSupervisor). Each session is fully isolated. They share buffers through the Buffer.Registry (refcounted access) and communicate through the Event Bus (pub/sub).

### 20.2 Buffer Forking for Concurrent Edits

When two agents need to edit the same file:
1. Each agent forks the buffer via `Buffer.Fork.fork/2`
2. Each edits their fork independently (serialized through the fork's GenServer)
3. When done, each merges back via `Buffer.Fork.merge/1`
4. Non-overlapping changes merge automatically
5. Conflicts are surfaced for human review

### 20.3 Workflow Orchestration

Reusable multi-agent workflows for common patterns:

```elixir
defmodule Minga.Agent.Workflow.Orchestrator do
  @moduledoc """
  Coordinates multi-agent workflows. A workflow is a DAG of agent tasks
  with dependencies and data flow between them.
  """

  @type step :: %{
    id: String.t(),
    prompt: String.t(),
    depends_on: [String.t()],
    model: String.t() | nil,
    tools: [String.t()] | :all
  }

  @spec start(name :: String.t(), steps :: [step()]) :: {:ok, workflow_id :: String.t()}
  @spec status(workflow_id :: String.t()) :: workflow_status()
  @spec abort(workflow_id :: String.t()) :: :ok
end
```

Example workflow: "Review PR"
1. Agent A: read the diff, summarize the changes
2. Agent B: check for security issues (depends on A's summary)
3. Agent C: run the test suite
4. Orchestrator: combine results into a review

Each step spawns an agent session. Dependencies are resolved through the DAG. Results flow between steps via the orchestrator.

---

## 21. Frontend Protocol

The binary protocol between the BEAM and native frontends (Swift, Zig, GTK4) is preserved. It's a high-performance, low-latency path for real-time rendering.

### 21.1 Wire Format

`{:packet, 4}` framing: 4-byte big-endian length prefix, then 1-byte opcode, then opcode-specific fields.

### 21.2 Render Commands (BEAM → Frontend)

| Opcode | Name | Fields |
|---|---|---|
| 0x10 | draw_text | row:16, col:16, fg:24, bg:24, attrs:8, text:... |
| 0x11 | set_cursor | row:16, col:16 |
| 0x12 | clear | (none) |
| 0x13 | batch_end | (flush frame) |
| 0x15 | cursor_shape | shape:8 (block/beam/underline) |
| 0x70-0x78 | GUI chrome | Structured data for native widgets |

### 21.3 Input Events (Frontend → BEAM)

| Opcode | Name | Fields |
|---|---|---|
| 0x01 | key_press | codepoint:32, modifiers:8 |
| 0x02 | resize | width:16, height:16 |
| 0x03 | ready | width:16, height:16, capabilities |
| 0x04 | mouse_event | row:16, col:16, button:8, mods:8, type:8, clicks:8 |
| 0x07 | gui_action | action-specific structured data |

### 21.4 Display List IR

The BEAM produces a display list of styled text runs (not a cell grid). Each frontend translates to its native format:

```elixir
@type text_run :: {col :: non_neg_integer(), text :: String.t(), style :: style()}
@type display_line :: [text_run()]
@type window_frame :: %{
  rect: rect(),
  lines: %{row :: non_neg_integer() => display_line()},
  cursor: {row :: non_neg_integer(), col :: non_neg_integer()}
}
```

The TUI quantizes runs to terminal cells. The GUI renders runs with CoreText/Cairo at pixel positions.

---

## 22. Editor Client (Reference Implementation)

The editor is a Layer 3 client. It is a rich, feature-complete text editor with vim-style modal editing, but architecturally it's just one consumer of the runtime API.

### 22.1 What the Editor Owns (presentation only)

- Vim mode FSM (normal, insert, visual, operator-pending, command)
- Input dispatch (focus stack, keymap scopes)
- Rendering pipeline (display list, protocol encoding, frame scheduling)
- Layout computation (window splits, regions, chrome sizing)
- Chrome (tab bar, modeline, file tree, which-key, picker, completion menu)
- Mouse handling (click, drag, scroll, multi-click)
- Shell behaviour (Traditional tab-based, Board card-based)
- Editor-specific commands (mode transitions, visual selection, window management)

### 22.2 What the Editor Does NOT Own

- Buffer state (lives in Core, accessed via API/tools)
- Agent sessions (lives in Agent Runtime)
- LSP communication (lives in Core)
- Git operations (lives in Core)
- Config and options (lives in Core)
- Event bus (lives in Core)
- Tool registry and execution (lives in Agent Runtime)

### 22.3 Editor Commands vs Tools

Editor commands are presentation-layer state transformers. They do NOT go through the tool system because they operate on presentation state (modes, selections, layout) that only the editor understands.

```elixir
# These are editor commands (presentation only, NOT tools):
:enter_insert_mode
:enter_visual_mode
:toggle_file_tree
:split_window_horizontal
:next_tab
:open_picker
:which_key_show

# These are tool invocations (go through the tool system):
:save          → execute_tool("buffer_save", %{path: current_path})
:delete_line   → execute_tool("buffer_edit", %{path: ..., old_text: line, new_text: ""})
:format_buffer → execute_tool("shell_exec", %{command: formatter_cmd})
:git_stage     → execute_tool("git_stage", %{paths: [current_path]})
```

### 22.4 Native Frontends

**macOS (Swift/Metal):** SwiftUI for chrome (tab bar, file tree, status bar, popups). Metal for the text surface (GPU-accelerated glyph rasterization via CoreText). System font support, native trackpad gestures, accessibility.

**TUI (Zig/libvaxis):** Terminal renderer using libvaxis. Reads from /dev/tty (not stdin, which is the Port channel). Cell-level diffing for efficient terminal updates.

**Linux (GTK4, planned):** GTK4 widgets for chrome. Cairo or OpenGL for the text surface. Native Wayland/X11 integration.

---

## 23. Project Structure

```
minga/
├── lib/
│   └── minga/
│       ├── core/                    # Layer 0: Core Runtime
│       │   ├── buffer/
│       │   │   ├── document.ex      # Pure gap buffer
│       │   │   ├── server.ex        # GenServer wrapper
│       │   │   ├── registry.ex      # Global path→pid with refcounts
│       │   │   ├── fork.ex          # Forked buffer for concurrent editing
│       │   │   ├── edit_delta.ex
│       │   │   ├── edit_source.ex
│       │   │   ├── state.ex
│       │   │   └── supervisor.ex
│       │   ├── events/
│       │   │   ├── bus.ex           # Registry-backed pub/sub
│       │   │   ├── payloads.ex      # Typed event structs
│       │   │   └── recorder.ex      # Persistent event log
│       │   ├── config/
│       │   │   ├── options.ex       # ETS-backed option store
│       │   │   ├── hooks.ex         # Lifecycle hooks
│       │   │   ├── advice.ex        # Before/after/around/override
│       │   │   └── loader.ex        # Config file evaluation
│       │   ├── language/
│       │   │   ├── registry.ex
│       │   │   └── filetype.ex
│       │   ├── lsp/
│       │   │   ├── client.ex
│       │   │   ├── supervisor.ex
│       │   │   ├── sync_server.ex
│       │   │   └── workspace_edit.ex
│       │   ├── git/
│       │   │   ├── backend.ex       # Behaviour
│       │   │   ├── system.ex        # Production (shell out)
│       │   │   ├── stub.ex          # Test (ETS)
│       │   │   ├── tracker.ex
│       │   │   ├── diff.ex
│       │   │   └── buffer.ex
│       │   ├── project/
│       │   │   ├── root.ex
│       │   │   ├── file_find.ex
│       │   │   ├── search.ex
│       │   │   └── file_tree.ex
│       │   ├── editing/
│       │   │   ├── motion/          # Pure motion functions
│       │   │   ├── operator.ex      # Delete, change, yank
│       │   │   ├── text_object.ex   # iw, aw, i", etc.
│       │   │   ├── search.ex
│       │   │   ├── auto_pair.ex
│       │   │   ├── formatter.ex
│       │   │   ├── comment.ex
│       │   │   └── completion.ex
│       │   ├── diagnostics/
│       │   │   ├── store.ex
│       │   │   └── decorations.ex
│       │   ├── parser/
│       │   │   └── manager.ex       # Tree-sitter Port
│       │   ├── extension/
│       │   │   ├── registry.ex
│       │   │   └── supervisor.ex
│       │   ├── data/                # Pure data structures
│       │   │   ├── interval_tree.ex
│       │   │   ├── face.ex
│       │   │   ├── decorations.ex
│       │   │   ├── diff.ex
│       │   │   └── unicode.ex
│       │   ├── supervisor.ex        # Core supervision tree root
│       │   └── foundation/
│       │       └── supervisor.ex
│       │
│       ├── agent/                   # Layer 1: Agent Runtime
│       │   ├── runtime.ex           # Top-level API facade
│       │   ├── session.ex           # Conversation GenServer
│       │   ├── session_manager.ex   # Session lifecycle
│       │   ├── supervisor.ex
│       │   ├── provider.ex          # LLM backend behaviour
│       │   ├── providers/
│       │   │   ├── native.ex        # In-BEAM via ReqLLM
│       │   │   └── rpc.ex           # External process via JSON-RPC
│       │   ├── tool/
│       │   │   ├── registry.ex      # ETS-backed tool lookup
│       │   │   ├── spec.ex          # Tool specification struct
│       │   │   ├── executor.ex      # Validation + approval + execution
│       │   │   └── approval.ex      # Approval state machine
│       │   ├── tools/               # Built-in tool implementations
│       │   │   ├── buffer_read.ex
│       │   │   ├── buffer_write.ex
│       │   │   ├── buffer_edit.ex
│       │   │   ├── buffer_multi_edit.ex
│       │   │   ├── file_find.ex
│       │   │   ├── file_search.ex
│       │   │   ├── shell.ex
│       │   │   ├── git_status.ex
│       │   │   ├── git_diff.ex
│       │   │   ├── git_log.ex
│       │   │   ├── git_stage.ex
│       │   │   ├── git_commit.ex
│       │   │   ├── lsp_diagnostics.ex
│       │   │   ├── lsp_definition.ex
│       │   │   ├── lsp_references.ex
│       │   │   ├── lsp_hover.ex
│       │   │   ├── lsp_symbols.ex
│       │   │   ├── lsp_rename.ex
│       │   │   ├── lsp_code_actions.ex
│       │   │   ├── memory_write.ex
│       │   │   ├── runtime_describe.ex
│       │   │   ├── runtime_register_tool.ex
│       │   │   ├── runtime_register_hook.ex
│       │   │   ├── runtime_eval.ex
│       │   │   └── runtime_process_tree.ex
│       │   ├── workflow/
│       │   │   ├── orchestrator.ex
│       │   │   └── choreography.ex
│       │   ├── introspection/
│       │   │   ├── describer.ex
│       │   │   ├── process_observer.ex
│       │   │   └── event_query.ex
│       │   ├── memory/
│       │   │   └── store.ex
│       │   ├── message.ex
│       │   ├── tool_call.ex
│       │   ├── event.ex
│       │   ├── cost.ex
│       │   ├── compaction.ex
│       │   ├── config.ex
│       │   └── credentials.ex
│       │
│       ├── gateway/                 # Layer 2: API Gateway
│       │   ├── server.ex
│       │   ├── websocket/
│       │   │   ├── handler.ex
│       │   │   ├── session.ex
│       │   │   ├── encoder.ex
│       │   │   └── decoder.ex
│       │   ├── jsonrpc/
│       │   │   ├── handler.ex
│       │   │   └── codec.ex
│       │   ├── port/
│       │   │   ├── handler.ex
│       │   │   ├── protocol.ex
│       │   │   └── gui_protocol.ex
│       │   ├── auth/
│       │   │   ├── token.ex
│       │   │   └── session.ex
│       │   └── streaming/
│       │       └── broadcaster.ex
│       │
│       ├── editor/                  # Layer 3: Reference Editor Client
│       │   ├── editor.ex           # Presentation GenServer
│       │   ├── state.ex            # Presentation-only state
│       │   ├── vim_state.ex        # Vim mode FSM state
│       │   ├── mode/               # Vim modes
│       │   │   ├── normal.ex
│       │   │   ├── insert.ex
│       │   │   ├── visual.ex
│       │   │   ├── operator_pending.ex
│       │   │   └── command.ex
│       │   ├── input/              # Input dispatch
│       │   │   ├── handler.ex      # Behaviour
│       │   │   ├── router.ex       # Focus stack walk
│       │   │   └── ...handlers
│       │   ├── render/             # Rendering pipeline
│       │   │   ├── pipeline.ex
│       │   │   ├── display_list.ex
│       │   │   └── chrome/
│       │   ├── layout.ex           # UI layout computation
│       │   ├── viewport.ex         # Scroll state
│       │   ├── shell/              # Shell implementations
│       │   │   ├── traditional.ex
│       │   │   └── board.ex
│       │   ├── commands/           # Editor-specific commands
│       │   │   ├── movement.ex
│       │   │   ├── editing.ex
│       │   │   ├── ui.ex
│       │   │   └── ...
│       │   ├── keymap/             # Keybinding management
│       │   │   ├── bindings.ex
│       │   │   ├── defaults.ex
│       │   │   └── scope/
│       │   ├── frontend/           # Frontend adapter
│       │   │   ├── adapter.ex
│       │   │   ├── manager.ex
│       │   │   ├── capabilities.ex
│       │   │   └── protocol.ex
│       │   └── ui/                 # UI components
│       │       ├── theme.ex
│       │       ├── picker.ex
│       │       ├── which_key.ex
│       │       └── ...
│       │
│       ├── application.ex          # OTP Application entry point
│       ├── cli.ex                  # CLI entry point
│       ├── log.ex                  # Per-subsystem logging
│       ├── telemetry.ex            # Performance instrumentation
│       └── system_observer.ex      # Process health monitor
│
├── macos/                          # macOS Swift/Metal frontend
├── zig/                            # TUI + tree-sitter parser
├── test/                           # Mirrors lib/ structure
├── config/                         # Mix config
├── mix.exs
└── MINGA_REWRITE_FOR_AGENTS.md     # This file
```

---

## 24. Build Order

Build in layer order. Each phase is independently testable and shippable.

### Phase 1: Core Runtime (Weeks 1-4)

Build Layer 0. This is the foundation everything else depends on.

**Week 1: Data structures and buffer**
1. `Core.Buffer.Document` (gap buffer, pure functions)
2. `Core.Buffer.EditDelta` and `Core.Buffer.EditSource`
3. `Core.Buffer.Server` (GenServer with undo, dirty tracking, events)
4. `Core.Buffer.Supervisor` (DynamicSupervisor)
5. `Core.Buffer.Registry` (ETS, path→pid, refcounts)
6. Property-based tests for Document (StreamData)

**Week 2: Events and config**
1. `Core.Events.Bus` (Registry-backed pub/sub)
2. `Core.Events.Payloads` (typed structs)
3. `Core.Events.Recorder` (SQLite persistent log)
4. `Core.Config.Options` (ETS-backed, typed)
5. `Core.Config.Hooks` (lifecycle hooks)
6. `Core.Config.Advice` (before/after/around/override)
7. `Core.Config.Loader` (evaluate config.exs)

**Week 3: Language and project services**
1. `Core.Language.Registry` (language definitions)
2. `Core.Language.Filetype` (detection)
3. `Core.Diagnostics.Store` (interval tree)
4. `Core.Project.Root` (project detection)
5. `Core.Project.FileFind` (file finding)
6. `Core.Project.Search` (text search)
7. `Core.Parser.Manager` (tree-sitter Port)

**Week 4: LSP and Git**
1. `Core.LSP.Client` (JSON-RPC over stdio)
2. `Core.LSP.Supervisor` (DynamicSupervisor)
3. `Core.LSP.SyncServer` (document sync)
4. `Core.Git.Backend` (behaviour)
5. `Core.Git.System` (production, shell out)
6. `Core.Git.Stub` (test, ETS)
7. `Core.Git.Tracker` (repo status)
8. `Core.Git.Diff` (pure Elixir Myers diff)
9. `Core.Supervisor` (wire everything together)

**Milestone:** The core runtime starts, manages buffers, connects to LSP servers, tracks git status, and records events. No agents, no UI.

### Phase 2: Agent Runtime (Weeks 5-7)

Build Layer 1 on top of the core.

**Week 5: Tool system**
1. `Agent.Tool.Spec` (tool specification struct)
2. `Agent.Tool.Registry` (ETS-backed lookup)
3. `Agent.Tool.Executor` (validation, approval, advice, execution)
4. `Agent.Tool.Approval` (approval state machine)
5. All built-in tools (buffer_*, file_*, git_*, lsp_*, shell_*, runtime_*)
6. Tool tests (each tool tested in isolation)

**Week 6: Sessions and providers**
1. `Agent.Provider` (behaviour)
2. `Agent.Providers.Native` (ReqLLM integration)
3. `Agent.Message`, `Agent.ToolCall`, `Agent.Event` (data structs)
4. `Agent.Session` (GenServer, conversation lifecycle)
5. `Agent.SessionManager` (session CRUD)
6. `Agent.Session.Supervisor` (DynamicSupervisor)
7. `Agent.Compaction` (context window management)
8. `Agent.Cost` (token tracking)

**Week 7: Introspection and runtime modification**
1. `Agent.Introspection.Describer` (capability description)
2. `Agent.Introspection.ProcessObserver` (process tree metrics)
3. `Agent.Introspection.EventQuery` (event log queries)
4. `Agent.Runtime` (facade module)
5. Runtime tools (describe, register_tool, register_hook, eval, process_tree)
6. `Agent.Memory.Store` (persistent agent memory)

**Milestone:** An agent session can start, send prompts, execute tools against real buffers, track costs, and self-describe its capabilities. All headless, no UI needed.

### Phase 3: API Gateway (Weeks 8-9)

Build Layer 2. External clients can now connect.

**Week 8: WebSocket gateway**
1. `Gateway.WebSocket.Handler` (connection management)
2. `Gateway.WebSocket.Session` (per-connection state, auth)
3. `Gateway.WebSocket.Encoder`/`Decoder` (JSON serialization)
4. `Gateway.Streaming.Broadcaster` (fan-out events)
5. `Gateway.Auth.Token` (bearer token validation)
6. `Gateway.Server` (supervisor)

**Week 9: Additional protocols**
1. `Gateway.JsonRpc.Handler` (JSON-RPC over stdio)
2. `Gateway.Port.Handler` (binary Port protocol for native frontends)
3. `Gateway.Port.Protocol` (encoder/decoder, preserving current opcodes)
4. `Gateway.Port.GuiProtocol` (GUI chrome opcodes)

**Milestone:** External clients can connect via WebSocket or JSON-RPC, execute tools, subscribe to events, and interact with agent sessions.

### Phase 4: Reference Editor Client (Weeks 10-14)

Build the Layer 3 reference editor. This is the largest phase because it includes the full vim-style editing experience.

**Week 10: Core editor**
1. `Editor.State` (presentation-only state)
2. `Editor.VimState` and mode FSM (normal, insert, visual, op-pending, command)
3. `Editor.Input.Router` (focus stack dispatch)
4. `Editor.Viewport` (scroll management)
5. `Editor.Layout` (region computation)

**Week 11: Rendering**
1. `Editor.Render.DisplayList` (styled text runs IR)
2. `Editor.Render.Pipeline` (7-stage render pipeline)
3. `Editor.Frontend.Manager` (Port management)
4. `Editor.Frontend.Protocol` (binary encoding)

**Week 12: Chrome and UI**
1. Tab bar, modeline, file tree
2. Which-key popup
3. Picker (fuzzy finder)
4. Completion menu
5. Theme system

**Week 13: Editor commands and keybindings**
1. Movement commands
2. Operator commands (dd, cc, yy)
3. Buffer management (save, close, split)
4. LSP commands (hover, definition, references)
5. Git commands (status, diff, stage)
6. Keymap defaults (Doom Emacs style)

**Week 14: Integration and polish**
1. Mouse handling
2. Agent UI (chat panel, tool approval, streaming display)
3. File watcher integration
4. Session persistence
5. Integration tests

**Milestone:** A fully functional vim-style editor running on top of the agentic runtime. Identical editing experience to the original Minga, but architecturally the editor is just a client.

### Phase 5: Multi-Agent and Advanced Features (Weeks 15+)

1. `Core.Buffer.Fork` (buffer forking with three-way merge)
2. `Agent.Workflow.Orchestrator` (multi-agent coordination)
3. `Agent.Providers.RPC` (external process provider)
4. `Gateway.Distribution.Handler` (Erlang distribution for multi-node)
5. Extension system (extension loading, lifecycle, config)

---

## 25. Tech Stack and Dependencies

### Runtime
- **Elixir 1.19** / OTP 28
- **ReqLLM** for LLM API calls (Anthropic, OpenAI, Ollama, etc.)
- **Exqlite** for event recording (SQLite)
- **Bandit** for WebSocket server
- **JSON** for JSON encoding/decoding (standard library in Elixir 1.18+)

### Frontends
- **Swift 6 / Metal 3.1** for macOS GUI
- **Zig 0.15 / libvaxis** for TUI
- **GTK4** for Linux GUI (planned)

### Development
- **ExUnit** + **StreamData** for testing
- **Credo** for linting
- **Dialyxir** for static analysis

### Build
- **Mix** for Elixir
- **XcodeGen** for macOS project
- **Zig build system** for TUI and parser

---

## 26. Design Principles

### 1. Tools are the universal API

Every stateful operation is a tool. Both agents and humans go through the same path. No backdoors, no special cases, no "internal only" mutations.

### 2. The BEAM is the product

Process isolation, supervision, preemptive scheduling, hot code reload, distribution, introspection. These aren't implementation details. They're the features. The BEAM's properties become user-visible capabilities: self-healing, live introspection, runtime customization, concurrent agents.

### 3. Layers flow downward only

Layer 0 knows nothing about agents, UIs, or networks. Layer 1 knows nothing about rendering or input. Layer 2 knows nothing about specific clients. This is mechanically verifiable.

### 4. Presentation is a client concern

The editor doesn't own buffers, sessions, or config. It reads them through the API and subscribes to events for reactive updates. If the editor crashes, everything else survives.

### 5. Self-describing everything

Every tool has a JSON Schema. Every event has a typed struct. Every process is addressable and introspectable. An LLM should be able to discover and use the full runtime without prior knowledge.

### 6. Build it right or don't build it

No "V1 that skips known requirements." If a data structure needs to handle 10,000 entries, use the right algorithm from the start. If a system needs incremental updates, don't ship clear-and-reapply. Infrastructure foundations are built once, correctly.

### 7. Convention over configuration

Ship working defaults for everything. A fresh install with no config file should be immediately useful. Your config is a diff, not a manifest.

### 8. Fault tolerance over speed

Crashes are recoverable events, not catastrophes. Every component can fail independently and be restarted by its supervisor. Degraded service (no LSP, no git, no parser) is better than total failure.

---

## 27. What This Enables

### Day 1 capabilities

- Headless agent runner (no UI, just the runtime processing prompts and executing tools)
- Multiple concurrent agent sessions on the same project
- Full vim-style editor as a rich client
- Real-time event streaming to any connected client
- Runtime tool registration and hook installation
- Self-describing capability endpoint for LLM onboarding

### Near-term (builds on the foundation)

- Web dashboard for monitoring agent sessions
- VS Code extension using Minga as the agent backend
- Multi-agent workflows (review, refactor, test pipelines)
- Buffer forking for concurrent agent edits with three-way merge
- Edit provenance and selective undo ("undo everything agent X did")
- Ghost cursors showing agent edit positions in real-time

### Long-term (enabled by the BEAM)

- Distributed Minga across multiple machines (Erlang distribution)
- Multi-human collaborative editing (same message-passing primitives)
- Persistent edit history with temporal queries ("show me this file last Tuesday")
- Self-healing workflows (agent session crashes, supervisor restarts, workflow resumes)
- Hot code upgrade of the runtime without restarting (Erlang release upgrades)

---

## 28. Coding Standards

### Types and Specs

- `@spec` on every public function
- `@type` / `@typep` for all custom types
- `@enforce_keys` on structs for required fields
- Guards in function heads where they aid type inference
- Pattern matching over `if/cond`
- No `cond` blocks (use multi-clause functions)
- `mix compile --warnings-as-errors` must pass clean

### Module Organization

- One `defmodule` per file
- Entry-point modules are mostly `defdelegate` and `@spec`
- GenServer modules contain OTP callbacks and route to handler modules
- Each `handle_info`/`handle_call` clause is 1-3 lines
- Modules over 500 lines need decomposition

### State Ownership

Each struct has one module that constructs and updates it. Other modules may read fields but never do `%{thing | field: value}`. Add functions to the owning module instead.

### No Process.sleep

Never in production code. Use `Process.send_after/3`, GenServer state machines, or `receive` with `after` clauses.

### Commit Messages

```
type(scope): short description

Longer body if needed.
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`

---

## 29. Testing Strategy

### Test layers (lightest first)

1. **Pure functions:** Document operations, motions, text objects, diff. Direct calls with assertions. No GenServer.
2. **Single GenServer:** Buffer.Server insert, delete, undo. Start supervised, call, assert.
3. **Tool execution:** Each tool tested with mock buffers and stub git backend.
4. **Integration:** Full agent session sending prompts, executing tools, receiving events.
5. **Editor (optional):** EditorCase with HeadlessPort for presentation tests.

### Property-based tests

StreamData generators for Document operations (insert, delete, move, undo/redo). Invariants: content is always valid UTF-8, line_count matches actual newlines, cursor is always within bounds.

### Async by default

All tests `async: true` unless they mutate global state. Process isolation makes this safe.

### DI stubs for OS processes

Tests never shell out. `Git.Stub` (ETS-backed) replaces `Git.System`. Tool callbacks receive a project root pointing to a temp directory.

### Event-based synchronization

Tests subscribe to events and `assert_receive` instead of sleeping. `Minga.Core.Events.Bus.subscribe(:buffer_changed)` followed by `assert_receive {:minga_event, :buffer_changed, %{...}}`.

```bash
mix test              # Full suite
mix test --stale      # Only affected modules
mix test --failed     # Re-run failures
mix test test/minga/core/buffer/document_test.exs  # Single file
```
