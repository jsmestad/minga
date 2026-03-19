/// Port protocol encoder/decoder for BEAM ↔ Zig communication.
///
/// Messages use a simple binary format with 1-byte opcodes:
///
/// Input events (Zig → BEAM):
///   0x01 key_press:    codepoint:u32, modifiers:u8
///   0x02 resize:       width:u16, height:u16
///   0x03 ready:        width:u16, height:u16
///   0x04 mouse_event:  row:i16, col:i16, button:u8, modifiers:u8, event_type:u8
///   0x06 paste_event:  text_len:u16, text:u8[text_len]
///
/// Render commands (BEAM → Zig):
///   0x10 draw_text:        row:u16, col:u16, fg:u24, bg:u24, attrs:u8, text_len:u16, text
///   0x1C draw_styled_text: row:u16, col:u16, fg:u24, bg:u24, attrs:u16, ul_color:u24, blend:u8, text_len:u16, text
///   0x11 set_cursor:       row:u16, col:u16
///   0x12 clear:      (empty)
///   0x13 batch_end:  (empty)
///
/// The 4-byte length prefix is handled by Erlang's {:packet, 4} and
/// is NOT included in encode/decode here.
const std = @import("std");

// ── Opcodes ──

pub const OP_KEY_PRESS: u8 = 0x01;
pub const OP_RESIZE: u8 = 0x02;
pub const OP_READY: u8 = 0x03;
pub const OP_MOUSE_EVENT: u8 = 0x04;
pub const OP_CAPABILITIES_UPDATED: u8 = 0x05;
pub const OP_PASTE_EVENT: u8 = 0x06;
pub const OP_DRAW_TEXT: u8 = 0x10;
pub const OP_SET_CURSOR: u8 = 0x11;
pub const OP_CLEAR: u8 = 0x12;
pub const OP_BATCH_END: u8 = 0x13;
pub const OP_DEFINE_REGION: u8 = 0x14;
pub const OP_SET_CURSOR_SHAPE: u8 = 0x15;
pub const OP_SET_TITLE: u8 = 0x16;
pub const OP_SET_WINDOW_BG: u8 = 0x17;
pub const OP_CLEAR_REGION: u8 = 0x18;
pub const OP_DESTROY_REGION: u8 = 0x19;
pub const OP_SET_ACTIVE_REGION: u8 = 0x1A;
pub const OP_SCROLL_REGION: u8 = 0x1B;
pub const OP_DRAW_STYLED_TEXT: u8 = 0x1C;

// Config commands (BEAM → frontend, TUI ignores)
pub const OP_SET_FONT: u8 = 0x50;
pub const OP_SET_FONT_FALLBACK: u8 = 0x51;
pub const OP_REGISTER_FONT: u8 = 0x52;

// Incremental content sync (BEAM → Zig)
pub const OP_EDIT_BUFFER: u8 = 0x26;

// Text measurement (BEAM → Zig)
pub const OP_MEASURE_TEXT: u8 = 0x27;

// Highlight commands (BEAM → Zig)
pub const OP_SET_LANGUAGE: u8 = 0x20;
pub const OP_PARSE_BUFFER: u8 = 0x21;
pub const OP_SET_HIGHLIGHT_QUERY: u8 = 0x22;
pub const OP_LOAD_GRAMMAR: u8 = 0x23;
pub const OP_SET_INJECTION_QUERY: u8 = 0x24;
pub const OP_QUERY_LANGUAGE_AT: u8 = 0x25;
pub const OP_SET_FOLD_QUERY: u8 = 0x28;
pub const OP_SET_INDENT_QUERY: u8 = 0x29;
pub const OP_REQUEST_INDENT: u8 = 0x2A;
pub const OP_SET_TEXTOBJECT_QUERY: u8 = 0x2B;
pub const OP_REQUEST_TEXTOBJECT: u8 = 0x2C;
pub const OP_CLOSE_BUFFER: u8 = 0x2D;

// Highlight responses (Zig → BEAM)
pub const OP_HIGHLIGHT_SPANS: u8 = 0x30;
pub const OP_HIGHLIGHT_NAMES: u8 = 0x31;
pub const OP_GRAMMAR_LOADED: u8 = 0x32;
pub const OP_LANGUAGE_AT_RESPONSE: u8 = 0x33;
pub const OP_INJECTION_RANGES: u8 = 0x34;

// Text measurement responses (Zig → BEAM)
pub const OP_TEXT_WIDTH: u8 = 0x35;

// Fold responses (Zig → BEAM)
pub const OP_FOLD_RANGES: u8 = 0x36;

// Indent responses (Zig → BEAM)
pub const OP_INDENT_RESULT: u8 = 0x37;

// Textobject responses (Zig → BEAM)
pub const OP_TEXTOBJECT_RESULT: u8 = 0x38;
pub const OP_TEXTOBJECT_POSITIONS: u8 = 0x39;

// Log messages (Zig → BEAM)
pub const OP_LOG_MESSAGE: u8 = 0x60;

// Log levels
pub const LOG_LEVEL_ERR: u8 = 0;
pub const LOG_LEVEL_WARN: u8 = 1;
pub const LOG_LEVEL_INFO: u8 = 2;
pub const LOG_LEVEL_DEBUG: u8 = 3;

// ── Cursor shapes ──

pub const CURSOR_BLOCK: u8 = 0x00;
pub const CURSOR_BEAM: u8 = 0x01;
pub const CURSOR_UNDERLINE: u8 = 0x02;

// ── Modifier flags ──

pub const MOD_SHIFT: u8 = 0x01;
pub const MOD_CTRL: u8 = 0x02;
pub const MOD_ALT: u8 = 0x04;
pub const MOD_SUPER: u8 = 0x08;

// ── Mouse button values (matching libvaxis Mouse.Button enum) ──

pub const MOUSE_LEFT: u8 = 0x00;
pub const MOUSE_MIDDLE: u8 = 0x01;
pub const MOUSE_RIGHT: u8 = 0x02;
pub const MOUSE_NONE: u8 = 0x03;
pub const MOUSE_WHEEL_UP: u8 = 0x40;
pub const MOUSE_WHEEL_DOWN: u8 = 0x41;
pub const MOUSE_WHEEL_RIGHT: u8 = 0x42;
pub const MOUSE_WHEEL_LEFT: u8 = 0x43;

// ── Mouse event types ──

pub const MOUSE_PRESS: u8 = 0x00;
pub const MOUSE_RELEASE: u8 = 0x01;
pub const MOUSE_MOTION: u8 = 0x02;
pub const MOUSE_DRAG: u8 = 0x03;

// ── Frontend capability constants ──

pub const CAPS_VERSION: u8 = 1;

pub const FRONTEND_TUI: u8 = 0;
pub const FRONTEND_NATIVE_GUI: u8 = 1;
pub const FRONTEND_WEB: u8 = 2;

pub const COLOR_MONO: u8 = 0;
pub const COLOR_256: u8 = 1;
pub const COLOR_RGB: u8 = 2;

pub const UNICODE_WCWIDTH: u8 = 0;
pub const UNICODE_15: u8 = 1;

pub const IMAGE_NONE: u8 = 0;
pub const IMAGE_KITTY: u8 = 1;
pub const IMAGE_SIXEL: u8 = 2;
pub const IMAGE_NATIVE: u8 = 3;

pub const FLOAT_EMULATED: u8 = 0;
pub const FLOAT_NATIVE: u8 = 1;

pub const TEXT_MONOSPACE: u8 = 0;
pub const TEXT_PROPORTIONAL: u8 = 1;

// ── Region roles ──

pub const REGION_EDITOR: u8 = 0;
pub const REGION_MODELINE: u8 = 1;
pub const REGION_MINIBUFFER: u8 = 2;
pub const REGION_GUTTER: u8 = 3;
pub const REGION_POPUP: u8 = 4;
pub const REGION_PANEL: u8 = 5;
pub const REGION_BORDER: u8 = 6;

// ── Highlight types (shared between renderer and parser) ──

/// A syntax highlight span: a byte range tagged with a capture ID.
pub const Span = struct {
    start_byte: u32,
    end_byte: u32,
    capture_id: u16,
    pattern_index: u16,
    /// Priority layer: 0 = outer language, 1+ = injection depth.
    /// Higher layers win when spans overlap at the same byte position.
    /// Serialized in the port protocol as u16.
    layer: u16 = 0,
};

/// An injection language region: a byte range mapped to a language name.
pub const InjectionRange = struct {
    start_byte: u32,
    end_byte: u32,
    language: []const u8,
};

/// A layout region defines a rectangular area on screen.
pub const Region = struct {
    id: u16,
    parent_id: u16,
    role: u8,
    row: u16,
    col: u16,
    width: u16,
    height: u16,
    z_order: u8,
};

/// Frontend capabilities, reported in the extended ready event and
/// capabilities_updated events.
pub const Capabilities = struct {
    frontend_type: u8 = FRONTEND_TUI,
    color_depth: u8 = COLOR_RGB,
    unicode_width: u8 = UNICODE_WCWIDTH,
    image_support: u8 = IMAGE_NONE,
    float_support: u8 = FLOAT_EMULATED,
    text_rendering: u8 = TEXT_MONOSPACE,
};

// ── Attribute flags ──

pub const ATTR_BOLD: u8 = 0x01;
pub const ATTR_UNDERLINE: u8 = 0x02;
pub const ATTR_ITALIC: u8 = 0x04;
pub const ATTR_REVERSE: u8 = 0x08;
pub const ATTR_STRIKETHROUGH: u16 = 0x10;
// Underline style occupies bits 5-7 of the extended u16 attrs:
// 0b000 = line (default), 0b001 = curl, 0b010 = dashed, 0b011 = dotted, 0b100 = double
pub const UL_STYLE_SHIFT: u4 = 5;
pub const UL_STYLE_MASK: u16 = 0x07 << UL_STYLE_SHIFT;

// ── Decoded types ──

pub const CursorShape = enum(u8) {
    block = CURSOR_BLOCK,
    beam = CURSOR_BEAM,
    underline = CURSOR_UNDERLINE,
};

pub const RenderCommand = union(enum) {
    draw_text: DrawText,
    draw_styled_text: DrawStyledText,
    set_cursor: SetCursor,
    set_cursor_shape: CursorShape,
    set_title: []const u8,
    clear: void,
    batch_end: void,
    // Region commands
    define_region: Region,
    clear_region: u16,
    destroy_region: u16,
    set_active_region: u16,
    // Scroll region (terminal scroll optimization)
    scroll_region: ScrollRegion,
    // Incremental content sync
    edit_buffer: EditBuffer,
    // Text measurement
    measure_text: MeasureText,
    // Default background color for cells that don't specify one.
    set_default_bg: u24,
    // No-op (command was decoded and skipped; GUI-only opcodes, etc.)
    noop: void,
    // Highlight commands
    set_language: SetLanguage,
    parse_buffer: ParseBuffer,
    set_highlight_query: SetHighlightQuery,
    set_injection_query: SetInjectionQuery,
    set_fold_query: SetFoldQuery,
    set_indent_query: SetIndentQuery,
    request_indent: RequestIndent,
    set_textobject_query: SetTextobjectQuery,
    request_textobject: RequestTextobject,
    load_grammar: LoadGrammar,
    query_language_at: QueryLanguageAt,
    close_buffer: u32, // buffer_id
};

/// A single edit delta for incremental content sync.
pub const EditDelta = struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_row: u32,
    start_col: u32,
    old_end_row: u32,
    old_end_col: u32,
    new_end_row: u32,
    new_end_col: u32,
    inserted_text: []const u8,
};

/// An edit_buffer command containing one or more edit deltas.
pub const EditBuffer = struct {
    buffer_id: u32 = 0,
    version: u32,
    edits: []const EditDelta,
};

pub const MeasureText = struct {
    request_id: u32,
    text: []const u8,
};

pub const QueryLanguageAt = struct {
    buffer_id: u32 = 0,
    request_id: u32,
    byte_offset: u32,
};

pub const ParseBuffer = struct {
    buffer_id: u32 = 0,
    version: u32,
    source: []const u8,
};

pub const SetLanguage = struct {
    buffer_id: u32 = 0,
    name: []const u8,
};

pub const SetHighlightQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const SetInjectionQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const SetFoldQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const SetIndentQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const SetTextobjectQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const RequestIndent = struct {
    buffer_id: u32 = 0,
    request_id: u32,
    line: u32,
};

pub const RequestTextobject = struct {
    buffer_id: u32 = 0,
    request_id: u32,
    row: u32,
    col: u32,
    capture_name: []const u8,
};

pub const LoadGrammar = struct {
    name: []const u8,
    path: []const u8,
};

/// A scroll region command: tells the renderer to use ANSI scroll
/// region sequences to shift content within a screen row range.
///
/// `delta` > 0: scroll up (content moves up, new lines revealed at bottom).
/// `delta` < 0: scroll down (content moves down, new lines revealed at top).
pub const ScrollRegion = struct {
    top_row: u16,
    bottom_row: u16,
    delta: i16,
};

pub const DrawText = struct {
    row: u16,
    col: u16,
    fg: u24,
    bg: u24,
    attrs: u8,
    text: []const u8,
};

/// Extended draw command with 16-bit attrs, underline color, blend, font weight, and font ID.
/// Opcode 0x1C. Wire format:
///   row:u16, col:u16, fg:u24, bg:u24, attrs:u16, ul_color:u24, blend:u8, font_weight:u8, font_id:u8, text_len:u16, text
/// The TUI ignores font_id (not stored in DrawStyledText).
pub const DrawStyledText = struct {
    row: u16,
    col: u16,
    fg: u24,
    bg: u24,
    attrs: u16,
    ul_color: u24,
    blend: u8,
    font_weight: u8,
    text: []const u8,
};

pub const SetCursor = struct {
    row: u16,
    col: u16,
};

pub const DecodeError = error{
    UnknownOpcode,
    Malformed,
};

// ── Encoding (Zig → BEAM) ──

/// Encodes a key_press event into the provided buffer.
/// Returns the number of bytes written (always 6).
pub fn encodeKeyPress(buf: []u8, codepoint: u32, modifiers: u8) !usize {
    if (buf.len < 6) return error.Malformed;
    buf[0] = OP_KEY_PRESS;
    std.mem.writeInt(u32, buf[1..5], codepoint, .big);
    buf[5] = modifiers;
    return 6;
}

/// Encodes a resize event into the provided buffer.
/// Returns the number of bytes written (always 5).
pub fn encodeResize(buf: []u8, width: u16, height: u16) !usize {
    if (buf.len < 5) return error.Malformed;
    buf[0] = OP_RESIZE;
    std.mem.writeInt(u16, buf[1..3], width, .big);
    std.mem.writeInt(u16, buf[3..5], height, .big);
    return 5;
}

/// Encodes a ready event into the provided buffer.
/// If `caps` is non-null, encodes the extended format with capability fields (13 bytes).
/// Otherwise encodes the short format (5 bytes).
pub fn encodeReady(buf: []u8, width: u16, height: u16) !usize {
    if (buf.len < 5) return error.Malformed;
    buf[0] = OP_READY;
    std.mem.writeInt(u16, buf[1..3], width, .big);
    std.mem.writeInt(u16, buf[3..5], height, .big);
    return 5;
}

/// Encodes a ready event with capabilities into the provided buffer.
/// Extended format: opcode(1) + width(2) + height(2) + caps_version(1) + caps_len(1) + caps(6) = 13 bytes.
pub fn encodeReadyWithCaps(buf: []u8, width: u16, height: u16, caps: Capabilities) !usize {
    const total = 13;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_READY;
    std.mem.writeInt(u16, buf[1..3], width, .big);
    std.mem.writeInt(u16, buf[3..5], height, .big);
    buf[5] = CAPS_VERSION;
    buf[6] = 6; // caps_len: 6 fields
    buf[7] = caps.frontend_type;
    buf[8] = caps.color_depth;
    buf[9] = caps.unicode_width;
    buf[10] = caps.image_support;
    buf[11] = caps.float_support;
    buf[12] = caps.text_rendering;
    return total;
}

/// Encodes a capabilities_updated event (opcode 0x05).
/// Same payload as the caps portion of extended ready: version(1) + len(1) + fields(6) = 8 bytes.
pub fn encodeCapabilitiesUpdated(buf: []u8, caps: Capabilities) !usize {
    const total = 9;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_CAPABILITIES_UPDATED;
    buf[1] = CAPS_VERSION;
    buf[2] = 6;
    buf[3] = caps.frontend_type;
    buf[4] = caps.color_depth;
    buf[5] = caps.unicode_width;
    buf[6] = caps.image_support;
    buf[7] = caps.float_support;
    buf[8] = caps.text_rendering;
    return total;
}

/// Encodes a mouse event into the provided buffer.
/// Returns the number of bytes written (always 9).
/// The click_count field is 1 for single click, 2 for double, 3 for triple.
/// The Zig TUI always sends 1; the BEAM does multi-click detection for TUI events.
/// GUI frontends (Swift) send the native click count.
pub fn encodeMouseEvent(buf: []u8, row: i16, col: i16, button: u8, modifiers: u8, event_type: u8, click_count: u8) !usize {
    if (buf.len < 9) return error.Malformed;
    buf[0] = OP_MOUSE_EVENT;
    std.mem.writeInt(i16, buf[1..3], row, .big);
    std.mem.writeInt(i16, buf[3..5], col, .big);
    buf[5] = button;
    buf[6] = modifiers;
    buf[7] = event_type;
    buf[8] = click_count;
    return 9;
}

/// Encodes a paste_event into an allocator-owned buffer.
/// Layout: opcode(1) + text_len(2, big-endian) + text(text_len).
/// The text is UTF-8 encoded. Maximum text length is 65535 bytes (u16 max).
/// Returns the allocated slice containing the encoded message.
/// Caller owns the returned memory.
pub fn encodePasteEvent(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const text_len: u16 = @intCast(@min(text.len, std.math.maxInt(u16)));
    const total: usize = 1 + 2 + text_len;
    const buf = try allocator.alloc(u8, total);
    buf[0] = OP_PASTE_EVENT;
    std.mem.writeInt(u16, buf[1..3], text_len, .big);
    @memcpy(buf[3..][0..text_len], text[0..text_len]);
    return buf;
}

/// Writes a length-prefixed message to the writer.
/// Adds a 4-byte big-endian length header before the payload.
pub fn writeMessage(writer: anytype, payload: []const u8) !void {
    const len: u32 = @intCast(payload.len);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, len, .big);
    try writer.writeAll(&len_buf);
    try writer.writeAll(payload);
}

// ── Encoding: highlight responses (Zig → BEAM) ──

/// Encodes highlight_spans: opcode(1) + buffer_id(4) + version(4) + count(4) + spans(count * 14)
/// Each span: start_byte:u32, end_byte:u32, capture_id:u16, pattern_index:u16, layer:u16
pub fn encodeHighlightSpans(allocator: std.mem.Allocator, buffer_id: u32, version: u32, spans: []const Span) ![]u8 {
    const header_size = 1 + 4 + 4 + 4; // opcode + buffer_id + version + count
    const span_size = 14; // 4 + 4 + 2 + 2 + 2
    const total = header_size + spans.len * span_size;
    const buf = try allocator.alloc(u8, total);

    buf[0] = OP_HIGHLIGHT_SPANS;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u32, buf[5..9], version, .big);
    std.mem.writeInt(u32, buf[9..13], @intCast(spans.len), .big);

    for (spans, 0..) |span, i| {
        const off = header_size + i * span_size;
        std.mem.writeInt(u32, buf[off..][0..4], span.start_byte, .big);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], span.end_byte, .big);
        std.mem.writeInt(u16, buf[off + 8 ..][0..2], span.capture_id, .big);
        std.mem.writeInt(u16, buf[off + 10 ..][0..2], span.pattern_index, .big);
        std.mem.writeInt(u16, buf[off + 12 ..][0..2], span.layer, .big);
    }

    return buf;
}

/// Encodes highlight_names: opcode(1) + buffer_id(4) + count(2) + (name_len:2 + name) for each
pub fn encodeHighlightNames(allocator: std.mem.Allocator, buffer_id: u32, names: []const []const u8) ![]u8 {
    var total: usize = 1 + 4 + 2; // opcode + buffer_id + count
    for (names) |name| {
        total += 2 + name.len;
    }

    const buf = try allocator.alloc(u8, total);
    buf[0] = OP_HIGHLIGHT_NAMES;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u16, buf[5..7], @intCast(names.len), .big);

    var off: usize = 7;
    for (names) |name| {
        std.mem.writeInt(u16, buf[off..][0..2], @intCast(name.len), .big);
        @memcpy(buf[off + 2 .. off + 2 + name.len], name);
        off += 2 + name.len;
    }

    return buf;
}

/// Encodes grammar_loaded: opcode(1) + success:u8 + name_len:2 + name
pub fn encodeGrammarLoaded(buf: []u8, success: bool, name: []const u8) !usize {
    const total = 4 + name.len;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_GRAMMAR_LOADED;
    buf[1] = if (success) 1 else 0;
    std.mem.writeInt(u16, buf[2..4], @intCast(name.len), .big);
    @memcpy(buf[4 .. 4 + name.len], name);
    return total;
}

/// Encodes log_message: opcode(1) + level:u8 + msg_len:u16 + msg
/// Wire format: `<0x60, level:8, msg_len:16, msg:binary>`
pub fn encodeLogMessage(buf: []u8, level: u8, msg: []const u8) !usize {
    const msg_len = @min(msg.len, std.math.maxInt(u16));
    const total = 4 + msg_len;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_LOG_MESSAGE;
    buf[1] = level;
    std.mem.writeInt(u16, buf[2..4], @intCast(msg_len), .big);
    @memcpy(buf[4 .. 4 + msg_len], msg[0..msg_len]);
    return total;
}

// ── Decoding (BEAM → Zig) ──

/// Decodes a render command from a binary payload.
pub fn decodeCommand(data: []const u8) DecodeError!RenderCommand {
    if (data.len == 0) return error.Malformed;

    const opcode = data[0];
    const rest = data[1..];

    switch (opcode) {
        OP_DRAW_TEXT => {
            // row:2, col:2, fg:3, bg:3, attrs:1, text_len:2 = 13 bytes minimum
            if (rest.len < 13) return error.Malformed;
            const row = std.mem.readInt(u16, rest[0..2], .big);
            const col = std.mem.readInt(u16, rest[2..4], .big);
            const fg = readU24(rest[4..7]);
            const bg = readU24(rest[7..10]);
            const attrs = rest[10];
            const text_len = std.mem.readInt(u16, rest[11..13], .big);
            if (rest.len < 13 + text_len) return error.Malformed;
            const text = rest[13 .. 13 + text_len];
            return .{ .draw_text = .{
                .row = row,
                .col = col,
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
                .text = text,
            } };
        },
        OP_DRAW_STYLED_TEXT => {
            // row:2, col:2, fg:3, bg:3, attrs:2, ul_color:3, blend:1, font_weight:1, font_id:1, text_len:2 = 20 bytes min
            if (rest.len < 20) return error.Malformed;
            const row = std.mem.readInt(u16, rest[0..2], .big);
            const col = std.mem.readInt(u16, rest[2..4], .big);
            const fg = readU24(rest[4..7]);
            const bg = readU24(rest[7..10]);
            const attrs = std.mem.readInt(u16, rest[10..12], .big);
            const ul_color = readU24(rest[12..15]);
            const blend = rest[15];
            const font_weight = rest[16];
            // font_id at rest[17] (ignored by TUI)
            const text_len = std.mem.readInt(u16, rest[18..20], .big);
            if (rest.len < 20 + text_len) return error.Malformed;
            const text = rest[20 .. 20 + text_len];
            return .{ .draw_styled_text = .{
                .row = row,
                .col = col,
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
                .ul_color = ul_color,
                .blend = blend,
                .font_weight = font_weight,
                .text = text,
            } };
        },
        OP_SET_CURSOR => {
            if (rest.len < 4) return error.Malformed;
            const row = std.mem.readInt(u16, rest[0..2], .big);
            const col = std.mem.readInt(u16, rest[2..4], .big);
            return .{ .set_cursor = .{ .row = row, .col = col } };
        },
        OP_CLEAR => return .clear,
        OP_BATCH_END => return .batch_end,
        OP_SET_CURSOR_SHAPE => {
            if (rest.len < 1) return error.Malformed;
            const shape = std.meta.intToEnum(CursorShape, rest[0]) catch return error.Malformed;
            return .{ .set_cursor_shape = shape };
        },
        OP_SET_TITLE => {
            if (rest.len < 2) return error.Malformed;
            const title_len = std.mem.readInt(u16, rest[0..2], .big);
            if (rest.len < 2 + title_len) return error.Malformed;
            return .{ .set_title = rest[2 .. 2 + title_len] };
        },
        OP_SET_WINDOW_BG => {
            // r:1, g:1, b:1 = 3 bytes. Sets the default bg for cells with bg=0.
            if (rest.len < 3) return error.Malformed;
            const rgb: u24 = @as(u24, rest[0]) << 16 | @as(u24, rest[1]) << 8 | @as(u24, rest[2]);
            return .{ .set_default_bg = rgb };
        },
        OP_SET_LANGUAGE => {
            // buffer_id:4, name_len:2, name
            if (rest.len < 6) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const name_len = std.mem.readInt(u16, rest[4..6], .big);
            if (rest.len < 6 + name_len) return error.Malformed;
            return .{ .set_language = .{
                .buffer_id = buffer_id,
                .name = rest[6 .. 6 + name_len],
            } };
        },
        OP_PARSE_BUFFER => {
            // buffer_id:4, version:4, source_len:4, source
            if (rest.len < 12) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const version = std.mem.readInt(u32, rest[4..8], .big);
            const source_len = std.mem.readInt(u32, rest[8..12], .big);
            if (rest.len < 12 + source_len) return error.Malformed;
            return .{ .parse_buffer = .{
                .buffer_id = buffer_id,
                .version = version,
                .source = rest[12 .. 12 + source_len],
            } };
        },
        OP_SET_HIGHLIGHT_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_highlight_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_SET_INJECTION_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_injection_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_SET_FOLD_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_fold_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_SET_INDENT_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_indent_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_REQUEST_INDENT => {
            // buffer_id:4, request_id:4, line:4
            if (rest.len < 12) return error.Malformed;
            return .{ .request_indent = .{
                .buffer_id = std.mem.readInt(u32, rest[0..4], .big),
                .request_id = std.mem.readInt(u32, rest[4..8], .big),
                .line = std.mem.readInt(u32, rest[8..12], .big),
            } };
        },
        OP_SET_TEXTOBJECT_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_textobject_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_REQUEST_TEXTOBJECT => {
            // buffer_id:4, request_id:4, row:4, col:4, name_len:2, name
            if (rest.len < 18) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const name_len = std.mem.readInt(u16, rest[16..18], .big);
            if (rest.len < 18 + name_len) return error.Malformed;
            return .{ .request_textobject = .{
                .buffer_id = buffer_id,
                .request_id = std.mem.readInt(u32, rest[4..8], .big),
                .row = std.mem.readInt(u32, rest[8..12], .big),
                .col = std.mem.readInt(u32, rest[12..16], .big),
                .capture_name = rest[18 .. 18 + name_len],
            } };
        },
        OP_LOAD_GRAMMAR => {
            // name_len:2, name, path_len:2, path
            if (rest.len < 2) return error.Malformed;
            const name_len = std.mem.readInt(u16, rest[0..2], .big);
            if (rest.len < 2 + name_len + 2) return error.Malformed;
            const name = rest[2 .. 2 + name_len];
            const path_off = 2 + name_len;
            const path_len = std.mem.readInt(u16, rest[path_off..][0..2], .big);
            if (rest.len < path_off + 2 + path_len) return error.Malformed;
            return .{ .load_grammar = .{
                .name = name,
                .path = rest[path_off + 2 .. path_off + 2 + path_len],
            } };
        },
        OP_QUERY_LANGUAGE_AT => {
            // buffer_id:4, request_id:4, byte_offset:4
            if (rest.len < 12) return error.Malformed;
            return .{ .query_language_at = .{
                .buffer_id = std.mem.readInt(u32, rest[0..4], .big),
                .request_id = std.mem.readInt(u32, rest[4..8], .big),
                .byte_offset = std.mem.readInt(u32, rest[8..12], .big),
            } };
        },
        OP_EDIT_BUFFER => {
            // Variable-length command. Decoded via decodeEditBuffer() with an allocator.
            // Here we just validate the header and return the buffer_id + version + empty edits.
            if (rest.len < 10) return error.Malformed;
            return .{ .edit_buffer = .{
                .buffer_id = std.mem.readInt(u32, rest[0..4], .big),
                .version = std.mem.readInt(u32, rest[4..8], .big),
                .edits = &.{},
            } };
        },
        OP_CLOSE_BUFFER => {
            // buffer_id:4
            if (rest.len < 4) return error.Malformed;
            return .{ .close_buffer = std.mem.readInt(u32, rest[0..4], .big) };
        },
        OP_MEASURE_TEXT => {
            // request_id:4, text_len:2, text
            if (rest.len < 6) return error.Malformed;
            const request_id = std.mem.readInt(u32, rest[0..4], .big);
            const text_len = std.mem.readInt(u16, rest[4..6], .big);
            if (rest.len < 6 + text_len) return error.Malformed;
            return .{ .measure_text = .{
                .request_id = request_id,
                .text = rest[6 .. 6 + text_len],
            } };
        },
        OP_DEFINE_REGION => {
            // id:2, parent_id:2, role:1, row:2, col:2, width:2, height:2, z_order:1 = 14
            if (rest.len < 14) return error.Malformed;
            return .{ .define_region = .{
                .id = std.mem.readInt(u16, rest[0..2], .big),
                .parent_id = std.mem.readInt(u16, rest[2..4], .big),
                .role = rest[4],
                .row = std.mem.readInt(u16, rest[5..7], .big),
                .col = std.mem.readInt(u16, rest[7..9], .big),
                .width = std.mem.readInt(u16, rest[9..11], .big),
                .height = std.mem.readInt(u16, rest[11..13], .big),
                .z_order = rest[13],
            } };
        },
        OP_CLEAR_REGION => {
            if (rest.len < 2) return error.Malformed;
            return .{ .clear_region = std.mem.readInt(u16, rest[0..2], .big) };
        },
        OP_DESTROY_REGION => {
            if (rest.len < 2) return error.Malformed;
            return .{ .destroy_region = std.mem.readInt(u16, rest[0..2], .big) };
        },
        OP_SET_ACTIVE_REGION => {
            if (rest.len < 2) return error.Malformed;
            return .{ .set_active_region = std.mem.readInt(u16, rest[0..2], .big) };
        },
        OP_SCROLL_REGION => {
            // top_row:2, bottom_row:2, delta:2(signed) = 6 bytes
            if (rest.len < 6) return error.Malformed;
            return .{ .scroll_region = .{
                .top_row = std.mem.readInt(u16, rest[0..2], .big),
                .bottom_row = std.mem.readInt(u16, rest[2..4], .big),
                .delta = std.mem.readInt(i16, rest[4..6], .big),
            } };
        },
        OP_SET_FONT => {
            // size:2, weight:1, ligatures:1, name_len:2 = 6 bytes after opcode
            if (rest.len < 6) return error.Malformed;
            const name_len = std.mem.readInt(u16, rest[4..6], .big);
            if (rest.len < 6 + name_len) return error.Malformed;
            // TUI ignores font config; just return a no-op clear.
            return .clear;
        },
        OP_REGISTER_FONT => {
            // font_id:1, name_len:2, name:bytes
            if (rest.len < 3) return error.Malformed;
            const name_len = std.mem.readInt(u16, rest[1..3], .big);
            if (rest.len < 3 + name_len) return error.Malformed;
            // TUI ignores font registration; return no-op.
            return .clear;
        },
        OP_SET_FONT_FALLBACK => {
            // count:1, then count * (name_len:2, name:bytes)
            if (rest.len < 1) return error.Malformed;
            const count = rest[0];
            var offset: usize = 1;
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                if (rest.len < offset + 2) return error.Malformed;
                const name_len = std.mem.readInt(u16, rest[offset..][0..2], .big);
                offset += 2 + name_len;
                if (rest.len < offset) return error.Malformed;
            }
            // TUI ignores font fallback; just return a no-op clear.
            return .clear;
        },
        else => return error.UnknownOpcode,
    }
}

/// Returns the byte size of the first command in `payload`.
///
/// Used when iterating a batch message containing multiple concatenated
/// commands.  The caller advances its offset by this value after decoding
/// each command.
///
/// Fixed sizes:
///   0x12 clear:            1 byte  (opcode only)
///   0x13 batch_end:        1 byte  (opcode only)
///   0x11 set_cursor:       5 bytes (opcode + row:2 + col:2)
///   0x15 set_cursor_shape: 2 bytes (opcode + shape:1)
///   0x10 draw_text:       14 bytes + text_len
pub fn commandSize(payload: []const u8) usize {
    if (payload.len == 0) return 0;
    return switch (payload[0]) {
        OP_CLEAR => 1,
        OP_BATCH_END => 1,
        OP_SET_CURSOR => 5,
        OP_SET_CURSOR_SHAPE => 2,
        OP_DRAW_TEXT => blk: {
            // opcode(1) + row(2) + col(2) + fg(3) + bg(3) + attrs(1) + text_len(2) = 14 fixed bytes
            if (payload.len < 14) break :blk payload.len;
            const text_len = std.mem.readInt(u16, payload[12..14], .big);
            break :blk 14 + text_len;
        },
        OP_SET_LANGUAGE => blk: {
            // opcode(1) + buffer_id(4) + name_len(2) + name
            if (payload.len < 7) break :blk payload.len;
            const name_len = std.mem.readInt(u16, payload[5..7], .big);
            break :blk 7 + name_len;
        },
        OP_PARSE_BUFFER => blk: {
            // opcode(1) + buffer_id(4) + version(4) + source_len(4) + source
            if (payload.len < 13) break :blk payload.len;
            const source_len = std.mem.readInt(u32, payload[9..13], .big);
            break :blk 13 + source_len;
        },
        OP_SET_HIGHLIGHT_QUERY, OP_SET_INJECTION_QUERY, OP_SET_FOLD_QUERY, OP_SET_INDENT_QUERY, OP_SET_TEXTOBJECT_QUERY => blk: {
            // opcode(1) + buffer_id(4) + query_len(4) + query
            if (payload.len < 9) break :blk payload.len;
            const query_len = std.mem.readInt(u32, payload[5..9], .big);
            break :blk 9 + query_len;
        },
        OP_LOAD_GRAMMAR => blk: {
            if (payload.len < 3) break :blk payload.len;
            const name_len = std.mem.readInt(u16, payload[1..3], .big);
            const path_off: usize = 3 + name_len;
            if (payload.len < path_off + 2) break :blk payload.len;
            const path_len = std.mem.readInt(u16, payload[path_off..][0..2], .big);
            break :blk path_off + 2 + path_len;
        },
        OP_SET_TITLE => blk: {
            if (payload.len < 3) break :blk payload.len;
            const title_len = std.mem.readInt(u16, payload[1..3], .big);
            break :blk 3 + title_len;
        },
        OP_QUERY_LANGUAGE_AT => 13, // opcode(1) + buffer_id(4) + request_id(4) + byte_offset(4)
        OP_REQUEST_INDENT => 13, // opcode(1) + buffer_id(4) + request_id(4) + line(4)
        OP_REQUEST_TEXTOBJECT => blk: {
            // opcode(1) + buffer_id(4) + request_id(4) + row(4) + col(4) + name_len(2) + name
            if (payload.len < 19) break :blk payload.len;
            const nl = std.mem.readInt(u16, payload[17..19], .big);
            break :blk 19 + nl;
        },
        OP_CLOSE_BUFFER => 5, // opcode(1) + buffer_id(4)
        OP_EDIT_BUFFER => blk: {
            // opcode(1) + buffer_id(4) + version(4) + edit_count(2) + variable per edit
            if (payload.len < 11) break :blk payload.len;
            const edit_count = std.mem.readInt(u16, payload[9..11], .big);
            var off: usize = 11;
            for (0..edit_count) |_| {
                // 9 × u32 fields + text_len:u32 = 40 bytes header per edit
                if (off + 40 > payload.len) break :blk payload.len;
                const text_len = std.mem.readInt(u32, payload[off + 36 ..][0..4], .big);
                off += 40 + text_len;
            }
            break :blk off;
        },
        OP_MEASURE_TEXT => blk: {
            if (payload.len < 7) break :blk payload.len;
            const text_len = std.mem.readInt(u16, payload[5..7], .big);
            break :blk 7 + text_len;
        },
        OP_SET_WINDOW_BG => 4, // opcode(1) + r(1) + g(1) + b(1)
        OP_DEFINE_REGION => 15, // opcode(1) + id(2) + parent_id(2) + role(1) + row(2) + col(2) + width(2) + height(2) + z_order(1)
        OP_CLEAR_REGION => 3, // opcode(1) + id(2)
        OP_DESTROY_REGION => 3, // opcode(1) + id(2)
        OP_SET_ACTIVE_REGION => 3, // opcode(1) + id(2)
        OP_SCROLL_REGION => 7, // opcode(1) + top_row(2) + bottom_row(2) + delta(2)
        OP_SET_FONT => blk: {
            // opcode(1) + size(2) + weight(1) + ligatures(1) + name_len(2) + name
            if (payload.len < 7) break :blk payload.len;
            const name_len = std.mem.readInt(u16, payload[5..7], .big);
            break :blk 7 + name_len;
        },
        OP_REGISTER_FONT => blk: {
            // opcode(1) + font_id(1) + name_len(2) + name
            if (payload.len < 4) break :blk payload.len;
            const name_len = std.mem.readInt(u16, payload[2..4], .big);
            break :blk 4 + name_len;
        },
        OP_SET_FONT_FALLBACK => blk: {
            // opcode(1) + count(1), then count * (name_len:2, name:bytes)
            if (payload.len < 2) break :blk payload.len;
            const count = payload[1];
            var offset: usize = 2;
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                if (payload.len < offset + 2) break :blk payload.len;
                const name_len = std.mem.readInt(u16, payload[offset..][0..2], .big);
                offset += 2 + name_len;
            }
            break :blk offset;
        },
        // Unknown opcode: skip 1 byte so the loop always makes progress.
        else => 1,
    };
}

/// Fully decodes an edit_buffer command payload (after the opcode byte).
/// Returns the buffer_id, version, and an allocated slice of EditDelta structs.
/// Caller owns the returned slice and must free it.
pub fn decodeEditBuffer(data: []const u8, alloc: std.mem.Allocator) !struct { buffer_id: u32, version: u32, edits: []EditDelta } {
    if (data.len < 10) return error.Malformed;
    const buffer_id = std.mem.readInt(u32, data[0..4], .big);
    const version = std.mem.readInt(u32, data[4..8], .big);
    const edit_count = std.mem.readInt(u16, data[8..10], .big);

    const edits = try alloc.alloc(EditDelta, edit_count);
    errdefer alloc.free(edits);

    var off: usize = 10;
    for (0..edit_count) |i| {
        if (off + 40 > data.len) return error.Malformed;
        edits[i] = .{
            .start_byte = std.mem.readInt(u32, data[off..][0..4], .big),
            .old_end_byte = std.mem.readInt(u32, data[off + 4 ..][0..4], .big),
            .new_end_byte = std.mem.readInt(u32, data[off + 8 ..][0..4], .big),
            .start_row = std.mem.readInt(u32, data[off + 12 ..][0..4], .big),
            .start_col = std.mem.readInt(u32, data[off + 16 ..][0..4], .big),
            .old_end_row = std.mem.readInt(u32, data[off + 20 ..][0..4], .big),
            .old_end_col = std.mem.readInt(u32, data[off + 24 ..][0..4], .big),
            .new_end_row = std.mem.readInt(u32, data[off + 28 ..][0..4], .big),
            .new_end_col = std.mem.readInt(u32, data[off + 32 ..][0..4], .big),
            .inserted_text = blk: {
                const text_len = std.mem.readInt(u32, data[off + 36 ..][0..4], .big);
                if (off + 40 + text_len > data.len) return error.Malformed;
                break :blk data[off + 40 .. off + 40 + text_len];
            },
        };
        const text_len = std.mem.readInt(u32, data[off + 36 ..][0..4], .big);
        off += 40 + text_len;
    }

    return .{ .buffer_id = buffer_id, .version = version, .edits = edits };
}

/// Encodes a text_width response: opcode(1) + request_id(4) + width(2) = 7 bytes.
pub fn encodeTextWidth(buf: []u8, request_id: u32, width: u16) !usize {
    if (buf.len < 7) return error.Malformed;
    buf[0] = OP_TEXT_WIDTH;
    std.mem.writeInt(u32, buf[1..5], request_id, .big);
    std.mem.writeInt(u16, buf[5..7], width, .big);
    return 7;
}

/// Encodes a language_at_response: opcode(1) + request_id(4) + name_len(2) + name
pub fn encodeLanguageAtResponse(buf: []u8, request_id: u32, language: ?[]const u8) !usize {
    const name = language orelse "";
    const total = 7 + name.len;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_LANGUAGE_AT_RESPONSE;
    std.mem.writeInt(u32, buf[1..5], request_id, .big);
    std.mem.writeInt(u16, buf[5..7], @intCast(name.len), .big);
    if (name.len > 0) {
        @memcpy(buf[7 .. 7 + name.len], name);
    }
    return total;
}

/// Encodes injection_ranges: opcode(1) + count(2) + (start_byte:4, end_byte:4, name_len:2, name) for each
pub fn encodeInjectionRanges(allocator: std.mem.Allocator, buffer_id: u32, ranges: []const InjectionRange) ![]u8 {
    var total: usize = 1 + 4 + 2; // opcode + buffer_id + count
    for (ranges) |r| {
        total += 4 + 4 + 2 + r.language.len;
    }
    const buf = try allocator.alloc(u8, total);
    buf[0] = OP_INJECTION_RANGES;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u16, buf[5..7], @intCast(ranges.len), .big);

    var off: usize = 7;
    for (ranges) |r| {
        std.mem.writeInt(u32, buf[off..][0..4], r.start_byte, .big);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], r.end_byte, .big);
        std.mem.writeInt(u16, buf[off + 8 ..][0..2], @intCast(r.language.len), .big);
        @memcpy(buf[off + 10 .. off + 10 + r.language.len], r.language);
        off += 10 + r.language.len;
    }

    return buf;
}

/// A fold range for protocol encoding: start_line .. end_line (0-indexed).
pub const FoldRange = struct {
    start_line: u32,
    end_line: u32,
};

/// Encodes fold_ranges: opcode(1) + buffer_id(4) + version(4) + count(4) + (start_line:4, end_line:4) for each
pub fn encodeFoldRanges(allocator: std.mem.Allocator, buffer_id: u32, version: u32, ranges: []const FoldRange) ![]u8 {
    const header_size = 1 + 4 + 4 + 4; // opcode + buffer_id + version + count
    const range_size = 8; // start_line:4 + end_line:4
    const total = header_size + ranges.len * range_size;
    const buf = try allocator.alloc(u8, total);

    buf[0] = OP_FOLD_RANGES;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u32, buf[5..9], version, .big);
    std.mem.writeInt(u32, buf[9..13], @intCast(ranges.len), .big);

    for (ranges, 0..) |r, i| {
        const off = header_size + i * range_size;
        std.mem.writeInt(u32, buf[off..][0..4], r.start_line, .big);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], r.end_line, .big);
    }

    return buf;
}

/// Text object result (shared between protocol and highlighter).
pub const TextobjectResult = struct {
    start_row: u32,
    start_col: u32,
    end_row: u32,
    end_col: u32,
};

/// Encodes textobject_result: opcode(1) + request_id(4) + found(1) + start_row(4) + start_col(4) + end_row(4) + end_col(4) = 22 bytes
pub fn encodeTextobjectResult(buf: *[22]u8, request_id: u32, result: ?TextobjectResult) usize {
    buf[0] = OP_TEXTOBJECT_RESULT;
    std.mem.writeInt(u32, buf[1..5], request_id, .big);
    if (result) |r| {
        buf[5] = 1; // found
        std.mem.writeInt(u32, buf[6..10], r.start_row, .big);
        std.mem.writeInt(u32, buf[10..14], r.start_col, .big);
        std.mem.writeInt(u32, buf[14..18], r.end_row, .big);
        std.mem.writeInt(u32, buf[18..22], r.end_col, .big);
        return 22;
    } else {
        buf[5] = 0; // not found
        return 6;
    }
}

/// A single textobject position for the proactive position cache.
pub const TextobjectEntry = struct {
    type_id: u8,
    row: u32,
    col: u32,
};

/// Encodes textobject_positions: opcode(1) + buffer_id(4) + version(4) + count(4) + [type_id(1) + row(4) + col(4)] * count
pub fn encodeTextobjectPositions(allocator: std.mem.Allocator, buffer_id: u32, version: u32, entries: []const TextobjectEntry) ![]u8 {
    const entry_size: usize = 9; // type_id(1) + row(4) + col(4)
    const header_size: usize = 13; // opcode(1) + buffer_id(4) + version(4) + count(4)
    const total_size = header_size + entries.len * entry_size;

    const buf = try allocator.alloc(u8, total_size);
    buf[0] = OP_TEXTOBJECT_POSITIONS;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u32, buf[5..9], version, .big);
    std.mem.writeInt(u32, buf[9..13], @intCast(entries.len), .big);

    var pos: usize = header_size;
    for (entries) |e| {
        buf[pos] = e.type_id;
        std.mem.writeInt(u32, buf[pos + 1 ..][0..4], e.row, .big);
        std.mem.writeInt(u32, buf[pos + 5 ..][0..4], e.col, .big);
        pos += entry_size;
    }

    return buf;
}

/// Encodes indent_result: opcode(1) + request_id(4) + line(4) + indent_level(4, signed)
pub fn encodeIndentResult(buf: *[13]u8, request_id: u32, line: u32, indent_level: i32) usize {
    buf[0] = OP_INDENT_RESULT;
    std.mem.writeInt(u32, buf[1..5], request_id, .big);
    std.mem.writeInt(u32, buf[5..9], line, .big);
    std.mem.writeInt(i32, buf[9..13], indent_level, .big);
    return 13;
}

/// Reads a 4-byte big-endian length header from the reader.
/// Returns the message length, or null on EOF.
pub fn readMessageLength(reader: anytype) !?u32 {
    var len_buf: [4]u8 = undefined;
    const bytes_read = try reader.readAll(&len_buf);
    if (bytes_read == 0) return null;
    if (bytes_read < 4) return error.Malformed;
    return std.mem.readInt(u32, &len_buf, .big);
}

// ── Helpers ──

fn readU24(bytes: *const [3]u8) u24 {
    return (@as(u24, bytes[0]) << 16) | (@as(u24, bytes[1]) << 8) | @as(u24, bytes[2]);
}

// ── Tests ──

test "encode and verify key_press" {
    var buf: [6]u8 = undefined;
    const len = try encodeKeyPress(&buf, 97, 0); // 'a', no mods
    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqual(@as(u8, OP_KEY_PRESS), buf[0]);
    try std.testing.expectEqual(@as(u32, 97), std.mem.readInt(u32, buf[1..5], .big));
    try std.testing.expectEqual(@as(u8, 0), buf[5]);
}

test "encode key_press with modifiers" {
    var buf: [6]u8 = undefined;
    const mods = MOD_CTRL | MOD_SHIFT;
    _ = try encodeKeyPress(&buf, 99, mods); // 'c' + ctrl + shift
    try std.testing.expectEqual(@as(u8, mods), buf[5]);
}

test "encode and verify ready" {
    var buf: [5]u8 = undefined;
    const len = try encodeReady(&buf, 80, 24);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqual(@as(u8, OP_READY), buf[0]);
    try std.testing.expectEqual(@as(u16, 80), std.mem.readInt(u16, buf[1..3], .big));
    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, buf[3..5], .big));
}

test "encode and verify resize" {
    var buf: [5]u8 = undefined;
    _ = try encodeResize(&buf, 120, 40);
    try std.testing.expectEqual(@as(u8, OP_RESIZE), buf[0]);
}

test "decode draw_text command" {
    // Opcode 0x10, row=5, col=10, fg=0xFFFFFF, bg=0x000000, attrs=0, text_len=5, "hello"
    const data = [_]u8{
        0x10,
        0x00, 0x05, // row
        0x00, 0x0A, // col
        0xFF, 0xFF, 0xFF, // fg
        0x00, 0x00, 0x00, // bg
        0x00, // attrs
        0x00, 0x05, // text_len
    } ++ "hello".*;

    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .draw_text => |dt| {
            try std.testing.expectEqual(@as(u16, 5), dt.row);
            try std.testing.expectEqual(@as(u16, 10), dt.col);
            try std.testing.expectEqual(@as(u24, 0xFFFFFF), dt.fg);
            try std.testing.expectEqual(@as(u24, 0x000000), dt.bg);
            try std.testing.expectEqual(@as(u8, 0), dt.attrs);
            try std.testing.expectEqualStrings("hello", dt.text);
        },
        else => return error.Malformed,
    }
}

test "decode set_cursor command" {
    const data = [_]u8{ 0x11, 0x00, 0x0A, 0x00, 0x19 };
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .set_cursor => |sc| {
            try std.testing.expectEqual(@as(u16, 10), sc.row);
            try std.testing.expectEqual(@as(u16, 25), sc.col);
        },
        else => return error.Malformed,
    }
}

test "decode clear command" {
    const data = [_]u8{0x12};
    const cmd = try decodeCommand(&data);
    try std.testing.expect(cmd == .clear);
}

test "decode batch_end command" {
    const data = [_]u8{0x13};
    const cmd = try decodeCommand(&data);
    try std.testing.expect(cmd == .batch_end);
}

test "decode set_window_bg as set_default_bg" {
    const data = [_]u8{ OP_SET_WINDOW_BG, 0x28, 0x2C, 0x34 };
    const cmd = try decodeCommand(&data);
    try std.testing.expect(cmd == .set_default_bg);
    try std.testing.expectEqual(@as(u24, 0x282C34), cmd.set_default_bg);
}

test "decode set_window_bg truncated returns malformed" {
    const data = [_]u8{ OP_SET_WINDOW_BG, 0x28, 0x2C };
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode set_cursor_shape block" {
    const data = [_]u8{ OP_SET_CURSOR_SHAPE, CURSOR_BLOCK };
    const cmd = try decodeCommand(&data);
    try std.testing.expect(cmd == .set_cursor_shape);
    try std.testing.expectEqual(CursorShape.block, cmd.set_cursor_shape);
}

test "decode set_cursor_shape beam" {
    const data = [_]u8{ OP_SET_CURSOR_SHAPE, CURSOR_BEAM };
    const cmd = try decodeCommand(&data);
    try std.testing.expectEqual(CursorShape.beam, cmd.set_cursor_shape);
}

test "decode set_cursor_shape underline" {
    const data = [_]u8{ OP_SET_CURSOR_SHAPE, CURSOR_UNDERLINE };
    const cmd = try decodeCommand(&data);
    try std.testing.expectEqual(CursorShape.underline, cmd.set_cursor_shape);
}

test "decode set_cursor_shape truncated returns malformed" {
    const data = [_]u8{OP_SET_CURSOR_SHAPE}; // missing shape byte
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode set_cursor_shape invalid value returns malformed" {
    const data = [_]u8{ OP_SET_CURSOR_SHAPE, 0xFF }; // invalid shape
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode unknown opcode returns error" {
    const data = [_]u8{0xFF};
    const result = decodeCommand(&data);
    try std.testing.expectError(error.UnknownOpcode, result);
}

test "decode empty data returns malformed" {
    const result = decodeCommand(&[_]u8{});
    try std.testing.expectError(error.Malformed, result);
}

test "decode truncated draw_text returns malformed" {
    const data = [_]u8{ 0x10, 0x00, 0x05 }; // too short
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

// ── Encoding: buffer too small ────────────────────────────────────────────────

// ── Mouse event encoding ──────────────────────────────────────────────────────

test "encodeMouseEvent byte layout: left click press at (5, 10)" {
    var buf: [9]u8 = undefined;
    const len = try encodeMouseEvent(&buf, 5, 10, MOUSE_LEFT, 0, MOUSE_PRESS, 1);
    try std.testing.expectEqual(@as(usize, 9), len);
    try std.testing.expectEqual(OP_MOUSE_EVENT, buf[0]);
    try std.testing.expectEqual(@as(i16, 5), std.mem.readInt(i16, buf[1..3], .big));
    try std.testing.expectEqual(@as(i16, 10), std.mem.readInt(i16, buf[3..5], .big));
    try std.testing.expectEqual(MOUSE_LEFT, buf[5]);
    try std.testing.expectEqual(@as(u8, 0), buf[6]);
    try std.testing.expectEqual(MOUSE_PRESS, buf[7]);
    try std.testing.expectEqual(@as(u8, 1), buf[8]);
}

test "encodeMouseEvent with click_count 2 (double-click)" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, MOUSE_PRESS, 2);
    try std.testing.expectEqual(@as(u8, 2), buf[8]);
}

test "encodeMouseEvent with wheel_up" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_WHEEL_UP, 0, MOUSE_PRESS, 1);
    try std.testing.expectEqual(MOUSE_WHEEL_UP, buf[5]);
}

test "encodeMouseEvent with wheel_down" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_WHEEL_DOWN, 0, MOUSE_PRESS, 1);
    try std.testing.expectEqual(MOUSE_WHEEL_DOWN, buf[5]);
}

test "encodeMouseEvent with drag event type" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 8, 15, MOUSE_LEFT, 0, MOUSE_DRAG, 1);
    try std.testing.expectEqual(MOUSE_DRAG, buf[7]);
}

test "encodeMouseEvent with release event type" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, MOUSE_RELEASE, 1);
    try std.testing.expectEqual(MOUSE_RELEASE, buf[7]);
}

test "encodeMouseEvent with modifiers" {
    var buf: [9]u8 = undefined;
    const mods = MOD_CTRL | MOD_SHIFT;
    _ = try encodeMouseEvent(&buf, 2, 4, MOUSE_LEFT, mods, MOUSE_PRESS, 1);
    try std.testing.expectEqual(mods, buf[6]);
}

test "encodeMouseEvent with negative coordinates" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, -1, -5, MOUSE_LEFT, 0, MOUSE_PRESS, 1);
    try std.testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, buf[1..3], .big));
    try std.testing.expectEqual(@as(i16, -5), std.mem.readInt(i16, buf[3..5], .big));
}

test "encodeMouseEvent buffer too small returns error" {
    var buf: [8]u8 = undefined; // needs 9
    const result = encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, MOUSE_PRESS, 1);
    try std.testing.expectError(error.Malformed, result);
}

test "encodeMouseEvent all button types" {
    var buf: [9]u8 = undefined;
    const buttons = [_]u8{ MOUSE_LEFT, MOUSE_MIDDLE, MOUSE_RIGHT, MOUSE_NONE, MOUSE_WHEEL_UP, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_RIGHT, MOUSE_WHEEL_LEFT };
    for (buttons) |b| {
        _ = try encodeMouseEvent(&buf, 0, 0, b, 0, MOUSE_PRESS, 1);
        try std.testing.expectEqual(b, buf[5]);
    }
}

test "encodeMouseEvent all event types" {
    var buf: [9]u8 = undefined;
    const types = [_]u8{ MOUSE_PRESS, MOUSE_RELEASE, MOUSE_MOTION, MOUSE_DRAG };
    for (types) |t| {
        _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, t, 1);
        try std.testing.expectEqual(t, buf[7]);
    }
}

test "encodeKeyPress buffer too small returns error" {
    var buf: [5]u8 = undefined; // needs 6
    const result = encodeKeyPress(&buf, 65, 0);
    try std.testing.expectError(error.Malformed, result);
}

test "encodeReady buffer too small returns error" {
    var buf: [4]u8 = undefined; // needs 5
    const result = encodeReady(&buf, 80, 24);
    try std.testing.expectError(error.Malformed, result);
}

test "encodeResize buffer too small returns error" {
    var buf: [4]u8 = undefined; // needs 5
    const result = encodeResize(&buf, 80, 24);
    try std.testing.expectError(error.Malformed, result);
}

// ── Encoding: paste event ─────────────────────────────────────────────────────

test "encodePasteEvent basic text" {
    const allocator = std.testing.allocator;
    const text = "hello\nworld\nline 3";
    const buf = try encodePasteEvent(allocator, text);
    defer allocator.free(buf);

    // opcode
    try std.testing.expectEqual(OP_PASTE_EVENT, buf[0]);
    // text_len (big-endian u16)
    const text_len = std.mem.readInt(u16, buf[1..3], .big);
    try std.testing.expectEqual(@as(u16, @intCast(text.len)), text_len);
    // text payload
    try std.testing.expectEqualStrings(text, buf[3..]);
}

test "encodePasteEvent empty text" {
    const allocator = std.testing.allocator;
    const buf = try encodePasteEvent(allocator, "");
    defer allocator.free(buf);

    try std.testing.expectEqual(OP_PASTE_EVENT, buf[0]);
    const text_len = std.mem.readInt(u16, buf[1..3], .big);
    try std.testing.expectEqual(@as(u16, 0), text_len);
    try std.testing.expectEqual(@as(usize, 3), buf.len);
}

test "encodePasteEvent unicode text" {
    const allocator = std.testing.allocator;
    const text = "こんにちは\n🎉 emoji\n中文";
    const buf = try encodePasteEvent(allocator, text);
    defer allocator.free(buf);

    try std.testing.expectEqual(OP_PASTE_EVENT, buf[0]);
    const text_len = std.mem.readInt(u16, buf[1..3], .big);
    try std.testing.expectEqual(@as(u16, @intCast(text.len)), text_len);
    try std.testing.expectEqualStrings(text, buf[3..]);
}

test "encodePasteEvent single line (no newline)" {
    const allocator = std.testing.allocator;
    const text = "just a single line paste";
    const buf = try encodePasteEvent(allocator, text);
    defer allocator.free(buf);

    try std.testing.expectEqual(OP_PASTE_EVENT, buf[0]);
    try std.testing.expectEqualStrings(text, buf[3..]);
}

test "encodePasteEvent large text (near u16 max)" {
    const allocator = std.testing.allocator;
    // Create a text just under the u16 max (65535 bytes)
    const large_text = try allocator.alloc(u8, 60000);
    defer allocator.free(large_text);
    @memset(large_text, 'A');
    // Add some newlines for realism
    large_text[100] = '\n';
    large_text[200] = '\n';
    large_text[300] = '\n';

    const buf = try encodePasteEvent(allocator, large_text);
    defer allocator.free(buf);

    try std.testing.expectEqual(OP_PASTE_EVENT, buf[0]);
    const text_len = std.mem.readInt(u16, buf[1..3], .big);
    try std.testing.expectEqual(@as(u16, 60000), text_len);
    try std.testing.expectEqualSlices(u8, large_text, buf[3..]);
}

// ── Encoding: special values ──────────────────────────────────────────────────

test "encodeKeyPress with max unicode codepoint (0x10FFFF)" {
    var buf: [6]u8 = undefined;
    const len = try encodeKeyPress(&buf, 0x10FFFF, 0);
    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqual(@as(u8, OP_KEY_PRESS), buf[0]);
    try std.testing.expectEqual(@as(u32, 0x10FFFF), std.mem.readInt(u32, buf[1..5], .big));
    try std.testing.expectEqual(@as(u8, 0), buf[5]);
}

test "encodeKeyPress with all modifier flags combined" {
    var buf: [6]u8 = undefined;
    const all_mods = MOD_SHIFT | MOD_CTRL | MOD_ALT | MOD_SUPER;
    const len = try encodeKeyPress(&buf, 65, all_mods);
    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqual(all_mods, buf[5]);
}

test "encodeReady with large terminal dimensions (500x200)" {
    var buf: [5]u8 = undefined;
    const len = try encodeReady(&buf, 500, 200);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqual(@as(u8, OP_READY), buf[0]);
    try std.testing.expectEqual(@as(u16, 500), std.mem.readInt(u16, buf[1..3], .big));
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, buf[3..5], .big));
}

test "encodeResize with minimum dimensions (1x1)" {
    var buf: [5]u8 = undefined;
    const len = try encodeResize(&buf, 1, 1);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqual(@as(u8, OP_RESIZE), buf[0]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[1..3], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[3..5], .big));
}

// ── Decoding: draw_text edge cases ────────────────────────────────────────────

test "decode draw_text with empty text (text_len=0)" {
    const data = [_]u8{
        0x10,
        0x00, 0x01, // row=1
        0x00, 0x02, // col=2
        0x00, 0x00, 0x00, // fg=0
        0x00, 0x00, 0x00, // bg=0
        0x00, // attrs
        0x00, 0x00, // text_len=0
    };
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .draw_text => |dt| {
            try std.testing.expectEqual(@as(u16, 1), dt.row);
            try std.testing.expectEqual(@as(u16, 2), dt.col);
            try std.testing.expectEqual(@as(usize, 0), dt.text.len);
        },
        else => return error.WrongVariant,
    }
}

test "decode draw_text with all style attributes (bold+italic+underline+reverse)" {
    const all_attrs = ATTR_BOLD | ATTR_ITALIC | ATTR_UNDERLINE | ATTR_REVERSE;
    const data = [_]u8{
        0x10,
        0x00, 0x00, // row=0
        0x00, 0x00, // col=0
        0x00, 0x00, 0x00, // fg=0
        0x00, 0x00, 0x00, // bg=0
        all_attrs, // attrs
        0x00, 0x00, // text_len=0
    };
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .draw_text => |dt| {
            try std.testing.expectEqual(all_attrs, dt.attrs);
        },
        else => return error.WrongVariant,
    }
}

test "decode draw_text with max colors (0xFFFFFF fg and bg)" {
    const data = [_]u8{
        0x10,
        0x00, 0x00, // row=0
        0x00, 0x00, // col=0
        0xFF, 0xFF, 0xFF, // fg=0xFFFFFF
        0xFF, 0xFF, 0xFF, // bg=0xFFFFFF
        0x00, // attrs
        0x00, 0x00, // text_len=0
    };
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .draw_text => |dt| {
            try std.testing.expectEqual(@as(u24, 0xFFFFFF), dt.fg);
            try std.testing.expectEqual(@as(u24, 0xFFFFFF), dt.bg);
        },
        else => return error.WrongVariant,
    }
}

test "decode draw_text where text_len exceeds remaining data returns malformed" {
    const data = [_]u8{
        0x10,
        0x00, 0x00, // row
        0x00, 0x00, // col
        0x00, 0x00, 0x00, // fg
        0x00, 0x00, 0x00, // bg
        0x00, // attrs
        0x00, 0x0A, // text_len=10, but no text bytes follow
    };
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

// ── Decoding: set_cursor edge cases ───────────────────────────────────────────

test "decode set_cursor with row=0 col=0" {
    const data = [_]u8{ 0x11, 0x00, 0x00, 0x00, 0x00 };
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .set_cursor => |sc| {
            try std.testing.expectEqual(@as(u16, 0), sc.row);
            try std.testing.expectEqual(@as(u16, 0), sc.col);
        },
        else => return error.WrongVariant,
    }
}

test "decode set_cursor with large values (1000, 2000)" {
    var data: [5]u8 = undefined;
    data[0] = OP_SET_CURSOR;
    std.mem.writeInt(u16, data[1..3], 1000, .big);
    std.mem.writeInt(u16, data[3..5], 2000, .big);
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .set_cursor => |sc| {
            try std.testing.expectEqual(@as(u16, 1000), sc.row);
            try std.testing.expectEqual(@as(u16, 2000), sc.col);
        },
        else => return error.WrongVariant,
    }
}

test "decode set_cursor truncated (only 3 bytes after opcode) returns malformed" {
    const data = [_]u8{ 0x11, 0x00, 0x05, 0x00 }; // 4 bytes total: opcode + 3
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

// ── writeMessage ──────────────────────────────────────────────────────────────

test "writeMessage writes correct 4-byte big-endian length prefix" {
    var out: [12]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);
    try writeMessage(fbs.writer(), "hello");
    const written = fbs.getWritten();
    // First 4 bytes: length = 5
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, written[0..4], .big));
    // Payload follows
    try std.testing.expectEqualSlices(u8, "hello", written[4..9]);
}

test "writeMessage with empty payload writes length 0" {
    var out: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);
    try writeMessage(fbs.writer(), "");
    const written = fbs.getWritten();
    try std.testing.expectEqual(@as(usize, 4), written.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, written[0..4], .big));
}

// ── readMessageLength ─────────────────────────────────────────────────────────

test "readMessageLength returns correct value for known bytes" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x2A }; // big-endian 42
    var fbs = std.io.fixedBufferStream(&data);
    const result = try readMessageLength(fbs.reader());
    try std.testing.expectEqual(@as(?u32, 42), result);
}

test "readMessageLength returns null on EOF (empty reader)" {
    const data = [_]u8{};
    var fbs = std.io.fixedBufferStream(&data);
    const result = try readMessageLength(fbs.reader());
    try std.testing.expectEqual(@as(?u32, null), result);
}

// ── Round-trip / byte-position verification ───────────────────────────────────

test "encodeKeyPress byte layout: each position verified" {
    var buf: [6]u8 = undefined;
    _ = try encodeKeyPress(&buf, 0x0001F600, MOD_CTRL | MOD_ALT); // 😀, ctrl+alt
    // [0] opcode
    try std.testing.expectEqual(OP_KEY_PRESS, buf[0]);
    // [1..4] codepoint big-endian
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[2]);
    try std.testing.expectEqual(@as(u8, 0xF6), buf[3]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[4]);
    // [5] modifiers
    try std.testing.expectEqual(MOD_CTRL | MOD_ALT, buf[5]);
}

// ── commandSize ──────────────────────────────────────────────────────────────

test "commandSize: clear is 1 byte" {
    const data = [_]u8{OP_CLEAR};
    try std.testing.expectEqual(@as(usize, 1), commandSize(&data));
}

test "commandSize: batch_end is 1 byte" {
    const data = [_]u8{OP_BATCH_END};
    try std.testing.expectEqual(@as(usize, 1), commandSize(&data));
}

test "commandSize: set_cursor is 5 bytes" {
    const data = [_]u8{ OP_SET_CURSOR, 0x00, 0x01, 0x00, 0x02 };
    try std.testing.expectEqual(@as(usize, 5), commandSize(&data));
}

test "commandSize: set_cursor_shape is 2 bytes" {
    const data = [_]u8{ OP_SET_CURSOR_SHAPE, CURSOR_BLOCK };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: draw_text with 5-byte text is 19 bytes" {
    // 14 fixed + 5 text = 19
    const data = [_]u8{
        OP_DRAW_TEXT,
        0x00, 0x00, // row
        0x00, 0x00, // col
        0xFF, 0xFF, 0xFF, // fg
        0x00, 0x00, 0x00, // bg
        0x00, // attrs
        0x00, 0x05, // text_len = 5
    } ++ "hello".*;
    try std.testing.expectEqual(@as(usize, 19), commandSize(&data));
}

test "commandSize: draw_text with 0-byte text is 14 bytes" {
    const data = [_]u8{
        OP_DRAW_TEXT,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00, 0x00, // text_len = 0
    };
    try std.testing.expectEqual(@as(usize, 14), commandSize(&data));
}

test "commandSize: truncated draw_text returns remaining length" {
    // Only 3 bytes — malformed, returns what's left
    const data = [_]u8{ OP_DRAW_TEXT, 0x00, 0x01 };
    try std.testing.expectEqual(@as(usize, 3), commandSize(&data));
}

test "commandSize: unknown opcode returns 1" {
    const data = [_]u8{0xFE};
    try std.testing.expectEqual(@as(usize, 1), commandSize(&data));
}

test "commandSize: empty payload returns 0" {
    try std.testing.expectEqual(@as(usize, 0), commandSize(&[_]u8{}));
}

test "batch decode: clear + set_cursor + batch_end parsed correctly" {
    // Concatenated batch: clear(1) + set_cursor(5) + batch_end(1) = 7 bytes
    const payload = [_]u8{
        OP_CLEAR,
        OP_SET_CURSOR,
        0x00,
        0x05,
        0x00,
        0x0A,
        OP_BATCH_END,
    };

    var offset: usize = 0;
    var cmds: [3]RenderCommand = undefined;
    var count: usize = 0;

    while (offset < payload.len) {
        const remaining = payload[offset..];
        cmds[count] = try decodeCommand(remaining);
        count += 1;
        offset += commandSize(remaining);
    }

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(cmds[0] == .clear);
    try std.testing.expect(cmds[1] == .set_cursor);
    try std.testing.expectEqual(@as(u16, 5), cmds[1].set_cursor.row);
    try std.testing.expectEqual(@as(u16, 10), cmds[1].set_cursor.col);
    try std.testing.expect(cmds[2] == .batch_end);
}

test "batch decode: draw_text (variable length) in the middle" {
    // clear(1) + draw_text(19) + batch_end(1) = 21 bytes
    const payload = [_]u8{OP_CLEAR} ++ [_]u8{
        OP_DRAW_TEXT,
        0x00, 0x01, // row=1
        0x00, 0x02, // col=2
        0xFF, 0xFF, 0xFF, // fg
        0x00, 0x00, 0x00, // bg
        0x00, // attrs
        0x00, 0x05, // text_len=5
    } ++ "hello".* ++ [_]u8{OP_BATCH_END};

    var offset: usize = 0;
    var cmds: [3]RenderCommand = undefined;
    var count: usize = 0;

    while (offset < payload.len) {
        const remaining = payload[offset..];
        cmds[count] = try decodeCommand(remaining);
        count += 1;
        offset += commandSize(remaining);
    }

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(cmds[0] == .clear);
    switch (cmds[1]) {
        .draw_text => |dt| {
            try std.testing.expectEqual(@as(u16, 1), dt.row);
            try std.testing.expectEqualStrings("hello", dt.text);
        },
        else => return error.WrongVariant,
    }
    try std.testing.expect(cmds[2] == .batch_end);
}

test "encodeResize byte layout: self-consistent encoding" {
    var buf: [5]u8 = undefined;
    _ = try encodeResize(&buf, 0x0102, 0x0304);
    try std.testing.expectEqual(OP_RESIZE, buf[0]);
    // width = 0x0102 → [0x01, 0x02]
    try std.testing.expectEqual(@as(u8, 0x01), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x02), buf[2]);
    // height = 0x0304 → [0x03, 0x04]
    try std.testing.expectEqual(@as(u8, 0x03), buf[3]);
    try std.testing.expectEqual(@as(u8, 0x04), buf[4]);
    // Decode back the width and height directly from the bytes
    const width_back = std.mem.readInt(u16, buf[1..3], .big);
    const height_back = std.mem.readInt(u16, buf[3..5], .big);
    try std.testing.expectEqual(@as(u16, 0x0102), width_back);
    try std.testing.expectEqual(@as(u16, 0x0304), height_back);
}

// ── Highlight protocol tests ──────────────────────────────────────────────────

test "decode set_language" {
    // opcode(1) + buffer_id:4 + name_len:2 + "elixir"(6) = 13 bytes
    var data: [13]u8 = undefined;
    data[0] = OP_SET_LANGUAGE;
    std.mem.writeInt(u32, data[1..5], 7, .big); // buffer_id = 7
    std.mem.writeInt(u16, data[5..7], 6, .big); // name_len = 6
    @memcpy(data[7..13], "elixir");
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .set_language => |sl| {
            try std.testing.expectEqual(@as(u32, 7), sl.buffer_id);
            try std.testing.expectEqualStrings("elixir", sl.name);
        },
        else => return error.Malformed,
    }
}

test "decode set_language truncated returns malformed" {
    // opcode(1) + buffer_id:4 + name_len:2 + only 2 of 6 name bytes
    const data = [_]u8{ OP_SET_LANGUAGE, 0x00, 0x00, 0x00, 0x01, 0x00, 0x06, 'e', 'l' };
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode parse_buffer" {
    // opcode(1) + buffer_id:4 + version:4 + source_len:4 + "hello"(5) = 18 bytes
    var data: [18]u8 = undefined;
    data[0] = OP_PARSE_BUFFER;
    std.mem.writeInt(u32, data[1..5], 3, .big); // buffer_id = 3
    std.mem.writeInt(u32, data[5..9], 1, .big); // version = 1
    std.mem.writeInt(u32, data[9..13], 5, .big); // source_len = 5
    @memcpy(data[13..18], "hello");
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .parse_buffer => |pb| {
            try std.testing.expectEqual(@as(u32, 3), pb.buffer_id);
            try std.testing.expectEqual(@as(u32, 1), pb.version);
            try std.testing.expectEqualStrings("hello", pb.source);
        },
        else => return error.Malformed,
    }
}

test "decode set_highlight_query" {
    const query = "(atom) @string";
    // opcode(1) + buffer_id(4) + query_len(4) + query
    var data: [1 + 4 + 4 + query.len]u8 = undefined;
    data[0] = OP_SET_HIGHLIGHT_QUERY;
    std.mem.writeInt(u32, data[1..5], 0, .big); // buffer_id = 0
    std.mem.writeInt(u32, data[5..9], query.len, .big);
    @memcpy(data[9..], query);
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .set_highlight_query => |shq| {
            try std.testing.expectEqualStrings(query, shq.source);
        },
        else => return error.Malformed,
    }
}

test "decode load_grammar" {
    // opcode + name_len:2 + "lua"(3) + path_len:2 + "/tmp/lua.so"(11)
    const data = [_]u8{ OP_LOAD_GRAMMAR, 0x00, 0x03 } ++ "lua".* ++ [_]u8{ 0x00, 0x0B } ++ "/tmp/lua.so".*;
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .load_grammar => |lg| {
            try std.testing.expectEqualStrings("lua", lg.name);
            try std.testing.expectEqualStrings("/tmp/lua.so", lg.path);
        },
        else => return error.Malformed,
    }
}

test "commandSize: set_language" {
    // opcode(1) + buffer_id(4) + name_len(2) + "elixir"(6) = 13 bytes
    var data: [13]u8 = undefined;
    data[0] = OP_SET_LANGUAGE;
    std.mem.writeInt(u32, data[1..5], 0, .big);
    std.mem.writeInt(u16, data[5..7], 6, .big);
    @memcpy(data[7..13], "elixir");
    try std.testing.expectEqual(@as(usize, 13), commandSize(&data));
}

test "commandSize: parse_buffer" {
    // opcode(1) + buffer_id(4) + version(4) + source_len(4) + "abc"(3) = 16 bytes
    var data: [16]u8 = undefined;
    data[0] = OP_PARSE_BUFFER;
    std.mem.writeInt(u32, data[1..5], 0, .big); // buffer_id
    std.mem.writeInt(u32, data[5..9], 1, .big); // version
    std.mem.writeInt(u32, data[9..13], 3, .big); // source_len
    @memcpy(data[13..16], "abc");
    try std.testing.expectEqual(@as(usize, 16), commandSize(&data));
}

test "commandSize: set_highlight_query" {
    // opcode(1) + buffer_id(4) + query_len(4) + "query"(5) = 14 bytes
    var data: [1 + 4 + 4 + 5]u8 = undefined;
    data[0] = OP_SET_HIGHLIGHT_QUERY;
    std.mem.writeInt(u32, data[1..5], 0, .big); // buffer_id
    std.mem.writeInt(u32, data[5..9], 5, .big); // query_len
    @memcpy(data[9..14], "query");
    try std.testing.expectEqual(@as(usize, 14), commandSize(&data));
}

test "decode set_injection_query" {
    const query = "(content) @injection.content";
    // opcode(1) + buffer_id(4) + query_len(4) + query
    var data: [1 + 4 + 4 + query.len]u8 = undefined;
    data[0] = OP_SET_INJECTION_QUERY;
    std.mem.writeInt(u32, data[1..5], 2, .big); // buffer_id = 2
    std.mem.writeInt(u32, data[5..9], query.len, .big);
    @memcpy(data[9..], query);
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .set_injection_query => |siq| {
            try std.testing.expectEqual(@as(u32, 2), siq.buffer_id);
            try std.testing.expectEqualStrings(query, siq.source);
        },
        else => return error.Malformed,
    }
}

test "commandSize: set_injection_query" {
    // opcode(1) + buffer_id(4) + query_len(4) + "query"(5) = 14 bytes
    var data: [1 + 4 + 4 + 5]u8 = undefined;
    data[0] = OP_SET_INJECTION_QUERY;
    std.mem.writeInt(u32, data[1..5], 0, .big);
    std.mem.writeInt(u32, data[5..9], 5, .big);
    @memcpy(data[9..14], "query");
    try std.testing.expectEqual(@as(usize, 14), commandSize(&data));
}

test "decode close_buffer" {
    var data: [5]u8 = undefined;
    data[0] = OP_CLOSE_BUFFER;
    std.mem.writeInt(u32, data[1..5], 42, .big);
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .close_buffer => |buffer_id| {
            try std.testing.expectEqual(@as(u32, 42), buffer_id);
        },
        else => return error.Malformed,
    }
}

test "commandSize: close_buffer" {
    var data: [5]u8 = undefined;
    data[0] = OP_CLOSE_BUFFER;
    std.mem.writeInt(u32, data[1..5], 0, .big);
    try std.testing.expectEqual(@as(usize, 5), commandSize(&data));
}

test "commandSize: load_grammar" {
    const data = [_]u8{ OP_LOAD_GRAMMAR, 0x00, 0x03 } ++ "lua".* ++ [_]u8{ 0x00, 0x04 } ++ "path".*;
    try std.testing.expectEqual(@as(usize, 12), commandSize(&data));
}

test "encodeHighlightSpans round-trip" {
    const spans = [_]Span{
        .{ .start_byte = 0, .end_byte = 9, .capture_id = 0, .pattern_index = 5, .layer = 0 },
        .{ .start_byte = 10, .end_byte = 15, .capture_id = 1, .pattern_index = 3, .layer = 1 },
    };
    const buf = try encodeHighlightSpans(std.testing.allocator, 5, 42, &spans);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqual(OP_HIGHLIGHT_SPANS, buf[0]);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, buf[1..5], .big)); // buffer_id
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[5..9], .big)); // version
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[9..13], .big)); // count
    // First span (14 bytes each)
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[13..17], .big)); // start
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, buf[17..21], .big)); // end
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[21..23], .big)); // capture_id
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, buf[23..25], .big)); // pattern_index
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[25..27], .big)); // layer
    // Second span
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, buf[27..31], .big)); // start
    try std.testing.expectEqual(@as(u32, 15), std.mem.readInt(u32, buf[31..35], .big)); // end
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[35..37], .big)); // capture_id
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, buf[37..39], .big)); // pattern_index
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[39..41], .big)); // layer
}

test "encodeHighlightNames round-trip" {
    const names = [_][]const u8{ "keyword", "string" };
    const buf = try encodeHighlightNames(std.testing.allocator, 3, &names);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqual(OP_HIGHLIGHT_NAMES, buf[0]);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buf[1..5], .big)); // buffer_id
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[5..7], .big)); // count
    // "keyword" (7)
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, buf[7..9], .big));
    try std.testing.expectEqualStrings("keyword", buf[9..16]);
    // "string" (6)
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, buf[16..18], .big));
    try std.testing.expectEqualStrings("string", buf[18..24]);
}

test "encodeGrammarLoaded" {
    var buf: [20]u8 = undefined;
    const len = try encodeGrammarLoaded(&buf, true, "elixir");
    try std.testing.expectEqual(@as(usize, 10), len);
    try std.testing.expectEqual(OP_GRAMMAR_LOADED, buf[0]);
    try std.testing.expectEqual(@as(u8, 1), buf[1]);
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, buf[2..4], .big));
    try std.testing.expectEqualStrings("elixir", buf[4..10]);
}

// ── Log message protocol tests ────────────────────────────────────────────────

test "encodeLogMessage byte layout" {
    var buf: [20]u8 = undefined;
    const len = try encodeLogMessage(&buf, LOG_LEVEL_WARN, "test msg");
    try std.testing.expectEqual(@as(usize, 12), len); // 4 header + 8 msg
    try std.testing.expectEqual(OP_LOG_MESSAGE, buf[0]);
    try std.testing.expectEqual(LOG_LEVEL_WARN, buf[1]);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, buf[2..4], .big));
    try std.testing.expectEqualStrings("test msg", buf[4..12]);
}

test "encodeLogMessage all levels" {
    var buf: [10]u8 = undefined;
    const levels = [_]u8{ LOG_LEVEL_ERR, LOG_LEVEL_WARN, LOG_LEVEL_INFO, LOG_LEVEL_DEBUG };
    for (levels) |lvl| {
        _ = try encodeLogMessage(&buf, lvl, "hi");
        try std.testing.expectEqual(lvl, buf[1]);
    }
}

test "encodeLogMessage empty message" {
    var buf: [4]u8 = undefined;
    const len = try encodeLogMessage(&buf, LOG_LEVEL_INFO, "");
    try std.testing.expectEqual(@as(usize, 4), len);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[2..4], .big));
}

test "encodeLogMessage buffer too small returns error" {
    var buf: [3]u8 = undefined; // needs at least 4
    const result = encodeLogMessage(&buf, LOG_LEVEL_ERR, "");
    try std.testing.expectError(error.Malformed, result);
}

// ── Scroll region protocol tests ──────────────────────────────────────────────

test "decode scroll_region with positive delta (scroll up)" {
    var data: [7]u8 = undefined;
    data[0] = OP_SCROLL_REGION;
    std.mem.writeInt(u16, data[1..3], 2, .big); // top_row
    std.mem.writeInt(u16, data[3..5], 20, .big); // bottom_row
    std.mem.writeInt(i16, data[5..7], 1, .big); // delta
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .scroll_region => |sr| {
            try std.testing.expectEqual(@as(u16, 2), sr.top_row);
            try std.testing.expectEqual(@as(u16, 20), sr.bottom_row);
            try std.testing.expectEqual(@as(i16, 1), sr.delta);
        },
        else => return error.WrongVariant,
    }
}

test "decode scroll_region with negative delta (scroll down)" {
    var data: [7]u8 = undefined;
    data[0] = OP_SCROLL_REGION;
    std.mem.writeInt(u16, data[1..3], 0, .big);
    std.mem.writeInt(u16, data[3..5], 30, .big);
    std.mem.writeInt(i16, data[5..7], -3, .big);
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .scroll_region => |sr| {
            try std.testing.expectEqual(@as(u16, 0), sr.top_row);
            try std.testing.expectEqual(@as(u16, 30), sr.bottom_row);
            try std.testing.expectEqual(@as(i16, -3), sr.delta);
        },
        else => return error.WrongVariant,
    }
}

test "decode scroll_region truncated returns malformed" {
    const data = [_]u8{ OP_SCROLL_REGION, 0x00, 0x02, 0x00 }; // only 4 bytes, need 7
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "commandSize: scroll_region is 7 bytes" {
    var data: [7]u8 = undefined;
    data[0] = OP_SCROLL_REGION;
    std.mem.writeInt(u16, data[1..3], 0, .big);
    std.mem.writeInt(u16, data[3..5], 20, .big);
    std.mem.writeInt(i16, data[5..7], 1, .big);
    try std.testing.expectEqual(@as(usize, 7), commandSize(&data));
}

test "batch decode: scroll_region + draw_text + batch_end" {
    var payload: [7 + 19 + 1]u8 = undefined;
    // scroll_region: top=1, bottom=20, delta=1
    payload[0] = OP_SCROLL_REGION;
    std.mem.writeInt(u16, payload[1..3], 1, .big);
    std.mem.writeInt(u16, payload[3..5], 20, .big);
    std.mem.writeInt(i16, payload[5..7], 1, .big);
    // draw_text: row=20, col=0, "hello"
    payload[7] = OP_DRAW_TEXT;
    std.mem.writeInt(u16, payload[8..10], 20, .big); // row
    std.mem.writeInt(u16, payload[10..12], 0, .big); // col
    payload[12] = 0xFF;
    payload[13] = 0xFF;
    payload[14] = 0xFF; // fg
    payload[15] = 0x00;
    payload[16] = 0x00;
    payload[17] = 0x00; // bg
    payload[18] = 0x00; // attrs
    std.mem.writeInt(u16, payload[19..21], 5, .big); // text_len
    @memcpy(payload[21..26], "hello");
    // batch_end
    payload[26] = OP_BATCH_END;

    var offset: usize = 0;
    var cmds: [3]RenderCommand = undefined;
    var count: usize = 0;
    while (offset < payload.len) {
        const remaining = payload[offset..];
        cmds[count] = try decodeCommand(remaining);
        count += 1;
        offset += commandSize(remaining);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(cmds[0] == .scroll_region);
    try std.testing.expect(cmds[1] == .draw_text);
    try std.testing.expect(cmds[2] == .batch_end);
}

// ── draw_styled_text (0x1C) tests ────────────────────────────────────────────

test "decode draw_styled_text command" {
    // Opcode 0x1C, row=3, col=7, fg=0xFF6C6B, bg=0x282C34,
    // attrs=0x0015 (bold | strikethrough), ul_color=0xFF0000, blend=50,
    // font_weight=5 (bold), text_len=5, "error"
    const data = [_]u8{
        0x1C,
        0x00, 0x03, // row
        0x00, 0x07, // col
        0xFF, 0x6C, 0x6B, // fg
        0x28, 0x2C, 0x34, // bg
        0x00, 0x11, // attrs: bold(0x01) | strikethrough(0x10)
        0xFF, 0x00, 0x00, // ul_color: red
        0x32, // blend: 50
        0x05, // font_weight: bold
        0x00, // font_id: primary
        0x00, 0x05, // text_len
    } ++ "error".*;

    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .draw_styled_text => |dt| {
            try std.testing.expectEqual(@as(u16, 3), dt.row);
            try std.testing.expectEqual(@as(u16, 7), dt.col);
            try std.testing.expectEqual(@as(u24, 0xFF6C6B), dt.fg);
            try std.testing.expectEqual(@as(u24, 0x282C34), dt.bg);
            try std.testing.expectEqual(@as(u16, 0x0011), dt.attrs);
            try std.testing.expectEqual(@as(u24, 0xFF0000), dt.ul_color);
            try std.testing.expectEqual(@as(u8, 50), dt.blend);
            try std.testing.expectEqual(@as(u8, 5), dt.font_weight);
            try std.testing.expectEqualStrings("error", dt.text);
        },
        else => return error.Malformed,
    }
}

test "decode draw_styled_text with underline style curl" {
    // attrs: underline(0x02) | curl style (1 << 5 = 0x20) = 0x0022
    const data = [_]u8{
        0x1C,
        0x00, 0x00, // row
        0x00, 0x00, // col
        0xFF, 0xFF, 0xFF, // fg
        0x00, 0x00, 0x00, // bg
        0x00, 0x22, // attrs: underline | curl
        0xFF, 0x00, 0x00, // ul_color: red
        0x64, // blend: 100
        0x02, // font_weight: regular
        0x00, // font_id: primary
        0x00, 0x03, // text_len
    } ++ "abc".*;

    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .draw_styled_text => |dt| {
            try std.testing.expectEqual(@as(u16, 0x0022), dt.attrs);
            // Verify underline style bits: (attrs >> 5) & 0x07 == 1 (curl)
            try std.testing.expectEqual(@as(u16, 1), (dt.attrs >> 5) & 0x07);
        },
        else => return error.Malformed,
    }
}

test "decode draw_styled_text truncated returns malformed" {
    const data = [_]u8{ 0x1C, 0x00, 0x03 }; // too short
    try std.testing.expectError(error.Malformed, decodeCommand(&data));
}
