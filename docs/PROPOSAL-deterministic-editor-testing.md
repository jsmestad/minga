# Deterministic editor testing: from monolith GenServer to layered state machine

**Type:** Proposal

## What

The Editor GenServer is a 2400-line, 75-clause monolith that handles input dispatch, rendering, buffer lifecycle, tab management, highlight events, LSP responses, agent lifecycle, session persistence, tool installation, and timer management in a single process. Every new feature adds more `handle_info` clauses that can interact with every other clause through shared mutable state. The test infrastructure can only reach state transitions by booting this full process, which brings 20+ deferred messages that create non-deterministic interleaving.

This proposal restructures the Editor into a thin state machine with focused handler modules, and builds three decoupled test layers that each operate at the right level of abstraction. The goal: any change to any shell, chrome, or UX workflow can be tested deterministically, and changes to one area don't break tests for unrelated areas.

## Why

The test suite has required at least 10 dedicated "fix flaky tests" commits over the past few weeks. Each fix patches one symptom (wrong frame waiter, stale snapshot, timer race) without addressing the root cause: the Editor GenServer does too many things, and side effects are inseparable from the state logic under test.

This is a scaling problem, not a quality problem. Every new shell feature, LSP integration, or agent capability adds more clauses to the same 75-clause process. The interaction surface grows with each new clause: certain clause pairs share mutable state in ordering-dependent ways, and every new clause creates potential new interactions with existing ones. No amount of sync barriers or sleep-based polling fixes this because the architecture makes non-determinism structural.

The current 75 clauses break down as:

| Subsystem | Clauses | Could be a separate module? |
|-----------|---------|------------------------------|
| Highlight/parser events | 15 | Yes |
| Input (key, mouse, paste, resize, GUI) | 8 | No (core, stays) |
| Tool installation events | 8 | Yes |
| LSP responses + debounce timers | 6 | Partially (debounce stays) |
| API calls (handle_call) | 9 | No (external interface) |
| Agent events | 3 | Already uses effects pattern |
| Session/lifecycle | 5 | Yes |
| UI timers (render, flash, popup, spinner) | 7 | No (stays, but becomes trivial) |
| Casts (render, log, background buffer) | 5 | No (stays) |
| File watcher, git events | 3 | Yes |
| Process DOWN | 1 | No (stays) |
| Catch-all | 1 | N/A |

31 clauses handle concerns that don't need inline domain logic in the Editor process. Extracting them to pure handler modules cuts the Editor to ~44 clauses, with the remaining clauses being thin routers (≤5 lines each) that delegate to handlers and apply effects.

## The end state

When this proposal is complete:

1. **The Editor GenServer is a thin state machine.** Each `handle_info` clause either routes input to `Input.Router`, delegates to a handler module and applies the returned effects, or triggers a render. No clause contains domain logic. No clause exceeds 5 lines.

2. **State transitions are pure functions.** Buffer lifecycle, tab switching, window management, and layout computation are all `state -> {state, effects}` functions testable without any GenServer.

3. **Subsystem logic lives in pure handler modules.** Highlight event routing, tool installation lifecycle, and session persistence each have a dedicated handler module that implements `handle(state, event) :: {state, [effect]}`. The Editor's catch-all clauses delegate to these handlers. Each handler is independently testable as pure functions without starting any GenServer. A separate batching process is added only if telemetry shows highlight message volume causes measurable input latency (see Phase 7b).

4. **Tests assert at the right level.** State tests use pure functions (microseconds, never flake). Rendering tests use display list assertions (decoupled from chrome layout). Snapshot tests are a thin visual regression layer, not the primary test of anything.

5. **New features don't touch the Editor GenServer.** A new shell, LSP feature, or agent capability adds logic to handler modules and pure state functions. The Editor's clause count stays flat.

## Acceptance Criteria

1. Buffer lifecycle state transitions (add, switch, close, find-or-create tab) are testable as pure functions without starting any GenServer
   - Tests cover: add to file tab (in-place), add from agent tab (new tab), add duplicate (switch to existing), close last/active/inactive buffer
2. Tab switch round-trips are testable as pure functions
   - `snapshot -> switch_tab -> snapshot` produces equivalent contexts for each tab
   - Tests cover: file-to-file, file-to-agent, agent-to-file, same-tab no-op
3. No `Process.send_after(self(), ...)` or `send(self(), ...)` fires during headless-mode Editor operations except where the effect is applied synchronously
4. A display list assertion layer lets tests verify rendering without depending on cell grid layout
   - Content tests survive modeline/tab bar/gutter changes
5. Window management operations (split, close, focus, resize) are testable as pure functions
6. Layout computation is testable as a pure function with no side effects
7. Each shell's chrome is independently testable: Traditional tests don't break when Board changes
8. Highlight event processing is handled by a dedicated pure module (`HighlightHandler`), not inline in the Editor GenServer
   - The Editor has 1-2 catch-all clauses that delegate to `HighlightHandler.handle/2` instead of routing 15 message types
   - If telemetry shows highlight message volume causes measurable input latency (>1ms per parse cycle), a batching bridge process is added (Phase 7b, measurement-gated)
9. Tool installation events are handled by a dedicated pure module (`ToolHandler`), not inline in the Editor GenServer
10. The Editor GenServer has ≤45 `handle_info`/`handle_cast`/`handle_call` clauses (down from 75), with no clause exceeding 5 lines of logic
11. The existing test suite continues to pass
12. `mix test.llm` and `make lint` pass clean

## Developer Notes

### Phase 1: Quarantine timers in headless mode

**Delivers:** AC 3. Immediate stability improvement for all existing tests.

Files: `lib/minga/editor.ex`, `lib/minga/editor/highlight_events.ex`, `lib/minga/editor/lsp_actions.ex`, `lib/minga/editor/completion_handling.ex`, `lib/minga/editor/commands/buffer_management.ex`, `lib/minga/editor/state/mouse.ex`, `lib/minga/editor/state/session.ex`

Every `send(self(), msg)` and `Process.send_after(self(), msg, delay)` in the Editor process gets one of two treatments:
- **Skip in headless:** Timer is purely cosmetic or deferred UX. Guard with `if state.backend != :headless`.
- **Apply synchronously in headless:** Timer has a functional effect tests rely on. Call the handler inline instead of self-sending.

**Important:** Phase 1 is a stabilizer, not a fix. It forks production and test code paths at 19 points. Phases 2-3 and 7 pay down this debt by making the underlying logic pure and testable without the timer fork. If those phases stall, the headless guards become permanent technical debt. Sequence Phases 2-3 and 7 immediately after Phase 1.

19 call sites:

| Call site | Message | Treatment |
|-----------|---------|-----------|
| `init/1` L221 | `:evict_parser_trees` | Skip |
| `:ready` handler L380 | `:setup_highlight` | Apply sync |
| `:parser_restarted` L839 | `:evict_parser_trees` | Skip |
| agent toast L1063 | `:dismiss_toast` | Skip |
| tab switch L1105 | `:save_session` | Skip |
| tool install L1134 | `:clear_tool_status` | Skip |
| `schedule_render` L1482 | `:debounced_render` | Already handled |
| spinner effect L1584 | spinner msg | Skip |
| effect dispatch L1598 | `{:send_after, ...}` | Guard |
| swap recovery L1682 | `:check_swap_recovery` | Skip |
| `register_buffer` L1762 | `:request_code_lens_and_inlay_hints` | Skip |
| warning popup L2299 | `:warning_popup_timeout` | Skip |
| completion L48 | `:completion_resolve` | Skip |
| highlight_events L60 | `:setup_highlight` | Apply sync |
| lsp_actions L169 | `:document_highlight_debounce` | Skip |
| lsp_actions L617 | `:inlay_hint_scroll_debounce` | Skip |
| buffer_management L487 | `:setup_highlight` | Apply sync |
| mouse state L146 | `:mouse_hover_timeout` | Skip |
| session state L53 | `:save_session` | Skip |

### Phase 2: Extract pure state transitions (buffer/tab lifecycle)

**Delivers:** AC 1, AC 2 (infrastructure).

Files: `lib/minga/editor/state.ex` (primary), `lib/minga/editor/state/buffers.ex`

The `{state, effects}` pattern already exists for agent events (editor.ex L1353). Extend it to buffer lifecycle and tab switching.

Define an effect type (extend the existing `@type effect` or create a shared one):

```elixir
@type state_effect ::
  {:monitor, pid()}
  | {:broadcast, atom(), term()}
  | {:log, String.t()}
  | {:setup_highlight, pid()}
  | {:schedule_code_lens, non_neg_integer()}
  | {:rebuild_agent_session, pid()}
  | {:stop_spinner}
  | {:start_spinner}
```

Extract pure variants of three entangled operations:

1. **`add_buffer_pure(state, pid) :: {state, [state_effect]}`** — tab lookup, in-place vs new tab, snapshot/restore. Returns effects instead of calling `Process.monitor`, `Minga.Events.broadcast`.
2. **`switch_tab_pure(state, tab_id) :: {state, [state_effect]}`** — snapshot outgoing, restore incoming, invalidate windows. Spinner management and session rebuild as effects.
3. **`close_buffer_pure(state, pid) :: {state, [state_effect]}`** — `remove_dead_buffer` logic as pure function.

Existing functions stay as thin wrappers that call the pure function and apply effects. All callers unchanged.

### Phase 3: Pure state test suite

**Delivers:** AC 1, AC 2 (coverage).

Files: `test/minga/editor/state/buffer_lifecycle_test.exs` (new), `test/minga/editor/state/tab_switch_test.exs` (new)

Build `EditorState` structs directly using an extended version of `RenderPipeline.TestHelpers.base_state/1` (which already builds state without a GenServer).

**Buffer lifecycle tests** (pure, async: true, microsecond runtime):
- Add buffer to empty state
- Add buffer when file tab active (in-place replace)
- Add buffer when agent tab active (new file tab)
- Add duplicate buffer (switches to existing tab)
- Add buffer with no tab bar (fallback path)
- Close active buffer (switches to neighbor)
- Close inactive buffer (active unchanged)
- Close only buffer (creates empty replacement)
- Close buffer clears agent/prompt references when matching

**Tab switch tests** (pure, async: true):
- file-to-file preserves both contexts
- file-to-agent sets keymap_scope to :agent
- agent-to-file sets keymap_scope to :editor
- Same tab is no-op
- Round-trip invariant: snapshot -> switch -> switch back -> equivalent
- Legacy context migration (nested format, bare-field format)

### Phase 4: Display list assertion layer

**Delivers:** AC 4.

Files: `test/support/display_list_assertions.ex` (new), `test/support/editor_case.ex` (extend)

The display list IR (`Frame`, `WindowFrame`, styled text runs) already exists. The missing piece is assertion helpers that let tests verify rendering at this level.

```elixir
# Extract text from a WindowFrame's content draws
@spec window_content_text(WindowFrame.t()) :: [String.t()]

# Find draws in a frame section matching a text pattern
@spec find_draws(Frame.t(), :tab_bar | :minibuffer | :status_bar, String.t()) :: [draw()]

# Assert window contains expected text
defmacro assert_window_has_text(frame, row, expected_text)

# Assert cursor position
defmacro assert_frame_cursor(frame, row, col, shape)
```

Add a `render_frame(state)` helper that runs Layout through Compose and returns the `Frame` without emitting to HeadlessPort. The `base_state/1` helper already proves this works: `RenderPipeline.TestHelpers` builds state and runs pipeline stages without any GenServer.

### Phase 5: Pure extraction for window management

**Delivers:** AC 5, AC 6.

Files: `lib/minga/editor/state/windows.ex`, `lib/minga/editor/window_tree.ex`, `lib/minga/editor/layout.ex`

Good news: `Window`, `WindowTree`, and `Windows` are already mostly pure (zero `GenServer.` calls, zero `Process.monitor` calls). The entanglement is only in 2-3 `EditorState` wrappers:

- `focus_window/2` calls `Buffer.move_to(target_win.buffer, target_win.cursor)` — becomes effect `{:move_cursor, pid, position}`
- `sync_active_window_cursor/1` calls `Buffer.cursor(buf)` — pure variant takes cursor as argument

Layout is already pure (`Layout.compute/1`). Just needs test coverage.

New tests in `test/minga/editor/state/windows_test.exs`:
- Split horizontal/vertical: correct dimensions
- Close split: returns to single window
- Focus switch: updates active, swaps buffer references
- Resize: proportional dimension updates
- Layout compute: correct rects for single, splits, file tree open/closed

### Phase 6: Shell-independent chrome testing

**Delivers:** AC 7.

Files: `test/minga/shell/traditional/chrome_test.exs` (new or expanded), `test/minga/shell/board/chrome_test.exs` (new)

Each shell's `build_chrome(state, layout, scrolls, cursor_info) :: Chrome.t()` is already a pure function. Test it directly:

```elixir
test "Traditional status bar shows mode badge" do
  state = base_state() |> set_mode(:insert)
  state = Layout.put(state)
  layout = Layout.get(state)
  {scrolls, state} = Scroll.scroll_windows(state, layout)

  chrome = Traditional.Chrome.build_chrome(state, layout, scrolls, nil)

  assert has_status_bar_text?(chrome, "INSERT")
end
```

Traditional modeline changes don't break Board tests. Board card layout changes don't break Traditional tests.

### Phase 7: Extract handler modules for highlight, tool, session, and file events

**Delivers:** AC 8, AC 9, AC 10.

This phase applies the same `{state, effects}` pattern from Phase 2 to the remaining 31 extractable clauses. The key insight: you don't need a separate process to get testable, isolated code. You need the logic in pure functions. A separate process only buys you one thing: moving message processing off the Editor's mailbox so it doesn't block input. That's only valuable if a subsystem generates enough message volume to cause input latency, and most of these don't.

Files: `lib/minga/editor/handlers/highlight_handler.ex` (new), `lib/minga/editor/handlers/tool_handler.ex` (new), `lib/minga/editor/handlers/session_handler.ex` (new), `lib/minga/editor/handlers/file_event_handler.ex` (new), `lib/minga/editor.ex` (remove ~31 clauses, add 4 catch-all clauses)

**Highlight events (15 clauses → 1-2):**

```elixir
# Before: 15 separate handle_info clauses for each parser message type
def handle_info({:minga_highlight, {:highlight_names, buffer_id, names}}, state) do ...
def handle_info({:minga_highlight, {:highlight_spans, buffer_id, spans}}, state) do ...
# ... 13 more

# After: 1 catch-all that delegates to a pure handler
def handle_info({:minga_highlight, _} = msg, state) do
  {state, effects} = HighlightHandler.handle(state, msg)
  {:noreply, apply_effects(state, effects)}
end
```

`HighlightHandler` is a plain module with pure functions. It holds the routing logic (buffer_id matching), version checking, eviction scheduling, and all 15 event-type handlers. Each function takes state and an event, returns `{state, effects}`. The buffer_id routing table stays in `state.workspace.highlight.buffer_ids` where the render pipeline can read it without crossing a process boundary.

**Tool events (8 clauses → 1):**

```elixir
def handle_info({:tool_event, _} = msg, state) do
  {state, effects} = ToolHandler.handle(state, msg)
  {:noreply, apply_effects(state, effects)}
end
```

Handles `:tool_install_started`, `:tool_install_progress`, `:tool_install_complete`, `:tool_install_failed`, `:tool_uninstall_complete`, `:clear_tool_status`, and tool-missing prompts. Tool installation is infrequent (once per session at most). A process boundary here is pure overhead.

**Session events (5 clauses → 1):**

```elixir
def handle_info({:session_event, _} = msg, state) do
  {state, effects} = SessionHandler.handle(state, msg)
  {:noreply, apply_effects(state, effects)}
end
```

Handles `:save_session`, `:check_swap_recovery`, and session timer management. Timer-driven saves don't need a separate mailbox.

**File/git events (3 clauses → 1):**

```elixir
def handle_info({:file_event, _} = msg, state) do
  {state, effects} = FileEventHandler.handle(state, msg)
  {:noreply, apply_effects(state, effects)}
end
```

Handles `:file_changed_on_disk`, `{:minga_event, :buffer_saved, ...}`, `{:minga_event, :git_status_changed, ...}`.

**Handler isolation rule:** Each handler module touches only its own state slice. `HighlightHandler` reads and writes `state.workspace.highlight`. `ToolHandler` reads and writes `state.tool_status`. If a handler needs to read another slice (e.g., ToolHandler needs `state.workspace.buffers` to find the active buffer name), it reads but never writes. This keeps handlers independent without requiring a process boundary to enforce isolation.

**Testing:** Each handler module gets its own test file. Construct an `EditorState` using `base_state/1`, call `Handler.handle(state, event)`, assert on the returned `{state, effects}` tuple. No GenServer, no HeadlessPort, `async: true`, microsecond runtime.

```elixir
test "highlight_spans updates the correct buffer's highlight state" do
  state = base_state() |> with_buffer(pid, buffer_id: 42)
  spans = [%{start: {0, 0}, end: {0, 5}, face: :keyword}]

  {new_state, effects} = HighlightHandler.handle(state, {:minga_highlight, {:highlight_spans, 42, spans}})

  assert new_state.workspace.highlight.spans[42] == spans
  assert {:render} in effects
end

test "highlight_spans for unknown buffer_id is a no-op" do
  state = base_state() |> with_buffer(pid, buffer_id: 42)

  {new_state, effects} = HighlightHandler.handle(state, {:minga_highlight, {:highlight_spans, 999, []}})

  assert new_state == state
  assert effects == []
end
```

**Interaction tests (pure):** The handlers share state through the Editor, so test the interaction at the state level:

```elixir
test "buffer close followed by stale highlight update is a no-op" do
  state = base_state() |> with_buffer(pid, buffer_id: 42)
  {state, _effects} = BufferLifecycle.close_buffer_pure(state, pid)
  {state, effects} = HighlightHandler.handle(state, {:minga_highlight, {:highlight_spans, 42, spans}})

  # buffer_id 42 is gone, handler should no-op
  assert effects == []
end
```

After Phase 7, the Editor GenServer has ~44 clauses:
- Input dispatch (8): key, mouse, paste, resize, ready, capabilities, GUI action
- API calls (9): open_file, active_buffer, mode, save, execute_command, etc.
- Casts (5): render, log, background buffer, extensions
- UI timers (7): debounced render, nav flash, warning popup, whichkey, space leader, mouse hover
- Handler delegates (4): highlight, tool, session, file events
- Agent events (3): already use effects pattern
- LSP responses (6): keep in Editor for now (debounce timers need self-sends)
- Process DOWN (1)
- Catch-all (1)

Each clause is a thin router: extract data from the message, call a handler module, apply effects, maybe render.

### Phase 7b: Highlight batching bridge (measurement-gated)

**This phase ships only if telemetry data justifies it. Do not build it speculatively.**

The question Phase 7b answers: does highlight message volume cause measurable input latency? If the parser sends 6 messages per parse cycle and each takes 10µs to process, that's 60µs. Not worth a process boundary. If it sends 500 span messages that take 5ms total, now you have a case.

**How to measure:** Add a telemetry span around the highlight catch-all clause from Phase 7. Use the existing `[:minga, :input, :dispatch]` span as a baseline. If highlight processing consistently exceeds 1ms per parse cycle and correlates with perceptible input lag, proceed.

If measurement justifies it:

Files: `lib/minga/editor/highlight_bridge.ex` (new GenServer), `lib/minga/editor.ex` (modify highlight catch-all)

The bridge sits between the parser and the Editor. It collects all highlight messages from a single parse cycle, runs them through `HighlightHandler` to produce a consolidated update, and sends one message to the Editor instead of N.

**Version protocol:** Every buffer edit increments a version (already tracked for LSP document sync). When the parser starts work, it snapshots the buffer version. The bridge tags consolidated updates with this parse version.

**Staleness policy:** The Editor applies the update only if `parse_version >= buffer.edit_version`. If the user typed while the parse was running, the update is stale and gets dropped. A new parse is already in flight for the current content.

```elixir
# Bridge batches N parser messages into one consolidated update
def handle_info({:minga_highlight, event}, bridge_state) do
  bridge_state = accumulate(bridge_state, event)
  if batch_complete?(bridge_state) do
    send(bridge_state.editor, {:highlight_batch, bridge_state.parse_version, bridge_state.updates})
    {:noreply, reset_batch(bridge_state)}
  else
    {:noreply, bridge_state}
  end
end

# Editor applies or drops based on version
def handle_info({:highlight_batch, parse_version, updates}, state) do
  if parse_version >= current_buffer_version(state) do
    {:noreply, HighlightHandler.apply_batch(state, updates) |> maybe_render()}
  else
    {:noreply, state}  # stale, drop it
  end
end
```

**Supervision:** The bridge is a child of `Editor.Supervisor`, started `:temporary` (not restarted automatically). If it crashes, the Editor re-spawns it on demand. Stale highlight state is cosmetic, not functional, so a brief gap is acceptable.

**Testing:**
- Bridge batching: send 15 parser events, assert one consolidated message
- Version acceptance: send batch with current version, assert highlights applied
- Version rejection: send batch with old version, assert state unchanged
- Race condition (pure): build state, apply buffer edit (bumps version), apply highlight batch from old version, assert dropped

### Phase 8: Thin out integration tests

**Delivers:** AC 11.

After Phases 3, 5, 6 provide pure state coverage and Phase 4 provides display list coverage, simplify existing EditorCase tests to thin wiring verification:

```elixir
# Before: testing state logic through keystrokes
test "opening a new file switches to it" do
  send_keys(ctx, ":e #{path2}<CR>")
  assert active_content(ctx) == "second file"
  assert buffer_count(ctx) == 2
  assert active_buffer_index(ctx) == 1
end

# After: thin wiring check (state logic covered by Phase 3)
test ":e opens file and switches to it" do
  send_keys(ctx, ":e #{path2}<CR>")
  assert active_content(ctx) == "second file"
end
```

**Decision criteria for keeping vs. thinning integration tests:**
- **Keep** if the test verifies wiring that pure tests can't reach (keystroke → command dispatch → state change → render). These are "does the plumbing connect?" tests.
- **Thin** if the test asserts on state details already covered by pure function tests (buffer count, tab index, cursor position after a motion). Remove the redundant assertions, keep the wiring assertion.
- **Remove** if the test is entirely redundant with a pure test and adds no wiring coverage. This should be rare; most EditorCase tests verify at least one wiring step.

Snapshot tests remain for visual regression only.

### Sequencing and dependencies

```
Phase 1 (timers)              → immediate stability, ships alone
Phase 2 (pure extraction)     → Phase 3 (pure tests)
Phase 4 (display list)        → can start in parallel with 2+3
Phase 5 (windows)             → after Phase 2 (same pattern)
Phase 6 (shell chrome)        → after Phase 4 (uses display list assertions)
Phase 7 (handler modules)     → after Phase 2 (uses effects pattern)
Phase 7b (highlight bridge)   → after Phase 7, only if telemetry justifies it
Phase 8 (thin integration)    → after all above
```

Phase 1 ships as its own PR. Phases 2+3 are one PR. Phase 4 is one PR. Phases 5+6 are one PR. Phase 7 is one PR. Phase 7b is one PR (if needed). Phase 8 is a cleanup PR.

**Urgency note:** Phase 7 should ship immediately after Phases 2+3, not after 5+6. Phase 7 pays down the Phase 1 timer-fork debt. If Phase 7 stalls, the 19 headless-mode guards become permanent.

### How to know when you're done

The Editor GenServer is "done" when every `handle_info` clause meets ALL of these criteria:
1. ≤5 lines of logic (excluding pattern match and `{:noreply, ...}` wrapper)
2. No domain logic: just extract data from message, call a handler module, apply result
3. No `Process.send_after(self(), ...)` or `send(self(), ...)` except through the centralized `schedule_render` helper
4. Adding a new feature to any subsystem (highlight, LSP, agent, tool) doesn't require a new clause in the Editor

When those four properties hold, new UX workflows ship without touching the Editor GenServer. Handler module tests are isolated and run in microseconds. The only process boundary (if any) is a measurement-gated highlight batching bridge with a well-defined version protocol.

### Testing strategy

- Phase 1: `mix test.llm` after each timer quarantine. Run suite 5x for flake check.
- Phase 2: Unit test each `_pure` function. Existing integration tests still pass.
- Phase 3: New pure state tests, async: true. Every branch in `add_buffer`, `switch_tab`, `close_buffer`.
- Phase 4: Display list assertion tests. Verify modeline format change breaks snapshot but not display list assertion.
- Phase 5: Pure window tests. Split/focus/resize without GenServer.
- Phase 6: Per-shell chrome tests. Chrome builder output directly.
- Phase 7: Handler module tests. `HighlightHandler.handle/2`, `ToolHandler.handle/2`, `SessionHandler.handle/2`, `FileEventHandler.handle/2` as pure function tests. Interaction tests at the state level (e.g., close buffer then stale highlight).
- Phase 7b (if needed): HighlightBridge batching tests. Send parser events, assert one consolidated message. Version rejection tests (stale parse version → update dropped).
- Phase 8: Audit integration tests against decision criteria. Remove redundant assertions, keep wiring checks.

### Risks / Open Questions

- **`add_buffer` has three code paths** based on active tab kind and duplicate detection. The pure extraction needs to handle all three without losing tab bar mutations.
- **`switch_tab` calls `rebuild_agent_from_session`** (GenServer.call to agent session). Becomes an effect. Tests assert effect is emitted without needing a live session process.
- **`snapshot_tab_context` / `restore_tab_context` round-trip** is the most fragile piece. Pure tests must verify the round-trip invariant.
- **Handler modules share state through the Editor.** The handlers are pure functions that take and return Editor state. They're isolated from each other (HighlightHandler can't call ToolHandler), but they both operate on the same state struct. This is fine for testability (test each handler independently with constructed state), but a handler bug can still corrupt shared state. Mitigate with the handler isolation rule: each handler reads and writes only its own state slice. Enforce through code review and, eventually, a compile-time check.
- **Message pattern matching after handler extraction.** The current 15 highlight clauses each match a specific message shape (`{:minga_highlight, {:highlight_names, ...}}`). The catch-all clause (`{:minga_highlight, _}`) works only if no other clause matches first. Verify that removing the specific clauses doesn't change match order for remaining clauses.
- **Display list assertions need the full pipeline to run** (Layout through Compose). Heavier than pure state tests but lighter than HeadlessPort. The existing `base_state/1` helper proves this works.
- **Agent events already use `{state, effects}`.** The existing `@type effect` and `apply_effects/2` (editor.ex L1353-1416) are the template. Phase 2 extends this pattern, not invents it.
- **Phase 1 headless guards are temporary debt.** The 19 `if state.backend != :headless` guards diverge production and test code paths. Phase 7's handler modules should eliminate most of these by making the underlying logic pure and testable directly. Track which guards remain after Phase 7 and convert them to effects or remove them.
- **Highlight batching bridge supervision (Phase 7b only).** If measurement justifies a bridge process, it needs supervision as a child of Editor.Supervisor. The bridge should be `:temporary` (not restarted) with the Editor re-spawning it on demand, since stale highlight state is cosmetic, not functional.
