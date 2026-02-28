# Plan: Mouse Support (Scroll + Click + Drag Selection)

## Goal

Add comprehensive mouse support to Minga: scroll wheel navigation,
click-to-position cursor placement, and drag-to-select text, matching standard
terminal editor behavior.

## Context

### Current Architecture
- **Zig side** (`main.zig`): libvaxis parses terminal input via `/dev/tty`. The
  `handleTtyEvent` function currently handles `key_press` events and forwards
  them over the Port protocol. Mouse events are explicitly ignored with the
  comment: *"We don't forward mouse / focus / paste to BEAM in this MVP."*
- **Protocol** (`protocol.zig` / `protocol.ex`): Three input opcodes exist
  (0x01 key_press, 0x02 resize, 0x03 ready). No mouse opcode.
- **BEAM side** (`editor.ex`): Handles `{:minga_input, {:key_press, ...}}`
  messages. Already has `:half_page_up`/`:half_page_down` commands and
  `Viewport.scroll_to_cursor/2` logic. `BufferServer.move_to/2` allows
  absolute cursor positioning.
- **Visual mode** already exists with `visual_anchor`, characterwise/linewise
  selection, highlight rendering, and yank/delete-on-selection commands.
- **libvaxis** provides full mouse support via `vaxis.Event.mouse` with a
  `Mouse` struct: `col: i16`, `row: i16`, `button` enum (including
  `wheel_up`/`wheel_down`/`wheel_left`/`wheel_right`, `left`/`middle`/`right`),
  `mods` (shift/alt/ctrl), `type` enum (press/release/motion/drag).
- Mouse mode must be explicitly enabled via `vx.setMouseMode(tty.writer(), true)`.

### Design Decisions

1. **Single general mouse opcode** (`0x04`) — carries row, col, button,
   modifiers, and event type. Covers scroll, click, and drag with one opcode.

2. **Click-to-position in all editing modes** — left click moves cursor to
   the clicked buffer position (accounting for viewport offset). In Visual
   mode, click cancels selection and returns to Normal. In Insert mode,
   click moves cursor and stays in Insert (VS Code behavior). In Command
   mode, click cancels command and returns to Normal. Clicks on
   modeline/minibuffer rows are ignored.

3. **Scroll wheel** — scrolls viewport by 3 lines per tick (configurable
   constant). Cursor is repositioned if it falls outside the viewport.

4. **Drag-to-select** — left press sets anchor and enters Visual mode
   (characterwise). Drag events update cursor position, extending the
   selection. Release finalizes the selection, leaving the user in Visual
   mode to yank/delete/operate. This reuses the existing Visual mode
   machinery — no new rendering or selection logic needed.

## Approach

Add a general `mouse_event` input opcode (0x04) to the Port protocol carrying
the full mouse event data. On the Zig side, enable mouse mode and forward all
mouse events. On the BEAM side, decode and handle scroll wheel, left-click,
and left-drag events.

### Alternatives Considered

1. **Separate opcodes per mouse action** (0x04 scroll, 0x05 click, 0x06 drag)
   — More specific but creates protocol bloat. A single opcode with typed
   fields is simpler and equally extensible.

2. **Translate scroll/click to key events in Zig** — Avoids protocol changes
   but loses mouse position data and makes Zig responsible for editor
   semantics it shouldn't own.

3. **Custom mouse selection (not Visual mode)** — Some editors track mouse
   selection separately from keyboard selection. Reusing Visual mode means
   mouse and keyboard selections are interchangeable — user can start with
   mouse, extend with keyboard, operate with either. Simpler and more
   powerful.

## Steps

### 1. Add mouse_event opcode to Port protocol (both sides)

- **Files**: `lib/minga/port/protocol.ex`, `zig/src/protocol.zig`
- **Changes**:
  - New opcode `0x04 mouse_event`:
    ```
    <<0x04, row::16-signed, col::16-signed, button::8, modifiers::8, event_type::8>>
    ```
  - Button values (matching libvaxis):
    - `0x00` left, `0x01` middle, `0x02` right, `0x03` none
    - `0x40` wheel_up, `0x41` wheel_down, `0x42` wheel_right, `0x43` wheel_left
    - `0x80..0x83` button_8 through button_11
  - Event type: `0x00` press, `0x01` release, `0x02` motion, `0x03` drag
  - Modifier flags: same bitmask as key events (SHIFT=0x01, CTRL=0x02, etc.)
  - Elixir: Add `@op_mouse_event 0x04`, decode clause returning
    `{:mouse_event, row, col, button, modifiers, event_type}` with atom
    conversions for button and type
  - Elixir: Add `@type mouse_button`, `@type mouse_event_type` types
  - Zig: Add `OP_MOUSE_EVENT = 0x04`, `encodeMouseEvent(buf, row, col, button, mods, event_type)`
  - Add encode/decode tests on both sides

### 2. Enable mouse mode and forward events in Zig

- **Files**: `zig/src/main.zig`
- **Changes**:
  - After entering alt screen, call `vx.setMouseMode(tty.writer(), true)`
  - In `handleTtyEvent`, add a `.mouse` arm:
    - Map libvaxis `Mouse.Button` to protocol button byte
    - Map libvaxis `Mouse.Type` to protocol event type byte
    - Map libvaxis `Mouse.Modifiers` to protocol modifier bitmask
    - Encode via `protocol.encodeMouseEvent()` and write to stdout
  - All mouse events are forwarded (BEAM side decides what to ignore)

### 3. Handle mouse scroll events in the Editor

- **Files**: `lib/minga/editor.ex`
- **Changes**:
  - Add `handle_info({:minga_input, {:mouse_event, ...}}, state)` clause
  - Define `@scroll_lines 3` module attribute
  - For `wheel_up`/`wheel_down` button with `:press` type:
    - Scroll viewport by `@scroll_lines` lines using `page_move/3`
    - If cursor is now outside visible viewport, clamp it to nearest visible row
    - Re-render
  - Works in all modes (scroll doesn't change mode state)
  - Ignore `wheel_left`/`wheel_right` for now (horizontal scroll is rare)

### 4. Handle click-to-position in the Editor

- **Files**: `lib/minga/editor.ex`
- **Changes**:
  - For `left` button with `:press` type (and NOT followed by drag — see step 5):
    - Calculate buffer position: `{row + viewport.top, col + viewport.left}`
    - Ignore clicks on modeline row (`viewport.rows - 2`) or minibuffer row
      (`viewport.rows - 1`)
    - Ignore clicks beyond the last buffer line (tilde `~` rows)
    - Clamp column to line length
    - Call `BufferServer.move_to(buf, {target_line, target_col})`
    - In `:visual` mode: cancel selection, transition to `:normal`, reset
      mode_state
    - In `:normal` mode: just move cursor
    - In `:insert` mode: move cursor, stay in insert mode
    - In `:command` mode: cancel command, return to normal, then position
    - Re-render
  - For `middle`/`right` button: ignore (future: context menu, paste)

### 5. Handle drag-to-select in the Editor

- **Files**: `lib/minga/editor.ex`, `lib/minga/editor/state.ex` (if exists,
  otherwise inline in editor.ex)
- **Changes**:
  - Add `mouse_dragging: boolean()` field to editor state (default `false`)
  - **Left press** (refined from step 4):
    - Calculate buffer position (same coordinate math as click)
    - Ignore presses on modeline/minibuffer/tilde rows
    - Move cursor to clicked position
    - Set `mouse_dragging: true`
    - If not already in visual mode: transition to `:visual` mode, set
      `visual_anchor` to clicked position, `visual_type: :char`
    - If already in visual mode: update `visual_anchor` to clicked position
      (start a fresh selection from the click point)
  - **Left drag** (event_type `:drag`):
    - Only process if `mouse_dragging` is true
    - Calculate buffer position from drag row/col
    - Clamp to valid buffer bounds (same validation as click)
    - Move cursor to drag position via `BufferServer.move_to/2`
    - Visual mode highlight updates automatically on re-render (selection
      spans from `visual_anchor` to current cursor)
    - **Edge auto-scroll**: if drag row is 0, scroll viewport up by 1 line;
      if drag row is `content_rows - 1`, scroll viewport down by 1 line
    - Re-render
  - **Left release** (event_type `:release`):
    - Set `mouse_dragging: false`
    - If anchor == cursor (click without drag, i.e. no movement): transition
      back to `:normal` mode (this was just a click, not a selection)
    - If anchor != cursor: stay in `:visual` mode — user can now `y`, `d`,
      `c`, or press `Escape` to cancel
    - Re-render
  - **Mode interaction**:
    - If in `:command` mode when drag starts: cancel command, enter visual
    - If in `:insert` mode when drag starts: exit insert, enter visual
    - If in `:normal` mode when drag starts: enter visual (most common case)
    - If in `:visual` mode when drag starts: restart selection from new anchor

### 6. Add tests

- **Files**: `test/minga/port/protocol_test.exs`, `test/minga/editor_test.exs`
- **Changes**:
  - **Protocol (Elixir)**:
    - Decode mouse_event with left click (press)
    - Decode mouse_event with wheel_up/wheel_down
    - Decode mouse_event with drag event type
    - Decode mouse_event with release event type
    - Decode mouse_event with all modifier flags
    - Decode mouse_event with negative row/col (signed encoding)
    - Decode truncated mouse_event → malformed
    - Round-trip: decode what Zig would encode
  - **Protocol (Zig)**:
    - `encodeMouseEvent` byte layout verification
    - Buffer too small → error
    - All button types encode correctly
    - All event types encode correctly
    - Signed row/col encoding (negative values)
  - **Editor — Scroll**:
    - Mouse scroll down moves viewport down by 3 lines
    - Mouse scroll up moves viewport up by 3 lines
    - Mouse scroll at top of file doesn't go negative
    - Mouse scroll at bottom of file clamps to last line
    - Mouse scroll doesn't change mode
    - Mouse scroll clamps cursor when it leaves viewport
  - **Editor — Click**:
    - Left click in content area moves cursor to clicked position
    - Left click accounts for viewport scroll offset
    - Left click on modeline/minibuffer row is ignored
    - Left click on tilde row (beyond buffer end) is ignored
    - Left click clamps column to line length
    - Left click in visual mode cancels selection, returns to normal
    - Left click in command mode cancels command, returns to normal
    - Left click in insert mode moves cursor, stays in insert
  - **Editor — Drag**:
    - Left press + drag creates characterwise visual selection
    - Drag updates cursor while anchor stays fixed
    - Release after drag keeps visual selection active
    - Release without movement (click) returns to normal mode
    - Drag from normal mode enters visual mode
    - Drag from insert mode exits insert, enters visual
    - Drag clamps to buffer bounds
    - Drag near viewport edge triggers auto-scroll

## Testing

- `mix test --warnings-as-errors` — all existing + new Elixir tests pass
- `zig build test` — all existing + new Zig protocol tests pass
- `mix lint` — no warnings, format + credo clean
- Manual: open a long file, scroll with wheel, click to reposition, drag to
  select text, yank selection with `y`, verify in each mode

## Risks & Open Questions

1. **Mouse mode vs terminal copy/paste** — Enabling mouse mode captures mouse
   events that would normally go to the terminal for text selection. Users hold
   Shift to bypass (standard terminal behavior). May want a `:set mouse=`
   toggle later.

2. **Signed row/col from libvaxis** — `Mouse.col` and `Mouse.row` are `i16`
   (can be negative with pixel mouse coordinates before translation). We use
   signed encoding in the protocol; BEAM side should ignore events with
   negative coordinates.

3. **Scroll amount with high-resolution scroll** — Modern trackpads may send
   many small scroll events. The 3-line multiplier might feel too fast. Could
   add a debounce or make the multiplier configurable later.

4. **Drag auto-scroll speed** — When dragging past the viewport edge, we
   scroll 1 line per drag event. With fast mouse movement this may feel slow.
   Could use a timer-based auto-scroll if this becomes an issue, but 1-line
   per event is the simple starting point.

5. **Drag across modeline/minibuffer** — If the user drags into the modeline
   area, we clamp to the last content row rather than selecting modeline text.
   This is correct but may feel slightly laggy if the cursor "sticks" at the
   bottom.

6. **Picker/which-key interaction** — When the picker is open, mouse events
   are ignored (they go through the picker key handler which won't match).
   When which-key popup is visible, a click dismisses it (existing leader
   cancel logic). This falls out naturally from the current architecture.

---

## GitHub Ticket

```markdown
# Users can navigate and select with the mouse (scroll, click, drag)

**Type:** Feature

## What
Minga does not respond to mouse input. Users cannot scroll through files with
the mouse wheel, click to reposition the cursor, or drag to select text —
three foundational interactions expected in any text editor. All navigation
and selection currently requires keyboard shortcuts.

## Why
Mouse interactions are baseline expectations for terminal editors. Without
them, Minga feels broken on first interaction, especially for users coming
from VS Code, Sublime, or any GUI editor. This is a critical first-impression
issue that affects every new user's evaluation of whether the editor is usable.

## Acceptance Criteria

### Scroll
- Scrolling the mouse wheel down moves the viewport down (content scrolls up)
- Scrolling the mouse wheel up moves the viewport up (content scrolls down)
- Scroll speed feels natural (approximately 3 lines per wheel tick)
- Scrolling works in all editor modes without changing the current mode
- The cursor is repositioned into the viewport if scrolling moves it off-screen

### Click
- Left-clicking in the text area moves the cursor to the clicked position
- Click position correctly accounts for scrolled viewport (clicking row 5 when
  scrolled to line 100 positions cursor at line 105)
- Clicking on the modeline or minibuffer rows does not move the cursor
- Clicking past the last line of the file does not move the cursor
- Clicking in Visual mode cancels the selection and returns to Normal mode
- Clicking in Command mode cancels the command and returns to Normal mode
- Clicking in Insert mode moves the cursor without leaving Insert mode

### Drag Selection
- Pressing and dragging the left mouse button selects text (highlighted)
- The selection starts at the press position and extends to the current drag
  position
- Releasing the mouse button after dragging leaves the selection active
  (user can yank, delete, or operate on it)
- Releasing without moving (a simple click) does not leave a selection active
- Dragging near the top or bottom edge of the viewport auto-scrolls
- After a drag selection, keyboard Visual mode commands work on the selection
  (y to yank, d to delete, Escape to cancel)

### General
- Holding Shift while clicking allows normal terminal text selection (standard
  terminal behavior — handled by the terminal emulator, not Minga)

### Developer Notes
- libvaxis provides mouse events via `vaxis.Event.mouse` — must call
  `vx.setMouseMode(tty.writer(), true)` to enable
- Single protocol opcode `0x04` carries full mouse event (row, col, button,
  mods, type) — covers all three interactions with one opcode
- Drag selection reuses the existing Visual mode machinery (visual_anchor,
  characterwise selection, highlight rendering, yank/delete commands) —
  no new rendering or selection logic needed
- Mouse.row and Mouse.col are i16 (signed) — ignore negative values
```
