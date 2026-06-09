/// Editor-body ZigZag fit checks for the current renderer.
///
/// This module does not render runtime cells. The editor body is the highest correctness-risk TUI surface, so #2186 records where ZigZag helpers fit and where direct component output would change Minga semantics. Runtime text, spans, cursor, gutters, diagnostics, selections, and scroll-left stay on the existing semantic renderer path.
const std = @import("std");
const zz = @import("zigzag");
const semantic = @import("semantic.zig");
const zigzag_view_data = @import("zigzag_view_data.zig");

pub const PlainCodeRow = struct {
    text: []const u8,
};

/// Returns the number of BEAM-owned visible rows that fit through ZigZag `Viewport`.
pub fn visibleWindowRowCount(alloc: std.mem.Allocator, window: semantic.WindowContent) !usize {
    if (window.rows.len == 0 or window.text_height == 0) return 0;
    const source = try joinedRows(alloc, window.rows);
    var viewport = zz.Viewport.init(alloc, @max(window.text_width, 1), @max(window.text_height, 1));
    defer viewport.deinit();
    viewport.setWrap(false);
    try viewport.setContent(source);
    const rendered = try viewport.view(alloc);
    var count: usize = 1;
    for (rendered) |byte| {
        if (byte == '\n') count += 1;
    }
    return @min(count, window.rows.len);
}

/// Renders a plain unstyled editor row through ZigZag `CodeView` with line numbers and syntax highlighting disabled.
pub fn plainCodeRow(alloc: std.mem.Allocator, row: semantic.WindowRow) !PlainCodeRow {
    const code = zz.components.CodeView{
        .source = row.text,
        .language = .plain,
        .show_line_numbers = false,
    };
    const rendered = code.view(alloc);
    if (std.mem.indexOfScalar(u8, rendered, 0x1B) != null) return error.AnsiOutputUnsupported;
    return .{ .text = rendered };
}

/// Evidence from adapting one semantic editor window into ZigZag helpers.
pub const EditorBodyFit = struct {
    window_id: u16,
    row_count: usize,
    first_row_width: usize,
    viewport_width: usize,
    code_view_width: usize,
    styled_row_width: usize,
    ascii_span_ranges: bool,
    styled_ranges_safe: bool,

    /// Returns true when ZigZag helpers can consume the basic text rows without owning editor semantics.
    pub fn hasTextHelperCoverage(self: EditorBodyFit) bool {
        return self.row_count > 0 and self.first_row_width > 0 and (self.viewport_width > 0 or self.code_view_width > 0 or self.styled_row_width > 0);
    }
};

/// Builds ZigZag helper views from the active retained semantic editor window.
pub fn assessEditorBodyFit(alloc: std.mem.Allocator, state: *const semantic.State) !?EditorBodyFit {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    const view_data = zigzag_view_data.fromSemanticState(state, 120);
    const window = view_data.editor_window orelse return null;
    const source = try joinedRows(scratch, window.rows);
    const first_row = firstNonEmptyRow(window.rows) orelse return null;
    const ascii_span_ranges = rowHasAsciiSpanRanges(first_row);

    const viewport_width = try viewportViewWidth(scratch, source, window.text_width, window.text_height);
    const code_view_width = codeViewWidth(scratch, source);
    const styled_row_width = if (ascii_span_ranges) try styledRowWidth(scratch, first_row) else 0;

    return .{
        .window_id = window.window_id,
        .row_count = window.rows.len,
        .first_row_width = zz.width(first_row.text),
        .viewport_width = viewport_width,
        .code_view_width = code_view_width,
        .styled_row_width = styled_row_width,
        .ascii_span_ranges = ascii_span_ranges,
        .styled_ranges_safe = ascii_span_ranges,
    };
}

fn firstNonEmptyRow(rows: []const semantic.WindowRow) ?semantic.WindowRow {
    for (rows) |row| {
        if (row.text.len > 0) return row;
    }
    if (rows.len == 0) return null;
    return rows[0];
}

fn joinedRows(alloc: std.mem.Allocator, rows: []const semantic.WindowRow) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (rows, 0..) |row, index| {
        if (index > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(row.text);
    }
    return out.toOwnedSlice();
}

fn viewportViewWidth(alloc: std.mem.Allocator, source: []const u8, width: u16, height: u16) !usize {
    var viewport = zz.Viewport.init(alloc, @max(width, 1), @max(height, 1));
    defer viewport.deinit();
    viewport.setWrap(false);
    try viewport.setContent(source);
    const rendered = try viewport.view(alloc);
    return zz.width(rendered);
}

fn codeViewWidth(alloc: std.mem.Allocator, source: []const u8) usize {
    const code = zz.components.CodeView{
        .source = source,
        .language = .plain,
        .show_line_numbers = false,
    };
    const rendered = code.view(alloc);
    return zz.width(rendered);
}

fn styledRowWidth(alloc: std.mem.Allocator, row: semantic.WindowRow) !usize {
    const ranges = try styleRangesForRow(alloc, row);
    const styled = try zz.renderWithRanges(alloc, row.text, ranges);
    return zz.width(styled);
}

fn styleRangesForRow(alloc: std.mem.Allocator, row: semantic.WindowRow) ![]zz.StyleRange {
    var ranges = try alloc.alloc(zz.StyleRange, row.spans.len);
    for (row.spans, 0..) |span, index| {
        ranges[index] = .{
            .start = @min(span.start_col, row.text.len),
            .end = @min(span.end_col, row.text.len),
            .s = zigzag_view_data.styleFromSemantic(span.fg, span.bg, span.attrs),
        };
    }
    return ranges;
}

fn rowHasAsciiSpanRanges(row: semantic.WindowRow) bool {
    const codepoint_count = std.unicode.utf8CountCodepoints(row.text) catch return false;
    return codepoint_count == row.text.len;
}

test "Viewport adapter derives visible editor row count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rows = try alloc.alloc(semantic.WindowRow, 3);
    rows[0] = .{ .text = try alloc.dupe(u8, "one") };
    rows[1] = .{ .text = try alloc.dupe(u8, "two") };
    rows[2] = .{ .text = try alloc.dupe(u8, "three") };
    const count = try visibleWindowRowCount(alloc, .{ .text_width = 20, .text_height = 2, .rows = rows });
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "CodeView adapter renders plain editor row without ANSI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const row = try plainCodeRow(alloc, .{ .text = try alloc.dupe(u8, "plain text") });
    try std.testing.expectEqualStrings("plain text", row.text);
    try std.testing.expect(std.mem.indexOfScalar(u8, row.text, 0x1B) == null);
}

test "ZigZag editor helpers consume full editor fixture text without runtime ownership" {
    const alloc = std.testing.allocator;
    const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/full_editor.bin", alloc, .limited(1024 * 1024));
    defer alloc.free(fixture);

    var state = try zigzag_view_data.decodeFixtureState(alloc, fixture);
    defer state.deinit();

    const fit = (try assessEditorBodyFit(alloc, &state)).?;
    try std.testing.expect(fit.hasTextHelperCoverage());
    try std.testing.expectEqual(state.windows[0].window_id, fit.window_id);
    try std.testing.expectEqual(state.windows[0].rows.len, fit.row_count);
    try std.testing.expect(fit.ascii_span_ranges);
    try std.testing.expect(fit.styled_ranges_safe);
    try std.testing.expect(fit.styled_row_width >= fit.first_row_width);
}

test "ZigZag unicode measurement covers wide and combining editor text but spans remain semantic" {
    const alloc = std.testing.allocator;
    const text = "a界e\u{301}";
    try std.testing.expectEqual(@as(usize, 4), zz.width(text));

    var rows = try alloc.alloc(semantic.WindowRow, 1);
    rows[0] = .{
        .text = try alloc.dupe(u8, text),
        .spans = try alloc.dupe(semantic.WindowSpan, &.{.{ .start_col = 1, .end_col = 3, .fg = 0xabcdef }}),
    };

    var state = semantic.State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.dupe(semantic.WindowContent, &.{.{
        .window_id = 42,
        .text_width = 20,
        .text_height = 1,
        .rows = rows,
    }});

    const fit = (try assessEditorBodyFit(alloc, &state)).?;
    try std.testing.expect(fit.hasTextHelperCoverage());
    try std.testing.expectEqual(@as(u16, 42), fit.window_id);
    try std.testing.expect(!fit.ascii_span_ranges);
    try std.testing.expect(!fit.styled_ranges_safe);
    try std.testing.expectEqual(@as(usize, 0), fit.styled_row_width);
}
