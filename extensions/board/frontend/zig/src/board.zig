const std = @import("std");

/// Extension-owned Board payload support moved out of Zig TUI core parity code.
pub const Board = struct {
    visible: bool,
    focused_card_id: u32,
    filter_mode: bool,
    filter_text: []u8,
    cards: []BoardCard,

    pub fn deinit(self: *Board, alloc: std.mem.Allocator) void {
        alloc.free(self.filter_text);
        for (self.cards) |*card| card.deinit(alloc);
        alloc.free(self.cards);
    }
};

pub const BoardCard = struct {
    id: u32,
    status: u8,
    flags: u8,
    task: []u8,
    model: []u8,
    timestamp: u32,
    recent_files: [][]u8,

    pub fn deinit(self: *BoardCard, alloc: std.mem.Allocator) void {
        alloc.free(self.task);
        alloc.free(self.model);
        for (self.recent_files) |file| alloc.free(file);
        alloc.free(self.recent_files);
    }
};

pub fn decodeBoard(alloc: std.mem.Allocator, packet: []const u8) !Board {
    if (packet.len < 11) return error.ShortBoardPacket;
    var offset: usize = 9;
    const card_count = readU16(packet, 6);
    const filter = try readString16(alloc, packet, &offset);
    errdefer alloc.free(filter);
    var cards = try alloc.alloc(BoardCard, card_count);
    errdefer alloc.free(cards);
    var decoded: usize = 0;
    errdefer {
        for (cards[0..decoded]) |*card| card.deinit(alloc);
    }

    while (decoded < card_count) : (decoded += 1) {
        if (packet.len < offset + 6) return error.ShortBoardCard;
        const id = readU32(packet, offset);
        const status = packet[offset + 4];
        const flags = packet[offset + 5];
        offset += 6;
        const task = try readString16(alloc, packet, &offset);
        errdefer alloc.free(task);
        if (packet.len < offset + 5) return error.ShortBoardCardMetadata;
        const model_len = packet[offset];
        offset += 1;
        if (packet.len < offset + model_len + 5) return error.ShortBoardModel;
        const model = try alloc.dupe(u8, packet[offset .. offset + model_len]);
        errdefer alloc.free(model);
        offset += model_len;
        const timestamp = readU32(packet, offset);
        offset += 4;
        const file_count = packet[offset];
        offset += 1;
        var files = try alloc.alloc([]u8, file_count);
        errdefer alloc.free(files);
        var file_index: usize = 0;
        errdefer {
            for (files[0..file_index]) |file| alloc.free(file);
        }
        while (file_index < file_count) : (file_index += 1) {
            files[file_index] = try readString16(alloc, packet, &offset);
        }
        if (packet.len < offset + 1) return error.ShortBoardSparkline;
        const sparkline_count = packet[offset];
        offset += 1;
        if (packet.len < offset + @as(usize, sparkline_count) * 2) return error.ShortBoardSparkline;
        offset += @as(usize, sparkline_count) * 2;
        cards[decoded] = .{ .id = id, .status = status, .flags = flags, .task = task, .model = model, .timestamp = timestamp, .recent_files = files };
    }

    return .{ .visible = packet[1] != 0, .focused_card_id = readU32(packet, 2), .filter_mode = packet[8] != 0, .filter_text = filter, .cards = cards };
}

pub fn statusLabel(status: u8) []const u8 {
    return switch (status) {
        0 => "idle",
        1 => "working",
        2 => "iterating",
        3 => "needs you",
        4 => "done",
        5 => "errored",
        else => "unknown",
    };
}

fn readU16(packet: []const u8, offset: usize) u16 {
    const bytes: *const [2]u8 = @ptrCast(packet[offset..][0..2]);
    return std.mem.readInt(u16, bytes, .big);
}

fn readU32(packet: []const u8, offset: usize) u32 {
    const bytes: *const [4]u8 = @ptrCast(packet[offset..][0..4]);
    return std.mem.readInt(u32, bytes, .big);
}

fn readString16(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) ![]u8 {
    if (packet.len < offset.* + 2) return error.ShortStringLength;
    const len = readU16(packet, offset.*);
    offset.* += 2;
    if (packet.len < offset.* + len) return error.ShortString;
    const value = try alloc.dupe(u8, packet[offset.* .. offset.* + len]);
    offset.* += len;
    return value;
}

test "decodes extension-owned board payload" {
    const packet = [_]u8{ 0x87, 1, 0, 0, 0, 7, 0, 1, 0, 0, 0, 0, 0, 0, 7, 3, 2, 0, 8 } ++ "fix auth".* ++ [_]u8{8} ++ "claude-4".* ++ [_]u8{ 0, 0, 0, 42, 1, 0, 8 } ++ "lib/a.ex".* ++ [_]u8{ 2, 0, 0, 0xFF, 0xFF };
    var board = try decodeBoard(std.testing.allocator, &packet);
    defer board.deinit(std.testing.allocator);

    try std.testing.expect(board.visible);
    try std.testing.expectEqual(@as(u32, 7), board.focused_card_id);
    try std.testing.expectEqual(@as(usize, 1), board.cards.len);
    try std.testing.expectEqual(@as(u32, 7), board.cards[0].id);
    try std.testing.expectEqual(@as(u8, 3), board.cards[0].status);
    try std.testing.expectEqualStrings("fix auth", board.cards[0].task);
    try std.testing.expectEqualStrings("claude-4", board.cards[0].model);
    try std.testing.expectEqualStrings("lib/a.ex", board.cards[0].recent_files[0]);
}

test "status labels are stable" {
    try std.testing.expectEqualStrings("needs you", statusLabel(3));
    try std.testing.expectEqualStrings("unknown", statusLabel(99));
}
