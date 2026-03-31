# Minga V2: Agentic-First Editor Specification

A complete specification for building a BEAM-powered agentic code editor from scratch. This document is written so an LLM or engineering team with no prior context can build the entire system.

## Table of Contents

1. [Vision and Philosophy](#1-vision-and-philosophy)
2. [Architecture Overview](#2-architecture-overview)
3. [Tech Stack](#3-tech-stack)
4. [Process Architecture and Supervision](#4-process-architecture-and-supervision)
5. [The Conversation Surface](#5-the-conversation-surface)
6. [The Board: Multi-Agent Orchestration](#6-the-board-multi-agent-orchestration)
7. [Agent System](#7-agent-system)
8. [Buffer System](#8-buffer-system)
9. [Diff Review System](#9-diff-review-system)
10. [Editor Surface (Zoom View)](#10-editor-surface-zoom-view)
11. [Input System](#11-input-system)
12. [Rendering Architecture](#12-rendering-architecture)
13. [Port Protocol](#13-port-protocol)
14. [Syntax Highlighting Pipeline](#14-syntax-highlighting-pipeline)
15. [LSP Integration](#15-lsp-integration)
16. [Git Integration](#16-git-integration)
17. [Configuration and Extensions](#17-configuration-and-extensions)
18. [Frontend Implementations](#18-frontend-implementations)
19. [Project Structure](#19-project-structure)
20. [Coding Standards](#20-coding-standards)
21. [Testing Strategy](#21-testing-strategy)
22. [Build Order](#22-build-order)

---

## 1. Vision and Philosophy

### What Minga V2 Is

Minga V2 is an **agent that has an editor**, not an editor that has an agent. The primary interface is a conversation where you describe intent in natural language, the agent works, and you review and direct. The code editor is a tool you zoom into when you need precision, not the default view.

Think of it as the difference between a car with GPS and a GPS that can drive. Both have the same components. The relationship between them is what changes everything.

### Why This Matters

Today's agentic coding tools fall into two camps:

1. **Editors with bolt-on agents** (Cursor, Windsurf, Zed): The editor is the center. The agent is a sidebar or inline suggestion. All architecture decisions optimize for human typing speed. Agent features fight for screen real estate and event loop time with the editing experience.

2. **Standalone CLI agents** (Claude Code, Aider, pi): The agent is the center. But there's no editor. File operations go to disk. There's no undo, no live preview, no syntax-aware rendering of changes. When you need to read or edit code precisely, you switch to a separate tool.

Minga V2 sits in the gap: **an agent-first tool with a real editor built in**. The agent is the primary interface. The editor is available when you need it. Both share the same buffer system, the same process model, and the same rendering pipeline.

### Design Principles

These guide every decision. When two options are equally viable, pick the one that better serves these principles.

1. **Conversation-first.** The default view is a conversation with your active agent. File editing is a zoom-in from the conversation, not the other way around.

2. **Agents are first-class processes.** Each agent session is a supervised BEAM process with its own state, its own workspace, and its own lifecycle. Agents are not plugins bolted onto an editor; they are peers of the editor in the process hierarchy.

3. **Buffer-aware from day one.** Agent file edits route through the buffer system. Edits appear instantly, go on the undo stack, trigger tree-sitter updates, and support concurrent access via buffer forking. No agent tool touches the filesystem directly for files that have open buffers.

4. **Structured review over live editing.** When an agent makes changes, the user sees a structured diff (per-file, per-hunk, approve/reject/edit). This is the most polished flow in the product because it's what users do 80% of the time.

5. **Process isolation everywhere.** The BEAM's actor model is the foundation. Each buffer, each agent, each LSP client, each frontend runs as an independent process. Crashes are contained. The scheduler guarantees responsiveness. No God objects.

6. **GUI-first, TUI-capable.** Design for native GUI frontends (macOS Swift/Metal, Linux GTK4) first. The TUI is a capable fallback, not the primary target.

7. **Convention over configuration.** Ship working defaults for everything. A fresh install should feel productive immediately. User config is a diff from the defaults, not a manifest.

---

## 2. Architecture Overview

### Two Big Ideas

**Idea 1: The BEAM is the brain.** All state, all logic, all coordination lives in Elixir processes on the Erlang VM. The BEAM provides preemptive scheduling (your keystrokes are never starved by agent work), per-process garbage collection (a large buffer's GC doesn't pause the UI), supervision trees (crashes are contained and recovered), and message-passing isolation (no shared mutable state).

**Idea 2: Frontends are dumb renderers.** Platform-native frontends (Swift/Metal, GTK4, Zig/libvaxis) handle only rendering and input capture. They communicate with the BEAM over a binary protocol on stdin/stdout. They share no memory with the BEAM. If a frontend crashes, the BEAM restarts it and re-renders. All editor state survives.

### Process Map (High Level)

```
BEAM VM
├── Foundation Supervisor (config, events, keymaps, registries)
├── Buffer Supervisor (one GenServer per open file + git tracking)
├── Services Supervisor (LSP clients, extensions, diagnostics, project)
├── Agent Supervisor (one process tree per agent session)
│   ├── Agent.Session "refactoring task"
│   │   └── owns Workspace (buffers, windows, vim state)
│   ├── Agent.Session "test writing task"
│   │   └── owns Workspace (buffers, windows, vim state)
│   └── Agent.Session "code review"
│       └── owns Workspace (buffers, windows, vim state)
├── Orchestrator (coordinates views, manages active workspace, drives rendering)
│   ├── InputDispatcher (focus stack, key/mouse routing)
│   ├── WindowManager (layout, window tree, focus tracking)
│   └── RenderCoordinator (display list, pipeline, port communication)
└── Runtime Supervisor (port manager, parser, file watcher)

Frontend Process (Swift/Metal, GTK4, or Zig TUI)
└── Communicates via stdin/stdout binary protocol

Parser Process (Zig + tree-sitter)
└── Communicates via stdin/stdout binary protocol
```

The key structural difference from a traditional editor: agent sessions own their own workspaces. The Orchestrator is a thin coordinator that switches between workspaces, not a God object that holds everything.

### Data Flow

```
User types a prompt
    → InputDispatcher routes to conversation handler
    → Conversation handler sends to active Agent.Session
    → Agent.Session calls LLM provider
    → LLM responds with tool calls
    → Agent.Session executes tools (buffer edits, file reads, shell commands)
    → Buffer edits route through Buffer.Server (undo, tree-sitter, dirty tracking)
    → Agent.Session emits events (status change, new message, edit complete)
    → Orchestrator receives events, updates display
    → RenderCoordinator builds display list
    → Port.Manager encodes and sends to frontend
    → Frontend renders to screen

User reviews a diff
    → InputDispatcher routes to diff review handler
    → Hunk approve/reject updates the agent's workspace
    → Approved hunks apply to the canonical buffer
    → Rejected hunks are discarded
    → Agent.Session is notified of review outcome

User zooms into a file
    → Orchestrator switches to editor view
    → Full vim keybindings activate
    → Render pipeline shows buffer content with syntax highlighting
    → ESC or keybinding returns to conversation view
```

---

## 3. Tech Stack

| Component | Technology | Why |
|-----------|-----------|-----|
| Editor core | **Elixir 1.19+ / OTP 28+** | Actor model, supervision, preemptive scheduling, hot code reload |
| macOS frontend | **Swift 6 / Metal 3** | Native SwiftUI chrome, GPU text rendering, system integration |
| Linux frontend | **GTK4 / Cairo** | Native widgets, Wayland/X11, system theming |
| TUI frontend | **Zig 0.15+ / libvaxis** | Zero-overhead terminal rendering, compiles C natively |
| Tree-sitter parser | **Zig 0.15+** | Compiles C grammars natively, no FFI overhead, single binary |
| LLM communication | **ReqLLM** (Elixir) | Structured tool calling, streaming, multi-provider |
| Testing | **ExUnit + StreamData** | Property-based testing for data structures |
| Build | **Mix + Zig build + XcodeGen** | Elixir manages the overall build, delegates to native toolchains |

### Version Pinning

Pin all versions in `.tool-versions` (asdf):

```
elixir 1.19.5-otp-28
erlang 28.3.4.3
zig 0.15.0-dev
```

---

## 4. Process Architecture and Supervision

### Supervision Tree

The top-level supervisor uses `rest_for_one` strategy: if Foundation restarts, everything below it restarts (they depend on config and events). But a crash in Runtime doesn't touch Services, Buffers, or Foundation.

```
Minga.Supervisor (rest_for_one)
├── Foundation.Supervisor (one_for_one)
│   ├── Minga.Events                    # PubSub for internal events
│   ├── Minga.Config.Options            # Typed option registry
│   ├── Minga.Keymap.Active             # Live merged keymap
│   ├── Minga.Config.Hooks              # Lifecycle hook registry
│   ├── Minga.Config.Advice             # Before/after command advice (ETS)
│   ├── Minga.Language.Registry         # Filetype detection, grammar mapping
│   └── Minga.Command.Registry          # Named command lookup
│
├── Buffer.Supervisor (DynamicSupervisor, one_for_one)
│   ├── Buffer.Server "main.ex"         # One process per open file
│   ├── Buffer.Server "router.ex"
│   ├── Buffer.Fork "main.ex:agent-1"   # Agent's forked copy
│   ├── Git.Buffer "main.ex"            # Per-buffer git tracking
│   └── Git.Buffer "router.ex"
│
├── Services.Supervisor (one_for_one)
│   ├── Git.Tracker                     # Project-level git state
│   ├── Diagnostics                     # Source-agnostic diagnostic aggregator
│   ├── LSP.Supervisor (DynamicSupervisor)
│   │   ├── LSP.Client :elixir_ls      # One per language server
│   │   └── LSP.Client :typescript
│   ├── Extension.Registry
│   ├── Extension.Supervisor (DynamicSupervisor)
│   └── Project                         # Project root, file finder
│
├── Agent.Supervisor (DynamicSupervisor, one_for_one)
│   ├── Agent.Session "task-1"          # Each session owns its workspace
│   ├── Agent.Session "task-2"
│   └── Agent.Session "task-3"
│
└── Runtime.Supervisor (rest_for_one)
    ├── FileWatcher
    ├── Parser.Manager                  # Manages tree-sitter Zig port
    ├── Port.Manager                    # Manages frontend port
    ├── InputDispatcher                 # Focus stack, key/mouse routing
    ├── WindowManager                   # Layout, window tree
    ├── RenderCoordinator               # Display list, render pipeline
    └── Orchestrator                    # Active workspace, view switching
```

### Why This Structure

Each tier is isolated so crashes don't cascade:

- **Foundation** rarely fails. Config, events, and registries are simple.
- **Buffers** are independent. One buffer crashing doesn't affect others. Your undo history, cursor positions, and unsaved changes survive any crash above them.
- **Services** are independent. An LSP client crashing doesn't affect editing. Git tracking crashing doesn't affect anything except gutter signs.
- **Agents** are independent. An agent session crashing doesn't affect other agents or the editor. The supervisor restarts it and the conversation continues.
- **Runtime** is the tightly-coupled group: rendering, input, orchestration. If the frontend port dies, the Orchestrator restarts it and re-renders. Buffer state is untouched.

### Process Responsibilities

#### Orchestrator

The thin coordinator that manages which view is active and routes events between subsystems. It does NOT hold editor state (that's on the active workspace). It does NOT hold rendering state (that's on RenderCoordinator). It does NOT process input (that's on InputDispatcher).

Responsibilities:
- Track the active view (Board grid, conversation, editor zoom, diff review)
- Track the active workspace (which agent session or manual workspace is focused)
- Handle view transitions (zoom in/out, switch agent, open diff review)
- Forward events between Agent.Session and RenderCoordinator

State: `active_view`, `active_workspace_ref`, `board_state`, `theme`.

#### InputDispatcher

Owns the focus stack and routes all input events (keyboard, mouse, GUI actions) to the appropriate handler.

Responsibilities:
- Maintain an ordered stack of input handler modules
- Walk the stack on each input event until one handler claims it
- Run post-action housekeeping (completion triggers, LSP updates)
- Push/pop handlers as UI modes change (picker open, diff review, etc.)

State: `focus_stack`, `pending_key_sequence`.

#### WindowManager

Owns the layout tree and window focus.

Responsibilities:
- Compute layout rectangles for all UI regions (editor, gutter, status bar, panels)
- Manage window splits and tabs within the editor zoom view
- Track which window has focus
- Provide hit-testing for mouse events (`which region contains row, col?`)

State: `window_tree`, `layout_cache`, `focused_window`.

#### RenderCoordinator

Owns the display list and drives the render pipeline.

Responsibilities:
- Build the display list from the active view's state
- Run the render pipeline stages (layout, content, chrome, compose, emit)
- Encode render commands and send to Port.Manager
- Track dirty regions for incremental rendering
- Rate-limit renders (coalesce rapid state changes into single frames)

State: `display_list`, `dirty_regions`, `render_timer`, `capabilities`.

### Why Split the Editor GenServer?

In V1, a single Editor GenServer (2,137 lines, 30+ sub-structs in state) processes every keystroke, every agent event, every render frame, every mouse click. This serializes all work through one mailbox, defeating the BEAM's concurrency model.

By splitting into four processes:
- InputDispatcher can process a keystroke while RenderCoordinator encodes the previous frame.
- Agent events can update the Orchestrator's view state while WindowManager computes layout.
- Mouse events route through InputDispatcher without waiting for a render cycle.
- Each process has a focused, small state struct instead of one massive nested state.

Communication between these processes uses GenServer calls for synchronous queries (WindowManager.layout/0) and casts/sends for fire-and-forget notifications (Orchestrator notifying RenderCoordinator that state changed).

---

## 5. The Conversation Surface

This is the default view. When you launch Minga V2, you see this.

### Layout

```
┌─────────────────────────────────────────────────────┐
│  Minga  │ agent-1: refactor auth │ agent-2: tests   │  ← Tab bar (agent sessions)
├─────────┬───────────────────────────────────────────┤
│         │                                           │
│  Files  │  Agent: I'll refactor the auth module.    │  ← Conversation (scrollable)
│  tree   │  Here's my plan:                          │
│  or     │                                           │
│  agent  │  1. Extract token validation into a       │
│  file   │     separate module                       │
│  list   │  2. Add refresh token rotation            │
│  side   │  3. Update the tests                      │
│  bar    │                                           │
│         │  [Tool: edit_file auth.ex] ✓ 2.3s         │  ← Collapsible tool call
│         │  [Tool: edit_file auth_test.ex] ✓ 1.1s    │
│         │                                           │
│         │  I've made the changes. Here's a summary: │
│         │                                           │
│         │  ┌─ auth.ex ──────────────────────────┐   │  ← Inline diff preview
│         │  │ -def validate(token) do             │   │
│         │  │ +def validate(token, opts \\ []) do │   │
│         │  └────────────────────────────────────┘   │
│         │                                           │
│         │  [Review Changes]  [Approve All]          │  ← Action buttons / keybinds
│         │                                           │
├─────────┴───────────────────────────────────────────┤
│ > Type a message...                                 │  ← Prompt input
├─────────────────────────────────────────────────────┤
│ NORMAL │ agent-1 │ thinking │ claude-sonnet │ $0.12 │  ← Status bar
└─────────────────────────────────────────────────────┘
```

### Conversation Elements

The conversation is a scrollable list of structured elements, not a plain text buffer. Each element type has its own rendering:

| Element | Description | Interaction |
|---------|-------------|-------------|
| **User message** | The user's prompt text | Read-only after sending |
| **Agent text** | Markdown-formatted agent response | Scrollable, code blocks have syntax highlighting |
| **Tool call** | Collapsible card showing tool name, args, result, duration | Click/Enter to expand, shows full input/output |
| **Inline diff** | Compact diff preview embedded in the conversation | Click/Enter to open full diff review |
| **Action row** | Buttons or keybind hints for review, approve, retry | Keyboard shortcuts (Enter, a, r) or click |
| **Error** | Agent error with retry option | r to retry |
| **Cost display** | Token usage and estimated cost for the turn | Read-only |

### Conversation Input

The prompt input at the bottom is a multi-line text area with:
- **Enter** to send (Shift+Enter for newline)
- **Up arrow** at empty prompt to recall previous messages
- **Tab** for @-mention completion (files, symbols, URLs)
- **Ctrl+C** to interrupt a running agent
- Basic Emacs-style editing (Ctrl+A/E/K/W) for the prompt text
- No vim modal editing in the prompt (it's a text input, not a buffer)

### Conversation Keybindings

When focused on the conversation (not the prompt input):

| Key | Action |
|-----|--------|
| `j` / `k` | Scroll conversation |
| `g` / `G` | Top / bottom of conversation |
| `Enter` | Expand focused element (tool call, diff) |
| `d` | Open diff review for agent's changes |
| `a` | Approve all pending changes |
| `r` | Retry last agent action |
| `i` | Focus the prompt input |
| `f` | Open file finder (fuzzy picker) |
| `e` | Zoom into editor view for the file under cursor |
| `SPC` | Leader key for command palette |
| `1-9` | Switch agent tabs |
| `q` | Return to Board grid view |

---

## 6. The Board: Multi-Agent Orchestration

The Board is the overview of all active agent sessions, shown when you have multiple agents running or press `q` from a conversation.

### Layout

```
┌─────────────────────────────────────────────────────┐
│  THE BOARD                              [+] New Agent│
├─────────────────────────────────────────────────────┤
│                                                     │
│  ┌─ You ─────────┐  ┌─ Refactor Auth ──────────┐   │
│  │ status: idle   │  │ status: thinking ●●●     │   │
│  │ model: —       │  │ model: claude-sonnet     │   │
│  │                │  │ task: Extract token       │   │
│  │ [manual edit]  │  │   validation and add...  │   │
│  └────────────────┘  │ files: auth.ex, +2       │   │
│                      │ cost: $0.34              │   │
│  ┌─ Write Tests ─┐  └──────────────────────────┘   │
│  │ status: done ✓ │                                 │
│  │ model: haiku   │  ┌─ Code Review ───────────┐   │
│  │ task: Add      │  │ status: needs you ⚡     │   │
│  │   property...  │  │ model: claude-sonnet     │   │
│  │ files: +3      │  │ task: Review PR #142     │   │
│  │ cost: $0.08    │  │ waiting: approval for    │   │
│  └────────────────┘  │   3 file changes         │   │
│                      └──────────────────────────┘   │
│                                                     │
├─────────────────────────────────────────────────────┤
│ BOARD │ 4 agents │ 1 needs attention │ $0.56 total  │
└─────────────────────────────────────────────────────┘
```

### Card States

Each card represents an agent session (or the "You" manual editing card):

| Status | Display | Meaning |
|--------|---------|---------|
| `idle` | Gray | No active work |
| `working` | Blue, animated | Agent is generating or executing tools |
| `iterating` | Purple, animated | Agent is in a test/lint feedback loop |
| `needs_you` | Yellow, flashing | Agent needs human input (approval, question) |
| `done` | Green, checkmark | Task completed |
| `errored` | Red, X | Agent hit an error |

### Board Keybindings

| Key | Action |
|-----|--------|
| `h/j/k/l` | Navigate between cards |
| `Enter` | Zoom into the focused card's conversation |
| `n` | Create a new agent session |
| `d` | Delete the focused card (with confirmation) |
| `r` | Retry the errored card |
| `/` | Filter cards by text |
| `s` | Sort cards (by status, by recency, by cost) |

### Card Data Structure

```elixir
defmodule Minga.Board.Card do
  @type status :: :idle | :working | :iterating | :needs_you | :done | :errored
  @type kind :: :you | :agent

  @type t :: %__MODULE__{
    id: pos_integer(),
    session: pid() | nil,       # Agent.Session pid (nil for "You" card)
    workspace: Workspace.t(),   # The session's workspace snapshot
    task: String.t(),           # Human-readable task description
    status: status(),
    kind: kind(),
    model: String.t() | nil,    # LLM model name
    created_at: DateTime.t(),
    total_cost: float(),
    touched_files: [String.t()]
  }
end
```

---

## 7. Agent System

### Agent.Session GenServer

Each agent session is a supervised GenServer under Agent.Supervisor. It owns its entire conversation lifecycle and workspace.

```elixir
defmodule Minga.Agent.Session do
  use GenServer

  # State
  @type state :: %{
    session_id: String.t(),
    provider: pid() | nil,            # LLM provider process
    provider_module: module(),
    status: :idle | :thinking | :tool_executing | :error,
    messages: [Message.t()],          # Full conversation history
    workspace: Workspace.t(),         # This session's editing workspace
    subscribers: MapSet.t(pid()),     # Processes receiving events
    total_usage: token_usage(),
    pending_approval: ToolApproval.t() | nil,
    model_name: String.t(),
    touched_files: %{String.t() => file_touch()},
    boundaries: %{String.t() => EditBoundary.t()}
  }
end
```

### Status Lifecycle

```
:idle → :thinking → :tool_executing → :thinking → ... → :idle
           ↓                              ↓
        :error                          :error
```

### Event System

Agent sessions broadcast events to subscribers via `Minga.Events`:

```elixir
# Events emitted by Agent.Session
{:agent_status_changed, session_pid, new_status}
{:agent_message, session_pid, message}
{:agent_tool_start, session_pid, tool_call}
{:agent_tool_complete, session_pid, tool_call, result}
{:agent_approval_needed, session_pid, tool_approval}
{:agent_edit_complete, session_pid, file_path, diff}
{:agent_error, session_pid, error_message}
{:agent_done, session_pid, summary}
```

The Orchestrator subscribes to these events and updates the Board/conversation view accordingly.

### Tool System

Tools are the agent's interface to the editor and filesystem. Each tool is a function with a JSON Schema for parameters and a callback that executes the operation.

#### Built-in Tools

| Tool | Description | Buffer-aware? |
|------|-------------|---------------|
| `read_file` | Read file contents (offset/limit for slices) | Yes: reads from buffer if open |
| `write_file` | Create or overwrite a file | Yes: routes through buffer |
| `edit_file` | Replace exact text in a file | Yes: routes through buffer |
| `multi_edit_file` | Multiple edits to one file atomically | Yes: single undo entry |
| `list_directory` | List files and directories | No (filesystem only) |
| `find` | Find files by name/glob | No (filesystem only) |
| `grep` | Search file contents | No (filesystem only) |
| `shell` | Run a shell command | No (OS process) |
| `git_status` | Changed files with status | No (git CLI) |
| `git_diff` | Unified diff | No (git CLI) |
| `git_log` | Recent commits | No (git CLI) |
| `git_stage` | Stage files | No (git CLI) |
| `git_commit` | Create a commit | No (git CLI) |
| `diagnostics` | LSP diagnostics for a file | No (reads from Diagnostics) |
| `definition` | Go-to-definition via LSP | No (LSP query) |
| `references` | Find all references via LSP | No (LSP query) |
| `hover` | Type info and docs via LSP | No (LSP query) |
| `document_symbols` | Symbols in a file via LSP | No (LSP query) |
| `workspace_symbols` | Project-wide symbol search | No (LSP query) |
| `rename` | Semantic rename via LSP | Yes: routes through buffers |
| `code_actions` | LSP code actions | Yes: routes through buffers |

#### Tool Approval

Destructive tools (write, edit, shell, git stage/commit) require user approval before execution. The approval flow:

1. Agent.Session receives a tool call from the LLM
2. If the tool is destructive, session enters `:pending_approval` state
3. Session emits `{:agent_approval_needed, pid, approval}` event
4. Orchestrator displays approval UI in the conversation view
5. User presses `y` (approve), `n` (reject), or `a` (approve all for this session)
6. Session receives the decision and executes or skips

Auto-approve mode can be toggled per-session or globally for trusted operations.

#### Buffer-Aware Tool Execution

When a tool edits a file that has an open buffer:

```elixir
# Instead of:
content = File.read!(path)
new_content = apply_edit(content, old_text, new_text)
File.write!(path, new_content)

# V2 does:
case Buffer.Supervisor.find_by_path(path) do
  {:ok, buffer_pid} ->
    # Edit goes through the buffer GenServer
    Buffer.Server.apply_text_edit(buffer_pid, start_pos, end_pos, new_text)
    # Result: undo works, tree-sitter updates, dirty tracking, live display

  :not_found ->
    # No buffer open, fall back to filesystem
    File.read!(path) |> apply_edit(old_text, new_text) |> then(&File.write!(path, &1))
end
```

### Buffer Forking for Concurrent Agents

When two agents need to edit the same file concurrently:

1. Agent.Session requests a fork: `Buffer.Server.fork(buffer_pid, :agent_session_id)`
2. Buffer.Supervisor starts a `Buffer.Fork` process with a copy of the document
3. The agent's tools read and write through the fork, not the canonical buffer
4. When the agent completes, the fork is merged back via three-way merge:
   - Base: the document state at fork time
   - Ours: the canonical buffer's current state (may have user edits)
   - Theirs: the fork's state (agent's edits)
5. If merge conflicts exist, the diff review surface shows them for manual resolution

```elixir
defmodule Minga.Buffer.Fork do
  use GenServer

  @type state :: %{
    parent: pid(),                # Canonical Buffer.Server
    base_version: non_neg_integer(),
    document: Document.t(),       # Forked copy
    session_id: String.t()
  }
end
```

### Multi-Agent Orchestration

Agents can spawn sub-agents for complex tasks:

```elixir
# Inside an agent session, the "plan" tool can spawn sub-agents
def execute_plan(session, plan) do
  for task <- plan.subtasks do
    {:ok, sub_session} = Agent.Supervisor.start_session(
      task: task.description,
      parent: session,
      model: task.model || session.model,
      workspace: Workspace.fork(session.workspace)
    )
    Agent.Session.send_prompt(sub_session, task.prompt)
  end
end
```

The Board displays sub-agents as nested cards under their parent.

### LLM Provider Abstraction

Agent sessions communicate with LLMs through a provider behaviour:

```elixir
defmodule Minga.Agent.Provider do
  @callback start_link(keyword()) :: GenServer.on_start()
  @callback send_message(pid(), [Message.t()], [Tool.t()]) :: :ok
  @callback cancel(pid()) :: :ok
end
```

Implementations:
- `Agent.Provider.Anthropic` for Claude models (direct API)
- `Agent.Provider.OpenAI` for GPT models
- `Agent.Provider.Local` for local models (Ollama, llama.cpp)
- `Agent.Provider.PiRPC` for delegating to pi agent harness

The provider streams responses back as messages to the session:

```elixir
{:agent_text_delta, text_chunk}
{:agent_tool_use, tool_name, tool_id, args}
{:agent_turn_complete, usage}
{:agent_error, reason}
```

---

## 8. Buffer System

### Gap Buffer Document

Each buffer stores text in a gap buffer: two binaries with a gap at the cursor position. Insertions and deletions at the cursor are O(1).

```elixir
defmodule Minga.Buffer.Document do
  @type t :: %__MODULE__{
    before: binary(),           # Text before cursor
    after_cursor: binary(),     # Text after cursor (reversed)
    line_count: non_neg_integer(),
    byte_size: non_neg_integer()
  }

  # O(1) operations at cursor
  @spec insert_char(t(), String.t()) :: t()
  @spec delete_before(t()) :: t()
  @spec insert_text(t(), String.t()) :: t()

  # O(k) cursor movement (k = distance)
  @spec move_to(t(), {line, col}) :: t()

  # O(n) full content extraction (for save, parse)
  @spec content(t()) :: String.t()
end
```

### Byte-Indexed Positions

All positions are `{line, byte_col}`, not grapheme indices:
- O(1) string slicing with `binary_part/3`
- Direct alignment with tree-sitter byte offsets
- ASCII fast path (>95% of code): byte offset equals grapheme index
- Grapheme conversion happens only at the render boundary for visible lines

### Buffer.Server GenServer

One process per open file. Owns the document, undo stack, and metadata.

```elixir
defmodule Minga.Buffer.Server do
  use GenServer

  @type state :: %{
    document: Document.t(),
    path: String.t() | nil,
    filetype: atom(),
    dirty: boolean(),
    version: non_neg_integer(),       # Monotonic, increments on every edit
    undo_stack: [edit_entry()],
    redo_stack: [edit_entry()],
    options: %{atom() => term()},     # Buffer-local option overrides
    forks: %{String.t() => pid()}     # Active forks by session_id
  }
end
```

### Edit Deltas

Every edit produces an `EditDelta` for incremental tree-sitter sync:

```elixir
defmodule Minga.Buffer.EditDelta do
  @type t :: %__MODULE__{
    start_byte: non_neg_integer(),
    old_end_byte: non_neg_integer(),
    new_end_byte: non_neg_integer(),
    start_position: {non_neg_integer(), non_neg_integer()},
    old_end_position: {non_neg_integer(), non_neg_integer()},
    new_end_position: {non_neg_integer(), non_neg_integer()},
    text: String.t()
  }
end
```

### Batch Edit API

For agent edits that touch multiple locations in one file:

```elixir
@spec apply_text_edits(server(), [text_edit()]) :: :ok | {:error, term()}
def apply_text_edits(server, edits) do
  GenServer.call(server, {:apply_text_edits, edits})
end

# In handle_call: sort edits by position (bottom-up), apply sequentially,
# push a single undo entry for the batch. Emit one version bump.
```

---

## 9. Diff Review System

This is the most important user-facing flow. When an agent makes changes, this is how the user reviews them.

### Entry Points

- Agent completes a task and has pending changes → automatic diff review
- User presses `d` in conversation view → explicit diff review
- User presses `SPC g d` → git diff review (manual changes)

### Layout

```
┌─────────────────────────────────────────────────────┐
│  DIFF REVIEW │ 3 files │ 7 hunks │ 2/7 approved     │
├─────────────────────────────────────────────────────┤
│  Files:                                             │
│  ● lib/auth.ex              3 hunks  [2/3 ✓]       │
│  ○ lib/auth/token.ex        2 hunks  [new file]     │
│  ○ test/auth_test.exs       2 hunks  [0/2]          │
├─────────────────────────────────────────────────────┤
│  lib/auth.ex — Hunk 2 of 3                          │
│                                                     │
│   45 │   def validate(token) do                     │
│   46 │-    case decode(token) do                    │
│   46 │+    case decode(token, opts) do              │
│   47 │       {:ok, claims} ->                       │
│   48 │-        check_expiry(claims)                 │
│   48 │+        claims                               │
│   49 │+        |> check_expiry()                    │
│   50 │+        |> check_issuer(opts[:issuer])       │
│   51 │       {:error, reason} ->                    │
│                                                     │
│  [y] approve  [n] reject  [e] edit  [s] split hunk │
├─────────────────────────────────────────────────────┤
│ REVIEW │ auth.ex │ hunk 2/3 │ +12 -4               │
└─────────────────────────────────────────────────────┘
```

### Diff Review Keybindings

| Key | Action |
|-----|--------|
| `j` / `k` | Next / previous hunk |
| `J` / `K` | Next / previous file |
| `y` | Approve current hunk |
| `n` | Reject current hunk |
| `a` | Approve all remaining hunks |
| `e` | Edit the hunk (opens editor zoom with the hunk selected) |
| `s` | Split hunk into smaller hunks |
| `c` | Add a comment for the agent (request changes) |
| `Enter` | Expand/collapse hunk context |
| `q` | Finish review (apply approved, discard rejected) |
| `Ctrl+C` | Abort review (discard all) |

### Diff Data Structure

```elixir
defmodule Minga.Diff.Review do
  @type hunk_status :: :pending | :approved | :rejected

  @type hunk :: %{
    file_path: String.t(),
    old_start: non_neg_integer(),
    old_count: non_neg_integer(),
    new_start: non_neg_integer(),
    new_count: non_neg_integer(),
    lines: [{:context | :add | :remove, String.t()}],
    status: hunk_status()
  }

  @type file_diff :: %{
    path: String.t(),
    status: :modified | :added | :deleted | :renamed,
    hunks: [hunk()]
  }

  @type review :: %{
    files: [file_diff()],
    source: :agent | :git,           # Where the diff came from
    session_id: String.t() | nil     # Which agent (if agent-sourced)
  }
end
```

### Semantic Diffs (Future Enhancement)

Use tree-sitter AST information to produce structural diffs:
- "Function `validate/1` signature changed to `validate/2`"
- "New function `check_issuer/2` added"
- "Import `Minga.Auth.Token` added"

This runs on top of the line-level diff, providing a summary view. The line-level diff remains available for precise review.

---

## 10. Editor Surface (Zoom View)

When the user zooms into a file from the conversation or Board, they get a full-featured code editor with vim keybindings. This is the same quality bar as a standalone vim-like editor.

### Zoom Lifecycle

1. User presses `e` on a file reference in the conversation
2. Orchestrator transitions to editor view
3. InputDispatcher pushes vim mode handler onto the focus stack
4. WindowManager activates the editor layout (gutter, content, status bar)
5. RenderCoordinator switches to the editor render pipeline
6. User edits with full vim (normal, insert, visual, operator-pending, command)
7. User presses `ESC ESC` or `SPC q` to return to conversation
8. Orchestrator transitions back, pops vim handler, restores conversation layout

### Vim Mode FSM

```
Normal ──(i/a/o/O/A/I)──→ Insert ──(ESC)──→ Normal
   │                                            │
   ├──(v)──→ Visual Char ──(ESC)──→ Normal      │
   ├──(V)──→ Visual Line ──(ESC)──→ Normal      │
   ├──(d/c/y/>/</=)──→ Operator Pending         │
   │                    ├──(motion)──→ [execute] → Normal
   │                    └──(ESC)──→ Normal       │
   └──(:)──→ Command ──(Enter/ESC)──→ Normal    │
```

Each mode is a pure module implementing the `Mode` behaviour:

```elixir
defmodule Minga.Mode do
  @type mode :: :normal | :insert | :visual_char | :visual_line | :visual_block
              | :operator_pending | :command | :replace

  @callback handle_key(key :: term(), mode_state :: term(), context :: term())
    :: {:handled, new_mode_state :: term(), [command()]}
     | {:pending, new_mode_state :: term()}
     | :passthrough
end
```

### Motions

Pure functions that compute cursor destinations:

```elixir
defmodule Minga.Editing.Motion do
  @spec word_forward(Document.t(), position()) :: position()
  @spec word_backward(Document.t(), position()) :: position()
  @spec line_start(Document.t(), position()) :: position()
  @spec line_end(Document.t(), position()) :: position()
  @spec paragraph_forward(Document.t(), position()) :: position()
  @spec find_char(Document.t(), position(), char(), direction()) :: position() | nil
  @spec matching_bracket(Document.t(), position()) :: position() | nil
  # ... 30+ motions
end
```

### Text Objects

Pure functions that compute ranges:

```elixir
defmodule Minga.Editing.TextObject do
  @spec inner_word(Document.t(), position()) :: {position(), position()}
  @spec around_word(Document.t(), position()) :: {position(), position()}
  @spec inner_quotes(Document.t(), position(), char()) :: {position(), position()} | nil
  @spec inner_parens(Document.t(), position()) :: {position(), position()} | nil
  @spec inner_function(Document.t(), position(), tree_sitter_data()) :: range() | nil
  # ... 20+ text objects
end
```

### Operators

Pure functions that transform document content:

```elixir
defmodule Minga.Editing.Operator do
  @spec delete(Document.t(), range()) :: {Document.t(), deleted_text :: String.t()}
  @spec change(Document.t(), range()) :: {Document.t(), deleted_text :: String.t()}
  @spec yank(Document.t(), range()) :: String.t()
  @spec indent(Document.t(), range(), direction :: :left | :right) :: Document.t()
end
```

### Layer Architecture

The editing system follows strict layering:

**Layer 0 (pure functions):** Document, Motion, TextObject, Operator, Search. No GenServer calls, no side effects. Take values, return values.

**Layer 1 (stateful services):** Buffer.Server, Config, Events, LSP.Client, Git.Buffer. GenServers that wrap Layer 0 data structures.

**Layer 2 (orchestration):** Orchestrator, InputDispatcher, RenderCoordinator, WindowManager. Depend on everything, change the most.

Dependencies flow downward only. Layer 0 never imports from Layer 1 or 2.

---

## 11. Input System

### Focus Stack

Input events flow through an ordered stack of handler modules. The first handler that returns `{:handled, state}` stops the walk.

```elixir
defmodule Minga.Input.Handler do
  @callback handle_key(key, state, context) ::
    {:handled, new_state} | :passthrough

  @callback handle_mouse(event, state, context) ::
    {:handled, new_state} | :passthrough

  @optional_callbacks [handle_mouse: 3]
end
```

### Stack Configuration by View

**Board view:**
```
[Input.BoardNav]
```

**Conversation view:**
```
[Input.ToolApproval,    # Intercepts when approval is pending
 Input.ConversationNav, # j/k scroll, Enter expand, d/a/r actions
 Input.PromptInput]     # Text input when prompt is focused
```

**Diff review view:**
```
[Input.DiffReview]      # y/n/a/e/q hunk review
```

**Editor zoom view:**
```
[Input.Picker,          # Fuzzy finder overlay (when open)
 Input.Completion,      # LSP completion (when showing)
 Input.SignatureHelp,   # Function signature (when showing)
 Input.Scoped,          # Keymap scope routing
 Input.ModeFSM]         # Vim mode state machine
```

### Mouse Routing

Mouse events route by position (hit-testing), not by focus:

```elixir
def dispatch_mouse(event, state) do
  layout = WindowManager.layout()

  cond do
    in_rect?(event, layout.sidebar) -> SidebarHandler.handle_mouse(event, state)
    in_rect?(event, layout.tab_bar) -> TabBarHandler.handle_mouse(event, state)
    in_rect?(event, layout.conversation) -> ConversationHandler.handle_mouse(event, state)
    in_rect?(event, layout.editor) -> EditorMouseHandler.handle_mouse(event, state)
    in_rect?(event, layout.status_bar) -> StatusBarHandler.handle_mouse(event, state)
    true -> :passthrough
  end
end
```

---

## 12. Rendering Architecture

### Display List IR

The BEAM side owns a display list of styled text runs. This intermediate representation sits between editor state and protocol encoding. All frontends consume it.

```elixir
@type text_run :: {col :: non_neg_integer(), text :: String.t(), style :: style()}
@type style :: %{fg: color(), bg: color(), attrs: attr_flags()}
@type display_line :: [text_run()]

@type window_frame :: %{
  rect: rect(),
  lines: %{row :: non_neg_integer() => display_line()},
  gutter: %{row :: non_neg_integer() => display_line()},
  cursor: {row :: non_neg_integer(), col :: non_neg_integer()}
}
```

### Render Pipelines

Different views use different render pipelines. The conversation surface doesn't need the same optimization as the code editor.

**Conversation pipeline (simple):**
1. Build element list from conversation messages
2. Compute visible elements (virtual scroll)
3. Render visible elements to display list (markdown, code blocks, diffs, tool calls)
4. Render chrome (tab bar, status bar, prompt input)
5. Encode and emit to frontend

**Editor pipeline (optimized):**
1. **Invalidation:** determine which lines changed since last frame
2. **Layout:** compute rectangles for gutter, content, status bar, panels
3. **Scroll:** adjust viewport if cursor moved off-screen
4. **Content:** build text runs for visible lines (syntax highlighted, decorated)
5. **Chrome:** build status bar, tab bar, modeline
6. **Compose:** merge window frames into the display list
7. **Emit:** encode display list to protocol commands, send to Port.Manager

**Diff review pipeline (moderate):**
1. Compute visible hunks
2. Render diff lines with add/remove/context styling
3. Render file list sidebar
4. Render chrome
5. Encode and emit

### Render Rate Limiting

RenderCoordinator coalesces rapid state changes into single frames:

```elixir
def handle_cast(:state_changed, state) do
  state = mark_dirty(state)

  unless state.render_timer do
    timer = Process.send_after(self(), :render_tick, @render_interval_ms)
    {:noreply, %{state | render_timer: timer}}
  else
    {:noreply, state}
  end
end

def handle_info(:render_tick, state) do
  if state.dirty do
    display_list = build_display_list(state)
    Port.Manager.emit(display_list)
    {:noreply, %{state | dirty: false, render_timer: nil}}
  else
    {:noreply, %{state | render_timer: nil}}
  end
end
```

---

## 13. Port Protocol

The BEAM communicates with frontend processes via length-prefixed binary messages on stdin/stdout.

### Transport

```
┌──────────────┬────────────────────────┐
│ length (4B)  │ payload (length bytes)  │
│ big-endian   │ opcode (1B) + fields    │
└──────────────┴────────────────────────┘
```

Erlang's `{:packet, 4}` handles framing on the BEAM side. Frontends read/write the 4-byte length header explicitly. All multi-byte integers are big-endian. All text is UTF-8.

### Render Commands (BEAM → Frontend)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x10` | draw_text | 14 + text_len | Draw styled text at position |
| `0x11` | set_cursor | 5 | Position the cursor |
| `0x12` | clear | 1 | Clear the entire screen |
| `0x13` | batch_end | 1 | End of frame, flush to screen |
| `0x14` | define_region | 15 | Create/update a layout region |
| `0x15` | set_cursor_shape | 2 | Change cursor appearance |
| `0x16` | set_title | 3 + title_len | Set window/terminal title |
| `0x18` | clear_region | 3 | Clear a specific region |
| `0x19` | destroy_region | 3 | Remove a region |
| `0x1A` | set_active_region | 3 | Route draw commands to a region |

### Input Events (Frontend → BEAM)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x01` | key_press | 6 | Key with modifiers |
| `0x02` | resize | 5 | Window/terminal resized |
| `0x03` | ready | 5 or 13 | Frontend initialized |
| `0x04` | mouse_event | 9 | Mouse button/wheel/motion |
| `0x05` | capabilities_updated | 9 | Updated capabilities |

### Highlight Commands (BEAM → Parser)

| Opcode | Name | Description |
|--------|------|-------------|
| `0x20` | set_language | Set active tree-sitter grammar |
| `0x21` | parse_buffer | Full parse for highlighting |
| `0x22` | set_highlight_query | Custom highlight query |
| `0x26` | edit_buffer | Incremental edit deltas |

### Highlight Responses (Parser → BEAM)

| Opcode | Name | Description |
|--------|------|-------------|
| `0x30` | highlight_spans | Syntax highlight byte ranges |
| `0x31` | highlight_names | Capture name list for spans |

### GUI Chrome Commands (BEAM → GUI Frontend Only)

| Opcode | Name | Description |
|--------|------|-------------|
| `0x70` | gui_file_tree | File tree sidebar data |
| `0x71` | gui_tab_bar | Tab bar state |
| `0x72` | gui_which_key | Which-key popup |
| `0x73` | gui_completion | Completion popup |
| `0x74` | gui_theme | Theme color slots |
| `0x75` | gui_breadcrumb | Path breadcrumb |
| `0x76` | gui_status_bar | Status bar sections |
| `0x77` | gui_agent_chat | Agent conversation structured data |

### GUI Action Events (GUI Frontend → BEAM)

| Opcode | Name | Description |
|--------|------|-------------|
| `0x07` | gui_action | Tab click, tree click, button press, etc. |

### Render Frame Lifecycle

Every frame follows this sequence:

```
clear → draw_text × N → set_cursor → set_cursor_shape → batch_end
```

The BEAM sends the entire frame as a single batched message. The frontend processes commands in order and only renders to screen on `batch_end`.

### draw_text Detail

```
opcode:   u8  = 0x10
row:      u16           screen row (0-indexed)
col:      u16           screen column (0-indexed)
fg:       u24           foreground RGB (0x000000 = default)
bg:       u24           background RGB (0x000000 = default)
attrs:    u8            flags: BOLD=0x01, UNDERLINE=0x02, ITALIC=0x04, REVERSE=0x08
text_len: u16           byte length
text:     [text_len]u8  UTF-8 text
```

### key_press Detail

```
opcode:    u8  = 0x01
codepoint: u32           Unicode codepoint (special keys use values above U+10FFFF)
modifiers: u8            SHIFT=0x01, CTRL=0x02, ALT=0x04, SUPER=0x08
```

### mouse_event Detail

```
opcode:      u8  = 0x04
row:         i16           screen row (signed, -1 = outside)
col:         i16           screen column (signed)
button:      u8            0x00=left, 0x01=middle, 0x02=right, 0x40-0x43=wheel
modifiers:   u8            same as key_press
event_type:  u8            0x00=press, 0x01=release, 0x02=motion, 0x03=drag
click_count: u8            1/2/3 for single/double/triple click
```

### Capability Negotiation

The `ready` event includes frontend capabilities:

```
frontend_type:  u8    (0=tui, 1=native_gui, 2=web)
color_depth:    u8    (0=mono, 1=256color, 2=rgb)
unicode_width:  u8    (0=wcwidth, 1=unicode_15)
image_support:  u8    (0=none, 1=kitty, 2=sixel, 3=native)
float_support:  u8    (0=emulated, 1=native)
text_rendering: u8    (0=monospace, 1=proportional)
```

The BEAM adapts rendering based on capabilities. GUI frontends receive chrome opcodes (0x70+). TUI frontends paint chrome as cells.

### Layout Regions

Regions provide layout structure for frontends:

```
define_region: id(u16), parent_id(u16), role(u8), row(u16), col(u16), width(u16), height(u16), z_order(u8)
```

Roles: 0=editor, 1=modeline, 2=minibuffer, 3=gutter, 4=popup, 5=panel, 6=border.

Frontends map regions to their native abstraction (virtual viewports for TUI, NSView for macOS, GtkWidget for GTK4).

### Forward Compatibility

Opcodes at 0x90+ use a length-prefixed envelope: `opcode(1) + payload_length(2) + payload(...)`. Old frontends skip unknown opcodes by reading the length and advancing. Opcodes below 0x90 use positional format (cannot be skipped if unknown).

---

## 14. Syntax Highlighting Pipeline

Tree-sitter parsing runs in a dedicated Zig process (`minga-parser`) separate from the rendering frontend. All frontends share the same parser.

### Flow

```
File opened, filetype detected
  → BEAM sends set_language("elixir") to parser
  → BEAM sends parse_buffer(version, content) to parser
  → Parser runs tree-sitter grammar
  → Parser runs highlight query against parse tree
  → Parser sends highlight_names (capture name list)
  → Parser sends highlight_spans (byte ranges + capture IDs)
  → BEAM maps capture names to theme colors
  → BEAM slices visible lines at span boundaries
  → BEAM sends draw_text with per-segment colors to frontend
```

### Incremental Parsing

After the initial full parse, edits use `edit_buffer` (opcode 0x26) to send compact deltas:

```elixir
# When a character is typed:
delta = %EditDelta{
  start_byte: 142,
  old_end_byte: 142,
  new_end_byte: 143,
  text: "x"
}
Parser.Manager.edit_buffer(buffer_id, version, [delta])
```

The parser applies `ts_tree_edit()` on the existing tree and does an incremental reparse. Unchanged subtrees are reused, making cost proportional to edit size, not file size.

### Grammar Registration

All grammars are compiled into the Zig parser binary. At minimum, support these languages at launch:

Elixir, Erlang, Rust, Go, Python, JavaScript, TypeScript, Ruby, C, C++, Lua, Zig, Swift, Bash, JSON, YAML, TOML, Markdown, HTML, CSS, SQL, Dockerfile, Make, Git (commit, rebase, diff), Regex, Scheme (for tree-sitter queries).

Each grammar needs:
1. The C source (vendored in `zig/grammars/`)
2. A `highlights.scm` query (in `zig/queries/{lang}/`)
3. Registration in the Zig build system
4. Registration in `highlighter.zig`
5. Filetype mapping in Elixir's `Language.Registry`

### Injection Support

Injection queries identify embedded languages (e.g., SQL in a Ruby string, JavaScript in HTML). The parser runs injection queries after the main parse and sends `injection_ranges` (opcode 0x34) back to the BEAM. The BEAM uses these for injection-aware features like line comment toggling.

---

## 15. LSP Integration

### Architecture

One `LSP.Client` GenServer per `{server_name, project_root}` pair. Multiple buffers of the same filetype share a single client.

```elixir
defmodule Minga.LSP.Client do
  use GenServer

  # Manages: JSON-RPC protocol, initialize/shutdown lifecycle,
  # document sync, diagnostics publishing, request/response tracking
end
```

### Lifecycle

```
spawn Port → initialize request → wait for capabilities → initialized notification → ready
```

### Document Sync

When a buffer changes:
1. Buffer.Server emits an event with the EditDelta
2. LSP.SyncServer receives the event
3. SyncServer sends `textDocument/didChange` with incremental edits to the client
4. Client forwards to the language server

### Capabilities Used

| Capability | Feature |
|------------|---------|
| `completion` | Code completion in insert mode |
| `hover` | Type info and docs on cursor hold |
| `definition` | Go-to-definition (gd) |
| `references` | Find all references |
| `rename` | Project-wide rename |
| `documentSymbol` | Symbol outline |
| `codeAction` | Quick fixes, refactors |
| `signatureHelp` | Function signature popup |
| `diagnostics` | Errors/warnings in gutter and modeline |
| `formatting` | Format buffer/range on save or command |
| `semanticTokens` | Enhanced syntax highlighting |

### Diagnostics Framework

`Minga.Diagnostics` is a source-agnostic aggregator. Any producer (LSP, compiler, linter, tree-sitter) publishes diagnostics via `Diagnostics.publish(source, path, diagnostics)`. Consumers (gutter renderer, status bar, agent tools) query `Diagnostics.get(path)`.

```elixir
defmodule Minga.Diagnostics.Diagnostic do
  @type severity :: :error | :warning | :info | :hint
  @type t :: %__MODULE__{
    range: {start_pos, end_pos},
    severity: severity(),
    message: String.t(),
    source: String.t(),
    code: String.t() | nil
  }
end
```

---

## 16. Git Integration

### Per-Buffer Git Tracking

Each open file in a git repo gets a `Git.Buffer` process:

1. Detects git root via `git rev-parse --show-toplevel`
2. Fetches HEAD version via `git show HEAD:<path>`
3. Diffs current buffer content vs HEAD using `List.myers_difference/2` (pure Elixir, no external process)
4. Produces a sign map: `%{line_number => :added | :modified | :deleted}`

The sign map feeds the gutter renderer. Diffs run entirely in-memory against cached base content; only buffer-open and explicit stage operations shell out to git.

### Git Operations (Agent Tools)

| Operation | Implementation |
|-----------|---------------|
| `git_status` | `git status --porcelain=v1` |
| `git_diff` | `git diff` (working tree) or `git diff --cached` (staged) |
| `git_log` | `git log --oneline -n N` |
| `git_stage` | `git add <paths>` |
| `git_commit` | `git commit -m <message>` |
| `git_blame` | `git blame --porcelain <path>` |

### Backend Behaviour

```elixir
defmodule Minga.Git.Backend do
  @callback root(String.t()) :: {:ok, String.t()} | :not_git
  @callback status(String.t()) :: {:ok, [status_entry()]} | {:error, term()}
  @callback diff(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback show(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback stage(String.t(), [String.t()]) :: :ok | {:error, term()}
  @callback commit(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback log(String.t(), keyword()) :: {:ok, [log_entry()]} | {:error, term()}
  @callback blame(String.t(), String.t()) :: {:ok, [blame_entry()]} | {:error, term()}
end
```

Production: `Git.System` (shells out to git CLI). Tests: `Git.Stub` (ETS-backed, configurable per-test).

---

## 17. Configuration and Extensions

### User Configuration

Config lives at `~/.config/minga/config.exs` (or `$XDG_CONFIG_HOME/minga/config.exs`). It's real Elixir code evaluated at startup:

```elixir
use Minga.Config

# Options
set :tab_width, 4
set :line_numbers, :relative
set :scroll_margin, 8
set :theme, :doom_one

# Agent defaults
set :agent_model, "claude-sonnet-4-20250514"
set :agent_auto_approve, false

# Per-filetype overrides
filetype :go, tab_width: 4, use_tabs: true
filetype :python, tab_width: 4

# Custom keybindings
bind :normal, "SPC g s", :git_status, "Git status"

# Extensions
extension :my_extension, path: "~/.config/minga/extensions/my_ext"
```

### Option Registry

`Config.Options` is a GenServer holding all options with typed validation:

```elixir
# Each option is defined with: name, type, default
{:tab_width, :pos_integer, 2}
{:line_numbers, {:enum, [:hybrid, :absolute, :relative, :none]}, :hybrid}
{:theme, :atom, :doom_one}
{:agent_model, :string, "claude-sonnet-4-20250514"}
{:agent_auto_approve, :boolean, false}
{:agent_destructive_tools, {:list, :string}, ["write_file", "edit_file", "multi_edit_file", "shell"]}
```

Options support per-filetype overrides. Resolution order:
1. Buffer-local override (highest priority)
2. Filetype defaults
3. Global user config
4. Built-in defaults

### Extension System

Extensions are Elixir modules loaded at runtime:

```elixir
defmodule Minga.Extension do
  @callback init(config :: keyword()) :: {:ok, state :: term()} | {:error, term()}
  @callback commands() :: [Command.t()]       # Optional
  @callback keybindings() :: [Keybinding.t()] # Optional
  @callback hooks() :: [Hook.t()]             # Optional
end
```

Each extension runs under `Extension.Supervisor`. A crashing extension doesn't affect the editor.

### Hooks and Advice

Lifecycle hooks run at specific points:

```elixir
hook :after_save, fn path, _state ->
  if String.ends_with?(path, ".ex"), do: System.cmd("mix", ["format", path])
end
```

Command advice wraps command execution:

```elixir
advise :around, :save_buffer, fn execute, state ->
  state = execute.(state)
  log_message(state, "Saved #{state.active_buffer.path}")
end
```

---

## 18. Frontend Implementations

### macOS (Swift 6 / Metal 3)

The primary frontend. Sets the quality bar.

**Architecture:**
- SwiftUI renders chrome (tab bar, file tree, status bar, popups, conversation elements)
- Metal renders the editor text surface (GPU-accelerated glyph rasterization via CoreText)
- Binary protocol decoder on a background thread
- Structured GUI chrome opcodes (0x70+) drive SwiftUI state updates
- Cell-grid opcodes (0x10+) drive Metal surface updates

**Conversation rendering:** The conversation surface is native SwiftUI. Agent messages render as rich text with Markdown support. Code blocks use a syntax-highlighted NSTextView. Tool calls are collapsible disclosure groups. Diffs use a custom diff view with add/remove line coloring. This is NOT painted as cells; it's native UI.

**Editor surface:** The editor zoom view uses a Metal-backed cell grid for the buffer content (fast, handles large files) and SwiftUI for chrome around it.

### Linux (GTK4 / Cairo)

Same architecture as macOS but with GTK4 widgets:
- GTK4 widgets for chrome
- Cairo (or OpenGL) for the editor text surface
- Native Wayland/X11 integration
- System theming via GTK CSS

### TUI (Zig / libvaxis)

Terminal fallback. Capable but not the primary target.

**Architecture:**
- libvaxis handles terminal differences, Unicode width, cell diffing
- Reads render commands from stdin (the BEAM's Port)
- Writes input events to stdout (back to the BEAM)
- Uses `/dev/tty` for terminal I/O (stdout is the protocol channel)
- All chrome is painted as cells (no structured chrome opcodes)

**Key rules:**
- Never write to stdout (that's the Port channel)
- `std.log` for debug output (captured by BEAM via stderr)
- No hidden allocations in the hot render loop
- Single binary output, no runtime dependencies

### Headless (Test Frontend)

For tests, a pure-Elixir "headless" frontend that implements the `Port.Frontend` behaviour without spawning an OS process:

```elixir
defmodule Minga.Test.HeadlessPort do
  @behaviour Minga.Port.Frontend
  # Captures render commands in state for assertion
  # Simulates key/mouse input for test driving
end
```

This enables fast, deterministic testing without OS process overhead.

---

## 19. Project Structure

```
lib/
  minga.ex                          # Root module
  minga/
    application.ex                  # OTP application / supervisor tree

    # Foundation (Layer 0+1)
    foundation/
      supervisor.ex
    core/
      unicode.ex                    # UAX #11 character width
      diff.ex                       # Myers diff algorithm
      interval_tree.ex              # For diagnostics, decorations
      face.ex                       # Style/face struct
      decorations.ex                # Line decorations (git signs, diagnostics)
    config.ex                       # Config DSL (use Minga.Config)
    config/
      options.ex                    # Typed option registry
      loader.ex                     # Config file discovery and evaluation
      hooks.ex                      # Lifecycle hook registry
      advice.ex                     # Before/after command advice
    events.ex                       # PubSub for internal events
    language/
      registry.ex                   # Filetype detection, grammar mapping

    # Buffer (Layer 0+1)
    buffer.ex                       # Entry point (delegates to Server)
    buffer/
      document.ex                   # Gap buffer (pure data structure, Layer 0)
      server.ex                     # GenServer per file (Layer 1)
      fork.ex                       # Forked buffer for concurrent agents
      edit_delta.ex                 # Edit delta for incremental sync
      state.ex                      # Server internal state

    # Editing (Layer 0)
    editing.ex                      # Entry point
    editing/
      motion.ex                     # Cursor motion functions
      motion/
        word.ex                     # Word motions
        line.ex                     # Line motions
        char.ex                     # Character motions
        search.ex                   # Search motions
      text_object.ex                # Text objects (iw, aw, i", etc.)
      operator.ex                   # delete, change, yank, indent
      search.ex                     # Search state and incremental search
      completion.ex                 # Completion data structures

    # Mode (Layer 0)
    mode.ex                         # Mode behaviour
    mode/
      normal.ex
      insert.ex
      visual.ex
      operator_pending.ex
      command.ex
      replace.ex

    # Agent (Layer 1+2)
    agent.ex                        # Entry point
    agent/
      session.ex                    # GenServer per conversation
      supervisor.ex                 # DynamicSupervisor for sessions
      provider.ex                   # LLM provider behaviour
      provider/
        anthropic.ex
        openai.ex
        local.ex
      tools.ex                      # Tool registry
      tools/
        read_file.ex
        write_file.ex
        edit_file.ex
        multi_edit_file.ex
        shell.ex
        grep.ex
        find.ex
        list_directory.ex
        git.ex                      # git_status, git_diff, git_log, git_stage, git_commit
        lsp_hover.ex
        lsp_definition.ex
        lsp_references.ex
        lsp_diagnostics.ex
        lsp_rename.ex
        lsp_code_actions.ex
        lsp_document_symbols.ex
        lsp_workspace_symbols.ex
      message.ex                    # Conversation message struct
      tool_call.ex                  # Tool call struct with status lifecycle
      tool_approval.ex              # Approval request struct
      event.ex                      # Event types
      cost_calculator.ex            # Token usage and cost tracking

    # Board (Layer 2)
    board.ex                        # Board view logic
    board/
      card.ex                       # Card struct
      state.ex                      # Board state (cards, focus, zoom)
      renderer.ex                   # Board-specific rendering

    # Diff Review (Layer 2)
    diff/
      review.ex                     # Review state (files, hunks, status)
      renderer.ex                   # Diff-specific rendering
      hunk.ex                       # Hunk data structure

    # Orchestrator (Layer 2)
    orchestrator.ex                 # View switching, workspace management
    input/
      dispatcher.ex                 # Focus stack, input routing
      handler.ex                    # Handler behaviour
      conversation_nav.ex           # Conversation scrolling/actions
      prompt_input.ex               # Prompt text input
      board_nav.ex                  # Board card navigation
      diff_review.ex                # Diff hunk review
      tool_approval.ex              # Tool approval y/n
      mode_fsm.ex                   # Vim mode state machine
      scoped.ex                     # Keymap scope routing
      picker.ex                     # Fuzzy finder overlay
      completion.ex                 # LSP completion overlay

    # Window Management (Layer 2)
    window/
      manager.ex                    # Layout, window tree, focus
      tree.ex                       # Window split tree
      layout.ex                     # Layout computation

    # Rendering (Layer 2)
    render/
      coordinator.ex                # Display list, render pipeline
      conversation_pipeline.ex      # Renders conversation view
      editor_pipeline.ex            # Renders editor zoom view
      diff_pipeline.ex              # Renders diff review view
      board_pipeline.ex             # Renders board grid view

    # Workspace (Layer 1)
    workspace.ex
    workspace/
      state.ex                      # Per-session editing context

    # Frontend Communication (Layer 1)
    frontend.ex                     # Entry point
    frontend/
      protocol.ex                   # Binary protocol encoder/decoder
      protocol/
        gui.ex                      # GUI chrome encoder
      manager.ex                    # Port.Manager GenServer
      capabilities.ex               # Frontend capabilities struct
      emit.ex                       # Display list → protocol encoding

    # Parser (Layer 1)
    parser/
      manager.ex                    # GenServer managing tree-sitter Port

    # Services (Layer 1)
    services/
      supervisor.ex
    lsp/
      client.ex                     # GenServer per language server
      sync_server.ex                # Document sync coordinator
      supervisor.ex
    diagnostics.ex                  # Source-agnostic diagnostic aggregator
    git.ex                          # Entry point (delegates to backend)
    git/
      backend.ex                    # Behaviour
      system.ex                     # Production (git CLI)
      stub.ex                       # Test stub (ETS)
      buffer.ex                     # Per-buffer git tracking
      diff.ex                       # Pure in-memory line diff
    project.ex                      # Project root, file finder

    # Keymap (Layer 1)
    keymap.ex                       # Entry point
    keymap/
      active.ex                     # Live merged keymap GenServer
      bindings.ex                   # Key sequence → command
      defaults.ex                   # Default keybindings
      scope.ex                      # Scope behaviour
      scope/
        editor.ex                   # Full vim keybindings
        conversation.ex             # Conversation keybindings
        board.ex                    # Board keybindings
        diff_review.ex              # Diff review keybindings

    # Command (Layer 1)
    command.ex                      # Command struct
    command/
      registry.ex                   # Named command lookup
      provider.ex                   # Provider behaviour

    # UI (Layer 1+2)
    ui/
      theme.ex                      # Theme system
      highlight.ex                  # Syntax highlight → face mapping
      icons.ex                      # Nerd font icons

    # Extension (Layer 1)
    extension.ex                    # Extension behaviour
    extension/
      registry.ex
      supervisor.ex

    # Runtime
    runtime/
      supervisor.ex
    cli.ex                          # CLI entry point

  mix/
    compilers/
      zig.ex                        # Custom Mix compiler for Zig

macos/                              # macOS GUI frontend
  project.yml                       # XcodeGen project definition
  Sources/
    MingaApp.swift                  # App entry point
    Protocol/                       # Binary protocol decoder/encoder
    Renderer/                       # Metal cell grid renderer
    Font/                           # CoreText font loading, glyph atlas
    Views/                          # SwiftUI views for chrome
    Conversation/                   # SwiftUI conversation elements
  Tests/

zig/                                # TUI frontend + tree-sitter parser
  build.zig
  build.zig.zon
  src/
    main.zig                        # TUI entry point
    protocol.zig                    # Protocol decoder/encoder
    renderer.zig                    # libvaxis render handler
    highlighter.zig                 # Tree-sitter highlighter
  grammars/                         # Vendored tree-sitter grammars
  queries/                          # Highlight/injection queries

test/                               # Mirrors lib/ structure
  support/
    headless_port.ex                # Headless frontend for tests
    editor_case.ex                  # Test helpers for editor integration
  minga/
    buffer/
      document_test.exs
      server_test.exs
      fork_test.exs
    editing/
      motion_test.exs
      text_object_test.exs
      operator_test.exs
    agent/
      session_test.exs
      tools_test.exs
    board/
      state_test.exs
    diff/
      review_test.exs
    ...
```

---

## 20. Coding Standards

### Elixir Types (Mandatory)

Elixir 1.19's set-theoretic type system catches real bugs at compile time:

- **`@spec`** on every public function, no exceptions
- **`@type` / `@typep`** for all custom types
- **`@enforce_keys`** on structs for required fields
- **Guards** in function heads where they aid type inference
- **Pattern matching** over `if/cond` for type narrowing
- **No `cond` blocks:** use multi-clause functions with pattern matching and guards
- `mix compile --warnings-as-errors` must pass clean

### Module Organization

- One `defmodule` per `.ex` file (never nest modules)
- Entry-point modules are mostly `defdelegate`, `@spec`, and `@doc`
- GenServer modules contain OTP callbacks and route to handler modules for logic
- If a GenServer exceeds ~500 lines, extract handler modules

### State Ownership

Each struct has one module that constructs and updates it. Other modules may read fields but never do `%{thing | field: value}` on a struct they don't own:

```elixir
# Good: owning module provides a transition function
new_state = Card.transition(card, :working)

# Bad: random module reaches in
new_state = %{card | status: :working}
```

### Dependency Direction

Layer 0 (pure) never imports Layer 1 (stateful) or Layer 2 (orchestration). Layer 1 never imports Layer 2. Check by looking at `alias`/`import` lines.

### Common Footguns

- Lists don't support index access (`mylist[0]` fails). Use `Enum.at/2` or pattern matching.
- Variables can't be rebound inside `if`/`case`/`with` and leak out. Always bind: `state = if condition, do: new_state, else: state`.
- Never nest modules in one file (causes cyclic compilation).
- Don't use `String.to_atom/1` on user input (atoms are never GC'd).
- Structs don't implement Access (`my_struct[:field]` fails). Use `my_struct.field`.
- No `Process.sleep/1` in production code.
- No `cond` blocks. Use multi-clause functions.
- Bulk text operations always use `Document.insert_text/2` or `Buffer.Server.apply_text_edits/2`, never character-by-character loops.

### Logging

Use a subsystem-aware logger (`Minga.Log`) that routes through per-subsystem log levels:

```elixir
Minga.Log.debug(:render, "[render:content] 24us")
Minga.Log.warning(:agent, "Agent session crashed: #{inspect(reason)}")
```

Never use `Logger.debug/info/warning/error` directly. Subsystems: `:render`, `:agent`, `:lsp`, `:editor`, `:input`, `:config`.

### Commit Messages

```
type(scope): short description
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
Scopes: `buffer`, `editing`, `agent`, `board`, `diff`, `ui`, `frontend`, `mode`, `keymap`, `config`, `lsp`, `command`, `git`, `input`, `render`, `zig`, `macos`, `gtk`.

---

## 21. Testing Strategy

### Test Layers

Pick the lightest layer that covers the behavior:

**1. Pure function tests (microseconds, never flake):**
```elixir
test "word_forward moves to start of next word" do
  doc = Document.new("hello world")
  assert Motion.word_forward(doc, {0, 0}) == {0, 6}
end
```

**2. Single GenServer tests:**
```elixir
test "insert_text adds text at cursor" do
  {:ok, buf} = start_supervised({Buffer.Server, content: "hello"})
  Buffer.Server.insert_text(buf, " world")
  assert Buffer.Server.content(buf) == "hello world"
end
```

**3. Integration tests (with HeadlessPort):**
```elixir
test "dd deletes current line" do
  ctx = start_editor("line one\nline two")
  send_keys_sync(ctx, "dd")
  assert buffer_content(ctx) == "line two"
end
```

**4. Rendered output tests (heaviest):**
```elixir
test "status bar shows agent status" do
  ctx = start_editor("")
  start_agent_session(ctx)
  assert_row_contains(ctx, last_row(ctx), "thinking")
end
```

### Property-Based Tests

Use StreamData for data structure modules:

```elixir
property "insert then delete restores original content" do
  check all content <- string(:printable),
            char <- string(:printable, length: 1) do
    doc = Document.new(content)
    doc = Document.insert_char(doc, char)
    doc = Document.delete_before(doc)
    assert Document.content(doc) == content
  end
end
```

### Test Concurrency

All test files use `async: true` unless they have a documented reason for serialization. Legitimate reasons: global Application env mutation, OS process spawning, `capture_io(:stderr)`.

`HeadlessPort` is pure Elixir and safe for concurrent tests.

### Synchronization

- Use `start_supervised!/1` for process cleanup
- Use `:sys.get_state/1` as a synchronization barrier (not for state inspection)
- Use `Minga.Events.subscribe/1` + `assert_receive` for async events
- Never use `Process.sleep/1` (send timer messages directly in tests)
- Never use `Process.alive?/1` in assertions (race condition; monitor instead)

### DI for OS Processes

Modules that shell out use a backend behaviour so tests inject stubs:
- `Minga.Git` → `Git.Backend` behaviour, `Git.Stub` in tests
- Tests that need OS processes must be `async: false` with `@moduletag timeout:`

---

## 22. Build Order

This is the recommended order for building V2 from scratch. Each phase builds on the previous and produces something testable.

### Phase 1: Foundation (Week 1-2)

Build the core data structures and infrastructure. Everything is testable in isolation.

1. **Buffer.Document** (gap buffer): insert, delete, move, content extraction. Property-based tests.
2. **Editing.Motion**: word, line, char, paragraph motions. Pure function tests.
3. **Editing.TextObject**: inner/around word, quotes, parens, brackets. Pure function tests.
4. **Editing.Operator**: delete, change, yank, indent. Pure function tests.
5. **Buffer.Server** GenServer: wraps Document with undo/redo, version tracking, dirty state.
6. **Buffer.EditDelta**: delta computation for incremental sync.
7. **Config.Options**: typed option registry GenServer.
8. **Events**: PubSub GenServer for internal events.
9. **Core utilities**: Unicode width tables, Myers diff, IntervalTree.

**Milestone:** All Layer 0 modules have comprehensive tests. `mix test` passes.

### Phase 2: Mode System and Editing (Week 2-3)

Build the vim modal editing system.

1. **Mode behaviour** and FSM transitions (normal → insert → normal, etc.)
2. **Mode.Normal**: key dispatch to motions, operators, text objects, count prefix.
3. **Mode.Insert**: character insertion, auto-indent, auto-pair.
4. **Mode.Visual**: visual char/line selection, operators on selection.
5. **Mode.OperatorPending**: d/c/y + motion/text-object composition.
6. **Mode.Command**: `:w`, `:q`, `:e`, `:set`.
7. **Keymap system**: scope tries, key sequence matching, defaults.
8. **Command registry**: named command lookup, provider behaviour.

**Milestone:** Full vim editing works in unit tests. `send_keys("ddiHello<Esc>")` produces correct document state.

### Phase 3: Agent System (Week 3-5)

Build the agent session system and tools.

1. **Agent.Session** GenServer: status lifecycle, message history, event broadcasting.
2. **Agent.Supervisor**: DynamicSupervisor for sessions.
3. **Agent.Provider behaviour** and Anthropic implementation.
4. **Tool system**: tool registry, JSON Schema, destructive classification.
5. **File tools**: read_file, write_file, edit_file, multi_edit_file (buffer-aware from start).
6. **Search tools**: grep, find, list_directory.
7. **Shell tool**: sandboxed command execution.
8. **Git tools**: status, diff, log, stage, commit.
9. **LSP tools**: hover, definition, references, diagnostics, rename, code_actions.
10. **Tool approval**: pending state, approval flow.
11. **Buffer.Fork**: forked buffer for concurrent agents, three-way merge.
12. **Workspace.State**: per-session editing context.

**Milestone:** An agent session can receive a prompt, call tools, edit files through buffers, and produce a conversation. Testable without any frontend.

### Phase 4: Protocol and Frontend Bootstrap (Week 5-7)

Get something on screen.

1. **Port protocol encoder/decoder** (Elixir side).
2. **Port.Manager** GenServer for managing the frontend Port.
3. **HeadlessPort** for tests (pure Elixir, no OS process).
4. **Zig TUI frontend**: protocol decoder, libvaxis renderer, input encoder.
5. **Parser.Manager** and tree-sitter Zig process.
6. **Basic render pipeline**: clear → draw_text → set_cursor → batch_end.
7. **Layout computation**: rectangles for editor regions.

**Milestone:** Launch Minga, see a file rendered with syntax highlighting, type characters, navigate with vim keys.

### Phase 5: Conversation and Board (Week 7-10)

Build the agentic-first UI.

1. **Conversation surface**: scrollable message list, prompt input, tool call rendering.
2. **Conversation renderer**: builds display list from conversation elements.
3. **Board**: card grid, focus navigation, zoom in/out.
4. **Board renderer**: card layout and rendering.
5. **Diff review surface**: file list, hunk navigation, approve/reject/edit.
6. **Diff renderer**: add/remove/context line styling.
7. **View transitions**: Board → conversation → editor zoom → diff review → back.
8. **InputDispatcher**: focus stack, per-view handler configuration.
9. **Orchestrator**: active view/workspace tracking, event routing.

**Milestone:** Launch Minga, see the Board, create an agent, type a prompt, watch tools execute, review changes in diff view, approve them.

### Phase 6: Services and Polish (Week 10-13)

1. **LSP.Client**: JSON-RPC protocol, initialize/shutdown, document sync.
2. **LSP.SyncServer**: incremental document sync from buffer edits.
3. **Diagnostics**: aggregator, gutter rendering, status bar counts.
4. **Completion**: LSP completion in insert mode.
5. **Git integration**: per-buffer tracking, gutter signs.
6. **Picker**: fuzzy file finder, buffer picker, command palette.
7. **Which-key**: keybinding discovery popup.
8. **Status bar**: mode, file info, git, diagnostics, agent status, cost.
9. **Tab bar**: agent sessions as tabs.
10. **Theme system**: face resolution, color schemes.

**Milestone:** Full-featured editor with agent integration. Syntax highlighting, LSP, git, completion all work.

### Phase 7: macOS GUI Frontend (Week 13-16)

1. **Protocol decoder/encoder** (Swift side).
2. **Metal renderer**: glyph atlas, cell grid rendering.
3. **SwiftUI chrome**: tab bar, status bar, file tree.
4. **Conversation view**: native SwiftUI conversation elements.
5. **GUI chrome opcodes** (0x70+): structured data for native widgets.
6. **GUI actions**: tab clicks, tree clicks, button presses.
7. **Diff review view**: native diff rendering.
8. **Board view**: native card grid.

**Milestone:** Native macOS app with GPU-rendered text, native chrome, and full agent functionality.

### Phase 8: Extensions, Config, and Hardening (Week 16-18)

1. **Extension system**: behaviour, runtime loading, supervision.
2. **Config DSL**: `use Minga.Config`, options, keybindings, hooks, advice.
3. **Config reload**: hot-reload config changes without restart.
4. **Session persistence**: save/restore agent conversations across restarts.
5. **Performance tuning**: telemetry spans, render optimization, profile under load.
6. **Error recovery**: supervision tree hardening, graceful degradation.

**Milestone:** Shippable product. Extensions work. Config is complete. Performance is acceptable.

---

## Appendix A: Workspace State

The workspace is the editing context that each agent session (and the "You" manual session) owns independently.

```elixir
defmodule Minga.Workspace.State do
  @type t :: %__MODULE__{
    buffers: Buffers.t(),           # Open buffers, active buffer, buffer order
    windows: Windows.t(),           # Window tree and focus
    viewport: Viewport.t(),         # Scroll position, visible line range
    editing: VimState.t(),          # Mode, mode state, count, register
    search: Search.t(),             # Active search term, match positions
    file_tree: FileTree.t(),        # File tree expansion state
    completion: Completion.t() | nil,
    keymap_scope: scope_name()
  }
end
```

Each tab on the tab bar corresponds to a workspace. Switching tabs snapshots the current workspace and restores the target workspace. Agent sessions carry their workspace with them.

---

## Appendix B: Key Design Decisions and Rationale

### Why the BEAM?

The BEAM was designed for telephone switches: systems serving millions of concurrent connections that stay responsive under load. An editor with AI agents is structurally similar: multiple concurrent workloads (keystrokes, LLM API calls, tool executions, background processing) that must not interfere with each other. The BEAM provides:

- **Preemptive scheduling:** your keystrokes are never starved by agent work. The scheduler guarantees CPU time per process regardless of what any single process is doing. This is qualitatively different from async/await.
- **Per-process GC:** a large buffer's garbage collection doesn't pause the UI.
- **Supervision trees:** crashes are contained and recovered. An agent crash doesn't lose your buffers.
- **Message-passing isolation:** no shared mutable state. Two agents editing the same file is just two messages in a queue, not a race condition.
- **Hot code reloading:** update editor logic in a running session without restarting.

### Why Not a NIF for Tree-sitter?

NIFs run inside the BEAM process. A segfault in a NIF takes down the entire VM. A Port is an OS process boundary: the parser can crash and the BEAM keeps running. The supervisor restarts the parser and re-parses.

### Why Buffer Forking Instead of CRDTs?

CRDTs (used by Zed for human collaboration) are character-level operational transforms with significant complexity. Agent edits arrive as discrete tool calls (replace text A with B), not character-by-character keystrokes. Three-way merge on the document level is simpler, well-understood (git uses it), and sufficient for the agent use case. If real-time human collaboration is added later, CRDTs can be layered on top.

### Why Split the Editor Into Four Processes?

A single God GenServer serializes all work through one mailbox. With four processes (InputDispatcher, WindowManager, RenderCoordinator, Orchestrator), the BEAM can actually use its concurrency model. Input processing, layout computation, rendering, and view management are genuinely independent most of the time.

### Why Conversation-First?

The thesis: as AI coding agents improve, the ratio of "human typing code" to "human reviewing and directing" will shift dramatically. An editor optimized for the typing case will increasingly feel like the wrong tool. By starting from the conversation and making the editor a zoom-in, V2 is positioned for where the workflow is going, not where it's been.

The hedge: the editor zoom view is a full-featured vim editor. Users who prefer the traditional workflow can stay zoomed in and use the agent from there. The architecture supports both; the default view is what changes.

---

## Appendix C: Glossary

| Term | Definition |
|------|-----------|
| **Board** | The overview grid showing all agent sessions as cards |
| **Card** | A single agent session displayed on the Board |
| **Conversation** | The primary interaction surface: chat messages, tool calls, diffs |
| **Diff review** | Structured hunk-by-hunk review of agent changes |
| **Display list** | The intermediate representation between editor state and protocol encoding |
| **Editor zoom** | Full-featured vim editor view, entered from conversation |
| **Focus stack** | Ordered list of input handlers; first to claim a key wins |
| **Fork** | An in-memory copy of a buffer for concurrent agent editing |
| **Gap buffer** | Two-binary text storage with O(1) insert/delete at cursor |
| **Hunk** | A contiguous group of changed lines in a diff |
| **Layer 0** | Pure functions and data structures (no process dependencies) |
| **Layer 1** | Stateful services (GenServers wrapping Layer 0) |
| **Layer 2** | Orchestration and presentation (depends on everything) |
| **Orchestrator** | Thin coordinator managing active view and workspace |
| **Port** | An OS process boundary for BEAM ↔ frontend communication |
| **Scope** | A keymap context (editor, conversation, board, diff_review) |
| **Shell** | A pluggable UX model (Traditional, Board) |
| **Tool** | A function an AI agent can call (read_file, edit_file, shell, etc.) |
| **Workspace** | Per-session editing context (buffers, windows, vim state, search) |

---

## Appendix D: What's Intentionally Excluded

These features exist in V1 but are deferred or dropped in V2:

| Feature | Reason |
|---------|--------|
| **Which-key for conversation** | You're typing prose, not leader-key sequences |
| **Visual block mode** | Rare even in traditional vim usage; add later if requested |
| **Macro recording** | Low priority for agent-first workflow; add later |
| **24 input handlers in focus stack** | Simplified to per-view stacks; overlays (picker, completion) push on demand |
| **Traditional shell as default** | Board/conversation is the default; editor zoom is the manual-editing fallback |
| **TUI-first development** | GUI-first; TUI is a capable fallback |
| **Cell-grid conversation rendering** | GUI conversations use native widgets; TUI uses simplified text rendering |

These can all be added incrementally after the core is working. The architecture doesn't prevent any of them.
