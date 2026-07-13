# Minga Port Protocol Specification

The BEAM editor core and rendering frontends communicate over a binary protocol on stdin/stdout of each frontend process. All frontends speak the same base transport, input, parser, and diagnostic protocol. Shared visible UI is carried as Semantic UI opcodes documented in [GUI_PROTOCOL.md](GUI_PROTOCOL.md); the `GUI` name is historical wire terminology, not a product split between GUI and terminal clients. This document is the authoritative reference for implementing a Minga frontend. You should be able to build a working frontend by reading this file plus GUI_PROTOCOL.md for Semantic UI surfaces.

**Shared chrome is delivered as Semantic UI, not cells.** The structured opcodes in GUI_PROTOCOL.md are the canonical contract for shared visible chrome (tab bar, status bar, file tree, picker, popups, agent surfaces, and so on). Each frontend decodes these semantic models and renders them with its own surface strategy: SwiftUI views, terminal widgets, GTK widgets, web components, or another future client. The cell-grid `draw_text`/`clear`/region commands were retired from the protocol in protocol_version 2; the only render-category opcodes that survive are transport-level framing (`begin_frame`, `commit_frame`, `set_cursor_shape`, `set_title`, `set_window_bg`, `protocol_error`). New shared chrome must be modeled as a `Minga.RenderModel.UI.*` semantic model and encoded by `Minga.Frontend.Adapter.GUI`, never added as ad-hoc cell draws.

Frontend identity is opaque to Minga product behavior. The BEAM may adapt to declared capabilities such as terminal grid versus desktop window, text measurement, color depth, image support, float support, and Semantic UI support, but it must not special-case Swift, Go, GTK, or another implementation name for product features.

Stream identity is producer-assigned and carried on the wire, never inferred by the consumer.

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

**Text encoding:** All text fields (titles, language names, query source, semantic content) are UTF-8 encoded.

**Protocol version:** The schema carries a `protocol_version` integer (currently 11). The BEAM and every frontend compile against it and exchange it in the `ready` handshake. The BEAM rejects a frontend whose version does not match and sends an explicit `protocol_error` instead of streaming frames the frontend cannot decode. Version 11 makes frame transactions generation-aware, adds explicit applied, rejected, and targeted window-reference-miss status, and evolves A2 with bounded immutable-base RowSplices. Version-10 A2 complete snapshots remain replay-decodable. See "Protocol Version Negotiation" below.

---

## Quick Reference

### BEAM → Frontend (Render-Transport Commands)

The cell-paradigm render opcodes (`draw_text`, `set_cursor`, `clear`, and the region commands) were retired in protocol_version 2. All visible content now flows through Semantic UI opcodes (see GUI_PROTOCOL.md, `gui_window_content` 0x80). Only transport-level framing survives in this category.

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x10` | begin_frame | 13 | Open a generation-aware frame transaction (frame_seq + base_frame_seq + generation); see Frame Transactions |
| `0x11` | commit_frame | 9 | Close a frame transaction; promote staging and present (frame_seq + input_seq) |
| `0x13` | _(reserved)_ | — | Freed by retiring batch_end in v3; do not reassign before a version bump past 3 |
| `0x15` | set_cursor_shape | 2 | Change cursor appearance |
| `0x16` | set_title | 3 + title_len | Set the window/terminal title |
| `0x17` | set_window_bg | 4 | Set the default background color |
| `0x18` | protocol_error | 3 + msg_len | Version-mismatch error; frontend shows it and stops decoding |
| `0x27` | measure_text | 7 + text_len | Request display width of text |

### BEAM → Frontend (Config Commands)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x50` | set_font | 7 + name_len | Set font family, size, weight, and ligatures |

### BEAM → Frontend (Highlight Commands)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x20` | set_language | 3 + name_len | Set the active tree-sitter language |
| `0x21` | parse_buffer | 9 + source_len | Parse buffer content for highlighting |
| `0x22` | set_highlight_query | 5 + query_len | Set a custom highlight query |
| `0x23` | load_grammar | 5 + name_len + path_len | Load a grammar from a shared library |
| `0x24` | set_injection_query | 5 + query_len | Set a custom injection query |
| `0x25` | query_language_at | 9 | Query the language at a byte offset |
| `0x26` | edit_buffer | 7 + variable | Incremental edit deltas |
| `0x28` | set_fold_query | 5 + query_len | Set a custom fold query |
| `0x29` | set_indent_query | 5 + query_len | Set a custom indent query |
| `0x2A` | request_indent | 13 | Request indent level for a line |
| `0x2B` | set_textobject_query | 5 + query_len | Set a custom text object query |
| `0x2C` | request_textobject | variable | Request a text object range |
| `0x2D` | close_buffer | 5 | Free parser state for a buffer |
| `0x2E` | request_match_item | 17 | Request structural delimiter, keyword, quote, or tag match |
| `0x2F` | request_structural_nav | 18 | Request parent, child, or sibling AST navigation |

### Frontend → BEAM (Input Events)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x01` | key_press | 6 | A key was pressed |
| `0x02` | resize | 5 | Terminal/window was resized |
| `0x03` | ready | 5, 13, or 29 | Frontend is initialized and ready (29 carries capability format 2 and protocol version) |
| `0x04` | mouse_event | 9 | Mouse button, wheel, or motion (8-byte legacy also accepted) |
| `0x05` | capabilities_updated | 9 or 23 | Updated versioned capabilities after async detection |
| `0x08` | request_keyframe | 9 | Ask the BEAM to start a fresh recovery generation (last_good_frame_seq + failed generation) |
| `0x0A` | frame_applied | 9 | Report semantic publication of a complete frame |
| `0x0B` | frame_rejected | 15 | Reject a correlated frame with stable reason and disposition |
| `0x0C` | window_ref_miss | 15 | Reject a missing row/window reference and identify the affected window |

### Frontend → BEAM (Highlight Responses)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x30` | highlight_spans | 9 + count × 10 | Syntax highlight byte ranges |
| `0x31` | highlight_names | 3 + variable | Capture name list for spans |
| `0x32` | grammar_loaded | 4 + name_len | Grammar load success/failure |
| `0x33` | language_at_response | 7 + name_len | Language at a byte offset |
| `0x34` | injection_ranges | 3 + variable | Injection language regions |
| `0x35` | text_width | 7 | Display width of measured text |
| `0x36` | fold_ranges | variable | Fold range results from tree-sitter |
| `0x37` | indent_result | 13 | Indent level result for a line |
| `0x38` | textobject_result | variable | Text object range result (or nil) |
| `0x39` | textobject_positions | 9 + count × 9 | Proactive text object position cache |
| `0x3A` | conceal_spans | variable | Conceal byte ranges and replacement text |
| `0x3B` | request_reparse | 5 | Parser requests full reparse after stale edit deltas |
| `0x3C` | match_item_result | 6 or 14 | Structural match position result (or nil) |
| `0x3D` | node_info | 6 or 24 + type_len | Structural navigation target range and node type |

### Frontend → BEAM (Diagnostics)

| Opcode | Name | Size | Description |
|--------|------|------|-------------|
| `0x60` | log_message | 4 + msg_len | Log message from the frontend |

---

## Render-Transport Commands (BEAM → Frontend)

The cell-paradigm render opcodes (`draw_text` 0x10, `set_cursor` 0x11, `clear` 0x12, and the region commands 0x14/0x18-0x1A/0x1B and `draw_styled_text` 0x1C) were retired in protocol_version 2 along with the Zig cell-grid renderer (#2223). All visible content is now carried by Semantic UI opcodes (GUI_PROTOCOL.md, `gui_window_content` 0x80 and the `gui_*` chrome opcodes), which embed their own cursor position and shape per window. Only the transport-level opcodes below survive in the render category.

### `0x10` begin_frame / `0x11` commit_frame

Frame transaction markers. See the "Frame Transactions" section for the full wire shapes, invalidation rules, and keyframe semantics.

### `0x13` _(reserved; batch_end retired in protocol_version 3)_

`batch_end` (0x13) was the single per-frame terminator before protocol_version 3. It was retired in #2219 child B: its echoed input-correlation u32 (ticket #2215) moved verbatim onto `commit_frame`, and the begin/commit transaction pair now brackets every frame. The 0x13 slot is reserved and must not be reassigned before a version bump past 3 (the freed-value reuse policy).

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

### `0x17` set_window_bg

Set the default background color for the frontend surface.

```
opcode: u8 = 0x17
r:      u8
g:      u8
b:      u8
```

Total size: 4 bytes.

**Behavior:** The frontend uses this as the fallback background so content does not fall back to the terminal/window default, which may not match the editor theme.

### `0x18` protocol_error

Sent by the BEAM when a frontend's handshake `protocol_version` does not match the BEAM's. See "Protocol Version Negotiation".

```
opcode:  u8  = 0x18
msg_len: u16            UTF-8 byte length of the message
message: [msg_len]u8    human-readable reason
```

Total size: 3 + msg_len bytes.

**Behavior:** The frontend displays the message as a blocking error and stops decoding subsequent frames. The BEAM does not stream render frames to a version-mismatched frontend.

---

## Render Frame Lifecycle

Visible content is carried by Semantic UI opcodes (GUI_PROTOCOL.md). A render frame is a single batched message of `gui_*` semantic commands (window content, chrome, overlays) bracketed by a `begin_frame`/`commit_frame` transaction (#2219):

```
begin_frame          (opens the transaction; frame_seq + base_frame_seq)
gui_window_content / gui_* chrome commands ...   (the semantic frame; see GUI_PROTOCOL.md)
set_cursor_shape     (optional; may be omitted if unchanged)
commit_frame         (triggers the actual present; carries frame_seq + the latency echo)
```

The BEAM sends the entire frame as a single batched message. The frontend processes commands in order and only presents on `commit_frame`. Cursor position and shape are embedded per window inside `gui_window_content`, not carried by standalone cell opcodes.

Between frames, the frontend must not mutate committed editor state or present new semantic content. The only exception is ephemeral presentation scroll driven by `gui_window_content` section 0x0A (`ScrollPresentation`): a frontend may transform already committed or retained rows inside the BEAM-provided clip rect and overscan bounds while waiting for the next committed frame. The BEAM still owns the committed viewport, cursor, selection, layout, row identity, and hit-test state.

---

## Bounded length carriers

`clipboard_write` uses a u32 outer payload length and u32 text length. `gui_window_content` and its A1/A2 delta commands use u32 section lengths and u32 row counts. These carriers represent values from 0 through 4,294,967,295 bytes or rows, but both shipped frontends reject packets larger than 64 MiB before allocation. A producer must reject a value outside its carrier before writing any part of the command. Fields documented as u8 or u16 remain intentionally bounded and must likewise fail before emission when their value is out of range. The BEAM reports a rejected field as a structured encoding error with its command, field, actual value, and allowed range, sends no frame commands, then resets its adapter cache so the following valid frame is a base-0 keyframe.

## Frame Transactions

> Status: protocol_version 11 makes every transaction recovery-generation-aware. Frontends stage and validate the complete semantic transaction, publish it atomically on `commit_frame`, and then report whether it was applied, rejected, or missed a window reference. The BEAM grants one in-flight frame credit per frontend connection and uses only an applied frame from the current generation as a later delta base.

A frame transaction makes a frame atomic: the BEAM brackets a frame's semantic commands between `begin_frame` and `commit_frame`, and a frontend paints nothing until it sees the matching `commit_frame`. This replaces the single `batch_end` terminator with an explicit open/close pair so a truncated or out-of-order stream can never paint a partial frame.

### Wire shapes

`begin_frame` (0x10), fixed 13 bytes:

```
opcode:         u8  = 0x10
frame_seq:      u32           strictly monotonic frame sequence for this connection
base_frame_seq: u32           acknowledged frame these deltas assume; 0 = keyframe
generation:     u32           BEAM-owned recovery generation
```

`commit_frame` (0x11), fixed 9 bytes:

```
opcode:    u8  = 0x11
frame_seq: u32                must equal the open begin_frame's frame_seq
input_seq: u32                echoed input correlation sequence (#2215); 0 = no correlation
```

`request_keyframe` (0x08, Frontend → BEAM), fixed 9 bytes:

```
opcode:              u8  = 0x08
last_good_frame_seq: u32      last frame_seq the frontend applied cleanly; 0 if none
failed_generation:   u32      generation whose recovery is being retried
```

A frame is therefore: `begin_frame ++ gui_* semantic/chrome commands ++ gui_surface_layout ++ commit_frame`. The placement envelope (`gui_surface_layout` 0xA4) is sent inside the transaction; see GUI_PROTOCOL.md for its section layout.

### Sequence identifiers

`frame_seq` and `input_seq` are separate correlation IDs and must not be conflated:

- `frame_seq` is strictly monotonic (it reuses `Renderer.Server`'s existing seq). It orders frames for resync and multi-client attach. Idle re-renders still advance `frame_seq`.
- `input_seq` is the latency echo moved verbatim from `batch_end` (#2215). It is the latest processed `key_press` correlation sequence, so the frontend resolves a keystroke-to-present latency sample when the frame presents. An idle re-render advances `frame_seq` while echoing a stale (unchanged) `input_seq`.

### Keyframe as base 0

There is no separate keyframe opcode. A keyframe is just a transaction whose `base_frame_seq == 0`: it depends on no prior frame and carries full snapshots (full `gui_window_content`, fresh content epochs) rather than deltas. Because it assumes nothing, a keyframe also doubles as the multi-client attach mechanism: a newly attached client is brought current by a full keyframe.

`base_frame_seq` names the frame whose committed state this transaction's deltas build on. A frontend may only apply a delta transaction whose `base_frame_seq` is a frame it has committed; otherwise the base is unknown (see invalidation below).

### Invalidation rules

Four conditions invalidate the in-flight frame. In every case the frontend discards its staged (uncommitted) frame and sends `request_keyframe` with its `last_good_frame_seq`, then resumes only once a fresh keyframe arrives:

1. **Truncation.** The stream ends mid-transaction, or a new `begin_frame` arrives before the open transaction's `commit_frame`. The partial frame is never presented.
2. **Seq mismatch.** A `commit_frame` whose `frame_seq` does not match the open `begin_frame`'s `frame_seq`, or a `begin_frame` arriving while a transaction is already open.
3. **In-transaction sizing failure or unknown opcode.** An unsizable or unknown opcode encountered inside an open transaction. Byte boundaries are no longer trustworthy, so the frontend cannot safely continue. This deliberately tightens the reader's normal warn-and-continue policy: outside a transaction the reader may still skip an unknown opcode, but inside one it invalidates.
4. **Base mismatch.** A delta transaction whose `base_frame_seq` names a frame this client never committed.

### request_keyframe flow

After any invalidation the frontend emits a typed rejection status. `window_ref_miss` identifies the affected window so the BEAM can preserve the acknowledged surrounding frame and emit a full replacement only for that window. Transaction-level rejection starts a fresh generation and sends the latest coalesced render intent as a full keyframe (`base_frame_seq == 0`). A manual `request_keyframe` also starts a fresh generation; it never merely repeats the failed generation.

The BEAM keeps one frame credit **per frontend connection**. A Port write consumes the credit but does not advance the delta base. While status is outstanding, newer render requests replace the single pending intent. Only a matching `frame_applied` returns the credit and advances the acknowledged base. Rejected, duplicate, stale, out-of-order, wrong-generation, and inconsistent-last-applied statuses cannot advance the base or clear recovery. Recovery clears only when the requested base-zero keyframe is semantically published and its matching applied status reaches the BEAM. Metal/GPU presentation is deliberately outside this contract.

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
width:  u16           content columns available at current presentation metrics
height: u16           content rows available at current presentation metrics
```

Total size: 5 bytes.

**Behavior:** Sent when the frontend detects a size change (SIGWINCH for TUI, window resize event for GUI). The BEAM re-renders to the new dimensions on the next frame.

`width`/`height` are **content cells**, not pixels. Each frontend owns the single row-fit floor and reports how many rows and columns fit its content area at the current font, backing scale, and line spacing: `rows = floor(content_pixels / (cell_height × line_spacing))`, computed once in the layer that owns the pixels. The BEAM lays out in exactly these rows and performs no pixel or line-spacing arithmetic of its own. The TUI reports its terminal grid unchanged (line spacing is 1.0 there by construction). Line spacing reaches the GUI only as a draw-time rendering hint (`gui_line_spacing`, 0x92) and a runtime spacing change arrives back here as an ordinary resize. See `docs/adr/0001-frontend-owns-row-fit.md`.

### `0x03` ready

The frontend has initialized and is ready to receive render commands.

The `width`/`height` fields carry the same "content cells at current presentation metrics" meaning as `resize` above (see that section for the row-fit rule and ADR-0001 reference).

**Short format (5 bytes):**
```
opcode: u8  = 0x03
width:  u16           initial content columns available at current presentation metrics
height: u16           initial content rows available at current presentation metrics
```

**Extended format (13 bytes, or 15+ with a version tail):**
```
opcode:           u8  = 0x03
width:            u16           initial content columns available at current presentation metrics
height:           u16           initial content rows available at current presentation metrics
caps_version:     u8            capability format version (currently 2)
caps_len:         u8            length of capability data
caps_data:        [caps_len]u8  capability fields (see "Capability Negotiation" section)
protocol_version: u16           OPTIONAL: the wire-contract version the frontend was generated against
```

**Behavior:** Sent exactly once, during startup, after the frontend has set up its rendering surface. The BEAM waits for this event before sending any render commands.

Frontends should use the extended format with the `protocol_version` tail. The BEAM detects which format was sent by checking the payload length: 5 bytes = short format with default capabilities and no version (treated as protocol_version 0); 13 bytes = extended capabilities with no version tail (also treated as protocol_version 0); 15+ bytes = extended capabilities followed by a u16 `protocol_version`. See "Protocol Version Negotiation".

### `0x04` mouse_event

A mouse button, wheel, or motion event.

```
opcode:      u8  = 0x04
row:         i16           screen row (signed; -1 = outside window)
col:         i16           screen column (signed; -1 = outside window)
button:      u8            button identifier
modifiers:   u8            modifier flags (same as key_press)
event_type:  u8            type of mouse event
click_count: u8            1 = single, 2 = double, 3 = triple (clamped)
```

Total size: 9 bytes.

**Backward compatibility:** The BEAM decoder accepts 8-byte messages (legacy format without `click_count`) and defaults `click_count` to 1. GUI frontends should always send the 9-byte format with the native click count from the OS. TUI frontends send `click_count=1` and let the BEAM detect multi-clicks via timing.

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

### Frame recovery status (`0x08`, `0x0A`–`0x0C`)

`request_keyframe` has the 9-byte generation-aware shape documented under Frame Transactions. It is the manual/general retry control and causes the BEAM to advance generation.

`frame_applied` (0x0A), fixed 9 bytes: `generation:u32, frame_seq:u32`. Emit it only after the complete transaction has validated and its semantic state has been published atomically. Do not wait for Metal submission, terminal drawing, visibility, or vsync.

`frame_rejected` (0x0B), fixed 15 bytes: `generation:u32, frame_seq:u32, last_applied_frame_seq:u32, reason:u8, disposition:u8`. The disposition byte is appended, so generation, frame sequence, last-good base, and reason retain their protocol-version-11 positions.

`window_ref_miss` (0x0C), fixed 15 bytes: `generation:u32, frame_seq:u32, last_applied_frame_seq:u32, window_id:u16`. It is the targeted form for a missing retained row/window reference; sibling windows and chrome remain committed at `last_applied_frame_seq`.

Stable rejection reasons are: 1 truncation, 2 commit sequence mismatch, 3 non-increasing frame sequence, 4 base sequence mismatch, 5 missing theme, 6 incomplete theme, 7 missing window reference, 8 window epoch mismatch, 9 invalid retained rows, 10 missing font resource, 11 transcript desync, 12 decode failure, 13 out-of-transaction command, 14 invalid row splice, 15 resource policy, and 255 unknown.

Disposition values are generated from the shared schema: 1 retryable recovery, 2 targeted replacement, 3 adapted retry, and 4 terminal frontend failure. Ordinary lineage failures remain retryable. Missing retained references use `window_ref_miss` and stay scoped. Resource-policy rejection defaults terminal. An adapted retry is valid only when the producer has one-shot local evidence bound to the rejected generation and frame, a non-zero advertised dimension (`frame_bytes`, `frame_commands`, or `window_rows`), distinct rejected/adapted values, and a concrete adapted intent distinct from the rejected intent; the evidence is deliberately not sent because detailed resource usage belongs only in privacy-safe telemetry. Terminal failure preserves `last_applied_frame_seq`, cancels outstanding credit, and must not emit or request the unchanged frame again. Current macOS and TUI frontends enforce and advertise only the 64 MiB packet-byte ceiling; command-count and window-row dimensions remain zero (unadvertised) until their hard admission checks exist.

---

## Config Commands (BEAM → Frontend)

Config commands push editor configuration to the frontend. The TUI silently ignores these (terminal fonts are set by the terminal emulator, not the editor). The macOS GUI applies them immediately.

### `0x50` set_font

Set the font family, size, weight, and ligature preference. Sent once on ready and again when the user changes font config at runtime.

```
opcode:    u8  = 0x50
size:      u16           font size in points
weight:    u8            font weight (see table below)
ligatures: u8            1 = enable programming ligatures, 0 = disable
name_len:  u16           byte length of the font family name
name:      [name_len]u8  UTF-8 encoded font family name
```

Total size: 7 + name_len bytes.

**Weight values:**

| Value | Weight |
|-------|--------|
| 0 | thin |
| 1 | light |
| 2 | regular (default) |
| 3 | medium |
| 4 | semibold |
| 5 | bold |
| 6 | heavy |
| 7 | black |

**Font name resolution (macOS GUI):** The name is a user-friendly display name like "JetBrains Mono" or "Fira Code". The frontend resolves it to an installed font using NSFontManager. PostScript names ("JetBrainsMonoNF-Regular") also work. If the font isn't found, the frontend falls back to the system monospace font and logs a warning.

**Ligature behavior:** When ligatures are enabled and the font supports programming ligatures, the frontend shapes multi-character sequences (like `->`, `!=`, `=>`) using CoreText and renders them as single wide glyphs spanning the appropriate number of cells. When disabled, each character renders individually regardless of font support. Fonts without ligature tables (e.g., Menlo) are unaffected by this flag.

**Grid resize:** Changing the font size changes the cell dimensions, which changes how many cells fit in the window. The frontend sends a `0x02 resize` event back to the BEAM with the new grid dimensions after applying a font change.

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

### `0x39` textobject_positions

Proactive cache of all `.around` text object positions in the current file, sent after each parse (initial and incremental). The BEAM caches these per-window for `]f`/`[f`-style navigation with zero per-keystroke IPC.

```
opcode:  u8  = 0x39
version: u32           parse version counter
count:   u32           number of entries
entries: [count × 9]   array of position entries
```

Each entry:
```
type_id: u8   text object type (see table below)
row:     u32  0-indexed line number
col:     u32  0-indexed byte column
```

Total size: 9 + count × 9 bytes.

**Type ID values:**

| Value | Type |
|-------|------|
| `0x00` | function |
| `0x01` | class |
| `0x02` | parameter |
| `0x03` | block |
| `0x04` | comment |
| `0x05` | test |

**Behavior:** The Zig parser runs the `textobjects.scm` query against the parse tree and collects the start positions of all `.around` captures (e.g., `@function.around`, `@class.around`). Entries are sorted by (row, col) before sending. The BEAM decodes them into a `%{atom => [{row, col}]}` map and stores them on the active window struct. Navigation commands (`]f`, `[f`, etc.) scan this cached data with no further IPC to Zig.

### `0x2F` request_structural_nav

Request Helix-style structural AST navigation from the parser. The parser starts from the deepest named tree-sitter node at the cursor and returns the requested named relative.

```
opcode:     u8  = 0x2F
buffer_id:  u32           parser buffer id
request_id: u32           caller-chosen correlation id
row:        u32           0-indexed line number
col:        u32           0-indexed byte column
action:     u8            0=parent, 1=first child, 2=next sibling, 3=previous sibling
```

Total size: 18 bytes.

**Behavior:** Anonymous and punctuation nodes are skipped by starting with `ts_node_named_descendant_for_point_range` and moving through named parents, children, or siblings. If the parser has no buffer, no grammar, or no target node, it responds with `node_info` and `found = 0`. Invalid action bytes are malformed protocol commands.

### `0x3C` match_item_result

Response to `request_match_item`. The parser returns one cursor position for the matching structural item, or `found = 0` when the cursor is not on a matchable item or the buffer has no grammar.

```
opcode:     u8  = 0x3C
request_id: u32           correlation ID from the request
found:      u8            1 if a match was found, 0 otherwise
row:        u32           present only when found = 1
col:        u32           present only when found = 1
```

Total size: 6 bytes when not found, 14 bytes when found.

**Behavior:** Used by `%` in normal, visual, and operator-pending modes. The Zig parser walks the tree-sitter AST to match structural brackets, block keywords such as `def`/`end`, string delimiters, and HTML/XML tags without falling back to text scanning.

### `0x3D` node_info

Response to `request_structural_nav`. The parser returns the target node range and tree-sitter node type, or `found = 0` when no target exists.

```
opcode:     u8  = 0x3D
request_id: u32           correlation ID from the request
found:      u8            1 if a node was found, 0 otherwise
start_row:  u32           present only when found = 1
start_col:  u32           present only when found = 1
end_row:    u32           present only when found = 1
end_col:    u32           present only when found = 1
type_len:   u16           present only when found = 1, capped at 255 bytes by the Zig encoder
type:       [type_len]u8  UTF-8 tree-sitter node type name
```

Total size: 6 bytes when not found, 24 + type_len bytes when found.

**Behavior:** The BEAM moves the cursor to `(start_row, start_col)` and can display `type` to help users learn the file's AST structure. The Zig encoder uses a fixed 280-byte stack buffer and truncates type names to 255 bytes. Current tree-sitter node type names are far shorter than this cap, but frontend and parser implementations should treat the cap as part of the wire contract.

### `0x3B` request_reparse

Sent by the parser when it receives an `edit_buffer` command with stale edit deltas (byte offsets that don't match the parser's stored source for that buffer). This typically happens after system sleep/wake, when the BEAM's view of the buffer has drifted from the parser's. The parser discards the buffer's tree and source and asks the BEAM to resend the full content via `parse_buffer`.

```
opcode:     u8  = 0x3B
buffer_id:  u32          the buffer that needs a full reparse
```

Total size: 5 bytes.

**Behavior:** The BEAM receives this event, looks up the buffer PID for the given `buffer_id`, and sends a full `set_language` + `parse_buffer` sequence for that buffer. This is the same path used when setting up a buffer for the first time, so custom user queries are replayed correctly.

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

**Highlight version mismatches:** The BEAM discards `highlight_spans` responses where the version is lower than the most recently requested version. This prevents stale async results from overwriting current highlights.

**Protocol version mismatches:** If a frontend's handshake `protocol_version` does not match the BEAM's compiled-in version, the BEAM does not mark the frontend ready and sends a single `protocol_error` (0x18) instead of streaming render frames. See "Protocol Version Negotiation".

**Frontend crash:** The BEAM's supervisor detects the Port exit and can restart the frontend. Buffer state, undo history, and cursor positions are preserved in the BEAM. The restarted frontend receives a full re-render on its first frame.

---

## Protocol Version Negotiation

The schema (`docs/protocol_schema.toml`) carries a `protocol_version` integer (currently 11). `mix protocol.gen` emits it as a constant on every side: `Minga.Protocol.Opcodes.protocol_version()` (Elixir), `generated.ProtocolVersion` (Go), `PROTOCOL_VERSION` (Swift), `PROTOCOL_VERSION` (Zig parser). Bump it whenever the wire contract changes incompatibly; protocol_version 2 retired the 9 cell-paradigm render opcodes, protocol_version 3 (#2219) added the frame-transaction vocabulary (`begin_frame`, `commit_frame`, `request_keyframe`) and authoritative layout (`surface_placement`, `gui_surface_layout`), protocol_version 4 added the `gui_file_tree` row `heat_level` byte, protocol_version 5 added producer-assigned `stream_instance` identity to the Messages stream, protocol_version 6 frames `gui_agent_context` and appends `gui_edit_timeline` file summaries, protocol_version 7 established the current baseline, protocol_version 8 added `set_link_cursor`, protocol_version 9 widened `gui_window_content` framing and section lengths, and protocol_version 10 widens clipboard and retained-window delta framing, and protocol_version 11 makes `begin_frame` generation-aware and adds explicit frame status/retry events. A frontend built against an older protocol handshakes with its old version and receives the `protocol_error` blocking surface instead of a desynced stream.

**Handshake.** A frontend appends its compiled-in `protocol_version` as a u16 tail on the extended `ready` event (after `caps_data`). A frontend that omits the tail (short ready, or extended ready without the tail) is treated as protocol_version 0.

**Enforcement.** The BEAM compares the handshake version against its own `Opcodes.protocol_version()` in `MingaEditor.Frontend.Manager`. On a match it marks the frontend ready and streams normally. On any mismatch (including 0, a frontend built before this mechanism) it does **not** mark the frontend ready and sends one `protocol_error` (0x18) carrying a human-readable reason, then drives nothing further. This converts a silent desync (a stale frontend decoding opcodes that moved or vanished) into an explicit, debuggable error.

**`0x18` protocol_error.**
```
opcode:  u8  = 0x18
msg_len: u16            UTF-8 byte length of the message
message: [msg_len]u8    human-readable reason
```
A frontend that receives `protocol_error` should display the message as a blocking error (not attempt to decode subsequent frames) and the operator should rebuild the frontend with `mix protocol.gen` so its constants match the editor.

---

## Architecture Notes

### Current design

Tree-sitter parsing runs in a dedicated `minga-parser` Zig process, separate from the rendering frontend. The rendering frontend handles the surviving render-transport commands (`begin_frame`, `commit_frame`, `set_cursor_shape`, `set_title`, `set_window_bg`, `protocol_error`) plus GUI chrome (`0x70+`). The parser process handles highlight commands (`0x20`-`0x2F`) and sends highlight responses (`0x30`-`0x3D`). Both use the same `{:packet, 4}` framing on their respective stdin/stdout pipes. The BEAM manages both Port processes, routing commands to the appropriate one. Zig is parser infrastructure only; the legacy Zig terminal renderer was removed in #2223.

This separation means rendering frontends (Swift/Metal, GTK4, Go/Bubble Tea) only need to implement render commands. Tree-sitter parsing is handled by the shared parser process regardless of which frontend is active.

---

## Capability Negotiation

The `ready` event supports an extended format with capability fields. This lets the BEAM adapt rendering strategy based on what the frontend supports.

### Extended Ready Format

```
0x03 ready (extended):
  width:          u16
  height:         u16
  caps_version:   u8    (currently 2)
  caps_len:       u8    (length of remaining fields)
  frontend_type:  u8    (0=tui, 1=native_gui, 2=web)
  color_depth:    u8    (0=mono, 1=256color, 2=rgb)
  unicode_width:  u8    (0=wcwidth, 1=unicode_15)
  image_support:  u8    (0=none, 1=kitty, 2=sixel, 3=native)
  float_support:  u8    (0=emulated, 1=native)
  text_rendering: u8    (0=monospace, 1=proportional)
  semantic_ui:    u8    (0=disabled, 1=enabled)
  resource_policy_version: u8
  max_frame_bytes:        u32
  max_frame_commands:     u32
  max_window_rows:        u32
```

Capability format 2 carries 20 capability bytes and the complete ready event is 29 bytes including the protocol-version tail. Format 1's original fields remain in the same positions.

Frontends that send the short 5-byte `ready` format are assumed to have default capabilities: `{tui, rgb, wcwidth, none, emulated, monospace}`.

### `0x05` capabilities_updated

Sent after the initial `ready` event when the frontend detects additional capabilities asynchronously (e.g., a TUI terminal responds to capability queries like DA1 after startup).

```
opcode:         u8  = 0x05
caps_version:   u8    (currently 2)
caps_len:       u8    (length of remaining fields)
frontend_type:  u8
color_depth:    u8
unicode_width:  u8
image_support:  u8
float_support:  u8
text_rendering: u8
semantic_ui:    u8
resource_policy_version: u8
max_frame_bytes:        u32
max_frame_commands:     u32
max_window_rows:        u32
```

Capability format 2 has 20 payload bytes (23 bytes including opcode/version/length).

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
| `semantic_ui` | 0=disabled, 1=enabled | Semantic render-model support |
| `resource_policy_version` | 0=unadvertised, 1=current | Version of hard-dimension policy |
| `max_frame_bytes` | u32; 0=unadvertised | Maximum admitted encoded frame bytes |
| `max_frame_commands` | u32; 0=unadvertised | Maximum admitted commands in one frame |
| `max_window_rows` | u32; 0=unadvertised | Maximum admitted rows for one semantic window |

### Implementation Notes

The TUI backend may send `ready` with default capabilities immediately at startup, then send `capabilities_updated` once its async terminal capability detection completes (e.g. after the DA1 response). The GUI backend sends `ready` with full native capabilities upfront since there is no detection delay.

## Text Measurement

For proportional-font frontends, the BEAM cannot compute display widths on its own. A request/response pair lets the BEAM query the frontend for rendered text width.

### `0x27` measure_text (BEAM → Frontend)

Request the display width of a text segment.

```
opcode:     u8  = 0x27
request_id: u32           unique request identifier
text_len:   u16           byte length of text
text:       [text_len]u8  UTF-8 encoded text to measure
```

Total size: 7 + text_len bytes.

### `0x35` text_width (Frontend → BEAM)

Response with the measured display width.

```
opcode:     u8  = 0x35
request_id: u32           matches the measure_text request
width:      u16           display width in columns (monospace) or pixels (GUI)
```

Total size: 7 bytes.

### Strategy

The BEAM uses a two-tier approach based on the frontend's `text_rendering` capability:

- **Monospace frontends** (TUI, monospace GUI): The BEAM uses its own UAX #11 width tables. `measure_text` is available for spot-checking alignment on startup but is not used per-keystroke.
- **Proportional frontends** (native GUI): The BEAM queries the frontend via `measure_text` for layout-critical computations (cursor placement, column alignment, menu truncation). Results are cached keyed by text content. The cache is flushed when the frontend sends `capabilities_updated` (e.g., after a font size change).

## Incremental Content Sync

### `0x26` edit_buffer

Send compact edit deltas instead of full file content. Enables tree-sitter incremental parsing (sub-millisecond reparse for single-character edits).

```
opcode:     u8  = 0x26
version:    u32           buffer version counter
edit_count: u16           number of edits

per edit:
  start_byte:     u32     byte offset where the edit begins
  old_end_byte:   u32     byte offset where the old text ends
  new_end_byte:   u32     byte offset where the new text ends
  start_row:      u32     row at start_byte
  start_col:      u32     column at start_byte
  old_end_row:    u32     row at old_end_byte
  old_end_col:    u32     column at old_end_byte
  new_end_row:    u32     row at new_end_byte
  new_end_col:    u32     column at new_end_byte
  text_len:       u32     byte length of inserted text
  text:           [text_len]u8  the inserted text (empty for deletions)
```

Total size: 7 + (40 + text_len) per edit.

**Behavior:** The parser applies each edit to its stored copy of the source, calls `ts_tree_edit()` on the existing parse tree, then performs an incremental reparse. Unchanged subtrees are reused, making the reparse cost proportional to the edit size rather than the file size.

**Fallback:** `parse_buffer` (opcode `0x21`) remains available for initial file load, language switches, and error recovery. If incremental parsing fails, the parser falls back to full reparse automatically.

**Edit semantics:** Each edit replaces the byte range `[start_byte, old_end_byte)` with the inserted text. For insertions, `old_end_byte == start_byte`. For deletions, `text_len == 0`. The row/col positions are needed by tree-sitter's `TSInputEdit` for invalidating the correct tree nodes.


---

## Semantic UI Protocol

Semantic-capable frontends receive additional structured data opcodes for chrome elements like tab bars, file trees, status bars, and popups. These opcodes start at 0x70. Many opcode and module names still use `GUI` because the Swift frontend was the first semantic client; treat that as historical naming. The product contract is Semantic UI for every capable frontend, including terminal clients. Capability negotiation decides whether a frontend receives and renders these models.

See [GUI_PROTOCOL.md](GUI_PROTOCOL.md) for the complete specification of Semantic UI opcodes, `gui_action` input events, theme color slots, and the behavioral contract for semantic frontends. The sectioned `gui_status_bar` opcode (`0x76`) is specified there, including the identity flags (with safe mode), the indent section (`0x0A`), named modeline segment section (`0x0B`), selection section (`0x0C`), and Editor-authored operation feedback section (`0x0F`). The operation section is independent of ordinary status messages, and generated operation kind and semantic status values—not message punctuation—define its meaning. The opcode names remain stable for compatibility.

---

## Future: Buffer Fork UI

When [buffer forking](BUFFER-AWARE-AGENTS.md#phase-2-buffer-forking-with-three-way-merge) lands, the protocol may need new opcodes for fork-related UI elements: fork status indicators in the modeline, merge conflict region rendering, or a fork branch picker. These will be additive (new opcodes, no changes to existing ones). Frontend implementors can safely ignore unknown opcodes by reading and discarding the payload based on the length prefix.
