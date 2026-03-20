# Swift macOS Frontend Audit Report
## March 2025, Pre-0.1.0 Release

**Scope:** Architecture consistency, testing gaps, cross-layer protocol integrity, UX robustness.

**Files reviewed:** All 51 Swift source files (9,692 LOC), 9 test files, test harness, BEAM-side GUI protocol encoder, integration tests.

---

## Executive Summary

The Swift frontend is well-structured. The architecture (protocol reader -> command dispatcher -> state objects -> SwiftUI views) is clean, and the `InputEncoder` protocol + `SpyEncoder` pattern shows good testability thinking. The GUI protocol integration test harness is excellent infrastructure.

Three categories of issues need attention before 0.1.0:

1. **Protocol decoder test coverage is dangerously low** (only 2 of 17 decoder branches have Swift-side unit tests)
2. **A concrete-type casting pattern** makes 3 views untestable and will silently break when refactored
3. **State lifecycle inconsistencies** will cause subtle bugs as features are added

---

## Critical Issues

### 1. Protocol Decoder: 15 of 17 GUI Opcodes Have Zero Swift-Side Unit Tests

**Severity:** High. A one-byte offset error in any decoder branch corrupts all subsequent data in the frame.

**Current state:**
- `ProtocolTests.swift` covers: `clear`, `batch_end`, `set_cursor`, `set_cursor_shape`, `draw_text`, `define_region`, `set_window_bg`, `set_font`, skip highlight opcodes, multi-command payloads
- `WindowContentTests.swift` covers: `gui_window_content` (0x80) thoroughly

**Not tested at all (Swift-side):**

| Opcode | Name | Complexity | Risk |
|--------|------|-----------|------|
| 0x1C | draw_styled_text | High (20-byte header + text) | Every rendered character |
| 0x70 | gui_file_tree | High (nested variable-length entries) | Sidebar rendering |
| 0x71 | gui_tab_bar | Medium (variable-length tabs with flags) | Tab bar |
| 0x72 | gui_which_key | Medium (nested bindings) | Which-key popup |
| 0x73 | gui_completion | Medium (visible/hidden branching) | Autocomplete |
| 0x74 | gui_theme | Low (fixed-size slot array) | All colors |
| 0x75 | gui_breadcrumb | Low (string array) | Path bar |
| 0x76 | gui_status_bar | High (conditional agent fields) | Status bar |
| 0x77 | gui_picker | Very High (items + action menu + match positions) | Command palette |
| 0x78 | gui_agent_chat | Very High (7 message sub-types) | Agent UI |
| 0x79 | gui_gutter_sep | Low (5 bytes) | Gutter separator |
| 0x7A | gui_cursorline | Low (5 bytes) | Current line highlight |
| 0x7B | gui_gutter | High (per-window header + entry array) | Line numbers |
| 0x7C | gui_bottom_panel | High (tabs + message entries) | Messages panel |
| 0x7D | gui_picker_preview | Medium (nested styled segments) | File preview |
| 0x7E | gui_tool_manager | High (nested tool entries) | Tool panel |

**Integration test coverage (BEAM -> Swift harness round-trip):**
- Tested: gui_theme, gui_tab_bar, gui_breadcrumb, gui_status_bar (both variants), gui_agent_chat (hidden + visible), gui_cursorline
- NOT tested: gui_file_tree, gui_completion, gui_which_key, gui_picker, gui_picker_preview, gui_gutter, gui_gutter_sep, gui_bottom_panel, gui_tool_manager, gui_window_content, draw_styled_text
- Harness supports but lacks ExUnit tests: gui_file_tree, gui_completion, gui_which_key, gui_picker, gui_picker_preview, gui_gutter_sep, gui_bottom_panel, gui_tool_manager

**Recommendation:** Use the `WindowContentTests.swift` pattern (builder struct + binary assertion) to add Swift-side decoder tests for all 15 missing opcodes. Prioritize by risk: `gui_picker`, `gui_agent_chat` (sub-types), `gui_status_bar`, `gui_file_tree`, `draw_styled_text`, then the rest. Also add ExUnit integration tests for the opcodes the harness already supports but has no tests for.

---

### 2. InputEncoder Protocol Violation: Concrete Type Casting

**Severity:** Medium. Three views cast to `ProtocolEncoder` instead of using the `InputEncoder` protocol.

**Files affected:**
- `BreadcrumbBar.swift:45`: `(encoder as? ProtocolEncoder)?.sendBreadcrumbClick(index:)`
- `CompletionOverlay.swift:86`: `(encoder as? ProtocolEncoder)?.sendCompletionSelect(index:)`
- `TabBarView.swift:47,100,114`: `(encoder as? ProtocolEncoder)?.sendNewTab()`, `sendSelectTab(id:)`, `sendCloseTab(id:)`

**Why it matters:**
- These methods are defined on `InputEncoder`. The cast is unnecessary.
- `SpyEncoder` conforms to `InputEncoder`, not `ProtocolEncoder`. So these casts silently evaluate to `nil` in tests, making click interactions untestable.
- If `ProtocolEncoder` is ever renamed or restructured, these casts break silently (no compile error, just nil).

**Fix:** Replace `(encoder as? ProtocolEncoder)?.sendFoo()` with `encoder?.sendFoo()`. One-line change per call site.

**Contrast:** `StatusBarView`, `FileTreeView`, `BottomPanelView`, `ToolManagerView`, and `MessagesContentView` correctly use `encoder?.sendFoo()`.

---

### 3. State Lifecycle Inconsistency

**Severity:** Medium. Two state objects lack the `hide()` method that all their siblings have.

| State | Has `hide()`? | Has `update()`? | Notes |
|-------|--------------|----------------|-------|
| CompletionState | Yes | Yes | Clears items on hide |
| WhichKeyState | Yes | Yes | Clears bindings on hide |
| PickerState | Yes | Yes | Clears items, preview, action menu |
| FileTreeState | Yes | Yes | Clears entries, project root |
| AgentChatState | Yes | Yes | Clears messages |
| ToolManagerState | Yes | Yes | Clears tools |
| BottomPanelState | Yes | Yes | Hides only, keeps messages |
| **TabBarState** | **No** | Yes | Tabs persist forever |
| **BreadcrumbState** | **No** | Yes | Segments persist forever |
| StatusBarState | No | Yes | Always visible, reasonable |

`TabBarState` and `BreadcrumbState` should have `hide()` methods that clear their data, and `CommandDispatcher` should call them when the BEAM sends empty data (matching the pattern used for FileTreeState). Without this, stale tab/breadcrumb data can persist after the BEAM has cleared them, especially during reconnection or error recovery scenarios.

---

## Moderate Issues

### 4. No CommandDispatcher Routing Tests

The dispatcher is a 280-line switch statement that routes ~30 command types to their state objects. Zero test coverage means:
- A typo in state assignment goes undetected
- A missing `hide()` call when `visible == false` goes undetected
- The `beginFrame()` -> dispatch -> `batchEnd` lifecycle is untested

**Recommendation:** Create `CommandDispatcherTests.swift`. For each command type, construct a `RenderCommand`, dispatch it, and assert the GUIState sub-state was updated correctly. This is the highest-value test target after the decoders because it catches wiring bugs.

### 5. No ThemeColors.applySlots Tests

`applySlots` maps 50+ slot IDs to properties via a manual switch statement. If a slot constant is duplicated, swapped, or missing, the wrong color appears everywhere. One test that applies all known slots and checks every property catches this entire class of bug.

### 6. No Protocol Encoder Binary Layout Tests

`ProtocolEncoder` builds binary buffers for all input events (key_press, mouse, resize, paste, gui_action). The `SpyEncoder` records call parameters but nobody verifies the actual wire format. If the binary layout drifts from the BEAM decoder, events are silently misinterpreted.

**Recommendation:** Add tests that call real `ProtocolEncoder` methods on a pipe (not stdout) and verify the exact bytes match the protocol spec. The `gui_action` sub-opcodes are the riskiest since they have the most variants.

### 7. Test Harness Supports More Opcodes Than It Tests

The `commandToJSON` function in `TestHarness/main.swift` handles gui_file_tree, gui_completion, gui_which_key, gui_picker, gui_picker_preview, gui_gutter_separator, gui_bottom_panel, and gui_tool_manager. But there are no ExUnit integration tests exercising them. The harness infrastructure is already built; the tests just need writing.

**Missing integration tests (harness already supports):**
- gui_file_tree round-trip
- gui_completion (visible + hidden)
- gui_which_key (visible + hidden)
- gui_picker (with items, match positions, action menu)
- gui_picker_preview (with styled segments)
- gui_gutter_separator
- gui_bottom_panel (with tabs + entries)
- gui_tool_manager (with tools)

**Missing from harness (needs harness update first):**
- gui_gutter (0x7B): not handled by `commandToJSON`
- gui_window_content (0x80): not handled by `commandToJSON`
- draw_styled_text (0x1C): not handled by `commandToJSON`

---

## Low Priority Issues

### 8. `GUIState.beginFrame()` Could Be More Defensive

Currently only clears `windowContents`. Consider also clearing any transient state that should not persist across frames if the BEAM stops sending updates. This is probably fine for now since the BEAM sends full state snapshots for most chrome elements, but worth keeping an eye on as complexity grows.

### 9. Color Conversion Duplication

`ThemeColors` has both a static method `ThemeColors.color(_:)` and a module-level `color(_:)` function that do the same thing (convert UInt32 RGB to SwiftUI Color). Minor duplication, not worth fixing unless you're already touching the file.

### 10. Accessibility Coverage

VoiceOver support exists in `EditorNSView` (role, value, cursor position, announcements on mode change). This is good baseline coverage. Not audited deeply, but the structure is there for expansion.

---

## Recommended Test Plan for 0.1.0

### Priority 1: Protocol Decoder Unit Tests (Swift-side)
Write binary builder + decode + assert tests for all 15 missing opcodes. Follow the `WindowContentBuilder` pattern from `WindowContentTests.swift`. Estimated: 1-2 days.

Focus order:
1. `gui_picker` (most complex, highest user-facing risk)
2. `gui_agent_chat` (7 sub-message types)
3. `gui_status_bar` (conditional agent fields)
4. `gui_file_tree` (variable-length nested entries)
5. `draw_styled_text` (every rendered character)
6. `gui_bottom_panel` + `gui_tool_manager`
7. The rest (theme, completion, which_key, breadcrumb, gutter, cursorline, picker_preview)

### Priority 2: Fix InputEncoder Cast Pattern
Replace all `(encoder as? ProtocolEncoder)?.` with `encoder?.` in TabBarView, BreadcrumbBar, CompletionOverlay. 15 minutes.

### Priority 3: CommandDispatcher Tests
Test that each command type updates the correct GUIState sub-state. Use the existing `GUIState()` constructor (no mocks needed). Estimated: half day.

### Priority 4: ThemeColors.applySlots Test
One comprehensive test that applies all 50+ known slots and verifies every property. Catches slot ID mismatches. 1 hour.

### Priority 5: Integration Test Expansion
Write ExUnit tests for the 8 opcodes the harness already supports but has no tests for. The harness code is already written; just add the Elixir test cases. Estimated: half day.

### Priority 6: Add State Lifecycle Tests
Test `hide()` clears all state, `update()` converts correctly from protocol types, and `beginFrame()` works. Estimated: half day.

---

## Automation Opportunities

1. **Protocol spec enforcement**: Generate opcode constants and field layouts from a single source (e.g., a TOML/JSON schema) shared between Elixir, Swift, and Zig. This eliminates the "forgot to update one frontend" class of bugs entirely.

2. **CI-gated harness tests**: The test harness is headless and CI-friendly. Gate PRs on `mix test --include swift_harness` passing. Currently these tests likely require the harness binary to be pre-built.

3. **Snapshot testing for SwiftUI chrome**: ViewInspector or similar library can assert SwiftUI view hierarchies without running the app. Useful for verifying that state changes produce the expected view structure (e.g., completion popup appears when `visible == true`).

4. **Property-based decoder testing**: Generate random valid binary payloads and verify the decoder doesn't crash. Catches buffer overflows and off-by-one errors that hand-written tests miss.
