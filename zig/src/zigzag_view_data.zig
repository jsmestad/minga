/// Borrowed ZigZag-friendly view data derived from Minga semantic state.
///
/// The BEAM remains authoritative for semantic payload meaning. These structs expose narrow slices of the retained renderer state so later tickets can feed ZigZag components without copying the whole state tree or inventing a second editor model.
const std = @import("std");
const protocol = @import("protocol.zig");
const semantic = @import("semantic.zig");
const zz = @import("zigzag");

/// Candidate ZigZag component or primitive for a derived view.
pub const ComponentHint = enum {
    tab_group,
    status_bar,
    viewport,
    code_view,
    render_with_ranges,
};

/// Top-level adapter output for the first ZigZag-assisted slices.
pub const ViewData = struct {
    tab_bar: ?TabBarInput = null,
    status_bar: ?StatusBarInput = null,
    editor_window: ?EditorWindowInput = null,
};

/// Borrowed tab strip data suitable for `zz.TabGroup`.
pub const TabBarInput = struct {
    active_index: usize,
    tabs: []const semantic.Tab,
    component_hint: ComponentHint = .tab_group,

    /// Returns the active tab label when the semantic payload has one.
    pub fn activeLabel(self: TabBarInput) ?[]const u8 {
        if (self.active_index >= self.tabs.len) return null;
        return self.tabs[self.active_index].label;
    }
};

/// Borrowed modeline data suitable for `zz.StatusBar`.
pub const StatusBarInput = struct {
    width: u16,
    mode: u8,
    line: u32,
    col: u32,
    line_count: u32,
    branch: []const u8,
    icon: []const u8,
    filename: []const u8,
    filetype: []const u8,
    message: []const u8,
    left_segments: []const semantic.StatusSegment,
    right_segments: []const semantic.StatusSegment,
    component_hint: ComponentHint = .status_bar,
};

/// Borrowed editor-window data suitable for `zz.Viewport`, `zz.CodeView`, or `zz.renderWithRanges` where later tickets prove semantic parity.
pub const EditorWindowInput = struct {
    window_id: u16,
    origin_row: u16,
    origin_col: u16,
    text_width: u16,
    text_height: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_shape: u8,
    scroll_left: u16,
    content_epoch: u32,
    rows: []const semantic.WindowRow,
    selection: semantic.WindowSelection,
    search_matches: []const semantic.SearchMatch,
    diagnostic_ranges: []const semantic.DiagnosticRange,
    document_highlights: []const semantic.DocumentHighlight,
    annotations: []const semantic.LineAnnotation,
    component_hint: ComponentHint = .render_with_ranges,

    /// Returns the first visible text row when the semantic payload has one.
    pub fn firstRow(self: EditorWindowInput) ?semantic.WindowRow {
        if (self.rows.len == 0) return null;
        return self.rows[0];
    }
};

/// Derives narrow ZigZag-friendly inputs from retained semantic state.
pub fn fromSemanticState(state: *const semantic.State, surface_width: u16) ViewData {
    return .{
        .tab_bar = tabBarInput(state),
        .status_bar = statusBarInput(state, surface_width),
        .editor_window = firstEditorWindowInput(state),
    };
}

fn tabBarInput(state: *const semantic.State) ?TabBarInput {
    const tab_bar = &(state.tab_bar orelse return null);
    return .{
        .active_index = tab_bar.active_index,
        .tabs = tab_bar.tabs,
    };
}

fn statusBarInput(state: *const semantic.State, surface_width: u16) ?StatusBarInput {
    const status = &(state.status_bar orelse return null);
    return .{
        .width = surface_width,
        .mode = status.mode,
        .line = status.line,
        .col = status.col,
        .line_count = status.line_count,
        .branch = status.branch,
        .icon = status.icon,
        .filename = status.filename,
        .filetype = status.filetype,
        .message = status.message,
        .left_segments = status.left_segments,
        .right_segments = status.right_segments,
    };
}

fn firstEditorWindowInput(state: *const semantic.State) ?EditorWindowInput {
    const window = activeWindow(state) orelse return null;
    return .{
        .window_id = window.window_id,
        .origin_row = window.origin_row,
        .origin_col = window.origin_col,
        .text_width = window.text_width,
        .text_height = window.text_height,
        .cursor_row = window.cursor_row,
        .cursor_col = window.cursor_col,
        .cursor_shape = window.cursor_shape,
        .scroll_left = window.scroll_left,
        .content_epoch = window.content_epoch,
        .rows = window.rows,
        .selection = window.selection,
        .search_matches = window.search_matches,
        .diagnostic_ranges = window.diagnostic_ranges,
        .document_highlights = window.document_highlights,
        .annotations = window.annotations,
    };
}

fn activeWindow(state: *const semantic.State) ?semantic.WindowContent {
    if (state.cursor_window_id) |cursor_window_id| {
        for (state.windows) |window| {
            if (window.window_id == cursor_window_id) return window;
        }
    }
    if (state.windows.len == 0) return null;
    return state.windows[0];
}

/// Converts a Minga RGB integer and attrs into a ZigZag inline style.
pub fn styleFromSemantic(fg: u24, bg: u24, attrs: u8) zz.Style {
    var style = zz.Style{};
    if (fg != 0) style = style.fg(colorFromU24(fg));
    if (bg != 0) style = style.bg(colorFromU24(bg));
    if (attrs & protocol.ATTR_BOLD != 0) style = style.bold(true);
    if (attrs & protocol.ATTR_ITALIC != 0) style = style.italic(true);
    if (attrs & protocol.ATTR_UNDERLINE != 0) style = style.underline(true);
    if (attrs & protocol.ATTR_REVERSE != 0) style = style.reverse(true);
    return style.inline_style(true);
}

fn colorFromU24(rgb: u24) zz.Color {
    return zz.Color.fromRgb(
        @intCast((rgb >> 16) & 0xff),
        @intCast((rgb >> 8) & 0xff),
        @intCast(rgb & 0xff),
    );
}

fn decodeFixtureState(alloc: std.mem.Allocator, bytes: []const u8) !semantic.State {
    var state = semantic.State.init(alloc);
    errdefer state.deinit();

    var offset: usize = 0;
    while (offset < bytes.len) {
        if (offset + 4 > bytes.len) return error.Malformed;
        const msg_len: usize = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        if (offset + msg_len > bytes.len) return error.Malformed;
        try applyPayload(&state, bytes[offset..][0..msg_len]);
        offset += msg_len;
    }

    return state;
}

fn applyPayload(state: *semantic.State, payload: []const u8) !void {
    var offset: usize = 0;
    while (offset < payload.len) {
        const remaining = payload[offset..];
        const cmd = try protocol.decodeCommand(remaining);
        switch (cmd) {
            .clear => state.clear(),
            .batch_end => {},
            .noop => try applySemanticNoop(state, remaining),
            else => {},
        }

        const advance = protocol.commandSize(remaining);
        if (advance == 0) return error.Malformed;
        offset += advance;
    }
}

fn applySemanticNoop(state: *semantic.State, packet: []const u8) !void {
    if (packet.len == 0) return;
    const cmd_size = protocol.commandSize(packet);
    try state.applyRetainedSemanticPacket(packet[0..cmd_size]);
}

test "full editor fixture decodes through semantic state into ZigZag view data" {
    const alloc = std.testing.allocator;
    const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/full_editor.bin", alloc, .limited(1024 * 1024));
    defer alloc.free(fixture);

    var state = try decodeFixtureState(alloc, fixture);
    defer state.deinit();

    const view_data = fromSemanticState(&state, 80);
    const tab_bar = view_data.tab_bar.?;
    const status_bar = view_data.status_bar.?;
    const editor_window = view_data.editor_window.?;

    try std.testing.expectEqual(ComponentHint.tab_group, tab_bar.component_hint);
    try std.testing.expectEqual(ComponentHint.status_bar, status_bar.component_hint);
    try std.testing.expectEqual(ComponentHint.render_with_ranges, editor_window.component_hint);

    try std.testing.expectEqual(state.tab_bar.?.tabs.len, tab_bar.tabs.len);
    try std.testing.expectEqual(state.tab_bar.?.active_index, @as(u8, @intCast(tab_bar.active_index)));
    try std.testing.expectEqualStrings(state.tab_bar.?.tabs[state.tab_bar.?.active_index].label, tab_bar.activeLabel().?);

    try std.testing.expectEqualStrings(state.status_bar.?.filename, status_bar.filename);
    try std.testing.expectEqual(state.status_bar.?.line, status_bar.line);
    try std.testing.expectEqual(state.status_bar.?.left_segments.len, status_bar.left_segments.len);
    try std.testing.expectEqual(state.status_bar.?.right_segments.len, status_bar.right_segments.len);

    try std.testing.expectEqual(state.windows[0].window_id, editor_window.window_id);
    try std.testing.expectEqual(state.windows[0].rows.len, editor_window.rows.len);
    try std.testing.expectEqualStrings(state.windows[0].rows[0].text, editor_window.firstRow().?.text);
    try std.testing.expectEqual(state.windows[0].rows[0].spans.len, editor_window.firstRow().?.spans.len);
}

test "editor view data prefers cursor window over retained order" {
    const alloc = std.testing.allocator;

    var windows = try alloc.alloc(semantic.WindowContent, 2);
    windows[0] = .{ .window_id = 7, .text_width = 40 };
    windows[1] = .{ .window_id = 9, .text_width = 80 };

    var state = semantic.State.init(alloc);
    defer state.deinit();
    state.windows = windows;
    state.cursor_window_id = 9;

    const view_data = fromSemanticState(&state, 120);
    try std.testing.expectEqual(@as(u16, 9), view_data.editor_window.?.window_id);
    try std.testing.expectEqual(@as(u16, 80), view_data.editor_window.?.text_width);
}

test "semantic style fields convert to ZigZag inline style" {
    const style = styleFromSemantic(0x112233, 0x445566, protocol.ATTR_BOLD | protocol.ATTR_UNDERLINE);

    try std.testing.expectEqual(zz.Color.fromRgb(0x11, 0x22, 0x33), style.foreground);
    try std.testing.expectEqual(zz.Color.fromRgb(0x44, 0x55, 0x66), style.background);
    try std.testing.expect(style.bold_attr.?);
    try std.testing.expect(style.underline_attr.?);
    try std.testing.expect(style.inline_mode);
}
