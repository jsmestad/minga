/// ZigZag component adapters backed by BEAM-owned semantic state.
///
/// These helpers use ZigZag components as presentation adapters only. They do not let ZigZag own query text, focus, filtering, selection, command execution, protocol meaning, or terminal output.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const zz = @import("zigzag");
const types = @import("semantic/types.zig");

pub const WhichKeyBinding = types.WhichKeyBinding;
pub const CompletionItem = types.CompletionItem;
pub const PickerItem = types.PickerItem;
pub const HoverLine = types.HoverLine;
pub const ToolSummary = types.ToolSummary;
pub const AgentChatMessage = types.AgentChatMessage;

pub const IndexedRow = struct {
    index: usize,
    selected: bool,
};

pub const PlainRow = struct {
    title: []const u8,
    detail: []const u8 = "",
    selected: bool = false,
};

pub const CompletionRow = struct {
    label: []const u8,
    detail: []const u8,
    selected: bool,
};

/// Renders BEAM-owned which-key bindings through ZigZag `Help` as plain rows.
pub fn renderWhichKeyHelp(alloc: std.mem.Allocator, bindings: []const WhichKeyBinding, max_width: u16) ![]const u8 {
    var help = zz.components.Help.init(alloc);
    defer help.deinit();

    help.key_style = .{};
    help.desc_style = .{};
    help.sep_style = .{};
    help.setMaxWidth(max_width);

    for (bindings) |binding| {
        const key = std.mem.trim(u8, binding.key, " \t\r\n");
        if (key.len == 0) continue;
        const description = if (binding.icon.len > 0)
            try std.fmt.allocPrint(alloc, "{s} {s}", .{ binding.icon, binding.description })
        else
            binding.description;
        try help.addBinding(key, description);
    }

    return renderHelpPlainVertical(alloc, &help);
}

fn renderHelpPlainVertical(alloc: std.mem.Allocator, help: *const zz.components.Help) ![]const u8 {
    var max_key_width: usize = 0;
    for (help.bindings.items) |binding| {
        max_key_width = @max(max_key_width, zz.width(binding.key));
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    const writer = &out.writer;
    for (help.bindings.items, 0..) |binding, index| {
        if (index > 0) try writer.writeByte('\n');
        try writer.writeAll(binding.key);
        const key_width = zz.width(binding.key);
        var pad = max_key_width - key_width + 2;
        while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
        const desc = if (help.short_mode and binding.short_desc != null) binding.short_desc.? else binding.description;
        try writer.writeAll(desc);
    }
    return out.toOwnedSlice();
}

/// Computes visible picker rows through ZigZag `CommandPalette` and `VirtualList` while keeping query/filter/acceptance BEAM-owned.
pub fn pickerRows(alloc: std.mem.Allocator, items: []const PickerItem, selected_index: u16, height: u16) ![]IndexedRow {
    if (items.len == 0 or height == 0) return &.{};

    var palette = try zz.CommandPalette.init(alloc);
    defer palette.deinit();
    palette.max_visible = height;
    palette.width = 80;

    for (items, 0..) |item, index| {
        const id = try std.fmt.allocPrint(alloc, "{d}", .{index});
        try palette.addCommand(.{ .id = id, .label = item.label, .description = if (item.description.len > 0) item.description else item.annotation });
    }

    const selected: usize = @min(selected_index, items.len - 1);
    palette.cursor = selected;

    const indices = try alloc.alloc(usize, palette.filtered.items.len);
    for (indices, 0..) |*value, filtered_index| value.* = palette.filtered.items[filtered_index];

    var list = zz.components.VirtualList(usize){};
    list.viewport_height = height;
    list.cursor = selected;
    list.show_count = false;
    list.show_scrollbar = false;
    list.cursor_symbol = "";
    list.normal_symbol = "";
    list.setItems(indices);

    const end = @min(list.offset + @as(usize, height), indices.len);
    const rows = try alloc.alloc(IndexedRow, end - list.offset);
    for (rows, list.offset..end) |*row, absolute| {
        row.* = .{ .index = indices[absolute], .selected = absolute == selected };
    }
    return rows;
}

/// Computes visible completion rows through ZigZag `List` while keeping completion state BEAM-owned.
pub fn completionRows(alloc: std.mem.Allocator, items: []const CompletionItem, selected_index: u16, height: u16) ![]CompletionRow {
    if (items.len == 0 or height == 0) return &.{};

    var list = zz.List(usize).init(alloc);
    defer list.deinit();
    list.height = height;
    list.cursor_symbol = "";
    list.show_item_count = false;
    list.wrap_around = false;

    for (items, 0..) |item, index| {
        try list.addItem(.{ .value = index, .title = item.label, .description = item.detail, .enabled = true });
    }

    const selected: usize = @min(selected_index, items.len - 1);
    list.cursor = selected;
    if (list.cursor >= list.height) list.y_offset = list.cursor - list.height + 1;

    const visible_count: usize = @min(height, items.len - list.y_offset);
    const rows = try alloc.alloc(CompletionRow, visible_count);
    for (rows, 0..) |*row, offset| {
        const item_index = list.items.items[list.y_offset + offset].value;
        row.* = .{
            .label = items[item_index].label,
            .detail = items[item_index].detail,
            .selected = item_index == selected,
        };
    }
    return rows;
}

/// Uses ZigZag `Tooltip` as a low-state shape adapter for plain hover/signature rows.
pub fn hoverTooltipRows(alloc: std.mem.Allocator, title: []const u8, line: HoverLine) ![]PlainRow {
    var body: std.Io.Writer.Allocating = .init(alloc);
    for (line.segments) |segment| try body.writer.writeAll(segment.text);
    const text = try body.toOwnedSlice();
    return tooltipRows(alloc, title, text);
}

/// Uses ZigZag `Tooltip` as a low-state shape adapter for plain hover/signature rows.
pub fn tooltipRows(alloc: std.mem.Allocator, title: []const u8, body: []const u8) ![]PlainRow {
    var tooltip = zz.Tooltip.titled(title, body);
    tooltip.show();
    const rendered = try tooltip.renderBox(alloc);
    if (std.mem.indexOf(u8, rendered, body) == null) return error.ComponentOutputMismatch;
    const rows = try alloc.alloc(PlainRow, 1);
    rows[0] = .{ .title = body };
    return rows;
}

/// Uses ZigZag `Table` to adapt simple two-column tool rows while keeping selection and actions BEAM-owned.
pub fn toolRows(alloc: std.mem.Allocator, tools: []const ToolSummary, selected_index: u16) ![]PlainRow {
    if (tools.len == 0) return &.{};
    var table = zz.Table(2).init(alloc);
    defer table.deinit();
    table.setHeaders(.{ "Tool", "Status" });
    for (tools) |tool| try table.addRow(.{ tool.label, tool.name });
    const rendered = try table.view(alloc);
    if (std.mem.indexOf(u8, rendered, "Tool") == null) return error.ComponentOutputMismatch;

    const selected: usize = @min(selected_index, tools.len - 1);
    const rows = try alloc.alloc(PlainRow, tools.len);
    for (rows, 0..) |*row, index| {
        const tool = tools[index];
        row.* = .{ .title = tool.label, .detail = tool.name, .selected = index == selected };
    }
    return rows;
}

/// Uses ZigZag `RichLog` as a transcript viewport helper while keeping transcript entries BEAM-owned.
pub fn agentMessageRows(alloc: std.mem.Allocator, messages: []const AgentChatMessage, height: u16) ![]IndexedRow {
    if (messages.len == 0 or height == 0) return &.{};
    var log = zz.RichLog.init(alloc, @max(@as(usize, height), 1));
    defer log.deinit();
    // RichLog.append only needs an Io to timestamp entries; the timestamp is
    // unused here. std.testing.io is a @compileError outside test builds, so use
    // the renderer's real Io in production and the test Io under `zig test`.
    const append_io: std.Io = if (builtin.is_test) std.testing.io else root.g_io;
    for (messages) |message| try log.append(append_io, .info, messageText(message));
    const rendered = try log.view(alloc);
    if (messages.len > 0 and std.mem.indexOf(u8, rendered, messageText(messages[messages.len - 1])) == null) return error.ComponentOutputMismatch;

    const visible_count: usize = @min(messages.len, height);
    const start = messages.len - visible_count;
    const rows = try alloc.alloc(IndexedRow, visible_count);
    for (rows, 0..) |*row, offset| row.* = .{ .index = start + offset, .selected = false };
    return rows;
}

fn messageText(message: AgentChatMessage) []const u8 {
    if (message.text.len > 0) return message.text;
    if (message.summary.len > 0) return message.summary;
    if (message.result.len > 0) return message.result;
    if (message.name.len > 0) return message.name;
    return "message";
}

test "which-key adapter renders BEAM-owned bindings through ZigZag Help" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key_find = try alloc.dupe(u8, " f ");
    const desc_find = try alloc.dupe(u8, "find file");
    const icon_find = try alloc.dupe(u8, "*");
    const key_buffers = try alloc.dupe(u8, "b");
    const desc_buffers = try alloc.dupe(u8, "buffers");

    const rendered = try renderWhichKeyHelp(alloc, &[_]WhichKeyBinding{
        .{ .key = key_find, .description = desc_find, .icon = icon_find },
        .{ .key = key_buffers, .description = desc_buffers },
    }, 40);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "f") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "* find file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "b") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "buffers") != null);
}

test "completion adapter uses ZigZag List selection and viewport state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rows = try completionRows(alloc, &[_]CompletionItem{
        .{ .label = try alloc.dupe(u8, "alpha"), .detail = try alloc.dupe(u8, "one") },
        .{ .label = try alloc.dupe(u8, "beta"), .detail = try alloc.dupe(u8, "two") },
        .{ .label = try alloc.dupe(u8, "gamma"), .detail = try alloc.dupe(u8, "three") },
    }, 2, 2);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("beta", rows[0].label);
    try std.testing.expect(!rows[0].selected);
    try std.testing.expectEqualStrings("gamma", rows[1].label);
    try std.testing.expect(rows[1].selected);
}

test "picker adapter uses CommandPalette and VirtualList viewport state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rows = try pickerRows(alloc, &[_]PickerItem{
        .{ .label = try alloc.dupe(u8, "alpha") },
        .{ .label = try alloc.dupe(u8, "beta") },
        .{ .label = try alloc.dupe(u8, "gamma") },
        .{ .label = try alloc.dupe(u8, "delta") },
    }, 3, 2);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(usize, 2), rows[0].index);
    try std.testing.expectEqual(@as(usize, 3), rows[1].index);
    try std.testing.expect(rows[1].selected);
}

test "tooltip adapter evaluates plain tooltip rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try tooltipRows(arena.allocator(), "Hover", "docs");
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("docs", rows[0].title);
}

test "table adapter preserves tool semantic rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tools = try toolRows(alloc, &[_]ToolSummary{
        .{ .name = try alloc.dupe(u8, "read"), .label = try alloc.dupe(u8, "Read") },
        .{ .name = try alloc.dupe(u8, "write"), .label = try alloc.dupe(u8, "Write") },
    }, 1);
    try std.testing.expectEqualStrings("Write", tools[1].title);
    try std.testing.expect(tools[1].selected);
}

test "rich log adapter preserves visible BEAM-owned transcript indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rows = try agentMessageRows(alloc, &[_]AgentChatMessage{
        .{ .text = try alloc.dupe(u8, "one") },
        .{ .text = try alloc.dupe(u8, "two") },
        .{ .text = try alloc.dupe(u8, "three") },
    }, 2);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(usize, 1), rows[0].index);
    try std.testing.expectEqual(@as(usize, 2), rows[1].index);
}

test "which-key adapter output contains no ANSI escape sequences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key = try alloc.dupe(u8, "SPC");
    const desc = try alloc.dupe(u8, "leader");
    const rendered = try renderWhichKeyHelp(alloc, &[_]WhichKeyBinding{.{ .key = key, .description = desc }}, 40);
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, 0x1B) == null);
}
