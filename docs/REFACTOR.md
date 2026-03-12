# Surface Extraction Refactor

**Status:** Agent state fully owned by surfaces. Bridge layer reduction in progress.
**Date:** 2026-03-10 (proposed), 2026-03-11 (Phases 1-4 + post-phase landed), 2026-03-11 (Steps 1-3 landed)

## The One Rule

**The vim editing model applies to all navigable content. Each content type implements `NavigableContent` with the data structure that fits its domain. Don't reimplement navigation commands; implement the protocol instead.**

Minga is agentic-first. The agent view is not a file buffer pretending to be chat. Chat content is structured data (messages, tool calls, code blocks with collapse state, thinking sections). Forcing it into a flat `Buffer.Server` to get vim navigation is the wrong tradeoff: it loses semantic structure, creates streaming/undo problems, and makes interactive elements (approve, collapse) harder.

The shared layer is the **interaction model**, not the data structure:

1. **The editing model (vim/CUA) produces command atoms from key sequences.** `Mode.process(mode, key, mode_state)` returns `:move_down`, `:scroll_half_page`, `:yank`, etc. It doesn't know what content it's operating on.

2. **Each content type interprets those commands against its own data model** via the `NavigableContent` protocol. Same command, different content:
   - File buffer: `:move_down` → `BufferServer.move(buf, :down)` (gap buffer cursor movement)
   - Chat messages: `:move_down` → scroll to next visual line in rendered message list
   - Agent prompt: `:move_down` → `BufferServer.move(prompt_buf, :down)` (this one IS a buffer)
   - Terminal scrollback: `:move_down` → scroll terminal output
   - Browser content: `:move_down` → scroll rendered page

3. **Content-specific actions are domain commands, not editing commands.** Submit prompt, approve tool, reject hunk, toggle collapse, session lifecycle. These are surface-level actions, not vim operations. They belong in surface-specific command handlers, not in the editing model.

### What goes where

| Content | Data structure | Editing | NavigableContent |
|---------|---------------|---------|-----------------|
| File buffer | `Buffer.Server` (gap buffer) | Full vim/CUA (insert, visual, operators, motions) | Buffer adapter |
| Agent prompt | `Buffer.Server` | Full vim/CUA | Buffer adapter |
| Chat messages | Structured list (`[%Message{}, %ToolCall{}, ...]`) | Navigation only (no insert, no editing) | Structured chat adapter |
| `*Messages*` buffer | `Buffer.Server` (read-only) | Navigation + yank (no insert) | Buffer adapter |
| Preview/diff pane | Generated read-only content | Navigation + interactive (approve/reject hunks) | Buffer or custom adapter |
| Terminal (future #122) | Terminal scrollback | Navigation only | Scrollback adapter |
| Browser (future #305) | Rendered web content | Navigation only | Web adapter |

### The test

**If you are about to write a command that duplicates an existing vim operation on a different data structure, stop.** Implement `NavigableContent` for that data structure instead. If you are about to add an `agent_` prefix to a command that already exists without the prefix, stop. The editing model should produce the same command atom; the content adapter interprets it.

This eliminates ~35 of the 62 "agent commands" that exist solely because the agent view reimplements vim on non-buffer data structures (scrolling, cursor movement, search, yank, folding). The only genuinely agent-specific commands are domain actions: submit prompt, approve/reject tools, session lifecycle, model settings.

The structural refactoring (Surfaces, bridges, state ownership) exists to enable this principle. If a structural change doesn't move us toward "one editing model, NavigableContent everywhere," it's the wrong change.

## Current Migration Status

### Step 1: Surface state authoritative for tab lifecycle ✅ (#319)
- Tab contexts store only `{surface_module, surface_state, keymap_scope}`
- `snapshot_tab_context` / `restore_tab_context` sync through surface state
- Legacy context auto-migration for backwards compatibility

### Step 2: Agent fields routed through AgentAccess ✅ (#319)
- All reads go through `Minga.Editor.State.AgentAccess`
- Safe fallbacks when agent state doesn't exist

### Step 3: Agent fields removed from EditorState ✅ (#320)
- `agent` and `agentic` fields deleted from EditorState defstruct
- AgentAccess reads from surface_state (active tab) or background tab context
- Dual-write eliminated: writes go to surface_state only

### Step 4: Background events unified ✅ (#321)
- `BackgroundEvents` module deleted (249 lines)
- Background events use `AgentView.handle_event/2` (same as active tabs)
- `update_background_agent/3` and `update_background_agentic/3` deleted
- `update_background_surface_state/3` added (atomic surface state replacement)

### Step 5: Bridge round-trip reduction (in progress)
- Event dispatch skips sync_from_editor/sync_to_editor (operates on surface_state directly)
- Input.Router no longer imports or calls BufferView.Bridge
- Remaining bridge calls: 21 (down from 53)

### Remaining work: window-level content architecture

The Surface abstraction (tab-level BufferView/AgentView) is being replaced by a simpler model: **the window tree hosts content**. Each window pane holds a content reference (buffer, agent session, terminal, etc.). The editing model and NavigableContent protocol make vim work in every pane. "Agent View" is a window layout preset, not a separate surface implementation.

This eliminates: the Surface behaviour, both bridges, SurfaceSync, Context struct, two parallel render/layout/input pipelines, surface_module/surface_state on EditorState, and ~35 reimplemented agent commands.

**Priority order:**

1. **`NavigableContent` protocol**: define the protocol (`move`, `scroll`, `text_in_range`, `search`, `fold_toggle`, `cursor`, `line_count`). Implement for `Buffer.Server` first (adapter that delegates to the GenServer). This is the foundational abstraction.

2. **`EditingModel` behaviour**: `handle_key/4` and `execute/3`. Vim implements it today (wrapping the existing Mode FSM); CUA (#306) implements it later. Command atoms are universal; NavigableContent adapters interpret them. Vim-specific state (`mode`, `mode_state`, `reg`, `marks`) stays grouped under the editing model, not on the editor or content types.

3. **Window tree hosts any content type**: extend `WindowTree` so each window holds a content reference (buffer pid, agent session, etc.) instead of only buffer pids. The active window determines which NavigableContent and editing model state are active. Vim window commands (`Ctrl-W h/j/k/l/s/v`) work identically regardless of content type.

4. **Agent prompt → Buffer.Server**: replace `TextField` with a real buffer so the standard editing model applies. The prompt is editable text; it should use the same editing model as file buffers.

5. **Structured chat NavigableContent adapter**: implement `NavigableContent` for the agent chat's `[%Message{}, %ToolCall{}, ...]` data model. `j/k` scrolls rendered lines, `{/}` jumps between messages, `/` searches text, `yy` yanks, `za` toggles collapse. No insert mode. Content stays structured.

6. **Window layout presets**: "Agent View" applies a default layout (e.g., file buffer left, agent chat right with prompt). User can customize from there with standard vim window commands. Tabs save/restore window tree configurations.

7. **Eliminate ~35 agent commands**: once the editing model and NavigableContent are in place, agent navigation/scroll/yank/search/fold commands are deleted. Only domain actions remain (~27 commands).

8. **Delete Surface layer**: remove `Minga.Surface` behaviour, both bridge modules, `SurfaceSync`, `Context` struct, `surface_module`/`surface_state` from EditorState. The window tree replaces all of this.

9. **Remove buffer fields from EditorState**: EditorState becomes a thin orchestrator (port, theme, tabs, overlays, window tree). Content-specific state lives in each window's content.

---

The Editor GenServer has become a God Object. It fuses orchestration, state ownership, event routing, and view-specific logic into a single 2,235-line process. Every new feature requires changes in two places (editor path and agent path) because the agentic view was bolted onto the Editor as "just another mode" instead of being built as a peer.

This document diagnoses the root causes, maps the damage across every layer, and proposes an incremental refactoring plan centered on a **Surface** abstraction.

---

## Table of Contents

- [Problem Statement](#problem-statement)
- [How We Got Here](#how-we-got-here)
- [Damage Map: Layer by Layer](#damage-map-layer-by-layer)
  - [State](#state)
  - [Input Routing](#input-routing)
  - [Commands](#commands)
  - [Render Pipeline](#render-pipeline)
  - [Editor GenServer](#editor-genserver)
  - [Layout](#layout)
- [Three Symptoms and Their Root Causes](#three-symptoms-and-their-root-causes)
- [The Missing Concept: Surface](#the-missing-concept-surface)
- [Target Architecture](#target-architecture)
- [Incremental Refactoring Plan](#incremental-refactoring-plan)
  - [Phase 1: Extract BufferView Surface](#phase-1-extract-bufferview-surface)
  - [Phase 2: Extract AgentView Surface](#phase-2-extract-agentview-surface)
  - [Phase 3: Move Agent Events Out of Editor](#phase-3-move-agent-events-out-of-editor)
  - [Phase 4: Push Sub-State Handlers onto Focus Stack](#phase-4-push-sub-state-handlers-onto-focus-stack)
- [DDD Alignment](#ddd-alignment)
- [Risks and Mitigations](#risks-and-mitigations)
- [Success Criteria](#success-criteria)

---

## Problem Statement

When you fix scrolling, paste handling, or vim keybindings, you have to fix them in two places. The editor buffer view and the agentic chat view share a single GenServer (`Minga.Editor`), a single state struct (`EditorState`), a single input dispatcher (`Input.Scoped`), and a single render pipeline (`RenderPipeline`). Each of these has grown `if agentic?` branches that duplicate logic, making every change fragile and every feature twice the work.

The difference between a file/buffer view and an agentic view is primarily **window layout and domain-specific commands** (e.g., `SPC m` runs major-mode actions in files, adjusts model settings in agent). The vim grammar, display list IR, theme, and shared chrome (tab bar, minibuffer) should be infrastructure that both views consume identically. Instead, each view has its own ad-hoc wiring into these shared systems.

---

## How We Got Here

The architecture started clean: one Editor GenServer, one buffer per file, one input pipeline. The agentic view arrived and was implemented as nested state inside the existing Editor rather than as a separate bounded context. Every layer grew conditional branches. The keymap scope system was designed to prevent this (it's Minga's equivalent of Emacs major modes), but the agent's complexity outgrew the scope trie pattern and leaked procedural sub-state machines into `Input.Scoped`.

---

## Damage Map: Layer by Layer

### State

`EditorState` is a 35+ field struct that owns both views' concerns:

```
# Fields that belong to the buffer/editor view:
buffers, windows, file_tree, viewport, mode, mode_state,
highlight, lsp, completion, completion_trigger, git_buffers,
injection_ranges, marks, last_jump_pos, last_find_char,
change_recorder, macro_recorder

# Fields that belong to the agentic view:
agent: %AgentState{}, agentic: %ViewState{}

# Fields shared by both:
port_manager, theme, status_msg, focus_stack, keymap_scope,
tab_bar, capabilities, layout, render_timer
```

The `agent` field contains session pid, status, panel UI state, error, spinner timer, buffer, pending approval, and session history. The `agentic` field contains focus, preview pane, search state, toast queue, diff baselines, chat width percentage, help visibility, and pending prefix state. These are deeply nested: `state.agent.panel.input.cursor` is four levels deep.

Tab switching snapshots/restores both `agent` and `agentic` via `snapshot_tab_context/1` and `restore_tab_context/2`, which copy ~10 fields between the live state and a context map. This is a manual, error-prone serialization layer that exists because the state doesn't live in its own process.

**File:** `lib/minga/editor/state.ex` (743 lines)
**File:** `lib/minga/editor/state/agent.ex` (309 lines)
**File:** `lib/minga/agent/view/state.ex` (366 lines)
**File:** `lib/minga/agent/panel_state.ex` (566 lines)

### Input Routing

`Input.Scoped` is 858 lines with 36 agent-related private functions vs 4 file-tree functions. It hardcodes agent-specific sub-state machines inline:

1. **Search input** (`handle_search_key/2`): character-by-character search query building with Enter/Escape/Backspace handlers.
2. **Mention completion** (`handle_mention_key/3`): Tab/Shift+Tab navigation, Enter accept, Escape cancel, Backspace prefix truncation.
3. **Tool approval** (`handle_approval_key/2`): y/n/Y/N dispatch.
4. **Diff review** (`handle_diff_review_key/2`): y/x/Y/X hunk acceptance/rejection.
5. **Paste block toggle**: Tab key overloaded to toggle expand/collapse when cursor is on a paste placeholder.

Each of these should be an `Input.Handler` pushed onto the focus stack when its sub-state activates (the same pattern `Picker` and `Completion` already use). Instead, they're checked with nested conditionals before the scope trie is consulted.

The agent side panel (editor scope with panel visible) re-implements insert-mode handling in `handle_panel_insert/3`: Ctrl+S, Ctrl+C, Ctrl+D, Ctrl+U, Ctrl+L, Escape, Backspace, Enter, Shift+Enter, Ctrl+J, arrow keys, and `@` trigger. These duplicate (or subtly differ from) the full-screen agentic view's `handle_agent_key/3` path.

Both paths use `dispatch_vim_key/3`, which manually swaps the active buffer to the agent buffer, runs through the mode FSM, blocks mode transitions, and restores the real buffer. This is the same hack used for file tree navigation (`delegate_to_mode_fsm_with_tree_buffer/3`). The pattern works but creates a tight coupling between `Input.Scoped` and buffer identity.

**File:** `lib/minga/input/scoped.ex` (858 lines)

### Commands

`Commands.execute/2` has 223 clauses. 62 of them (28%) are `agent_*` pass-throughs to `Commands.Agent`:

```elixir
def execute(state, :agent_scroll_down), do: AgentCommands.scope_scroll_down(state)
def execute(state, :agent_scroll_up), do: AgentCommands.scope_scroll_up(state)
def execute(state, :agent_scroll_half_down), do: AgentCommands.scope_scroll_half_down(state)
# ... 59 more
```

`Commands.Agent` is 1,585 lines. It contains session lifecycle management (`start_agent_session`, `restart_session`), prompt submission with mention resolution, slash command dispatch, diff review with disk writes, clipboard operations, code block extraction, chat search, and 30+ `scope_*` functions that map scope trie commands to state mutations.

These functions reach directly into `EditorState.agent` and `EditorState.agentic` via `update_agent/2` and `update_agentic/2` helpers. They are pure `state -> state` functions, which is good, but they operate on the Editor's state struct rather than an agent-owned state, which forces the Editor to be the single owner.

**File:** `lib/minga/editor/commands.ex` (800 lines)
**File:** `lib/minga/editor/commands/agent.ex` (1,585 lines)

### Render Pipeline

`RenderPipeline.run/1` branches at line 226:

```elixir
if state.agentic.active do
  run_agentic(state, layout)
else
  run_windows(state, layout)
end
```

These are two completely separate render paths:

- `run_windows` goes through Scroll -> Content (per-window line rendering) -> Chrome (modeline, minibuffer, file tree, agent side panel, overlays) -> Compose -> Emit.
- `run_agentic` calls `ViewRenderer.render(state)` for content, then `build_chrome_agentic` and `compose_agentic` for chrome and frame assembly.

Each path has its own compose function, its own cursor resolution, and its own chrome builder. The chrome stages share tab bar and minibuffer rendering but diverge on everything else.

The agent side panel (editor scope, panel visible) adds another render path within the regular `run_windows` chrome stage via `render_agent_panel_from_layout/2`.

**File:** `lib/minga/editor/render_pipeline.ex` (1,588 lines)
**File:** `lib/minga/agent/view/renderer.ex` (1,569 lines)

### Editor GenServer

25+ `handle_info` clauses handle `:agent_event` messages. Each one dispatches through `EditorState.route_agent_event/2`, which returns `{:active, tab}`, `{:background, tab}`, or `:not_found`. The active path updates `state.agent`/`state.agentic` directly. The background path uses `update_background_agent/3` or `update_background_agentic/3` to patch the stored tab context map.

This routing exists because agent events arrive as messages to the Editor process (the only GenServer). If agent UI state lived in its own process, these events would go directly there. The Editor would only hear "surface needs re-render."

Event types handled: `status_changed`, `text_delta`, `thinking_delta`, `messages_changed`, `tool_started` (shell, read_file, list_directory, edit_file, write_file), `tool_update` (shell, generic), `tool_ended` (shell, read_file, list_directory, edit_file, write_file, generic), `file_changed`, `approval_pending`, `approval_resolved`, `error`, `spinner_tick`, `dismiss_toast`.

**File:** `lib/minga/editor.ex` (2,235 lines; ~158 lines reference agent/agentic)

### Layout

`Layout.compute/1` handles agent panel rects when the side panel is visible (editor scope). When the agentic view is active, the Layout struct's `agent_panel` field is nil because the `ViewRenderer` handles its own internal layout. This means layout computation is split between `Layout` (for the side panel case) and `ViewRenderer` (for the full-screen case), with no shared abstraction.

**File:** `lib/minga/editor/layout.ex` (360 lines)

---

## Three Symptoms and Their Root Causes

### 1. "Fix it in two places"

**Symptom:** Paste events have explicit `if agent input focused, route to agent; else route to buffer` branching in `Editor.handle_paste_event/2`. The agent side panel's insert-mode handling re-implements Ctrl+S, Ctrl+C, Ctrl+D, Ctrl+U, Ctrl+L, backspace, enter, newline, arrow keys, and @ trigger. Those same keys work differently (or identically by accident) in the full-screen agentic view.

**Root cause:** There is no shared "text input surface" abstraction. The editor's insert mode uses `Mode.Insert` via the mode FSM. The agent's insert mode uses `Input.Vim` via `dispatch_vim_key`. These are two different code paths that happen to implement similar vim grammars.

### 2. Agent state is hostage to the Editor process

**Symptom:** Every agent event (`text_delta`, `tool_started`, `messages_changed`) routes through the Editor's mailbox even though the Editor has nothing to do with the agent's domain logic. The Editor is the bottleneck for agent responsiveness.

**Root cause:** Agent UI state (`AgentState`, `ViewState`, `PanelState`) lives as nested fields inside `EditorState`. The Editor GenServer serializes all access. There is no separate process for agent UI concerns.

### 3. The scope system isn't a scope system

**Symptom:** `Input.Scoped` is a 36-function procedural handler that hardcodes agent-specific sub-state machines. The scope trie is only consulted after special cases are handled.

**Root cause:** The keymap scope behaviour (`Minga.Keymap.Scope`) defines `keymap/2`, `shared_keymap/0`, and trie resolution. But the agent's complexity outgrew the "resolve a key through a trie" model. Sub-states (search, mention, approval, diff review) need their own input handling that the trie can't express. Instead of composing handlers via the focus stack (the pattern Picker and Completion use), these sub-states were inlined into `Input.Scoped`.

---

## Why Not Surfaces?

The first iteration of this refactor proposed a **Surface** abstraction: a tab-level behaviour where BufferView and AgentView each implement `handle_key`, `render`, `handle_event`, etc. We built it, shipped it across PRs #319-#321, and learned it was the wrong abstraction. Here's why.

### Surfaces are tab-level; composition needs window-level

A Surface owns a tab. Switch to an agent tab, AgentView takes over the entire screen. Switch to a file tab, BufferView takes over. They can never coexist in the same tab. You can't split a window with a file buffer on the left and an agent chat on the right. You can't tile four agent sessions. The "agent side panel" (showing agent chat while editing a file) had to be built as a special-case hack rendered inside BufferView's chrome, because two Surfaces can't share a tab.

Minga is agentic-first. The default agent workflow should look like OpenCode or Cursor: file buffer on one side, agent chat on the other, prompt at the bottom. That's a window layout, not a surface type. And users should be able to customize it with standard vim window commands (`Ctrl-W v/s/h/j/k/l`).

### Surfaces duplicate the editing model

The Surface abstraction treats BufferView and AgentView as separate bounded contexts with their own input handling. This led to AgentView reimplementing vim navigation on its own data structures: `agent_scroll_down`, `agent_self_insert`, `agent_input_backspace`, `agent_copy_code_block`, etc. 35 of 62 agent commands are vim operations rebuilt on `TextField` and custom scroll state instead of using the same editing model that file buffers use.

The diagnosis was right ("vim should be shared infrastructure") but the Surface prescription preserved the duplication by giving each surface its own `handle_key` → command dispatch → command execution pipeline.

### Surfaces require bridges

Each Surface has its own state struct (`BufferViewState`, `AgentViewState`). But commands and input handlers were written against `EditorState`. This created a bridge layer: `reconstruct_editor_state` builds a fake EditorState from surface state, handlers run on it, then `Bridge.from_editor_state` deconstructs the result back. This copying happens on every key press, mouse event, and render frame. Adding a field to one struct and forgetting the bridge silently loses state.

### What we keep from the Surface work

The work wasn't wasted. Steps 1-5 established important foundations:
- Agent state (`agent`, `agentic`) is fully removed from EditorState
- Tab contexts store only `{surface_module, surface_state, keymap_scope}`
- Background agent events go through the same handle_event as active tabs
- Agent-specific input handlers (search, mention, approval, diff review) are separate `Input.Handler` modules on the focus stack

These changes survive into the new architecture. The Surface behaviour itself, the bridges, and SurfaceSync are what gets replaced.

---

## The Right Abstraction: Window-Level Content

The window tree already exists (`Minga.Editor.WindowTree`). It already manages splits. It currently only hosts buffer pids. The fix is simple: each window hosts a **content reference** (buffer pid, agent session, terminal, etc.) instead of only buffers. The editing model and `NavigableContent` protocol make vim work in every pane.

### Three layers

**1. EditingModel (behaviour)**: translates key sequences into command atoms.

The vim Mode FSM already does this: `Mode.process(mode, key, mode_state)` returns `:move_down`, `:yank`, `:delete_line`, etc. It doesn't know what content it's operating on. This is the right design. The behaviour formalizes it so CUA (#306) can provide a different implementation.

```elixir
defmodule Minga.EditingModel do
  @callback handle_key(state, buffer_or_content, codepoint, modifiers) :: {state, [command]}
  @callback execute(state, navigable_content, command) :: {state, navigable_content}
end
```

Vim-specific state (`mode`, `mode_state`, `reg`, `marks`, `change_recorder`, `macro_recorder`) lives inside the editing model's state struct, not on the window or editor. This is the right boundary: when CUA arrives, it brings its own state (selection anchor, clipboard mode) without touching the window or editor structs.

**2. NavigableContent (protocol)**: lets commands operate on any content type.

```elixir
defprotocol Minga.NavigableContent do
  def cursor(content)
  def set_cursor(content, position)
  def line_count(content)
  def line_at(content, row)
  def text_in_range(content, start_pos, end_pos)
  def replace_range(content, start_pos, end_pos, text)  # no-op for read-only
  def editable?(content)
  def scroll_region(content)
  def set_scroll(content, top)
  def search(content, pattern, direction)
  def fold_toggle(content, position)
end
```

Commands are written ONCE against the protocol. `move_down` calls `NavigableContent.cursor`, computes the new position, calls `NavigableContent.set_cursor`. It doesn't know if the content is a gap buffer, a structured message list, or terminal scrollback. The protocol adapter handles the translation.

This is why adding evil-surround works in one place: the command calls `text_in_range` and `replace_range`. Each content adapter implements those two functions. The surround logic is written once.

**3. Window tree (universal container)**: each window pane holds content.

```
Editor GenServer
├── Window Tree
│   ├── Window 1: content=buffer_pid, viewport, editing_model_state
│   ├── Window 2: content=agent_session, viewport, editing_model_state
│   └── Window 3: content=buffer_pid, viewport, editing_model_state
├── Tab Bar (saves/restores window tree layouts)
├── Shared chrome (modeline per window, minibuffer, overlays)
└── Editing model state (mode is global, registers are global)
```

### Why this is simpler

**What goes away:**
- `Minga.Surface` behaviour (10 callbacks, 2 implementations)
- `BufferView.Bridge` and `AgentView.Bridge` (reconstruct/deconstruct EditorState)
- `SurfaceSync` (sync_from_editor, sync_to_editor, init_surface, dispatch_event)
- `Surface.Context` struct (copying shared fields between editor and surfaces)
- Two render pipelines (`run_windows` vs `run_agentic`)
- Two layout systems (`Layout.compute` vs `ViewRenderer` internal layout)
- `surface_handlers()` mixed list with self-gating
- Agent side panel hack (special-case rendering inside BufferView)
- `surface_module`/`surface_state` on EditorState
- ~35 reimplemented agent commands (scroll, insert, backspace, yank, search, fold)

**What replaces it:**
- `NavigableContent` protocol (~8 functions, N small adapters)
- `EditingModel` behaviour (~2 functions, vim + future CUA)
- Window tree accepts any content type (small extension to existing code)
- Each content type: an adapter (~50-100 lines) + a renderer + domain commands
- "Agent View" = a window layout preset, not a separate system

### Content types and what they support

| Content | Data structure | Editing | Why not Buffer.Server? |
|---------|---------------|---------|----------------------|
| File buffer | `Buffer.Server` (gap buffer) | Full vim/CUA | N/A, it IS a Buffer.Server |
| Agent prompt | `Buffer.Server` | Full vim/CUA | N/A, it IS a Buffer.Server |
| Chat messages | Structured list (`[%Message{}, %ToolCall{}, ...]`) | Navigation only (no insert) | Structured data with tool cards, streaming, collapse state. Flat text loses semantics, creates undo/reparse problems. |
| `*Messages*` | `Buffer.Server` (read-only) | Navigation + yank | N/A, already a Buffer.Server |
| Preview/diff | Generated read-only content | Navigation + interactive | Content is generated, not user-edited |
| Terminal (#122) | Terminal scrollback | Navigation only | Terminal output has its own cursor model |
| Browser (#305) | Rendered web content | Navigation only | Web content isn't text |

The agent prompt is a Buffer.Server because it's editable text. Chat messages stay as structured data because they have semantic structure (message roles, tool call status, code block languages, collapse state) that flat text can't represent without a complex sidecar mapping system. The `NavigableContent` protocol brings vim navigation to the structured data without forcing it into the wrong data model.

---

## Target Architecture

### Module organization

Code is organized by **domain**, not by technical layer. `Minga.Agent` never imports from `Minga.Buffer`. `Minga.Buffer` never imports from `Minga.Agent`. Both import from shared infrastructure. The namespace makes coupling violations visible at code review.

```
Minga.Editor                              # Thin orchestrator
  editor.ex                               # GenServer: window tree, tabs, overlays, port
  editor/layout.ex                        # Gives each window a rect
  editor/tab_bar.ex                       # Tab bar state and rendering
  editor/modeline.ex                      # Per-window modeline rendering
  editor/minibuffer.ex                    # Shared minibuffer

Minga.Buffer                              # File editing domain
  buffer/document.ex                      # Gap buffer data structure (exists)
  buffer/server.ex                        # Buffer GenServer (exists)
  buffer/commands/movement.ex             # Currently editor/commands/movement.ex
  buffer/commands/editing.ex              # Currently editor/commands/editing.ex
  buffer/commands/operators.ex            # etc.
  buffer/renderer.ex                      # Currently run_windows in render_pipeline
  buffer/layout.ex                        # Window splits, file tree sidebar
  buffer/input/file_tree_handler.ex       # Currently input/file_tree_handler.ex
  buffer/navigable_content.ex             # NavigableContent impl for Buffer.Server

Minga.Agent                               # Agentic domain
  agent/session.ex                        # Session GenServer (exists)
  agent/commands.ex                       # Domain actions: submit, approve, reject
  agent/renderer.ex                       # Currently agent/view/renderer.ex
  agent/layout.ex                         # Chat, prompt, preview pane layout
  agent/input/search.ex                   # Currently input/agent_search.ex
  agent/input/mention_completion.ex       # Currently input/mention_completion.ex
  agent/input/tool_approval.ex            # Currently input/tool_approval.ex
  agent/input/diff_review.ex              # Currently input/diff_review.ex
  agent/navigable_content/chat.ex         # NavigableContent impl for structured messages
  agent/navigable_content/prompt.ex       # NavigableContent impl (delegates to Buffer.Server)

Minga.EditingModel                        # Shared: key → command translation
  editing_model.ex                        # Behaviour definition
  editing_model/vim.ex                    # Vim Mode FSM (wraps existing Mode module)
  editing_model/vim/state.ex              # mode, mode_state, reg, marks, etc.
  editing_model/cua.ex                    # Future: CUA chords, shift-select (#306)

Minga.NavigableContent                    # Shared: content navigation protocol
  navigable_content.ex                    # Protocol definition

Minga.Input                               # Shared: overlay handlers
  input/picker.ex                         # Modal picker overlay
  input/completion.ex                     # Completion popup overlay
  input/conflict_prompt.ex                # Save conflict overlay
```

### How input flows

```
Key arrives at Editor.handle_info
  │
  ├─ Walk overlay handlers (picker, completion, conflict prompt)
  │   └─ If handled: done
  │
  ├─ Walk active window's domain handlers
  │   └─ Agent window: search, mention, tool approval, diff review
  │   └─ Buffer window: file tree handler (if file tree focused)
  │   └─ If handled: done
  │
  └─ Editing model handles key
      └─ EditingModel.Vim.handle_key(vim_state, content, cp, mods)
          ├─ Mode FSM produces command atoms
          ├─ Commands execute against NavigableContent
          │   └─ NavigableContent.move(content, :down)  ← one implementation
          │   └─ NavigableContent.set_cursor(content, pos)
          └─ Returns {new_vim_state, new_content}
```

Every content type goes through the same editing model. The NavigableContent protocol handles the content-specific behavior. Commands are written once.

### How agent events flow

```
Agent.Session sends {:agent_event, event} to the owning window's content
  │
  ├─ Active window: content updates, Editor schedules render
  │
  └─ Background window/tab: content updates silently, renders when activated
```

The Editor is not the message broker. Each agent session knows which window's content it belongs to and sends events directly. The Editor only needs to know "a window's content changed; should I re-render?"

### How rendering works

```
Editor gives each window a rect from the window tree layout
  │
  ├─ Each window renders its content into its rect
  │   ├─ Buffer window: gutter + lines + cursor (Minga.Buffer.Renderer)
  │   ├─ Agent window: chat messages + prompt + preview (Minga.Agent.Renderer)
  │   └─ Terminal window: scrollback text (future)
  │
  ├─ Each window renders its modeline (shared component, content provides data)
  │
  └─ Editor renders shared chrome
      ├─ Tab bar
      ├─ Minibuffer / status line
      └─ Overlays (picker popup, completion menu)
```

One render pipeline. Each content type has its own renderer, but they all receive a rect and produce display list draws. No `if agentic?` branches.

### Window layout presets

"Agent View" is not a surface type. It's a window layout preset:

```
Default "Agent View" layout:
┌──────────────┬──────────────┐
│ File buffer  │ Agent chat   │
│ (editable)   │ (read-only)  │
│              ├──────────────┤
│              │ Prompt       │
│              │ (editable)   │
└──────────────┴──────────────┘
```

The user can customize this with standard vim window commands: `Ctrl-W v` to split, `Ctrl-W q` to close a pane, `Ctrl-W =` to equalize, drag borders with the mouse. Open three agents side by side, or go full-screen agent, or put a terminal at the bottom. It's just windows with content.

Tabs save and restore window tree configurations. Switching tabs restores the exact window layout and content references from when you left.

---

## Testing Strategy

### What to test

- **NavigableContent protocol conformance.** Every content adapter runs against a shared test module that exercises all protocol functions. If `move(:down)` works for buffers, it must work (with appropriate semantics) for chat content, terminal scrollback, etc.
- **EditingModel contract.** Arbitrary key sequences fed to the editing model never crash. Commands returned by the editing model are valid NavigableContent operations.
- **Window tree composition.** Split a window, put different content types in each pane, verify: vim commands work in each pane, switching focus preserves state, closing a pane redistributes space, tab save/restore preserves the layout.
- **Domain isolation.** Agent code never imports Buffer code. Buffer code never imports Agent code. A compile-time check or credo rule enforces this.
- **Content-type-specific rendering.** Given known content state, each renderer produces expected display list draws. Snapshot tests work well here.
- **Editing model switching.** When CUA arrives: switch a window's editing model from vim to CUA, verify standard chords work, switch back, verify vim state is preserved.

### Property-based tests

- Arbitrary key sequences fed to any content type through the editing model never crash.
- Arbitrary window tree operations (split, close, resize, switch focus) never produce invalid layouts.
- Arbitrary NavigableContent operations never move cursor outside content bounds.

### Validation cadence

After every change: `mix test --warnings-as-errors && mix dialyzer`. Dialyzer catches stale references when modules move between domains.

---

## Incremental Migration Plan

The old Phases 1-4 (extract BufferView Surface, extract AgentView Surface, move agent events, push sub-state handlers) are superseded. Some of that work landed and remains valuable (Steps 1-5 above). The new plan builds on that foundation toward the window-level content architecture.

### Phase A: NavigableContent protocol + Buffer.Server adapter

**Goal:** Define the protocol. Implement it for `Buffer.Server`. Prove that existing buffer commands can be expressed as protocol operations.

This is the foundational abstraction. Everything else builds on it. Start small: `cursor`, `set_cursor`, `line_count`, `line_at`, `editable?`. Add `text_in_range`, `replace_range`, `search`, `fold_toggle` as commands need them.

### Phase B: EditingModel behaviour + Vim adapter

**Goal:** Wrap the existing Mode FSM in the EditingModel behaviour. Commands execute against NavigableContent instead of pattern-matching on EditorState fields.

Vim-specific state (`mode`, `mode_state`, `reg`, `marks`, etc.) moves into `EditingModel.Vim.State`, out of EditorState. The editing model is per-window (cursor, scroll) with some global state (registers, mode).

### Phase C: Window tree hosts any content type

**Goal:** Extend `WindowTree` so each window holds a content reference + viewport + editing model state, not just a buffer pid.

The active window determines which content and editing model state receive key input. `Ctrl-W h/j/k/l` switches focus between windows regardless of content type.

### Phase D: Agent prompt → Buffer.Server

**Goal:** Replace `TextField` with a real `Buffer.Server` for the agent prompt. Standard vim editing applies.

This eliminates `agent_self_insert`, `agent_input_backspace`, `agent_insert_newline`, `agent_input_up/down`, `agent_input_to_normal`, and the `Input.Vim` / `dispatch_vim_key` hack.

### Phase E: Structured chat NavigableContent adapter

**Goal:** Implement `NavigableContent` for the agent chat's message list. `j/k` scrolls, `{/}` jumps between messages, `/` searches, `yy` yanks, `za` toggles collapse.

This eliminates `agent_scroll_down/up/half_down/half_up/top/bottom`, `agent_next_message/prev_message`, `agent_start_search/next_search_match/prev_search_match`, `agent_copy_message/copy_code_block`, `agent_toggle_collapse/collapse_all/expand_all`.

### Phase F: Window layout presets + agent side panel removal

**Goal:** "Agent View" becomes a window layout preset (file buffer left, agent chat right, prompt below chat). The agent side panel hack is deleted. The current toggle-agentic-view command applies the layout preset. User customizes with standard vim window commands.

### Phase G: Domain reorganization

**Goal:** Move code into `Minga.Buffer` and `Minga.Agent` namespaces. Delete the Surface layer, bridges, SurfaceSync, Context struct.

Buffer commands move from `editor/commands/movement.ex` to `buffer/commands/movement.ex`. Agent commands move from `editor/commands/agent.ex` to `agent/commands.ex`. The old Surface behaviour module, both bridge modules, and SurfaceSync are deleted.

### Phase H: Remove buffer fields from EditorState

**Goal:** EditorState becomes a thin orchestrator struct: port, theme, tabs, window tree, overlays. No buffer-specific or agent-specific fields.

Content-specific state lives in each window's content reference. Editing model state lives per-window. Shared infrastructure (theme, capabilities, port_manager) stays on EditorState.

---

## Success Criteria

The refactoring is complete when:

1. **No `if agentic?` branches** exist anywhere in the codebase. No parallel code paths for buffer vs agent.
2. **`Minga.Editor` is under 500 lines** and contains only: GenServer callbacks, window tree management, tab management, overlay management, port communication, and shared chrome rendering.
3. **Any content type can go in any window pane.** Split a window, put a file buffer in one pane and an agent chat in the other. Vim works in both.
4. **Adding a new content type** (terminal, browser, git status) requires: implementing `NavigableContent`, writing a renderer, writing domain commands. Zero changes to Editor, Buffer, or Agent code.
5. **`Minga.Agent` never imports from `Minga.Buffer`** and vice versa. Shared infrastructure lives in `Minga.EditingModel`, `Minga.NavigableContent`, and `Minga.Editor`.
6. **evil-surround (or any new vim operation) is implemented once** and works in every content type that supports the required NavigableContent functions.
7. **Agent bugfixes don't touch buffer code.** Buffer bugfixes don't touch agent code. Editing model improvements propagate to all content types automatically.
8. **All tests pass**, `mix dialyzer` clean, CI coverage does not regress after each phase.

```
Editor GenServer (thin orchestrator, ~500 lines)
├── Owns: terminal size, port manager, tab bar, minibuffer
├── Routes input to: active Surface
├── Routes rendering to: active Surface + shared chrome
├── Interprets: surface side effects (open file, switch buffer, push overlay)
│
├── Surface: BufferView
│     ├── Owns: window tree, buffer references, viewport,
│     │         file tree, highlight cache, LSP sync, completion, git buffers
│     ├── Editing model: pluggable via Input.EditingModel behaviour
│     │         Vim: mode FSM, marks, registers, change recorder, macro recorder
│     │         CUA: permanent insert, Shift+arrow selection, clipboard-only (future)
│     ├── Scope: :editor
│     ├── Input: delegated to the active editing model
│     ├── Renders: gutter, lines, modeline, window separators, file tree sidebar
│     └── Events: file watcher, LSP responses, highlight spans, diagnostics
│
├── Surface: AgentView
│     ├── Owns: session pid, chat scroll, panel state (input, vim, history),
│     │         preview pane, search state, toast queue, diff baselines,
│     │         pending approval, spinner, buffer sync
│     ├── Scope: :agent
│     ├── Input: scope trie + Input.Vim for prompt editing
│     ├── Renders: title bar, chat messages, input area, preview/dashboard, modeline
│     └── Events: agent_event (status, text_delta, tool_*, approval, error)
│
└── Shared infrastructure (not surfaces)
      ├── Input.EditingModel  — behaviour for pluggable editing strategies
      │     ├── Input.Vim     — modal editing (mode FSM, operator+motion, registers, marks)
      │     └── Input.CUA     — standard editing (permanent insert, Ctrl chords) (future, #306)
      ├── Input.Handler stack — modal overlays (picker, completion, conflict prompt)
      ├── Keymap.Scope        — trie-based key resolution per scope
      ├── DisplayList / Frame — frame assembly, protocol conversion
      ├── Layout              — rect computation (surface gets its allocated rect)
      ├── Theme               — color scheme
      ├── Modeline            — shared modeline renderer (surfaces provide data)
      └── TabBarRenderer      — shared tab bar
```

### What changes for input flow

```
Before:
  Key arrives -> Editor.handle_info -> Input.Router walks focus stack
    -> Input.Scoped checks keymap_scope, branches on :editor/:agent/:file_tree
      -> Agent: 36 functions of inline sub-state handling
      -> Editor: passthrough to ModeFSM
    -> ModeFSM -> Mode.process -> Commands.execute (223 clauses, 62 agent)

After:
  Key arrives -> Editor.handle_info -> check overlays (picker, completion)
    -> Active Surface.handle_key(surface_state, cp, mods)
      -> BufferView: delegates to editing model (vim: Mode.process; CUA: chord resolver)
      -> AgentView: Scope.Agent trie, then editing model for prompt input
    -> Surface returns {new_state, effects}
    -> Editor applies effects (render, open file, etc.)
```

### What changes for agent events

```
Before:
  Session sends {:agent_event, session_pid, event} to Editor
    -> Editor.handle_info matches 25+ clauses
    -> route_agent_event checks active tab vs background tab vs not found
    -> Active: update state.agent / state.agentic directly
    -> Background: update_background_agent patches tab context map
    -> Editor schedules render

After:
  Session sends {:agent_event, session_pid, event} to Editor
    -> Editor forwards to the AgentView surface that owns session_pid
    -> AgentView.handle_event(surface_state, event)
    -> Returns {new_state, [:render]}
    -> Editor schedules render if it's the active surface
    -> Background surfaces update silently (no render)
```

---

## Testing Strategy

This refactoring touches the most critical code paths in the editor: input routing, command dispatch, rendering, and state management. A regression here breaks everything. The testing bar is higher than a typical feature.

The existing 2,714 tests are the primary safety net. They exercise the full Editor pipeline (keystroke in, render out) through `EditorCase` and would catch most regressions from code movement alone. But the test suite has real gaps in the agent-side code that's being extracted, and the refactoring introduces genuinely new API (the Surface behaviour) that needs tests from scratch.

### Two kinds of testing work

This refactoring requires two distinct activities. Don't mix them in the same PR; they have different failure modes.

**1. Fill coverage gaps (separate PRs, before the refactor).**

The modules being extracted have uneven test coverage. Some are well-tested through integration; others have real behavioral gaps:

| Module | Lines | Dedicated Tests | Risk |
|--------|-------|-----------------|------|
| `Commands.Agent` | 1,585 | 17 | **High.** Session lifecycle, prompt submission, slash commands, diff review with disk writes, and 30+ `scope_*` functions. Many of these are pure `state -> state` functions that are straightforward to test but currently aren't. |
| `ViewRenderer` | 1,569 | ~10 | **High.** Complex rendering logic with multiple code paths (chat messages, tool cards, input area, preview pane). |
| `Input.Scoped` (agent branches) | ~500 of 858 | covered by 59 tests, but agent sub-states are sparse | **Moderate.** The search, mention, approval, and diff review sub-state machines need dedicated tests before they move to separate `Input.Handler` modules. |
| `RenderPipeline` (agentic path) | ~400 of 1,588 | covered by 35 tests, but `run_agentic` is sparse | **Moderate.** |
| `Editor` | 2,235 | 12 | **Low for Phase 1.** Most Editor logic is tested through `EditorCase` integration tests. The 12 dedicated tests are thin, but the integration coverage is real. |

Write characterization tests for `Commands.Agent` and the agent sub-states in `Input.Scoped` as standalone PRs before Phase 2 starts. These tests pin current behavior so that when you move the code, a failure unambiguously means the move broke something, not that the test was wrong.

Phase 1 moves well-tested buffer/editor code. The existing test suite is sufficient protection there. Don't burn time writing characterization tests for `Commands.Movement` when hundreds of existing integration tests already exercise it.

**2. Write tests for new API (as part of each phase).**

The Surface behaviour is genuinely new. Test-drive it:

- **Contract tests for the Surface behaviour.** Write a shared test module that exercises the contract: `handle_key` returns `{state, [effect()]}`, `render` produces valid display list draws, `activate`/`deactivate` round-trip cleanly. Both `BufferView` and `AgentView` run against this shared contract.
- **Integration tests for surface transitions.** Tab switching, overlay push/pop, surface activation/deactivation, and cross-surface effects (agent opens a file in BufferView). These exercise the Editor's orchestration layer.
- **Tab lifecycle tests.** Create tab, switch away, switch back: surface state is preserved. No state leaks between tabs. This is one of the trickiest parts of the refactor (replacing manual snapshot/restore with `activate`/`deactivate`) and worth thorough testing.
- **Error boundary tests.** A surface callback that raises is caught by the Editor. The surface is reset or an error is surfaced. The Editor doesn't crash.

### What to test per layer

- **Surface state transitions.** Given a surface in state X, when key Y arrives, the state becomes Z and effects are E. Pure `state -> {state, effects}` functions are trivially testable.
- **Effect interpretation.** Given a surface returns `{:open_file, "main.ex"}`, the Editor opens the file in the correct tab.
- **Input routing.** Given the focus stack contains [Picker, AgentSearch, Scoped, ModeFSM], key X is handled by handler Y and doesn't leak to handlers below.
- **Render output.** Given a surface with known state, `render/2` produces expected display list draws. Snapshot tests (compare against known-good output) work well here.

### Property-based tests

One property test earns its place: **arbitrary key sequences fed to a surface never crash it.** The focus stack with multiple handlers, prefix state machines, and mode transitions is complex enough that hand-written examples will miss combinations. StreamData generates key sequences that no human would think to test.

Don't write property tests for "effects are valid tuples" or "renders stay within bounds." Dialyzer catches both of those statically through `@spec` on the Surface behaviour callbacks. Minga already runs `mix dialyzer` as a pre-commit check. Use it.

### Validation cadence

After every file move or function extraction: `mix test --warnings-as-errors && mix dialyzer`. Red means stop. Dialyzer is especially valuable for structural refactoring because moving a function between modules is exactly the kind of change where a stale call site shows up as a type error.

Set a CI coverage threshold that fails builds if total project coverage drops after a phase merges. This catches accidental test deletion or dead code paths that lost their coverage without anyone noticing. Don't attach coverage reports to PRs; let CI enforce the floor mechanically.

---

## Incremental Refactoring Plan

Do not attempt this as a single branch. Each phase is a standalone PR that preserves all existing behavior.

### Phase 1: Extract BufferView Surface

**Goal:** Move the `run_windows` render path, buffer-related state fields, and editor-scope input handling into a `Minga.Surface.BufferView` module. The Editor GenServer calls into it.

**What moves:**
- `EditorState` fields: `buffers`, `windows`, `file_tree`, `viewport`, `highlight`, `lsp`, `completion`, `completion_trigger`, `git_buffers`, `injection_ranges`, `search`, `pending_conflict`
- Vim-specific state (`mode`, `mode_state`, `marks`, `last_jump_pos`, `last_find_char`, `change_recorder`, `macro_recorder`, `reg`) moves into the editing model's state, not BufferView's top-level struct. This keeps the door open for alternative editing models (#306) without requiring a separate surface implementation.
- `RenderPipeline.run_windows/2` and its Content/Chrome/Compose stages
- `Commands.Movement`, `Commands.Editing`, `Commands.Operators`, `Commands.Visual`, `Commands.Search`, `Commands.BufferManagement`, `Commands.Marks`, `Commands.Git`, `Commands.Diagnostics`, `Commands.Eval`, `Commands.Project`, `Commands.Help`
- `Input.ModeFSM` handling stays as the default editing model, injected into BufferView via configuration

**What stays in Editor:**
- `port_manager`, `theme`, `status_msg`, `tab_bar`, `capabilities`, `layout`, `render_timer`, `focus_stack` (for overlays)
- Tab switching, overlay management (picker, completion), shared chrome rendering
- Agent-related fields (moved in Phase 2)

**Validation:**
- All existing tests pass. `mix dialyzer` clean. No behavior change.
- Surface behaviour contract tests pass for `BufferView`.
- The Editor delegates to BufferView for buffer-related operations.
- The existing 2,714 tests are the primary safety net here. Phase 1 moves well-tested code; don't block on writing new characterization tests for it.

### Phase 2: Extract AgentView Surface

**Goal:** Move agent-specific state, commands, input handling, and rendering into a `Minga.Surface.AgentView` module.

**What moves:**
- `EditorState` fields: `agent` (%AgentState{}), `agentic` (%ViewState{})
- `Commands.Agent` (all 1,585 lines)
- Agent-specific branches from `Input.Scoped` (search input, mention completion, tool approval, diff review, paste block toggle, agent key dispatch)
- `RenderPipeline.run_agentic/2` and `ViewRenderer.render/1`
- `Agent.View.Mouse`

**What stays in Editor:**
- Tab-level agent management: creating agent tabs, switching between them
- Forwarding `agent_event` messages to the correct AgentView instance (simplified from 25+ clauses to ~5 lines of routing)

**Prerequisite:** Characterization tests for `Commands.Agent` and agent-specific `Input.Scoped` branches must land in separate PRs *before* Phase 2 starts. This is the biggest coverage gap in the refactoring. Don't move code that isn't tested.

**Validation:**
- Agentic view works identically. Agent side panel (editor scope) may need a compatibility shim initially.
- All existing tests pass. `mix dialyzer` clean.
- Surface behaviour contract tests pass for `AgentView`.
- Integration tests cover surface transitions: switching between a BufferView tab and an AgentView tab preserves both surfaces' state.
- Tab lifecycle tests verify `activate`/`deactivate` round-trips preserve agent session state, chat scroll position, and preview pane content.

### Phase 3: Move Agent Events Out of Editor

**Goal:** Agent events go directly to the AgentView surface that owns the session. The Editor stops being the message broker.

**Implementation:**
- Each AgentView instance registers itself as the subscriber for its session pid.
- `Agent.Session` sends events to the registered subscriber (the AgentView), not to the Editor.
- The AgentView updates its own state and sends `{:surface_dirty, surface_id}` to the Editor.
- The Editor schedules a render if the dirty surface is the active tab.
- Background surfaces stay dirty until they become active (lazy re-render).

**What this removes:**
- All 25+ `handle_info({:agent_event, ...})` clauses from `Editor`
- `EditorState.route_agent_event/2` and its active/background/not_found dispatch
- `update_background_agent/3` and `update_background_agentic/3`

**Validation:**
- Agent streaming, tool execution, and multi-tab agent sessions work identically.
- All existing tests pass. `mix dialyzer` clean.
- Integration tests verify the new event path: event arrives at Session, AgentView receives it, Editor gets `{:surface_dirty, id}`, render is scheduled only for the active surface.
- Background tab events do not trigger renders (test with a mock surface that asserts `render/2` is not called).

### Phase 4: Push Sub-State Handlers onto Focus Stack

**Goal:** Search input, mention completion, tool approval, and diff review become `Input.Handler` implementations, pushed onto the focus stack when active.

**Implementation:**

```elixir
# When search starts:
state = push_handler(state, Minga.Input.AgentSearch)

# AgentSearch implements Input.Handler:
defmodule Minga.Input.AgentSearch do
  @behaviour Minga.Input.Handler

  def handle_key(%{agentic: %{search: %{input_active: true}}} = state, cp, _mods) do
    # Handle search keys
    {:handled, updated_state}
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}
end
```

This matches the existing pattern for `Picker` and `Completion`. The focus stack becomes:

```
ConflictPrompt -> Picker -> Completion -> AgentSearch | MentionCompletion | ToolApproval | DiffReview -> Scoped -> GlobalBindings -> ModeFSM
```

`Input.Scoped` shrinks to scope trie resolution only (the `resolve_scope_key` path). All inline sub-state machines are removed.

**Validation:**
- All sub-state interactions (search, mention, approval, diff review) work identically.
- All existing tests pass. `mix dialyzer` clean.
- `Input.Scoped` drops from 858 lines to ~200.
- Each new `Input.Handler` module (AgentSearch, MentionCompletion, ToolApproval, DiffReview) has a dedicated test file covering its key handling paths.
- Property-based test: arbitrary key sequences fed to each handler never crash.
- Focus stack integration tests verify handler ordering: a key consumed by AgentSearch never reaches Scoped or ModeFSM.

---

## DDD Alignment

The refactoring maps cleanly to Domain-Driven Design patterns:

| DDD Concept | Minga Mapping |
|---|---|
| **Bounded Context** | Each Surface is a bounded context with its own domain model, state, and rules. BufferView owns buffer editing; AgentView owns AI chat. They share infrastructure but not domain logic. |
| **Aggregate Root** | The Surface struct is the aggregate root for its context. All mutations go through surface functions, never by reaching into nested state from outside. |
| **Application Service** | `Minga.Editor` becomes the application service: it coordinates between contexts, handles cross-cutting concerns (tab bar, overlays, port communication), and translates surface effects into system actions. |
| **Domain Event** | Surface effects (`[:render, {:open_file, path}]`) are domain events. The Editor interprets them without knowing the surface's internal logic. |
| **Anti-Corruption Layer** | The `Surface` behaviour is the anti-corruption layer between the Editor orchestrator and each view's domain. The Editor never pattern-matches on surface-internal state. |
| **Shared Kernel** | `Input.EditingModel` (and its implementations), `DisplayList`, `Theme`, `Layout`, `Keymap.Scope` are the shared kernel: infrastructure both contexts depend on but neither owns. |

### Elixir-specific patterns

- **GenServer per surface (optional).** Phase 1-2 can use plain modules with `state -> {state, effects}` functions. Phase 3 promotes AgentView to its own GenServer so it can receive events directly. BufferView may stay as a module if the Editor process's mailbox isn't a bottleneck.
- **Behaviour + implementations.** The `Surface` behaviour enforces the contract. Each implementation is a separate module with its own state struct. No inheritance, no shared mutable state.
- **Focus stack composition.** Elixir's pattern matching makes the focus stack walk clean: `Enum.reduce_while(stack, state, fn handler, acc -> handler.handle_key(acc, cp, mods) end)`. Sub-state handlers are just more modules in the list.
- **No `cond` blocks.** Per project standards, all dispatch uses multi-clause functions with pattern matching. The Surface behaviour naturally enforces this.

---

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| **Regression in editor behavior** | Phase 1 is a pure refactor. Run the full test suite after every file move. No behavior change until Phase 3. |
| **Performance regression from message passing** | Phase 3 adds one message hop for agent events (Session -> AgentView instead of Session -> Editor). This is microseconds. The win from removing 25+ pattern-match clauses from the Editor's `handle_info` more than compensates. |
| **Tab switching complexity** | Tab context snapshot/restore becomes simpler: each tab stores its surface's state directly, not a hand-picked subset of EditorState fields. The Surface's `activate/deactivate` callbacks replace the manual snapshot/restore functions. |
| **Agent side panel (editor scope) breaks** | The side panel is a hybrid: editor scope with an agent panel visible. In the target architecture, this is the BufferView rendering with an AgentView panel embedded. This needs a composition mechanism (the BufferView delegates a rect to a mini AgentView). Handle this in Phase 2 with a compatibility shim, clean up in Phase 4. |
| **Shared state (theme, capabilities, terminal size)** | These move into a `Minga.Editor.Context` struct passed to surfaces on each `render` call. Surfaces don't own shared state; they receive it. |

---

## Success Criteria

The refactoring is complete when:

1. **No `if agentic?` branches** exist in the render pipeline, input routing, or command dispatch.
2. **`Minga.Editor` is under 600 lines** and contains only orchestration: init, tab management, overlay management, port communication, and surface delegation.
3. **`Input.Scoped` is under 200 lines** and contains only scope trie resolution. All sub-state machines are separate `Input.Handler` modules.
4. **A new surface can be added** (e.g., a `GitView` for staging, a `HelpView` for documentation) by implementing the `Surface` behaviour and registering it as a tab kind. No changes to the Editor GenServer are required.
5. **Agent bugfixes don't touch editor code** and editor bugfixes don't touch agent code. Shared infrastructure changes (vim grammar, display list, theme) propagate to both surfaces automatically.
6. **All existing tests pass** and `mix dialyzer` is clean after each phase.
7. **Surface behaviour contract tests** pass for every surface implementation. Property-based tests verify that arbitrary key sequences never crash a surface.
8. **CI coverage threshold** does not regress. Total project coverage after the refactoring is equal to or higher than before it started.
