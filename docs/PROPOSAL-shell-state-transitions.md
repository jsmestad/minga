# Proposal: Shell-Owned State Transitions

**Status:** Proposed
**Date:** 2026-03-28
**Related:** Epic #1304 (Editor.State Decomposition), #1203 (Board V1), #1340 (synthetic tab bar removal), #1277 (persisted card zoom), #1235 (scoped tab bar)

## The Problem

The Shell behaviour is half-built. It abstracts presentation (render, chrome, layout, input handlers) but not state transitions (buffer lifecycle, window content management, context preservation). Every buffer operation in `EditorState` and `WorkspaceState` encodes Traditional-shell assumptions. The Board shell silently inherits those assumptions, and they're wrong for its model.

This causes a specific, recurring bug class: state transitions that work correctly in the Traditional shell destroy state in the Board shell. Opening a file overwrites agent chat content. Switching buffers overwrites agent chat content. A buffer crash overwrites agent chat content. Each instance looks like a different bug, but they all have the same root cause: a shared function assumes every window shows a buffer and every shell has a tab bar.

Epic #1304 closed with "Shell independence refactor is complete" because its completion signal was scoped to presentation: "Board has its own chrome and layout and imports nothing from shell/traditional/." That was the right goal for that epic, but it left the other half undone. This proposal covers that other half.

## Where We Are Today

### What the Shell behaviour owns (done)

```
init/1              — shell-specific initial state
render/1            — full frame rendering
build_chrome/4      — chrome draw lists (tab bar, modeline, context bar)
compute_layout/1    — spatial layout rects
input_handlers/1    — overlay + surface handler stack
handle_event/3      — shell-specific events
handle_gui_action/3 — GUI semantic actions
```

### What `EditorState` still owns (the problem)

These functions live in `EditorState` and `WorkspaceState`. They pattern-match on `shell_state.tab_bar` to decide behavior. The Traditional shell gets the smart path. Everything else gets a fallback that assumes Traditional-shell semantics.

| Function | What it does | How it breaks Board |
|----------|-------------|-------------------|
| `add_buffer/2` | Adds buffer to pool, decides where to show it | Two clauses: `%TabBar{}` gets tab logic, `nil` gets `sync_active_window_buffer` which destroys agent content |
| `sync_active_window_buffer/1` | Syncs window content to match `buffers.active` | Unconditionally overwrites `window.content` to `{:buffer, pid}`, destroying `{:agent_chat, _}` |
| `switch_buffer/2` | Changes active buffer | Calls `sync_active_window_buffer`, same destruction |
| `sync_active_tab_label/1` | Updates tab label from buffer name | No-ops on `tab_bar: nil`, harmless but pointless |
| `switch_tab/2` | Snapshots context, switches tab, restores context | No-ops on `tab_bar: nil`, Board has no equivalent |
| `active_tab/1` | Returns current tab | Returns `nil` for Board, callers must handle |
| `find_tab_by_buffer/2` | Finds tab showing a buffer | Returns `nil` for Board |
| `active_tab_kind/1` | Returns `:file` or `:agent` | Hardcodes `:file` for Board |

In `editor.ex`, three more functions reach directly into `shell_state.tab_bar`:

| Function | What it does |
|----------|-------------|
| `update_background_tab_status/3` | Updates agent tab status badge from session events |
| `maybe_set_background_attention/3` | Sets attention flag when agent needs user input |
| `handle_gui_action({:close_tab, id})` | Closes a tab (guards on `tab_bar: nil`) |

The `tab_bar` field has become the de facto shell type discriminator. Code that should ask "what does this shell want to do?" instead asks "does this shell have a tab bar?"

## Where We Need to Get

### The endgame: shells own their state transitions

Every state transition that depends on how the shell presents content goes through the Shell behaviour. `EditorState` does generic work (buffer pool management, process monitoring, workspace field updates) and then dispatches to the shell for decisions about presentation. No function in `EditorState` or `WorkspaceState` pattern-matches on `tab_bar` or any other shell-specific field.

The Shell behaviour gains lifecycle callbacks:

```elixir
# Buffer was added to the pool. Shell decides how to present it.
# Traditional: find or create a tab, snapshot context, sync window.
# Board: if zoomed, add silently or show in split. If grid, buffer
# appears when You card is zoomed into.
@callback on_buffer_added(shell_state(), workspace(), buffer_pid :: pid()) ::
            {shell_state(), workspace()}

# Active buffer changed (user switched with :bn, :bp, picker, etc.).
# Shell decides whether/how to update window content.
# Traditional: sync window, update tab label.
# Board: sync only if window shows a buffer, not if it shows agent chat.
@callback on_buffer_switched(shell_state(), workspace()) ::
            {shell_state(), workspace()}

# A buffer process died. Shell decides how to recover.
# Traditional: switch to nearest tab, close tab if needed.
# Board: if the dead buffer was in the active card's workspace, recover
# to the card's agent chat or the next buffer.
@callback on_buffer_died(shell_state(), workspace(), dead_pid :: pid()) ::
            {shell_state(), workspace()}

# Agent session status changed. Shell updates its own tracking.
# Traditional: update tab status badge, set attention flag.
# Board: update card status, set card attention.
@callback on_agent_status(shell_state(), session_pid :: pid(), status :: atom()) ::
            shell_state()
```

### What `EditorState` keeps

Generic, shell-agnostic operations:

- `Buffers.add/2`, `Buffers.switch_to/2`, `Buffers.remove/2` (buffer pool management)
- `monitor_buffer/2`, `handle_buffer_death/2` (process lifecycle, pre-callback)
- `update_workspace/2`, `update_shell_state/2` (field setters)
- `switch_window/2` (focus movement between windows, already content-aware via `scope_for_content`)
- Tab-related accessors (`active_tab`, `find_tab_by_buffer`, etc.) stay but become delegates to the shell, not `tab_bar` pattern matches

### What `WorkspaceState` loses

`sync_active_window_buffer/1` either:

1. Gets a content-type guard (`content: {:buffer, _}` in the pattern match) so it only touches buffer windows, OR
2. Is removed entirely and replaced by the shell's `on_buffer_switched` callback

Option 1 is the pragmatic choice. The function's semantics become "sync the active buffer reference into the window, but only if the window is already showing a buffer." That's correct for all content types, all shells, forever. No per-type guards, no shell dispatch needed. The shell callbacks handle the higher-level question of "should we even change the active buffer?"

## How to Get There

Three phases, each independently deliverable. Each phase fixes a real bug or eliminates a real coupling. No phase requires a later phase to be useful.

### Phase 1: Fix `sync_active_window_buffer` semantics (the bleeding fix)

**What:** Add `content: {:buffer, _}` to the pattern match in `WorkspaceState.sync_active_window_buffer/1`. One line change, fixes all 7 call sites at once.

**Why first:** This is the immediate source of content destruction. Every buffer lifecycle operation goes through this function. Fixing it stops the bleeding for the Board and for any future content type.

**Scope:** `lib/minga/workspace/state.ex` (1 line), tests to verify agent_chat content is preserved.

**After this phase:** Opening a file while zoomed into a Board agent card no longer destroys the agent view. The file opens "invisibly" in the buffer pool because the Board's `add_buffer` path still doesn't do anything useful with it, but at least it doesn't break anything.

### Phase 2: Shell callback for buffer lifecycle

**What:** Add `on_buffer_added/3` and `on_buffer_switched/2` callbacks to the Shell behaviour. Extract Traditional's tab logic into `Traditional.on_buffer_added/3`. Implement `Board.on_buffer_added/3`. Collapse `EditorState.add_buffer/2` to one clause that dispatches through the shell.

**Why second:** Phase 1 made the fallback path safe (it doesn't destroy content). Phase 2 makes the Board path smart (it actually does something useful with the buffer). This phase also eliminates the `tab_bar` pattern match in `add_buffer`, which is the most egregious shell-type-discriminator in EditorState.

**Scope:**
- `lib/minga/shell.ex` (new callbacks)
- `lib/minga/shell/traditional.ex` (implement `on_buffer_added`, `on_buffer_switched`)
- `lib/minga/shell/board.ex` (implement `on_buffer_added`, `on_buffer_switched`)
- `lib/minga/editor/state.ex` (collapse `add_buffer` to one clause, replace `switch_buffer` internals)
- `lib/minga/workspace/state.ex` (remove or simplify `switch_buffer` if shell handles it)

**Design decision: callback signature.** The callbacks take `(shell_state, workspace, ...)` and return `{shell_state, workspace}`. They don't take or return full `EditorState`. This keeps shells at Layer 1/2 boundary: they can mutate workspace fields and their own state, but they don't see process monitors, render timers, or port managers. Generic concerns (monitoring, rendering) stay in `EditorState`.

**After this phase:** The Board decides what happens when a file opens. V1 behavior: add the buffer silently, don't touch the active window. #1235 (scoped tab bar) can build on this to show the buffer in the card's file list.

### Phase 3: Shell callback for agent events + remaining `tab_bar` elimination

**What:** Add `on_agent_status/3` callback. Move `update_background_tab_status` and `maybe_set_background_attention` logic into shell callbacks. Audit and eliminate all remaining `tab_bar` pattern matches in `EditorState` and `editor.ex`.

**Why third:** This is the cleanup phase. Phases 1 and 2 fix the user-facing bugs. Phase 3 eliminates the remaining architectural debt so the next person adding a shell callback has a clean pattern to follow.

**Scope:**
- `lib/minga/shell.ex` (new callback)
- `lib/minga/shell/traditional.ex` (move tab status logic here)
- `lib/minga/shell/board.ex` (card status logic)
- `lib/minga/editor.ex` (replace direct `shell_state.tab_bar` access with callback dispatch)
- `lib/minga/editor/state.ex` (remaining `tab_bar` accessors become shell delegates)

**Remaining `tab_bar` sites to eliminate (12 total in editor/state.ex + editor.ex):**
- `sync_active_tab_label/1` → shell callback or Traditional-internal
- `active_tab/1` → shell delegate
- `find_tab_by_buffer/2` → shell delegate
- `active_tab_kind/1` → shell delegate
- `set_tab_session/3` → shell delegate
- `switch_tab/2` → stays, but `tab_bar: nil` guard becomes `shell doesn't implement tabs` (already a no-op)
- `update_background_tab_status/3` → `on_agent_status` callback
- `maybe_set_background_attention/3` → `on_agent_status` callback
- `handle_gui_action({:close_tab, _})` → shell's `handle_gui_action` (Board already handles this)
- Agent group GUI actions (3 sites) → shell's `handle_gui_action`

**After this phase:** No function in `EditorState` or `editor.ex` pattern-matches on `tab_bar`. The Shell behaviour is the complete abstraction for both presentation and state transitions. A third shell can be built by implementing the callbacks, with no implicit fallback behavior to worry about.

## Completion Signal

This proposal is done when:

1. `grep -rn "tab_bar:" lib/minga/editor/state.ex lib/minga/editor.ex` returns only the `set_tab_bar` helper and the struct field definition (Traditional-internal)
2. Every Shell behaviour callback that exists has implementations in both `Traditional` and `Board`
3. The Board shell can handle file open, buffer switch, buffer death, and agent status changes through its own callbacks without falling through to generic fallback behavior
4. The test suite includes at least one test per callback verifying Board-specific behavior diverges from Traditional

## What This Doesn't Cover

- **Board's file-switching UX** (#1235). This proposal makes file opens safe and gives the Board a callback to handle them. What the Board actually does with opened files (scoped tab bar, split pane, file list sidebar) is a separate design question.
- **Board session persistence** (#1277). Restored cards with `session: nil` need session restart on zoom. That's a Board-specific feature, not a Shell abstraction concern.
- **`on_buffer_died` callback.** Listed in the endgame for completeness, but can be deferred. The Phase 1 fix to `sync_active_window_buffer` makes buffer death safe for all content types. A smarter recovery strategy is nice-to-have, not a content-destruction bug.
- **CUA editing model** (#306). VimState is workspace-level state that the shell doesn't need to know about. CUA is orthogonal to this work.
- **Deterministic testing** (PROPOSAL-deterministic-editor-testing.md). The `{state, effects}` separation proposed there would make shell callbacks easier to test, but neither blocks the other.
