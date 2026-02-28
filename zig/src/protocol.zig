/// Port protocol encoder/decoder for BEAM ↔ Zig communication.
///
/// Messages use a simple binary format with 1-byte opcodes:
///
/// Input events (Zig → BEAM):
///   0x01 key_press:  codepoint:u32, modifiers:u8
///   0x02 resize:     width:u16, height:u16
///   0x03 ready:      width:u16, height:u16
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
pub const OP_DRAW_TEXT: u8 = 0x10;
pub const OP_SET_CURSOR: u8 = 0x11;
pub const OP_CLEAR: u8 = 0x12;
pub const OP_BATCH_END: u8 = 0x13;

// ── Modifier flags ──

pub const MOD_SHIFT: u8 = 0x01;
pub const MOD_CTRL: u8 = 0x02;
pub const MOD_ALT: u8 = 0x04;
pub const MOD_SUPER: u8 = 0x08;

// ── Attribute flags ──

pub const ATTR_BOLD: u8 = 0x01;
pub const ATTR_UNDERLINE: u8 = 0x02;
pub const ATTR_ITALIC: u8 = 0x04;
pub const ATTR_REVERSE: u8 = 0x08;

// ── Decoded types ──

pub const RenderCommand = union(enum) {
    draw_text: DrawText,
    set_cursor: SetCursor,
    clear: void,
    batch_end: void,
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

/// Writes a length-prefixed message to the writer.
/// Adds a 4-byte big-endian length header before the payload.
pub fn writeMessage(writer: anytype, payload: []const u8) !void {
    const len: u32 = @intCast(payload.len);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, len, .big);
    try writer.writeAll(&len_buf);
    try writer.writeAll(payload);
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
        else => return error.UnknownOpcode,
    }
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
