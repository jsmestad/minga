# UI State Analysis: Why the Editor Gets Stuck

**Date:** 2026-03-28
**Related:** PROPOSAL-shell-state-transitions.md, Epic #1304, #1203 (Board V1)

## Summary

The editor gets into visual states it shouldn't be able to reach. Overlays linger after they should have closed. The Board shell shows the wrong content when zooming between cards. The agentic view fails to appear on most cards. These all look like different bugs, but they share a root cause: the UI state is a bag of independent nullable fields, not a state machine.

---

## The State Machine That Exists (and Works)

The Mode FSM is a genuine state machine and it's solid:

- 14 modes, each with a dedicated struct and `handle_key/2` callback
- Single gate function `VimState.transition/3` for all transitions (enforced by Credo rule)
- Result contract (`{:continue | :transition | :execute | :execute_then_transition}`) makes every transition explicit
- `Mode.State.pending` is a tagged union enforcing mutual exclusivity at the type level
- Count prefix is reset on every transition

This part of the architecture is correct. The mode FSM doesn't get stuck.

## The State Machine That's Missing

Everything outside the Mode FSM that affects what appears on screen is an independent nullable field. The renderer checks each one:

```
if picker_ui.picker != nil    → render picker overlay
if prompt_ui.handler != nil   → render prompt overlay
if completion != nil          → render completion overlay
if hover_popup != nil         → render hover popup
if signature_help != nil      → render signature help
if whichkey.show              → render which-key popup
```

These fields live in `ShellState` and `WorkspaceState` as independent values. The set of possible visual states is the cartesian product: 2^6 = 64 overlay combinations. Most are nonsensical (picker + prompt + completion all visible), but the type system allows every one.

A state machine would make the illegal combinations unrepresentable:

```elixir
# Current: product type (all combinations legal)
%ShellState{
  picker_ui: %Picker{picker: nil | Picker.t()},
  prompt_ui: %Prompt{handler: nil | module()},
  hover_popup: nil | HoverPopup.t(),
  ...
}

# State machine: sum type (only legal combinations)
@type modal_overlay ::
  :none
  | {:picker, Picker.t()}
  | {:prompt, Prompt.t()}
  | {:completion, Completion.t()}
```

### Why it mostly works anyway

The overlay stacking order in the renderer acts as an implicit priority chain:

```
float_overlays → hover → sig_help → whichkey → completion → picker → prompt
```

Later overlays paint over earlier ones. The cursor priority chain does the same. So visually, the highest-priority overlay usually wins. But "usually" is not "always."

### Where it breaks

1. **Completion + picker both non-nil**: Completion renders behind the picker. Dismiss the picker and stale completion appears from a state set before the picker opened.
2. **Hover persists across mode changes**: Set by an async LSP response, cleared by... unclear paths. If the clear is missed, the hover floats over whatever comes next.
3. **Which-key timer fires after context changes**: Leader sequence starts, scope switches to agent, timer fires — which-key renders with stale keymap data.

### Evidence: the interrupt handler

`Input.Interrupt` (Ctrl-G) is the escape hatch. Look at what it has to manually reset:

```elixir
{state, resets} = maybe_reset_scope(state, resets)      # keymap scope
{state, resets} = maybe_reset_mode(state, resets)        # mode FSM
{state, resets} = maybe_close_picker(state, resets)      # overlay #1
{state, resets} = maybe_close_whichkey(state, resets)    # overlay #2
{state, resets} = maybe_close_conflict(state, resets)    # overlay #3
{state, resets} = maybe_close_completion(state, resets)  # overlay #4
{state, resets} = maybe_clear_agent_prefix(state, resets)# agent state
state = EditorState.clear_status(state)                  # presentation
```

If the UI were one state machine, Ctrl-G would set one field. Instead, it manually enumerates 8 independent axes. Every new overlay added to the editor needs to be added here too.

---

## The Board Zoom Problem

The Board shell bugs (agentic view not showing, tab bar wrong, odd behavior cycling cards) are a specific instance of the nullable-field problem, compounded by a **state ownership split** across the zoom boundary.

### How agent state is split

| State | Lives in | Snapshotted per card? |
|---|---|---|
| `agent_ui` (panel, scroll, toasts) | `workspace.agent_ui` | Yes |
| `agent` (session pid, status, monitors) | `shell_state.agent` | **No** |
| `keymap_scope` | `workspace.keymap_scope` | Yes |
| Window content type | `workspace.windows.map[id].content` | Yes |

There is **one** `shell_state.agent.session` — a global singleton. But there are **N** cards, each with their own workspace snapshot containing `agent_ui`, `keymap_scope`, and window content.

### The zoom-in/zoom-out lifecycle

**Zoom into Card A (agent):**
1. Current workspace → snapshot stored on Card A
2. Card A's saved workspace → restored as live workspace
3. `AgentActivation.activate_for_card` runs:
   - `shell_state.agent.session = card_a.session` (global slot overwritten)
   - `workspace.keymap_scope = :agent`
   - Active window content → `{:agent_chat, card_a.session}`
   - `agent_ui.panel.input_focused = true`

**Zoom out of Card A:**
1. Live workspace → stored on Card A
2. Card A's grid snapshot → restored as live workspace
3. `shell_state.agent.session` is **not touched** — still points to Card A

**Zoom into Card B (agent):**
1. Grid workspace → snapshot stored on Card B
2. Card B's workspace → restored
3. `activate_for_card` runs → `shell_state.agent.session = card_b.session`

This works in the happy path. Here's where it breaks:

### Bug: agentic view doesn't show on most cards

When a card has **never been zoomed into** (or its workspace was cleared), `card.workspace` is `nil`. In `Board.Input.zoom_into_focused/1`:

```elixir
case card.workspace do
  ws when is_map(ws) and map_size(ws) > 0 ->
    EditorState.restore_tab_context(state, ws)
  _ ->
    state  # workspace stays as the grid workspace
end
```

The workspace isn't restored, but `activate_for_card` still runs and sets the window content to `{:agent_chat, session}` on the **grid workspace's window**. This window may not be appropriate for the agent view. On subsequent zoom cycles, the wrong workspace gets snapshotted and restored, carrying the error forward.

### Bug: no agent deactivation on zoom-out

`ZoomOut.zoom_out/1` snapshots the workspace and restores the grid workspace. It does **not** call any deactivation step. After zoom-out:

- `shell_state.agent.session` still points to the last card's session
- Any code checking `AgentAccess.session(state)` gets a non-nil session
- Any agent events that arrive route to whatever session is in the singleton

There is no `deactivate_agent_for_card` counterpart to `activate_for_card`.

### Bug: context bar shows wrong card info

When zoomed, `Board.build_chrome` reads `shell_state.zoomed_into` to find the card and render its context bar. If the workspace doesn't match that card (because `restore_tab_context` was skipped or returned stale data), the context bar shows Card X's info while the editor shows Card Y's content.

---

## How Other Editors Solve This

### VSCode: context keys

Every keybinding has a `when` clause evaluated against a flat namespace of observable facts (`suggestWidgetVisible`, `inQuickOpen`, `editorTextFocus`). The system determines which binding matches — handlers don't check their own preconditions. The state space is a set of facts, not a product of nullable fields.

### Neovim: everything is a window

Popups, completion menus, and file pickers are floating windows with buffer-local keymaps. The mode FSM runs unchanged against whatever buffer is focused. There's no separate "overlay" concept at the mode level. Focus is structural (which window), not modal (which handler).

### Emacs: everything is a buffer, keymaps compose

The minibuffer, completion, file tree — all buffers with their own major mode and composed keymaps. `set-transient-map` handles temporary key capture (like pending operations) with automatic deactivation. No overlay cleanup needed.

### Zed: focus is a tree

UI elements form a tree. Focus flows through it. Actions dispatch to the focused node and bubble up. Two siblings can't both have focus — the structure prevents it.

### Common principle

All four editors route input by **structural focus**, not by **each handler checking its own preconditions**:

```
# Minga today:
key → walk handler list → each handler asks "am I active?" → first "yes" wins

# Modern editors:
key → resolve focus target → look up bindings for that context → execute
```

---

## Recommendations

### 1. Modal overlay as a tagged union (immediate value)

Replace independent nullable overlay fields with a single tagged union for modal overlays:

```elixir
@type modal_overlay ::
  :none
  | {:picker, Picker.t()}
  | {:prompt, Prompt.t()}
  | {:completion, Completion.t()}
```

Transient floats (hover, signature help, which-key) can remain independent — they're informational and don't capture input. But the modal overlays that capture input should be mutually exclusive by construction.

This eliminates the entire class of "two modals active at once" bugs and simplifies both the interrupt handler and the renderer.

### 2. Agent deactivation on zoom-out (Board fix)

Add a `deactivate_agent_for_card` step to `ZoomOut.zoom_out/1` that clears `shell_state.agent.session` before restoring the grid workspace. The smallest change that fixes the Board bugs.

Longer term, the agent session should either move into the workspace (snapshotted per card) or be indexed by card ID so all sessions coexist.

### 3. Shell-owned state transitions (already proposed)

PROPOSAL-shell-state-transitions.md covers the `sync_active_window_buffer` destruction bug and the `tab_bar`-as-type-discriminator problem. That work is complementary to this analysis — it fixes the buffer lifecycle side while this document addresses the overlay and zoom lifecycle side.

### 4. Context system (future)

A VSCode-style context key system would replace the handler chain with declarative guards. Each binding declares the conditions it needs; the system resolves which binding matches. This is the highest-leverage long-term change but also the largest.

---

## Relationship to Existing Work

| Document | Scope | Overlap |
|---|---|---|
| PROPOSAL-shell-state-transitions.md | Buffer lifecycle through shell callbacks | Complementary — that fixes `sync_active_window_buffer`, this addresses overlay and zoom state |
| ARCHITECTURE.md | System-level process architecture | No overlap — that covers the BEAM/frontend split, this covers state shape within the BEAM |
| KEYMAP-SCOPES.md | Keymap scope design | Tangential — scope is one axis of the state problem identified here |
