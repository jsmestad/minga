# Plan: UI Stability for Beta Release

**Status:** Active
**Date:** 2026-03-28
**Goal:** Fix the UI state bugs that make Minga feel janky, stabilize the test suite so changes can be verified, and land the structural fixes that prevent regression — all in one coordinated push.

## Context for cold-start agents

Minga is a terminal code editor. The BEAM (Elixir) process owns all editor state and sends render commands to a Zig TUI frontend over a binary port protocol. The BEAM is the single source of truth. The Zig side is stateless except for paste buffering.

Three existing documents diagnose three facets of the same problem:

- **`docs/UI-STATE-ANALYSIS.md`** — The UI state that controls what appears on screen is a bag of independent nullable fields, not a state machine. The Board shell's zoom lifecycle has a state ownership split that causes agent views to not appear, context bars to show wrong info, and stale state to propagate across card transitions.
- **`docs/PROPOSAL-shell-state-transitions.md`** — Buffer lifecycle functions in `EditorState` encode Traditional-shell assumptions. `sync_active_window_buffer` unconditionally overwrites window content to `{:buffer, pid}`, destroying `{:agent_chat, _}` content in the Board shell. The `tab_bar` field is used as a shell type discriminator.
- **`docs/PROPOSAL-deterministic-editor-testing.md`** — The Editor GenServer is a 62-clause monolith with 19 self-sends that create non-deterministic test interleaving. Core state transitions are untestable without booting the full GenServer. The test suite has required 10+ "fix flaky tests" commits recently.

This plan sequences work from all three into a single execution order. Each work item is independently shippable and testable. The items are grouped into streams that can run in parallel.

---

## Architecture you need to know

### State hierarchy

```
EditorState (GenServer state, one per editor instance)
+-- workspace: WorkspaceState    # per-tab, snapshotted on tab/card switch
|   +-- editing: VimState        # mode FSM (mode + mode_state)
|   +-- buffers: Buffers         # buffer list, active buffer pid
|   +-- windows: Windows         # window tree, active window id
|   +-- keymap_scope: atom       # :editor | :agent | :file_tree | :git_status
|   +-- completion: Completion | nil
|   +-- agent_ui: UIState        # agent panel/view state (per-tab)
|   +-- ...
+-- shell_state: ShellState      # presentation state, NOT snapshotted per tab
|   +-- picker_ui: Picker        # nullable, independent
|   +-- prompt_ui: Prompt        # nullable, independent
|   +-- whichkey: WhichKey       # nullable, independent
|   +-- hover_popup: ...         # nullable, independent
|   +-- agent: Agent.State       # session pid, status, monitors (SINGLETON)
|   +-- tool_prompt_queue: [atom]
|   +-- ...
+-- shell: module                # Shell.Traditional | Shell.Board
+-- layout: Layout | nil
+-- theme: Theme
+-- focus_stack: [module]        # legacy, being replaced by shell.input_handlers
```

### Key files

| File | Role |
|------|------|
| `lib/minga/editor.ex` | GenServer: 62 handle_info clauses, apply_effects/2 |
| `lib/minga/editor/state.ex` | EditorState struct, tab context snap/restore, buffer lifecycle |
| `lib/minga/workspace/state.ex` | WorkspaceState struct, sync_active_window_buffer, field_names |
| `lib/minga/editor/vim_state.ex` | VimState.transition/3 gate function |
| `lib/minga/editor/key_dispatch.ex` | Central key dispatch through Mode FSM |
| `lib/minga/editor/agent_activation.ex` | activate_for_card: 5-step agent view setup |
| `lib/minga/shell/board/state.ex` | Board.State: cards, zoom_into, zoom_out |
| `lib/minga/shell/board/input.ex` | Board grid input, zoom_into_focused |
| `lib/minga/shell/board/zoom_out.ex` | ZoomOut handler, workspace swap |
| `lib/minga/shell/board/card.ex` | Card struct (workspace: map \| nil) |
| `lib/minga/shell/traditional/state.ex` | Traditional.State: tabs, overlays |
| `lib/minga/input.ex` | Handler stack: overlay_handlers, surface_handlers |
| `lib/minga/input/interrupt.ex` | Ctrl-G escape hatch (resets 8 state axes) |
| `lib/minga/mode.ex` | Mode FSM: process/3, display/2, mode_module dispatch |
| `lib/minga/mode/state.ex` | Mode.State: pending tagged union, describe_key |
| `lib/minga/agent/events.ex` | Agent event handler, {state, effects} pattern |
| `lib/minga/editor/render_pipeline.ex` | 7-stage render pipeline |

### Existing patterns to follow

The `{state, effects}` pattern already exists for agent events:

```elixir
# lib/minga/agent/events.ex
@spec handle(EditorState.t(), term()) :: {EditorState.t(), [effect()]}

# lib/minga/editor.ex (line 1365)
@type effect ::
  :render
  | {:render, delay_ms :: pos_integer()}
  | {:open_file, String.t()}
  | {:switch_buffer, pid()}
  | {:set_status, String.t()}
  | {:push_overlay, module()}
  | {:pop_overlay, module()}
  | {:log_message, String.t()}
  | {:log_warning, String.t()}
  | :sync_agent_buffer
  | {:update_tab_label, String.t()}
```

Effects are applied by `apply_effects/2` (line 1385) which calls `apply_effect/2` for each. New handler modules should return `{state, [effect()]}` using this same type.

### Test infrastructure

`test/support/render_pipeline/test_helpers.ex` has `base_state/1` which builds a full `EditorState` without starting a GenServer. This is the foundation for pure state tests.

Headless backend (`backend: :headless`) skips port communication. Tests use `EditorCase` which boots the full GenServer with HeadlessPort.

---

## Work streams

Three parallel streams, each independently valuable. Within each stream, items are sequential. Across streams, items can run concurrently unless noted.

### Stream A: Board zoom fixes (UI-STATE-ANALYSIS)

These fix the user-visible Board bugs. Each is a small, focused change.

#### A1: Content-type guard on sync_active_window_buffer

**What:** Add a content-type pattern match so `sync_active_window_buffer` only replaces content on windows that are already showing a buffer.

**File:** `lib/minga/workspace/state.ex`

**Current code (lines 134-149):**
```elixir
def sync_active_window_buffer(
      %__MODULE__{windows: %{map: windows, active: id} = ws, buffers: buffers} = wspace
    ) do
  case Map.fetch(windows, id) do
    {:ok, %Window{buffer: existing} = window} when existing != buffers.active ->
      window = %{
        Window.invalidate(window)
        | buffer: buffers.active,
          content: Content.buffer(buffers.active)
      }
      %{wspace | windows: %{ws | map: Map.put(windows, id, window)}}
    _ ->
      wspace
  end
end
```

**Change:** Add a guard on the window's content type. Only sync if the window is currently showing a buffer:

```elixir
{:ok, %Window{buffer: existing, content: {:buffer, _}} = window}
    when existing != buffers.active ->
```

Windows showing `{:agent_chat, _}` or any future content type are left untouched.

**Test:** Write a test that constructs a workspace with a window whose content is `{:agent_chat, some_pid}`, calls `sync_active_window_buffer/1`, and asserts the content is unchanged.

**Why this matters:** This is called by every buffer lifecycle operation. Without this guard, opening a file, switching buffers, or a buffer crash destroys agent chat content in the Board shell. This is the single highest-value line change in this entire plan.

**Acceptance:** `sync_active_window_buffer` preserves `{:agent_chat, _}` window content. Existing tests pass.

---

#### A2: Agent deactivation on zoom-out

**What:** Clear the agent session singleton when zooming out of a card, so it doesn't bleed into the grid view or the next card.

**File:** `lib/minga/shell/board/zoom_out.ex`

**Current code (lines 56-84):** `zoom_out/1` snapshots workspace onto card, restores grid workspace, but never touches `shell_state.agent`.

**Change:** After restoring the grid workspace, clear the agent session:

```elixir
# After line 76 (state = %{state | shell_state: board})
# Clear the singleton agent session so it doesn't bleed into grid view
state = Minga.Editor.State.AgentAccess.update_agent(state, fn a ->
  Minga.Editor.State.Agent.clear_session(a)
end)
```

`Agent.clear_session/1` already exists (line 105 of `lib/minga/editor/state/agent.ex`) — it demonitors the session and sets session/monitor/status to nil/nil/:idle.

**Test:** Zoom into an agent card, zoom out, assert `AgentAccess.session(state) == nil`.

**Acceptance:** After zoom-out, `shell_state.agent.session` is nil. Agent events that arrive during grid view don't crash or route to the wrong handler.

---

#### A3: Fresh workspace for first-time zoom into agent card

**What:** When zooming into a card that has never been zoomed into (`card.workspace == nil`), create a proper workspace instead of running `activate_for_card` against the grid workspace.

**File:** `lib/minga/shell/board/input.ex`

**Current code (lines 259-267):**
```elixir
state =
  case card.workspace do
    ws when is_map(ws) and map_size(ws) > 0 ->
      EditorState.restore_tab_context(state, ws)
    _ ->
      state  # BUG: workspace stays as the grid workspace
  end

# activate_for_card then runs against the grid workspace's window
Minga.Editor.AgentActivation.activate_for_card(state, card)
```

**Change:** In the `nil`/empty case, build a minimal workspace before activation. The workspace needs:
- A buffer (create one or reuse the scratch buffer)
- A window pointing to that buffer
- Default keymap_scope (`:editor`, will be overridden by `activate_for_card`)

The simplest approach: don't restore anything (keep the grid workspace), but let `activate_for_card` handle it. The real bug is that `activate_for_card` sets `content: {:agent_chat, session}` on the grid workspace's window, which then gets snapshotted as the card's workspace on zoom-out, corrupting future cycles.

**Better fix:** After `activate_for_card` runs, if the card had no prior workspace, snapshot the newly-activated workspace onto the card immediately so it's available for the next zoom-in:

```elixir
state =
  case card.workspace do
    ws when is_map(ws) and map_size(ws) > 0 ->
      EditorState.restore_tab_context(state, ws)
    _ ->
      state
  end

state = Minga.Editor.AgentActivation.activate_for_card(state, card)

# If this was a first-time zoom, store the activated workspace on the card
# so subsequent zoom-out/zoom-in cycles restore it correctly.
if card.workspace == nil or card.workspace == %{} do
  live_ws = Map.from_struct(state.workspace)
  board = state.shell_state
  board = Minga.Shell.Board.State.update_card(board, card.id, fn c ->
    Minga.Shell.Board.Card.store_workspace(c, live_ws)
  end)
  %{state | shell_state: board}
else
  state
end
```

Wait — this overwrites the grid snapshot that `zoom_into` already stored. The grid snapshot is on the card from line 256. We need to store the activated workspace *separately* or accept that the card's workspace field has a dual purpose (grid snapshot during zoom, card snapshot outside zoom).

**Simplest correct fix:** Don't change the snapshot logic. Instead, fix `zoom_into_focused` to ensure `activate_for_card` gets called *after* a clean workspace is in place. The real problem is that `activate_for_card` mutates `state.workspace.windows` which still holds the grid's windows. The grid workspace shouldn't be the target of agent activation.

**Actual fix:** When the card has no prior workspace, build a fresh one with a fresh window before calling `activate_for_card`:

```elixir
state =
  case card.workspace do
    ws when is_map(ws) and map_size(ws) > 0 ->
      EditorState.restore_tab_context(state, ws)

    _ ->
      # First zoom: reset workspace to clean state so activate_for_card
      # operates on a fresh window, not the grid's window.
      fresh_ws = %{state.workspace |
        keymap_scope: :editor,
        editing: Minga.Editor.VimState.new(),
        completion: nil,
        agent_ui: Minga.Agent.UIState.new()
      }
      %{state | workspace: fresh_ws}
  end
```

This gives `activate_for_card` a workspace with an existing window (inherited from the grid) but with clean editing and agent state. The window's content will be set to `{:agent_chat, session}` by `activate_for_card`. On zoom-out, this gets snapshotted correctly.

**Test:** Create a card with `workspace: nil`, zoom in, assert the agentic view is active (window content is `{:agent_chat, _}`, keymap_scope is `:agent`). Zoom out, zoom back in, assert the same.

**Acceptance:** First-time zoom into an agent card shows the agent view. Second zoom shows the same view with preserved state.

---

#### A4: Deactivation counterpart to activate_for_card

**What:** Create `deactivate_for_card/1` in `AgentActivation` that reverses the activation steps. Call it from `ZoomOut.zoom_out/1` before restoring the grid workspace.

**File:** `lib/minga/editor/agent_activation.ex`

**New function:**
```elixir
@doc """
Deactivates the agent view when zooming out of a card.

Reverses activate_for_card: clears the session singleton, resets
keymap scope to :editor, and unfocuses the prompt. Does NOT modify
workspace.windows — that's handled by the workspace restore in zoom_out.
"""
@spec deactivate(EditorState.t()) :: EditorState.t()
def deactivate(state) do
  state
  |> clear_session()
  |> reset_scope()
  |> unfocus_prompt()
end
```

**Update `ZoomOut.zoom_out/1`:** Call `AgentActivation.deactivate(state)` before restoring the grid workspace. This replaces the manual `clear_session` from A2 with a proper counterpart.

**Test:** Activate agent view, deactivate, assert session is nil, scope is `:editor`, prompt is not focused.

**Acceptance:** `activate_for_card` and `deactivate` are symmetric. Every activation path has a corresponding deactivation.

---

### Stream B: Test suite stabilization (PROPOSAL-deterministic-editor-testing)

These make the test suite trustworthy so you can verify Streams A and C without manual smoke testing.

#### B1: Quarantine timers in headless mode

**What:** Guard every `send(self(), ...)` and `Process.send_after(self(), ...)` in the Editor process so tests don't get non-deterministic timer messages.

**Files:** See the 19 call sites table in `docs/PROPOSAL-deterministic-editor-testing.md` Phase 1.

**Rules:**
- **Skip in headless** if the timer is cosmetic or deferred UX (`:dismiss_toast`, `:warning_popup_timeout`, `:save_session`, `:evict_parser_trees`, `:check_swap_recovery`, spinner msgs, `:mouse_hover_timeout`, `:clear_tool_status`, `:document_highlight_debounce`, `:inlay_hint_scroll_debounce`, `:request_code_lens_and_inlay_hints`)
- **Apply synchronously in headless** if the timer has a functional effect tests rely on (`:setup_highlight`)
- **Already handled** if it goes through `schedule_render` (which has its own headless guard)

For each site, the pattern is:
```elixir
# Before:
Process.send_after(self(), :some_timer, 500)

# After:
if state.backend != :headless do
  Process.send_after(self(), :some_timer, 500)
end
```

Or for synchronous application:
```elixir
# Before:
send(self(), :setup_highlight)

# After:
if state.backend == :headless do
  handle_setup_highlight(state)  # inline the handler
else
  send(self(), :setup_highlight)
end
```

**Test:** Run `mix test` 5 times. No flakes.

**Acceptance:** Timer-related flakiness eliminated. All existing tests pass.

---

#### B2: Pure state functions for buffer lifecycle

**What:** Extract pure `{state, [effect]}` variants of buffer lifecycle operations.

**Files:** `lib/minga/editor/state.ex`, `lib/minga/editor/state/buffers.ex`

**Functions to extract:**
1. `add_buffer_pure(state, pid) :: {state, [effect]}` — tab lookup, in-place vs new tab, snapshot/restore
2. `switch_tab_pure(state, tab_id) :: {state, [effect]}` — snapshot outgoing, restore incoming
3. `close_buffer_pure(state, pid) :: {state, [effect]}` — remove_dead_buffer logic

Existing functions become thin wrappers that call the pure variant and apply effects. All callers unchanged.

**Use the existing effect type** from `lib/minga/editor.ex` (line 1365). Add new effect variants as needed:
```elixir
| {:monitor, pid()}
| {:broadcast, atom(), term()}
| {:setup_highlight, pid()}
```

**Test:** See B3.

**Acceptance:** Pure functions exist. Existing callers unchanged. All tests pass.

---

#### B3: Pure state test suite

**What:** Test buffer lifecycle and tab switching as pure functions without any GenServer.

**Files:** `test/minga/editor/state/buffer_lifecycle_test.exs` (new), `test/minga/editor/state/tab_switch_test.exs` (new)

Build `EditorState` structs using `RenderPipeline.TestHelpers.base_state/1`. All tests `async: true`.

**Buffer lifecycle tests:**
- Add buffer to empty state
- Add buffer when file tab active (in-place replace)
- Add buffer when agent tab active (new file tab)
- Add duplicate buffer (switches to existing tab)
- Close active buffer (switches to neighbor)
- Close only buffer
- Add buffer with Board shell (sync_active_window_buffer preserves agent_chat content — exercises the A1 fix)

**Tab switch tests:**
- File-to-file preserves both contexts
- File-to-agent sets keymap_scope to :agent
- Agent-to-file sets keymap_scope to :editor
- Round-trip invariant: snapshot -> switch -> switch back -> equivalent

**Acceptance:** Every branch in add_buffer, switch_tab, close_buffer has a pure test. Tests run in < 100ms total. No GenServer started.

---

### Stream C: Shell-owned state transitions (PROPOSAL-shell-state-transitions)

These eliminate the architectural root cause: `EditorState` encoding Traditional-shell assumptions.

#### C1: Shell lifecycle callbacks

**What:** Add `on_buffer_added`, `on_buffer_switched`, `on_buffer_died` callbacks to the Shell behaviour.

**File:** `lib/minga/shell.ex` (new callbacks)

```elixir
@callback on_buffer_added(shell_state(), WorkspaceState.t(), pid()) ::
            {shell_state(), WorkspaceState.t()}

@callback on_buffer_switched(shell_state(), WorkspaceState.t()) ::
            {shell_state(), WorkspaceState.t()}

@callback on_buffer_died(shell_state(), WorkspaceState.t(), pid()) ::
            {shell_state(), WorkspaceState.t()}
```

Callbacks take `(shell_state, workspace, ...)` and return `{shell_state, workspace}`. They don't see full `EditorState` — no process monitors, render timers, or port managers. Generic concerns stay in `EditorState`.

**Acceptance:** Shell behaviour has the callbacks. Both Traditional and Board have stub implementations that reproduce current behavior.

---

#### C2: Traditional shell implements buffer lifecycle callbacks

**What:** Move Traditional's tab logic from `EditorState.add_buffer/2` into `Traditional.on_buffer_added/3`.

**Files:**
- `lib/minga/shell/traditional.ex` (implement callbacks)
- `lib/minga/editor/state.ex` (collapse `add_buffer` to one clause that dispatches through shell)

The current `add_buffer/2` has two clauses: one for `%TabBar{}` (Traditional) and one for `nil` (Board fallback). The `%TabBar{}` clause moves into `Traditional.on_buffer_added`. The `nil` clause becomes `Board.on_buffer_added`.

**Acceptance:** `EditorState.add_buffer/2` has one clause that dispatches to `state.shell.on_buffer_added/3`. No `tab_bar` pattern match. Existing tests pass.

---

#### C3: Board shell implements buffer lifecycle callbacks

**What:** Implement `Board.on_buffer_added/3` with Board-specific logic.

**File:** `lib/minga/shell/board.ex`

V1 behavior: add the buffer to the pool silently, don't touch the active window. The A1 fix (content-type guard) already makes this safe — `sync_active_window_buffer` won't destroy agent content. The Board callback just needs to not create tabs.

**Acceptance:** Opening a file while zoomed into an agent card adds it to the buffer pool without affecting the agent view. No tab bar created. Existing tests pass.

---

#### C4: Shell callback for agent events

**What:** Add `on_agent_status/3` callback. Move `update_background_tab_status` and `maybe_set_background_attention` from `editor.ex` into shell callbacks.

**Files:**
- `lib/minga/shell.ex` (new callback)
- `lib/minga/shell/traditional.ex` (tab status badge logic)
- `lib/minga/shell/board.ex` (card status logic)
- `lib/minga/editor.ex` (replace direct `shell_state.tab_bar` access)

**Acceptance:** Agent status events route through shell callbacks. Traditional updates tab badges. Board updates card status. No `tab_bar` pattern match in `editor.ex` for agent events.

---

## Execution order

```
Stream A (Board fixes)          Stream B (Test stability)       Stream C (Shell callbacks)
========================        ========================        ==========================

A1: content-type guard          B1: quarantine timers
    (1 line change)                 (19 sites)
         |                              |
A2: agent deactivation          B2: pure state functions
         |                              |
A3: first-zoom workspace        B3: pure state tests
         |                                                      C1: shell lifecycle callbacks
A4: deactivate counterpart                                           |
                                                                C2: Traditional implements
                                                                     |
                                                                C3: Board implements
                                                                     |
                                                                C4: agent event callback
```

**Dependencies across streams:**
- A1 has no dependencies. Start immediately.
- B1 has no dependencies. Start immediately. Run in parallel with A1.
- A2, A3, A4 depend on A1 (they all touch Board zoom; A1 must land first to avoid conflicts).
- B2 depends on B1 (timer quarantine must land first or pure tests will flake).
- B3 depends on B2 (needs the pure functions to exist).
- C1-C4 depend on A1 (the content-type guard is the safety net that makes shell callbacks safe).
- C2-C3 depend on C1 (need the callback signatures).
- C4 depends on C2 (same pattern, extends it to agent events).

**Parallel execution:** A1+B1 can run simultaneously. After both land, A2-A4 and B2-B3 and C1-C4 can all run in parallel across different branches, merged sequentially (A before C to avoid merge conflicts in Board files).

---

## What is NOT in this plan

- **Modal overlay tagged union** (UI-STATE-ANALYSIS Recommendation 1). High value but large surface area. Do after beta.
- **Context key system** (UI-STATE-ANALYSIS Recommendation 4). Future architectural investment. Not needed for stability.
- **Deterministic-testing Phases 4-8** (display list assertions, window management extraction, shell chrome testing, handler module extraction, integration test thinning). All valuable but not blocking beta.
- **Board file-switching UX** (#1235). This plan makes file opens safe in Board. What the Board does with opened files is a separate feature.
- **CUA editing model** (#306). VimState is already extracted. CUA is orthogonal.
- **Highlight batching bridge** (Deterministic-testing Phase 7b). Measurement-gated, not speculative.

---

## Completion signal

This plan is done when:

1. Opening a file while zoomed into a Board agent card does not destroy the agent view
2. Zooming out of a card clears the agent session singleton
3. First-time zoom into an agent card shows the agent view correctly
4. Zoom out then back in restores the card's workspace with agent view intact
5. `mix test` passes 5 consecutive runs with zero flakes
6. Buffer lifecycle (add, switch, close) has pure function tests that run without a GenServer
7. `EditorState.add_buffer/2` dispatches through `shell.on_buffer_added/3` with no `tab_bar` pattern match
8. Agent status events route through shell callbacks in both Traditional and Board
9. `grep -n "tab_bar:" lib/minga/editor/state.ex lib/minga/editor.ex` shows only the struct field definition and `set_tab_bar` helper (Traditional-internal)

---

## For agents executing this plan

**Read before writing:** Read the target file before making changes. The line numbers in this document are accurate as of 2026-03-28 but may drift.

**One PR per work item.** A1 is one PR. A2 is one PR. Don't bundle.

**Test your changes.** Every work item has an acceptance criterion. Write a test that exercises it. Run `mix test` and `mix test.llm` (if it exists) before marking complete.

**Don't refactor adjacent code.** These changes are surgical. Don't rename variables, add type specs to untouched functions, reorganize imports, or "clean up" code near your change site. Unrelated changes create merge conflicts with parallel streams.

**Don't defer the hard parts.** A3 (first-zoom workspace) and C2 (Traditional implements callbacks) are the hardest items. They require understanding the snapshot/restore lifecycle. If you're unsure, read `EditorState.restore_tab_context/2` (state.ex line 887), `snapshot_workspace_fields/1` (state.ex line 871), and `WorkspaceState.field_names/0` (workspace/state.ex line 70). The round-trip is: `Map.from_struct(workspace)` to snapshot, `Enum.reduce(field_names, ws, ...)` to restore.

**Follow existing patterns.** New pure functions return `{state, [effect()]}` using the existing `@type effect` at editor.ex line 1365. New shell callbacks take `(shell_state, workspace, ...)` and return `{shell_state, workspace}`. New tests use `RenderPipeline.TestHelpers.base_state/1` to build state without a GenServer.

**The content-type guard (A1) is the keystone.** If you're unsure where to start, start there. It's one line, it's safe, and it unblocks everything else.
