# Minga Port Protocol Specification

The BEAM editor core and the rendering frontend communicate over a binary protocol on stdin/stdout of the frontend process. This document is the authoritative reference for implementing a Minga frontend. You should be able to build a working frontend by reading only this file.

## Transport

The frontend runs as a child process of the BEAM. Communication uses stdin (BEAM → Frontend) and stdout (Frontend → BEAM).

**Framing:** Every message is prefixed with a 4-byte big-endian unsigned integer indicating the payload length. The payload follows immediately. Erlang's `{:packet, 4}` Port option handles framing on the BEAM side; frontends must read/write the 4-byte length header explicitly.

```
┌──────────────┬────────────────────────┐
│ length (4B)  │ payload (length bytes)  │
│ big-endian   │ opcode (1B) + fields    │
└──────────────┴────────────────────────┘
```

**Batching:** The BEAM may concatenate multiple commands into a single length-prefixed message. The frontend must parse commands sequentially within a payload using `commandSize()` to determine where each command ends. The Elixir encoder typically batches an entire render frame into one message.

**Byte order:** All multi-byte integers are big-endian unless noted otherwise.

**Text encoding:** All text fields (draw_text content, language names, query source) are UTF-8 encoded.

---

## Quick Reference

### BEAM → Frontend (Render Commands)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x10` | draw_text | 14 + text_len | Draw styled text at a position |
| `0x11` | set_cursor | 5 | Position the cursor |
| `0x12` | clear | 1 | Clear the entire screen |
| `0x13` | batch_end | 1 | End of frame; flush to screen |
| `0x14` | define_region | 15 | Create/update a layout region |
| `0x15` | set_cursor_shape | 2 | Change cursor appearance |
| `0x16` | set_title | 3 + title_len | Set the window/terminal title |
| `0x18` | clear_region | 3 | Clear a specific region |
| `0x19` | destroy_region | 3 | Remove a region |
| `0x1A` | set_active_region | 3 | Route draw commands to a region |

### BEAM → Frontend (Highlight Commands)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x20` | set_language | 3 + name_len | Set the active tree-sitter language |
| `0x21` | parse_buffer | 9 + source_len | Parse buffer content for highlighting |
| `0x22` | set_highlight_query | 5 + query_len | Set a custom highlight query |
| `0x23` | load_grammar | 5 + name_len + path_len | Load a grammar from a shared library |
| `0x24` | set_injection_query | 5 + query_len | Set a custom injection query |
| `0x25` | query_language_at | 9 | Query the language at a byte offset |

### Frontend → BEAM (Input Events)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x01` | key_press | 6 | A key was pressed |
| `0x02` | resize | 5 | Terminal/window was resized |
| `0x03` | ready | 5 or 13 | Frontend is initialized and ready |
| `0x04` | mouse_event | 8 | Mouse button, wheel, or motion |
| `0x05` | capabilities_updated | 9 | Updated capabilities after async detection |

### Frontend → BEAM (Highlight Responses)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x30` | highlight_spans | 9 + count × 10 | Syntax highlight byte ranges |
| `0x31` | highlight_names | 3 + variable | Capture name list for spans |
| `0x32` | grammar_loaded | 4 + name_len | Grammar load success/failure |
| `0x33` | language_at_response | 7 + name_len | Language at a byte offset |
| `0x34` | injection_ranges | 3 + variable | Injection language regions |

### Frontend → BEAM (Diagnostics)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x60` | log_message | 4 + msg_len | Log message from the frontend |

---

## Render Commands (BEAM → Frontend)

### `0x10` draw_text

Draw styled text at a screen position.

```
opcode:   u8  = 0x10
row:      u16           screen row (0-indexed from top)
col:      u16           screen column (0-indexed from left)
fg:       u24           foreground color (RGB, 0x000000 = terminal default)
bg:       u24           background color (RGB, 0x000000 = terminal default)
attrs:    u8            style attribute flags (see below)
text_len: u16           byte length of text
text:     [text_len]u8  UTF-8 encoded text
```

Total size: 14 + text_len bytes.

**Attribute flags:**

| Flag | Value | Meaning |
|------|-------|---------|
| BOLD | `0x01` | Bold weight |
| UNDERLINE | `0x02` | Single underline |
| ITALIC | `0x04` | Italic style |
| REVERSE | `0x08` | Swap foreground and background |

Multiple flags can be combined with bitwise OR: `0x05` = bold + italic.

**Behavior:** The frontend writes each grapheme cluster in the text to consecutive screen cells starting at `(row, col)`. Wide characters (CJK, emoji) occupy 2 cells. The frontend is responsible for grapheme iteration and display width calculation. Text that extends past the screen width is clipped.

**Color convention:** `0x000000` for fg means "use the terminal's default foreground." `0x000000` for bg means "use the terminal's default background." Actual black can be represented as `0x000001` if needed, though in practice themes avoid this ambiguity.

### `0x11` set_cursor

Position the visible cursor.

```
opcode: u8  = 0x11
row:    u16           screen row
col:    u16           screen column
```

Total size: 5 bytes.

**Behavior:** Move the cursor to the specified position. The cursor is displayed at this location after the next `batch_end` render. Only one cursor position is active at a time; the last `set_cursor` in a frame wins.

### `0x12` clear

Clear the entire screen.

```
opcode: u8 = 0x12
```

Total size: 1 byte.

**Behavior:** Reset all cells to blank (space character, default colors, no attributes). This is always the first command in a render frame.

### `0x13` batch_end

End of a render frame.

```
opcode: u8 = 0x13
```

Total size: 1 byte.

**Behavior:** The frontend flushes all pending draw operations to the screen. For a TUI, this means writing the diff of changed cells to the terminal. For a GUI, this means triggering a display refresh. No visible changes should appear until `batch_end` is received.

### `0x15` set_cursor_shape

Change the cursor's visual appearance.

```
opcode: u8 = 0x15
shape:  u8           cursor shape
```

Total size: 2 bytes.

**Shape values:**

| Value | Shape | Typical Use |
|-------|-------|-------------|
| `0x00` | Block | Normal mode |
| `0x01` | Beam (line) | Insert mode |
| `0x02` | Underline | Replace mode |

### `0x16` set_title

Set the window or terminal title.

```
opcode:    u8  = 0x16
title_len: u16           byte length of title
title:     [title_len]u8 UTF-8 encoded title string
```

Total size: 3 + title_len bytes.

**Behavior:** TUI frontends emit OSC 0 (`\x1b]0;{title}\x07`). GUI frontends set the window title.

---

## Render Frame Lifecycle

Every render frame follows this sequence:

```
clear
draw_text × N       (one per styled text segment, ordered top-to-bottom)
set_cursor           (exactly once)
set_cursor_shape     (exactly once; may be omitted if unchanged)
batch_end            (triggers the actual render)
```

The BEAM sends the entire frame as a single batched message. The frontend processes commands in order and only renders to screen on `batch_end`.

Between frames, the frontend must not modify the screen. The BEAM drives all visual updates.

---

## Input Events (Frontend → BEAM)

### `0x01` key_press

A key was pressed.

```
opcode:    u8  = 0x01
codepoint: u32           Unicode codepoint of the key
modifiers: u8            modifier flags (see below)
```

Total size: 6 bytes.

**Codepoint values:** Standard Unicode codepoints for printable characters. For special keys, use the codepoint values defined by the frontend's input library (e.g., libvaxis uses values above the Unicode range for function keys, arrows, etc.). The BEAM's key handling maps these to editor actions.

**Modifier flags:**

| Flag | Value |
|------|-------|
| SHIFT | `0x01` |
| CTRL | `0x02` |
| ALT | `0x04` |
| SUPER | `0x08` |

Combined with bitwise OR: Ctrl+Shift = `0x03`.

### `0x02` resize

The terminal or window was resized.

```
opcode: u8  = 0x02
width:  u16           new width in columns (or pixels for GUI)
height: u16           new height in rows (or pixels for GUI)
```

Total size: 5 bytes.

**Behavior:** Sent when the frontend detects a size change (SIGWINCH for TUI, window resize event for GUI). The BEAM re-renders to the new dimensions on the next frame.

### `0x03` ready

The frontend has initialized and is ready to receive render commands.

**Short format (5 bytes):**
```
opcode: u8  = 0x03
width:  u16           initial width
height: u16           initial height
```

**Extended format (13 bytes):**
```
opcode:       u8  = 0x03
width:        u16           initial width
height:       u16           initial height
caps_version: u8            capability format version (currently 1)
caps_len:     u8            length of capability data
caps_data:    [caps_len]u8  capability fields (see "Capability Negotiation" section)
```

**Behavior:** Sent exactly once, during startup, after the frontend has set up its rendering surface. The BEAM waits for this event before sending any render commands.

Frontends should use the extended format when possible. The BEAM detects which format was sent by checking the payload length: 5 bytes = short format with default capabilities, 13+ bytes = extended format with explicit capabilities.

### `0x04` mouse_event

A mouse button, wheel, or motion event.

```
opcode:     u8  = 0x04
row:        i16           screen row (signed; -1 = outside window)
col:        i16           screen column (signed; -1 = outside window)
button:     u8            button identifier
modifiers:  u8            modifier flags (same as key_press)
event_type: u8            type of mouse event
```

Total size: 8 bytes.

**Button values:**

| Value | Button |
|-------|--------|
| `0x00` | Left |
| `0x01` | Middle |
| `0x02` | Right |
| `0x03` | None (motion without button) |
| `0x40` | Wheel up |
| `0x41` | Wheel down |
| `0x42` | Wheel right |
| `0x43` | Wheel left |

**Event type values:**

| Value | Type |
|-------|------|
| `0x00` | Press |
| `0x01` | Release |
| `0x02` | Motion (no button held) |
| `0x03` | Drag (button held during motion) |

---

## Highlight Commands (BEAM → Frontend)

These commands control tree-sitter syntax highlighting. In the current architecture, the frontend process that handles these may be the same as or separate from the renderer (see Architecture Notes below).

### `0x20` set_language

Set the active tree-sitter grammar.

```
opcode:   u8  = 0x20
name_len: u16           byte length of language name
name:     [name_len]u8  language name (e.g., "elixir", "json", "markdown")
```

Total size: 3 + name_len bytes.

**Behavior:** Select the grammar for subsequent parse operations. The frontend should look up the language in its grammar registry. If the language is not found, log a warning and continue (highlighting will be unavailable for this buffer).

### `0x21` parse_buffer

Parse buffer content and return highlight spans.

```
opcode:     u8  = 0x21
version:    u32           monotonically increasing version counter
source_len: u32           byte length of source text
source:     [source_len]u8  UTF-8 encoded buffer content
```

Total size: 9 + source_len bytes.

**Behavior:** Parse the source text with the currently active grammar. Run the highlight query (and injection query, if set) against the parse tree. Send back `highlight_names` (if capture names changed) followed by `highlight_spans` with the version counter. If injection regions are found, also send `injection_ranges`.

The version counter prevents stale results: the BEAM discards spans with a version lower than the most recently requested parse. The frontend should include the version from the request in the `highlight_spans` response.

### `0x22` set_highlight_query

Override the built-in highlight query with custom `.scm` source.

```
opcode:    u8  = 0x22
query_len: u32           byte length of query source
query:     [query_len]u8 tree-sitter query source (.scm format)
```

Total size: 5 + query_len bytes.

**Behavior:** Compile the query for the currently active language and use it for subsequent highlighting. If compilation fails, log a warning and continue with the previous query (or no query). This is used for user-overridden queries from `~/.config/minga/queries/{lang}/highlights.scm`.

### `0x23` load_grammar

Dynamically load a grammar from a shared library.

```
opcode:   u8  = 0x23
name_len: u16           byte length of grammar name
name:     [name_len]u8  grammar name
path_len: u16           byte length of library path
path:     [path_len]u8  filesystem path to .so/.dylib
```

Total size: 5 + name_len + path_len bytes.

**Behavior:** Load the shared library at `path` and look up the symbol `tree_sitter_{name}`. Register the language in the grammar registry. Respond with `grammar_loaded` (opcode `0x32`) indicating success or failure.

### `0x24` set_injection_query

Override the built-in injection query for language embedding (e.g., Markdown fenced code blocks).

```
opcode:    u8  = 0x24
query_len: u32           byte length of query source
query:     [query_len]u8 tree-sitter query source (.scm format)
```

Total size: 5 + query_len bytes.

**Behavior:** Same as `set_highlight_query` but for the injection query. The injection query identifies embedded language regions (e.g., code blocks in Markdown) and their language names.

### `0x25` query_language_at

Ask which language is active at a byte offset (for injection-aware features like comment toggling).

```
opcode:      u8  = 0x25
request_id:  u32           caller-provided correlation ID
byte_offset: u32           byte offset into the last parsed source
```

Total size: 9 bytes.

**Behavior:** Check the injection ranges from the most recent parse. If the byte offset falls within an injection region, return that region's language name. Otherwise, return the outer (root) language name. Respond with `language_at_response` (opcode `0x33`).

---

## Highlight Responses (Frontend → BEAM)

### `0x30` highlight_spans

Syntax highlight byte ranges with capture IDs.

```
opcode:  u8  = 0x30
version: u32           version from the parse_buffer request
count:   u32           number of spans
spans:   [count × 10] array of spans
```

Each span:
```
start_byte: u32           start byte offset in source
end_byte:   u32           end byte offset in source (exclusive)
capture_id: u16           index into the capture names list
```

Total size: 9 + count × 10 bytes.

**Behavior:** Spans are sorted by `(start_byte ASC, layer DESC, pattern_index DESC, end_byte ASC)`. The BEAM uses a first-wins walk: the first span covering a byte position determines its style. Higher-layer spans (from injection languages) take priority over lower-layer spans (from the outer language) at the same position.

### `0x31` highlight_names

Capture name list for interpreting span capture IDs.

```
opcode: u8  = 0x31
count:  u16           number of names
names:  [variable]    array of length-prefixed strings
```

Each name:
```
name_len: u16           byte length of name
name:     [name_len]u8  capture name (e.g., "keyword", "string", "comment")
```

**Behavior:** Sent before or alongside `highlight_spans` whenever the set of capture names changes (typically on first parse or language switch). The BEAM maps capture names to theme colors. The `capture_id` in each span is an index into this list.

### `0x32` grammar_loaded

Response to `load_grammar`.

```
opcode:   u8  = 0x32
success:  u8            1 = success, 0 = failure
name_len: u16           byte length of grammar name
name:     [name_len]u8  grammar name
```

Total size: 4 + name_len bytes.

### `0x33` language_at_response

Response to `query_language_at`.

```
opcode:     u8  = 0x33
request_id: u32           correlation ID from the request
name_len:   u16           byte length of language name (0 if no language set)
name:       [name_len]u8  language name
```

Total size: 7 + name_len bytes.

### `0x34` injection_ranges

Language injection regions found during parsing.

```
opcode: u8  = 0x34
count:  u16           number of ranges
ranges: [variable]    array of injection ranges
```

Each range:
```
start_byte: u32           start byte offset
end_byte:   u32           end byte offset (exclusive)
name_len:   u16           byte length of language name
name:       [name_len]u8  language name for this region
```

**Behavior:** Sent after `highlight_spans` when the parse found embedded language regions (e.g., JSON inside a Markdown fenced code block). The BEAM can use these ranges for injection-aware features like line comment toggling.

---

## Log Messages (Frontend → BEAM)

### `0x60` log_message

A log message from the frontend process.

```
opcode:  u8  = 0x60
level:   u8            log level
msg_len: u16           byte length of message
msg:     [msg_len]u8   UTF-8 encoded log text
```

Total size: 4 + msg_len bytes.

**Log level values:**

| Value | Level |
|-------|-------|
| `0x00` | Error |
| `0x01` | Warning |
| `0x02` | Info |
| `0x03` | Debug |

**Behavior:** The BEAM routes these to the `*Messages*` buffer, prefixed with the log level (e.g., `[ZIG/WARN] message text`). Frontends should use this for diagnostic messages that help the user understand what the rendering layer is doing.

---

## Error Handling

**Unknown opcodes:** The receiver should log a warning and skip the command. For batched messages, use `commandSize()` to advance past the unknown command.

**Malformed payloads:** If a payload is too short for its opcode's expected format, the receiver should log a warning and discard the message.

**Version mismatches:** The BEAM discards `highlight_spans` responses where the version is lower than the most recently requested version. This prevents stale async results from overwriting current highlights.

**Frontend crash:** The BEAM's supervisor detects the Port exit and can restart the frontend. Buffer state, undo history, and cursor positions are preserved in the BEAM. The restarted frontend receives a full re-render on its first frame.

---

## Architecture Notes

### Current design

The Zig process currently handles both rendering and tree-sitter parsing. The TUI runtime intercepts highlight opcodes before the renderer. The GUI runtime does not, so highlight opcodes are silently no-op'd.

### Planned evolution

Tree-sitter parsing will be extracted into a separate `minga-parser` process (see #150). When this happens:
- The **renderer** process handles only render commands (`0x10`-`0x16`)
- The **parser** process handles only highlight commands (`0x20`-`0x25`) and sends highlight responses (`0x30`-`0x34`)
- Both use the same `{:packet, 4}` framing on their respective stdin/stdout pipes
- The BEAM manages two Port processes, routing commands to the appropriate one

This separation means new rendering frontends (Swift, GTK4) only need to implement render commands. Tree-sitter parsing is handled by the shared parser process.

---

## Capability Negotiation

The `ready` event supports an extended format with capability fields. This lets the BEAM adapt rendering strategy based on what the frontend supports.

### Extended Ready Format

```
0x03 ready (extended):
  width:          u16
  height:         u16
  caps_version:   u8    (currently 1)
  caps_len:       u8    (length of remaining fields)
  frontend_type:  u8    (0=tui, 1=native_gui, 2=web)
  color_depth:    u8    (0=mono, 1=256color, 2=rgb)
  unicode_width:  u8    (0=wcwidth, 1=unicode_15)
  image_support:  u8    (0=none, 1=kitty, 2=sixel, 3=native)
  float_support:  u8    (0=emulated, 1=native)
  text_rendering: u8    (0=monospace, 1=proportional)
```

Total size: 13 bytes.

Frontends that send the short 5-byte `ready` format are assumed to have default capabilities: `{tui, rgb, wcwidth, none, emulated, monospace}`.

### `0x05` capabilities_updated

Sent after the initial `ready` event when the frontend detects additional capabilities asynchronously (e.g., a TUI terminal responds to capability queries like DA1 after startup).

```
opcode:         u8  = 0x05
caps_version:   u8    (currently 1)
caps_len:       u8    (length of remaining fields)
frontend_type:  u8
color_depth:    u8
unicode_width:  u8
image_support:  u8
float_support:  u8
text_rendering: u8
```

Total size: 9 bytes.

**Behavior:** The BEAM updates its stored capabilities for this frontend. No re-render is triggered; the updated caps take effect on the next frame.

### Capability Fields

| Field | Values | Description |
|-------|--------|-------------|
| `frontend_type` | 0=tui, 1=native_gui, 2=web | Type of rendering surface |
| `color_depth` | 0=mono, 1=256color, 2=rgb | Color support level |
| `unicode_width` | 0=wcwidth, 1=unicode_15 | Character width calculation method |
| `image_support` | 0=none, 1=kitty, 2=sixel, 3=native | Inline image protocol |
| `float_support` | 0=emulated, 1=native | Floating window support |
| `text_rendering` | 0=monospace, 1=proportional | Font rendering model |

### Implementation Notes

The TUI backend sends `ready` with default capabilities immediately at startup, then sends `capabilities_updated` once libvaxis finishes its async terminal capability detection (triggered by the DA1 response). The GUI backend sends `ready` with full native capabilities upfront since there is no detection delay.

## Layout Regions

Regions express layout structure so frontends can map editor areas to their native abstraction: virtual viewports with clipping (TUI), NSView hierarchy (AppKit), GtkWidget containers (GTK4).

Region ID 0 is the implicit root region (the entire screen). All draw commands before any `set_active_region` target the root.

### `0x14` define_region

Create or update a layout region.

```
opcode:    u8  = 0x14
id:        u16           region identifier (must be > 0)
parent_id: u16           parent region (0 = root)
role:      u8            semantic role (see table below)
row:       u16           top-left row relative to parent
col:       u16           top-left column relative to parent
width:     u16           width in columns
height:    u16           height in rows
z_order:   u8            stacking order (higher = on top)
```

Total size: 15 bytes.

**Region roles:**

| Value | Role | Description |
|-------|------|-------------|
| 0 | editor | Main editor viewport |
| 1 | modeline | Status line |
| 2 | minibuffer | Command/message input area |
| 3 | gutter | Line numbers and signs |
| 4 | popup | Floating completion, which-key, etc. |
| 5 | panel | Side panel (file tree, etc.) |
| 6 | border | Window split borders |

### `0x18` clear_region

Clear all cells within a region to blank.

```
opcode: u8  = 0x18
id:     u16           region to clear
```

Total size: 3 bytes.

### `0x19` destroy_region

Remove a region and clear its area.

```
opcode: u8  = 0x19
id:     u16           region to destroy
```

Total size: 3 bytes.

If the destroyed region was the active region, the frontend resets to the root region.

### `0x1A` set_active_region

Route subsequent `draw_text` commands to a region.

```
opcode: u8  = 0x1A
id:     u16           region to activate (0 = root)
```

Total size: 3 bytes.

**Behavior:** After this command, `draw_text` coordinates are relative to the active region's origin. The frontend offsets and clips draw commands to stay within the region bounds. The active region resets to root on `clear`.

### TUI Implementation

The TUI renderer maintains a hash map of regions. When `set_active_region` is called, the renderer adds the region's row/col offset to every subsequent `draw_text` and clips at the region boundary. `clear_region` blanks only the cells within the region's bounds.

### GUI Implementation

Native GUI frontends should map regions to native view objects: `define_region` creates a view, `destroy_region` removes it, `set_active_region` targets draw commands into the view's coordinate space. The `role` field provides semantic hints for styling and layout behavior.

## Future: Incremental Content Sync

_This section describes a planned extension. See #154._

A new `0x26 edit_buffer` opcode will send compact edit deltas instead of full file content, reducing IPC bandwidth from O(file_size) to O(edit_size) per keystroke and enabling tree-sitter's incremental parsing.
