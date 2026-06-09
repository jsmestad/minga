/// Static chrome ZigZag adapters for the current renderer.
///
/// These helpers use ZigZag structural components as presentation adapters over BEAM-owned semantic state. They do not let ZigZag own semantic payloads, commands, terminal output, expansion state, selected IDs, protocol meaning, or durable editor state.
const std = @import("std");
const zz = @import("zigzag");
const semantic = @import("semantic.zig");
const zigzag_view_data = @import("zigzag_view_data.zig");

pub const TabPresentation = struct {
    index: usize,
    active: bool,
};

pub const SplitDims = struct {
    left_width: u16,
    right_width: u16,
};

pub const TreeRowPresentation = struct {
    source_index: usize,
    depth: u8,
    marker: []const u8,
    label: []const u8,
};

/// Derives tab presentation state through ZigZag `TabGroup` while keeping tab IDs and actions BEAM-owned.
pub fn tabRows(alloc: std.mem.Allocator, tabs: []const semantic.Tab, active_index: u8) ![]TabPresentation {
    if (tabs.len == 0) return &.{};

    var group = zz.TabGroup.init(alloc);
    defer group.deinit();
    group.show_numbers = false;
    group.activate_on_focus = false;

    var selected: usize = @min(active_index, tabs.len - 1);
    for (tabs, 0..) |tab, index| {
        if (tab.active()) selected = index;
        const id = try std.fmt.allocPrint(alloc, "{d}", .{tab.id});
        _ = try group.addTab(.{ .id = id, .title = tab.label, .enabled = true, .visible = true });
    }
    _ = group.setActive(selected, .set_active);

    const rows = try alloc.alloc(TabPresentation, group.tabs.items.len);
    for (rows, 0..) |*row, index| {
        row.* = .{ .index = index, .active = group.active_index != null and group.active_index.? == index };
    }
    return rows;
}

/// Computes split geometry through ZigZag `SplitPane`.
pub fn horizontalSplit(width: u16, height: u16, ratio: f32) SplitDims {
    var split = zz.SplitPane.init(.horizontal);
    split.setSize(width, height);
    split.setRatio(ratio);
    const dims = split.dims();
    return .{ .left_width = dims.a_width, .right_width = dims.b_width };
}

/// Uses ZigZag `StatusBar` segment groups to derive the right-aligned start column.
pub fn statusRightStart(alloc: std.mem.Allocator, status: semantic.StatusBar, width: u16) !u16 {
    var bar = zz.StatusBar.init(alloc);
    defer bar.deinit();
    bar.setWidth(width);
    bar.setSeparator("");

    for (status.left_segments) |segment| try bar.addLeft(.{ .text = segment.text, .style = null });
    for (status.right_segments) |segment| try bar.addRight(.{ .text = segment.text, .style = null });

    var right_width: u16 = 0;
    for (bar.right.items) |segment| right_width +|= @intCast(@min(zz.width(segment.text), std.math.maxInt(u16)));
    return if (right_width >= width) 0 else width - right_width;
}

/// Builds a ZigZag `Tree` from the BEAM-owned visible file tree and returns preserved row presentation data.
pub fn fileTreeRows(alloc: std.mem.Allocator, tree: semantic.FileTree) ![]TreeRowPresentation {
    if (tree.rows.len == 0) return &.{};

    var component = zz.Tree(usize).init(alloc);
    defer component.deinit();

    var parent_by_depth: [256]usize = undefined;
    var have_depth: [256]bool = [_]bool{false} ** 256;
    const out = try alloc.alloc(TreeRowPresentation, tree.rows.len);

    for (tree.rows, 0..) |row, index| {
        const label = if (row.editing_text.len > 0) row.editing_text else row.name;
        const node_index = if (row.depth == 0 or !have_depth[row.depth -| 1])
            try component.addRoot(index, label)
        else
            try component.addChild(parent_by_depth[row.depth -| 1], index, label);
        component.nodes.items[node_index].expanded = row.expanded();
        parent_by_depth[row.depth] = node_index;
        have_depth[row.depth] = true;

        var clear_depth = @as(usize, row.depth) + 1;
        while (clear_depth < have_depth.len) : (clear_depth += 1) have_depth[clear_depth] = false;

        out[index] = .{
            .source_index = index,
            .depth = row.depth,
            .marker = if (row.directory()) (if (component.nodes.items[node_index].expanded) "v" else ">") else " ",
            .label = label,
        };
    }
    return out;
}

/// Result of adapting retained static chrome into ZigZag component views.
pub const StaticChromeFit = struct {
    tab_group_width: usize,
    status_bar_width: usize,
    tree_width: usize,
    tab_count: usize,
    left_status_count: usize,
    right_status_count: usize,
    tree_row_count: usize,

    /// Returns true when ZigZag can represent the main static chrome payloads as component views.
    pub fn hasComponentCoverage(self: StaticChromeFit) bool {
        return self.tab_count > 0 and self.tab_group_width > 0 and self.status_bar_width > 0 and self.tree_width > 0;
    }
};

/// Builds ZigZag component views from retained semantic chrome without writing them to the terminal.
pub fn assessStaticChromeFit(alloc: std.mem.Allocator, state: *const semantic.State, width: u16) !StaticChromeFit {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    const view_data = zigzag_view_data.fromSemanticState(state, width);

    const tab_group_width = if (view_data.tab_bar) |tabs| try tabGroupWidth(scratch, tabs, width) else 0;
    const status_bar_width = if (view_data.status_bar) |status| try statusBarWidth(scratch, status, width) else 0;
    const tree_width = if (state.file_tree) |tree| try treeWidth(scratch, tree) else 0;

    return .{
        .tab_group_width = tab_group_width,
        .status_bar_width = status_bar_width,
        .tree_width = tree_width,
        .tab_count = if (view_data.tab_bar) |tabs| tabs.tabs.len else 0,
        .left_status_count = if (view_data.status_bar) |status| status.left_segments.len else 0,
        .right_status_count = if (view_data.status_bar) |status| status.right_segments.len else 0,
        .tree_row_count = if (state.file_tree) |tree| tree.rows.len else 0,
    };
}

fn tabGroupWidth(alloc: std.mem.Allocator, tabs: zigzag_view_data.TabBarInput, width: u16) !usize {
    var group = zz.TabGroup.init(alloc);
    defer group.deinit();
    group.max_width = width;

    for (tabs.tabs) |tab| {
        const id = try std.fmt.allocPrint(alloc, "{d}", .{tab.id});
        defer alloc.free(id);
        _ = try group.addTab(.{ .id = id, .title = tab.label });
    }
    if (tabs.tabs.len > 0 and tabs.active_index < tabs.tabs.len) _ = group.setActive(tabs.active_index, .set_active);

    const rendered = try group.view(alloc);
    defer alloc.free(rendered);
    return zz.width(rendered);
}

fn statusBarWidth(alloc: std.mem.Allocator, status: zigzag_view_data.StatusBarInput, width: u16) !usize {
    var bar = zz.StatusBar.init(alloc);
    defer bar.deinit();
    bar.setWidth(width);

    if (status.left_segments.len > 0 or status.right_segments.len > 0) {
        for (status.left_segments) |segment| try bar.addLeft(.{ .text = segment.text, .style = zigzag_view_data.styleFromSemantic(segment.fg, segment.bg, segment.attrs) });
        for (status.right_segments) |segment| try bar.addRight(.{ .text = segment.text, .style = zigzag_view_data.styleFromSemantic(segment.fg, segment.bg, segment.attrs) });
    } else {
        try bar.setLeft(status.filename, null);
        try bar.setRight(status.filetype, null);
    }

    const rendered = try bar.view(alloc);
    defer alloc.free(rendered);
    return zz.width(rendered);
}

fn treeWidth(alloc: std.mem.Allocator, tree: semantic.FileTree) !usize {
    var component = zz.Tree([]const u8).init(alloc);
    defer component.deinit();

    const root_label = if (tree.root_path.len > 0) tree.root_path else "Files";
    const root = try component.addRoot(root_label, root_label);
    for (tree.rows) |row| {
        const label = if (row.editing_text.len > 0) row.editing_text else row.name;
        _ = try component.addChild(root, label, label);
    }

    const rendered = try component.view(alloc);
    defer alloc.free(rendered);
    return zz.width(rendered);
}

test "TabGroup adapter derives active tab presentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rows = try tabRows(alloc, &[_]semantic.Tab{
        .{ .id = 1, .label = try alloc.dupe(u8, "one") },
        .{ .id = 2, .flags = 0x01, .label = try alloc.dupe(u8, "two") },
    }, 0);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expect(!rows[0].active);
    try std.testing.expect(rows[1].active);
}

test "SplitPane adapter derives horizontal split dimensions" {
    const dims = horizontalSplit(100, 20, 0.45);
    try std.testing.expectEqual(@as(u16, 44), dims.left_width);
    try std.testing.expectEqual(@as(u16, 55), dims.right_width);
}

test "StatusBar adapter derives right segment start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const right = try alloc.alloc(semantic.StatusSegment, 2);
    right[0] = .{ .text = try alloc.dupe(u8, "Ln 1") };
    right[1] = .{ .text = try alloc.dupe(u8, "Col 2") };

    const start = try statusRightStart(alloc, .{ .right_segments = right }, 20);
    try std.testing.expectEqual(@as(u16, 11), start);
}

test "Tree adapter preserves BEAM-owned file rows through ZigZag Tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rows = try alloc.alloc(semantic.FileTreeRow, 3);
    rows[0] = .{ .name = try alloc.dupe(u8, "src"), .depth = 0, .flags = 0x03 };
    rows[1] = .{ .name = try alloc.dupe(u8, "main.zig"), .depth = 1 };
    rows[2] = .{ .name = try alloc.dupe(u8, "test"), .depth = 0, .flags = 0x01 };

    const presentation = try fileTreeRows(alloc, .{ .rows = rows });
    try std.testing.expectEqual(@as(usize, 3), presentation.len);
    try std.testing.expectEqualStrings("v", presentation[0].marker);
    try std.testing.expectEqual(@as(u8, 1), presentation[1].depth);
    try std.testing.expectEqualStrings("main.zig", presentation[1].label);
    try std.testing.expectEqualStrings(">", presentation[2].marker);
}

test "ZigZag component views can represent full editor static chrome at 80x24" {
    const alloc = std.testing.allocator;
    const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/full_editor.bin", alloc, .limited(1024 * 1024));
    defer alloc.free(fixture);

    var state = try zigzag_view_data.decodeFixtureState(alloc, fixture);
    defer state.deinit();

    const fit = try assessStaticChromeFit(alloc, &state, 80);
    try std.testing.expect(fit.hasComponentCoverage());
    try std.testing.expectEqual(state.tab_bar.?.tabs.len, fit.tab_count);
    try std.testing.expectEqual(state.status_bar.?.left_segments.len, fit.left_status_count);
    try std.testing.expectEqual(state.status_bar.?.right_segments.len, fit.right_status_count);
    try std.testing.expectEqual(state.file_tree.?.rows.len, fit.tree_row_count);
    try std.testing.expect(fit.tab_group_width <= 80);
    try std.testing.expect(fit.status_bar_width <= 80);
}

test "ZigZag component views can represent full editor static chrome at wide size" {
    const alloc = std.testing.allocator;
    const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/full_editor.bin", alloc, .limited(1024 * 1024));
    defer alloc.free(fixture);

    var state = try zigzag_view_data.decodeFixtureState(alloc, fixture);
    defer state.deinit();

    const narrow = try assessStaticChromeFit(alloc, &state, 80);
    const wide = try assessStaticChromeFit(alloc, &state, 140);
    try std.testing.expect(wide.hasComponentCoverage());
    try std.testing.expect(wide.status_bar_width >= narrow.status_bar_width);
    try std.testing.expect(wide.tab_group_width >= narrow.tab_group_width);
    try std.testing.expect(wide.status_bar_width <= 140);
}
