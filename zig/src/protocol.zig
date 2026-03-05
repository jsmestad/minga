/// Port protocol encoder/decoder for BEAM ↔ Zig communication.
///
/// Messages use a simple binary format with 1-byte opcodes:
///
/// Input events (Zig → BEAM):
///   0x01 key_press:    codepoint:u32, modifiers:u8
///   0x02 resize:       width:u16, height:u16
///   0x03 ready:        width:u16, height:u16
///   0x04 mouse_event:  row:i16, col:i16, button:u8, modifiers:u8, event_type:u8
///
/// Render commands (BEAM → Zig):
///   0x10 draw_text:  row:u16, col:u16, fg:u24, bg:u24, attrs:u8, text_len:u16, text
///   0x11 set_cursor: row:u16, col:u16
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
pub const OP_DRAW_TEXT: u8 = 0x10;
pub const OP_SET_CURSOR: u8 = 0x11;
pub const OP_CLEAR: u8 = 0x12;
pub const OP_BATCH_END: u8 = 0x13;
pub const OP_SET_CURSOR_SHAPE: u8 = 0x15;
pub const OP_SET_TITLE: u8 = 0x16;

// Highlight commands (BEAM → Zig)
pub const OP_SET_LANGUAGE: u8 = 0x20;
pub const OP_PARSE_BUFFER: u8 = 0x21;
pub const OP_SET_HIGHLIGHT_QUERY: u8 = 0x22;
pub const OP_LOAD_GRAMMAR: u8 = 0x23;

// Highlight responses (Zig → BEAM)
pub const OP_HIGHLIGHT_SPANS: u8 = 0x30;
pub const OP_HIGHLIGHT_NAMES: u8 = 0x31;
pub const OP_GRAMMAR_LOADED: u8 = 0x32;

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

// ── Attribute flags ──

pub const ATTR_BOLD: u8 = 0x01;
pub const ATTR_UNDERLINE: u8 = 0x02;
pub const ATTR_ITALIC: u8 = 0x04;
pub const ATTR_REVERSE: u8 = 0x08;

// ── Decoded types ──

pub const CursorShape = enum(u8) {
    block = CURSOR_BLOCK,
    beam = CURSOR_BEAM,
    underline = CURSOR_UNDERLINE,
};

pub const RenderCommand = union(enum) {
    draw_text: DrawText,
    set_cursor: SetCursor,
    set_cursor_shape: CursorShape,
    set_title: []const u8,
    clear: void,
    batch_end: void,
    // Highlight commands
    set_language: []const u8,
    parse_buffer: ParseBuffer,
    set_highlight_query: []const u8,
    load_grammar: LoadGrammar,
};

pub const ParseBuffer = struct {
    version: u32,
    source: []const u8,
};

pub const LoadGrammar = struct {
    name: []const u8,
    path: []const u8,
};

pub const DrawText = struct {
    row: u16,
    col: u16,
    fg: u24,
    bg: u24,
    attrs: u8,
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
/// Returns the number of bytes written (always 5).
pub fn encodeReady(buf: []u8, width: u16, height: u16) !usize {
    if (buf.len < 5) return error.Malformed;
    buf[0] = OP_READY;
    std.mem.writeInt(u16, buf[1..3], width, .big);
    std.mem.writeInt(u16, buf[3..5], height, .big);
    return 5;
}

/// Encodes a mouse event into the provided buffer.
/// Returns the number of bytes written (always 8).
pub fn encodeMouseEvent(buf: []u8, row: i16, col: i16, button: u8, modifiers: u8, event_type: u8) !usize {
    if (buf.len < 8) return error.Malformed;
    buf[0] = OP_MOUSE_EVENT;
    std.mem.writeInt(i16, buf[1..3], row, .big);
    std.mem.writeInt(i16, buf[3..5], col, .big);
    buf[5] = button;
    buf[6] = modifiers;
    buf[7] = event_type;
    return 8;
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

/// Encodes highlight_spans: opcode(1) + version(4) + count(4) + spans(count * 10)
/// Each span: start_byte:u32, end_byte:u32, capture_id:u16
pub fn encodeHighlightSpans(allocator: std.mem.Allocator, version: u32, spans: []const @import("highlighter.zig").Span) ![]u8 {
    const header_size = 1 + 4 + 4; // opcode + version + count
    const span_size = 10; // 4 + 4 + 2
    const total = header_size + spans.len * span_size;
    const buf = try allocator.alloc(u8, total);

    buf[0] = OP_HIGHLIGHT_SPANS;
    std.mem.writeInt(u32, buf[1..5], version, .big);
    std.mem.writeInt(u32, buf[5..9], @intCast(spans.len), .big);

    for (spans, 0..) |span, i| {
        const off = header_size + i * span_size;
        std.mem.writeInt(u32, buf[off..][0..4], span.start_byte, .big);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], span.end_byte, .big);
        std.mem.writeInt(u16, buf[off + 8 ..][0..2], span.capture_id, .big);
    }

    return buf;
}

/// Encodes highlight_names: opcode(1) + count(2) + (name_len:2 + name) for each
pub fn encodeHighlightNames(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var total: usize = 1 + 2; // opcode + count
    for (names) |name| {
        total += 2 + name.len;
    }

    const buf = try allocator.alloc(u8, total);
    buf[0] = OP_HIGHLIGHT_NAMES;
    std.mem.writeInt(u16, buf[1..3], @intCast(names.len), .big);

    var off: usize = 3;
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
        OP_SET_LANGUAGE => {
            // name_len:2, name
            if (rest.len < 2) return error.Malformed;
            const name_len = std.mem.readInt(u16, rest[0..2], .big);
            if (rest.len < 2 + name_len) return error.Malformed;
            return .{ .set_language = rest[2 .. 2 + name_len] };
        },
        OP_PARSE_BUFFER => {
            // version:4, source_len:4, source
            if (rest.len < 8) return error.Malformed;
            const version = std.mem.readInt(u32, rest[0..4], .big);
            const source_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + source_len) return error.Malformed;
            return .{ .parse_buffer = .{
                .version = version,
                .source = rest[8 .. 8 + source_len],
            } };
        },
        OP_SET_HIGHLIGHT_QUERY => {
            // query_len:4, query
            if (rest.len < 4) return error.Malformed;
            const query_len = std.mem.readInt(u32, rest[0..4], .big);
            if (rest.len < 4 + query_len) return error.Malformed;
            return .{ .set_highlight_query = rest[4 .. 4 + query_len] };
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
            if (payload.len < 3) break :blk payload.len;
            const name_len = std.mem.readInt(u16, payload[1..3], .big);
            break :blk 3 + name_len;
        },
        OP_PARSE_BUFFER => blk: {
            if (payload.len < 9) break :blk payload.len;
            const source_len = std.mem.readInt(u32, payload[5..9], .big);
            break :blk 9 + source_len;
        },
        OP_SET_HIGHLIGHT_QUERY => blk: {
            if (payload.len < 5) break :blk payload.len;
            const query_len = std.mem.readInt(u32, payload[1..5], .big);
            break :blk 5 + query_len;
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
        // Unknown opcode: skip 1 byte so the loop always makes progress.
        else => 1,
    };
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
    var buf: [8]u8 = undefined;
    const len = try encodeMouseEvent(&buf, 5, 10, MOUSE_LEFT, 0, MOUSE_PRESS);
    try std.testing.expectEqual(@as(usize, 8), len);
    try std.testing.expectEqual(OP_MOUSE_EVENT, buf[0]);
    try std.testing.expectEqual(@as(i16, 5), std.mem.readInt(i16, buf[1..3], .big));
    try std.testing.expectEqual(@as(i16, 10), std.mem.readInt(i16, buf[3..5], .big));
    try std.testing.expectEqual(MOUSE_LEFT, buf[5]);
    try std.testing.expectEqual(@as(u8, 0), buf[6]);
    try std.testing.expectEqual(MOUSE_PRESS, buf[7]);
}

test "encodeMouseEvent with wheel_up" {
    var buf: [8]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_WHEEL_UP, 0, MOUSE_PRESS);
    try std.testing.expectEqual(MOUSE_WHEEL_UP, buf[5]);
}

test "encodeMouseEvent with wheel_down" {
    var buf: [8]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_WHEEL_DOWN, 0, MOUSE_PRESS);
    try std.testing.expectEqual(MOUSE_WHEEL_DOWN, buf[5]);
}

test "encodeMouseEvent with drag event type" {
    var buf: [8]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 8, 15, MOUSE_LEFT, 0, MOUSE_DRAG);
    try std.testing.expectEqual(MOUSE_DRAG, buf[7]);
}

test "encodeMouseEvent with release event type" {
    var buf: [8]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, MOUSE_RELEASE);
    try std.testing.expectEqual(MOUSE_RELEASE, buf[7]);
}

test "encodeMouseEvent with modifiers" {
    var buf: [8]u8 = undefined;
    const mods = MOD_CTRL | MOD_SHIFT;
    _ = try encodeMouseEvent(&buf, 2, 4, MOUSE_LEFT, mods, MOUSE_PRESS);
    try std.testing.expectEqual(mods, buf[6]);
}

test "encodeMouseEvent with negative coordinates" {
    var buf: [8]u8 = undefined;
    _ = try encodeMouseEvent(&buf, -1, -5, MOUSE_LEFT, 0, MOUSE_PRESS);
    try std.testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, buf[1..3], .big));
    try std.testing.expectEqual(@as(i16, -5), std.mem.readInt(i16, buf[3..5], .big));
}

test "encodeMouseEvent buffer too small returns error" {
    var buf: [7]u8 = undefined; // needs 8
    const result = encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, MOUSE_PRESS);
    try std.testing.expectError(error.Malformed, result);
}

test "encodeMouseEvent all button types" {
    var buf: [8]u8 = undefined;
    const buttons = [_]u8{ MOUSE_LEFT, MOUSE_MIDDLE, MOUSE_RIGHT, MOUSE_NONE, MOUSE_WHEEL_UP, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_RIGHT, MOUSE_WHEEL_LEFT };
    for (buttons) |b| {
        _ = try encodeMouseEvent(&buf, 0, 0, b, 0, MOUSE_PRESS);
        try std.testing.expectEqual(b, buf[5]);
    }
}

test "encodeMouseEvent all event types" {
    var buf: [8]u8 = undefined;
    const types = [_]u8{ MOUSE_PRESS, MOUSE_RELEASE, MOUSE_MOTION, MOUSE_DRAG };
    for (types) |t| {
        _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, t);
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
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
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
        OP_SET_CURSOR, 0x00, 0x05, 0x00, 0x0A,
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
    // opcode(1) + name_len:2 + "elixir"(6) = 9 bytes
    const data = [_]u8{ OP_SET_LANGUAGE, 0x00, 0x06 } ++ "elixir".*;
    const cmd = try decodeCommand(&data);
    try std.testing.expect(cmd == .set_language);
    try std.testing.expectEqualStrings("elixir", cmd.set_language);
}

test "decode set_language truncated returns malformed" {
    const data = [_]u8{ OP_SET_LANGUAGE, 0x00, 0x06, 'e', 'l' }; // only 2 of 6 name bytes
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode parse_buffer" {
    // opcode(1) + version:4 + source_len:4 + "hello"(5) = 14 bytes
    const data = [_]u8{
        OP_PARSE_BUFFER,
        0x00, 0x00, 0x00, 0x01, // version = 1
        0x00, 0x00, 0x00, 0x05, // source_len = 5
    } ++ "hello".*;
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .parse_buffer => |pb| {
            try std.testing.expectEqual(@as(u32, 1), pb.version);
            try std.testing.expectEqualStrings("hello", pb.source);
        },
        else => return error.Malformed,
    }
}

test "decode set_highlight_query" {
    const query = "(atom) @string";
    var data: [1 + 4 + query.len]u8 = undefined;
    data[0] = OP_SET_HIGHLIGHT_QUERY;
    std.mem.writeInt(u32, data[1..5], query.len, .big);
    @memcpy(data[5..], query);
    const cmd = try decodeCommand(&data);
    try std.testing.expect(cmd == .set_highlight_query);
    try std.testing.expectEqualStrings(query, cmd.set_highlight_query);
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
    const data = [_]u8{ OP_SET_LANGUAGE, 0x00, 0x06 } ++ "elixir".*;
    try std.testing.expectEqual(@as(usize, 9), commandSize(&data));
}

test "commandSize: parse_buffer" {
    const data = [_]u8{
        OP_PARSE_BUFFER,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x03,
    } ++ "abc".*;
    try std.testing.expectEqual(@as(usize, 12), commandSize(&data));
}

test "commandSize: set_highlight_query" {
    var data: [1 + 4 + 5]u8 = undefined;
    data[0] = OP_SET_HIGHLIGHT_QUERY;
    std.mem.writeInt(u32, data[1..5], 5, .big);
    @memcpy(data[5..10], "query");
    try std.testing.expectEqual(@as(usize, 10), commandSize(&data));
}

test "commandSize: load_grammar" {
    const data = [_]u8{ OP_LOAD_GRAMMAR, 0x00, 0x03 } ++ "lua".* ++ [_]u8{ 0x00, 0x04 } ++ "path".*;
    try std.testing.expectEqual(@as(usize, 12), commandSize(&data));
}

test "encodeHighlightSpans round-trip" {
    const hl = @import("highlighter.zig");
    const spans = [_]hl.Span{
        .{ .start_byte = 0, .end_byte = 9, .capture_id = 0, .pattern_index = 0 },
        .{ .start_byte = 10, .end_byte = 15, .capture_id = 1, .pattern_index = 1 },
    };
    const buf = try encodeHighlightSpans(std.testing.allocator, 42, &spans);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqual(OP_HIGHLIGHT_SPANS, buf[0]);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[1..5], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[5..9], .big));
    // First span
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[9..13], .big));
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, buf[13..17], .big));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[17..19], .big));
    // Second span
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, buf[19..23], .big));
    try std.testing.expectEqual(@as(u32, 15), std.mem.readInt(u32, buf[23..27], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[27..29], .big));
}

test "encodeHighlightNames round-trip" {
    const names = [_][]const u8{ "keyword", "string" };
    const buf = try encodeHighlightNames(std.testing.allocator, &names);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqual(OP_HIGHLIGHT_NAMES, buf[0]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[1..3], .big));
    // "keyword" (7)
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, buf[3..5], .big));
    try std.testing.expectEqualStrings("keyword", buf[5..12]);
    // "string" (6)
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, buf[12..14], .big));
    try std.testing.expectEqualStrings("string", buf[14..20]);
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
