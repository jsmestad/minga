# Surface Extraction Refactor

**Status:** Agent state fully owned by surfaces. Bridge layer reduction in progress.
**Date:** 2026-03-10 (proposed), 2026-03-11 (Phases 1-4 + post-phase landed), 2026-03-11 (Steps 1-3 landed)

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

### Remaining work
- **Buffer field migration**: ~221 refs across the codebase. The right approach is changing command signatures, not wrapping reads in an access module.
- **Command signature changes**: `execute(EditorState.t(), command)` should become surface-specific
- **Input handler signature changes**: handlers should receive surface state directly instead of EditorState
- **Eliminate SurfaceSync**: replace sync_surface_from_editor calls with direct surface_state management

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

## The Missing Concept: Surface

A **Surface** is an independent view context that owns its own state, input handling, and rendering. Both the editor buffer view and the agentic chat view are surfaces. In Domain-Driven Design terms, these are separate **bounded contexts** that share common infrastructure (vim grammar, display list IR, theme) but have their own domain models.

```elixir
defmodule Minga.Surface do
  @moduledoc """
  Behaviour for a view context that can receive input and render itself.

  A Surface owns its domain state and manages its own lifecycle. The
  Editor GenServer holds a reference to the active surface and delegates
  input/rendering to it. Surfaces communicate with the Editor through
  a narrow interface: "I need a re-render" and "switch to buffer X."
  """

  alias Minga.Editor.DisplayList

  @typedoc "Opaque surface state. Each implementation defines its own struct."
  @type state :: term()

  @typedoc "Side effects the Editor must handle after a surface processes input."
  @type effect ::
          :render
          | {:open_file, String.t()}
          | {:switch_buffer, pid()}
          | {:set_status, String.t()}
          | {:push_overlay, module()}
          | {:pop_overlay, module()}

  @doc "Returns the keymap scope name for this surface."
  @callback scope() :: Minga.Keymap.Scope.scope_name()

  @doc "Processes a key press. Returns updated state and any side effects."
  @callback handle_key(state(), codepoint :: non_neg_integer(), modifiers :: non_neg_integer()) ::
              {state(), [effect()]}

  @doc "Processes a mouse event. Returns updated state and any side effects."
  @callback handle_mouse(state(), row :: integer(), col :: integer(), button :: atom(),
              modifiers :: non_neg_integer(), event_type :: atom(), click_count :: pos_integer()) ::
              {state(), [effect()]}

  @doc "Renders the surface into the given rect. Returns display list draws."
  @callback render(state(), rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}) ::
              {state(), [DisplayList.draw()]}

  @doc "Processes a domain-specific event (e.g., agent_event for AgentView)."
  @callback handle_event(state(), event :: term()) :: {state(), [effect()]}

  @doc "Returns the cursor position and shape for the surface."
  @callback cursor(state()) :: {row :: non_neg_integer(), col :: non_neg_integer(), shape :: atom()}

  @doc "Called when this surface becomes the active tab."
  @callback activate(state()) :: state()

  @doc "Called when this surface is backgrounded (another tab activated)."
  @callback deactivate(state()) :: state()
end
```

Key properties:

- **Surfaces own their state.** `BufferView` owns the window tree, buffer list, viewport, file tree, and a pluggable editing model (vim by default). `AgentView` owns the session reference, chat scroll, panel state, preview, search, toast queue. Neither touches the other's state.
- **Surfaces handle their own events.** Agent events go to `AgentView.handle_event/2`, not to the Editor. The Editor only forwards events it can't route itself.
- **Surfaces render into a rect.** The Editor gives the surface a rectangle (the area between the tab bar and the minibuffer). The surface produces display list draws within that rect. The Editor handles shared chrome (tab bar, minibuffer).
- **Side effects are declarative.** A surface returns `[effect()]` tuples, not imperative calls. The Editor interprets them. This keeps surfaces testable as pure `state -> {state, effects}` functions.

---

## Target Architecture

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
