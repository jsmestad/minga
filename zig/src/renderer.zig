/// Renderer — translates port protocol commands into Surface draw calls.
///
/// Generic over a Surface type, enabling backend-independent rendering.
/// The TUI backend provides a VaxisSurface; a future GPU backend would
/// provide a MetalSurface, etc.
///
/// Memory: grapheme byte slices from Port messages are short-lived (the
/// message buffer is reused between commands). The renderer copies each
/// grapheme into an arena that is reset after every `batch_end` render,
/// ensuring cell grapheme slices remain valid until render() finishes.
const std = @import("std");
const vaxis = @import("vaxis");
const protocol = @import("protocol.zig");
const surface_mod = @import("surface.zig");
const Cell = surface_mod.Cell;

/// Creates a Renderer bound to a specific Surface implementation.
///
/// The Surface type must implement the interface defined in surface.zig:
///   clear, writeCell, showCursor, setCursorShape, render, width, height
pub fn Renderer(comptime SurfaceT: type) type {
    // Validate the surface interface at comptime.
    comptime surface_mod.assertSurface(SurfaceT);

    return struct {
        const Self = @This();

        surface: *SurfaceT,
        arena: std.heap.ArenaAllocator,
        /// Active region for coordinate offset/clipping. null = root (no offset).
        active_region: ?protocol.Region = null,
        /// All defined regions, keyed by region ID.
        regions: std.AutoHashMap(u16, protocol.Region),
        /// Default background color for cells that don't specify one (bg=0).
        /// Set via set_default_bg / set_window_bg. 0 = use terminal default.
        default_bg: u24 = 0,

        /// Initialize a renderer bound to a surface.
        /// `alloc` backs the internal arena used for grapheme byte copies.
        pub fn init(s: *SurfaceT, alloc: std.mem.Allocator) Self {
            return .{
                .surface = s,
                .arena = std.heap.ArenaAllocator.init(alloc),
                .regions = std.AutoHashMap(u16, protocol.Region).init(alloc),
            };
        }

        /// Free all arena memory.
        pub fn deinit(self: *Self) void {
            self.regions.deinit();
            self.arena.deinit();
        }

        /// Process a single render command.
        pub fn handleCommand(self: *Self, cmd: protocol.RenderCommand) !void {
            switch (cmd) {
                .clear => {
                    self.surface.clear();
                    // Safe to discard pending grapheme copies when the screen is cleared.
                    _ = self.arena.reset(.retain_capacity);
                },

                .draw_text => |dt| {
                    // Apply region offset and clipping.
                    var abs_row = dt.row;
                    var abs_col = dt.col;
                    var max_col: u16 = self.surface.width();

                    if (self.active_region) |region| {
                        abs_row +|= region.row;
                        abs_col +|= region.col;
                        // Clip to region bounds: row out of range, skip.
                        if (abs_row >= region.row +| region.height) return;
                        max_col = @min(self.surface.width(), region.col +| region.width);
                    }

                    var col: u16 = abs_col;

                    // Iterate over the text grapheme by grapheme and write each
                    // one as a separate cell.
                    var iter = vaxis.unicode.graphemeIterator(dt.text);

                    while (iter.next()) |grapheme| {
                        if (col >= max_col) break;

                        const raw = grapheme.bytes(dt.text);

                        // Copy bytes to arena-backed memory so the cell slice
                        // outlives the message buffer.
                        const stable = try self.arena.allocator().dupe(u8, raw);

                        // Compute display width.
                        const w: u16 = vaxis.gwidth.gwidth(stable, .wcwidth);

                        // Use the default bg when the command doesn't
                        // specify one (bg=0), so the theme background
                        // shows through instead of the terminal default.
                        const effective_bg = if (dt.bg == 0) self.default_bg else dt.bg;

                        self.surface.writeCell(col, abs_row, .{
                            .grapheme = stable,
                            .width = @intCast(if (w == 0) 1 else w),
                            .fg = dt.fg,
                            .bg = effective_bg,
                            .attrs = dt.attrs,
                        });

                        col +|= if (w == 0) 1 else w;
                    }
                },

                .set_cursor => |sc| {
                    self.surface.showCursor(sc.col, sc.row);
                },

                .set_cursor_shape => |shape| {
                    self.surface.setCursorShape(shape);
                },

                .batch_end => {
                    try self.surface.render();
                    // After render() all grapheme slices have been consumed —
                    // reset the arena for the next batch.
                    _ = self.arena.reset(.retain_capacity);
                },

                .set_title => |title| {
                    // Set terminal window title via OSC 0
                    self.surface.tty_writer.print("\x1b]0;{s}\x07", .{title}) catch {};
                },

                .define_region => |region| {
                    self.regions.put(region.id, region) catch {};
                },

                .clear_region => |id| {
                    if (self.regions.get(id)) |region| {
                        self.clearRegionArea(region);
                    }
                },

                .destroy_region => |id| {
                    if (self.regions.get(id)) |region| {
                        self.clearRegionArea(region);
                    }
                    _ = self.regions.remove(id);
                    // If the destroyed region was active, reset to root.
                    if (self.active_region) |ar| {
                        if (ar.id == id) self.active_region = null;
                    }
                },

                .set_active_region => |id| {
                    if (id == 0) {
                        self.active_region = null;
                    } else {
                        self.active_region = self.regions.get(id);
                    }
                },

                .set_default_bg => |bg| {
                    self.default_bg = bg;
                },

                // edit_buffer, measure_text and highlight commands are handled by the event loop, not the renderer.
                .noop, .edit_buffer, .measure_text, .set_language, .parse_buffer, .set_highlight_query, .set_injection_query, .load_grammar, .query_language_at => {},
            }
        }

        /// Clear all cells within a region's bounds to blank.
        fn clearRegionArea(self: *Self, region: protocol.Region) void {
            var r: u16 = region.row;
            const row_end = region.row +| region.height;
            const col_end = region.col +| region.width;
            while (r < row_end) : (r += 1) {
                var c: u16 = region.col;
                while (c < col_end) : (c += 1) {
                    self.surface.writeCell(c, r, .{
                        .grapheme = " ",
                        .width = 1,
                        .fg = 0,
                        .bg = 0,
                        .attrs = 0,
                    });
                }
            }
        }
    };
}

// ── Mock Surface for testing ──────────────────────────────────────────────────

/// A mock Surface that records calls for test verification.
const MockSurface = struct {
    clear_count: usize = 0,
    render_count: usize = 0,
    last_cursor_col: u16 = 0,
    last_cursor_row: u16 = 0,
    last_cursor_shape: surface_mod.CursorShape = .block,
    cells_written: usize = 0,
    last_cell: ?Cell = null,
    mock_width: u16 = 80,
    mock_height: u16 = 24,
    /// No-op writer that discards all output (satisfies set_title).
    tty_writer: NullWriter = .{},

    const NullWriter = struct {
        pub fn print(self: *NullWriter, comptime fmt: []const u8, args: anytype) !void {
            _ = self;
            _ = fmt;
            _ = args;
        }
    };

    pub fn clear(self: *MockSurface) void {
        self.clear_count += 1;
    }

    pub fn writeCell(self: *MockSurface, _: u16, _: u16, cell: Cell) void {
        self.cells_written += 1;
        self.last_cell = cell;
    }

    pub fn showCursor(self: *MockSurface, col: u16, row: u16) void {
        self.last_cursor_col = col;
        self.last_cursor_row = row;
    }

    pub fn setCursorShape(self: *MockSurface, shape: surface_mod.CursorShape) void {
        self.last_cursor_shape = shape;
    }

    pub fn render(self: *MockSurface) !void {
        self.render_count += 1;
    }

    pub fn width(self: *MockSurface) u16 {
        return self.mock_width;
    }

    pub fn height(self: *MockSurface) u16 {
        return self.mock_height;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "handleCommand clear calls surface.clear and resets arena" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    try rend.handleCommand(.clear);
    try std.testing.expectEqual(@as(usize, 1), mock.clear_count);
}

test "handleCommand set_cursor calls surface.showCursor" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    try rend.handleCommand(.{ .set_cursor = .{ .row = 5, .col = 10 } });
    try std.testing.expectEqual(@as(u16, 10), mock.last_cursor_col);
    try std.testing.expectEqual(@as(u16, 5), mock.last_cursor_row);
}

test "handleCommand set_cursor_shape calls surface.setCursorShape" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    try rend.handleCommand(.{ .set_cursor_shape = .beam });
    try std.testing.expectEqual(surface_mod.CursorShape.beam, mock.last_cursor_shape);
}

test "handleCommand batch_end calls surface.render" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    try rend.handleCommand(.batch_end);
    try std.testing.expectEqual(@as(usize, 1), mock.render_count);
}

test "handleCommand draw_text writes cells to surface" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    try rend.handleCommand(.{ .draw_text = .{
        .row = 0,
        .col = 0,
        .fg = 0xFFFFFF,
        .bg = 0x000000,
        .attrs = 0,
        .text = "hi",
    } });
    try std.testing.expectEqual(@as(usize, 2), mock.cells_written);
    // Last cell should be 'i'
    const cell = mock.last_cell.?;
    try std.testing.expectEqualStrings("i", cell.grapheme);
    try std.testing.expectEqual(@as(u24, 0xFFFFFF), cell.fg);
    try std.testing.expectEqual(@as(u24, 0x000000), cell.bg);
}

test "handleCommand draw_text respects surface width boundary" {
    var mock = MockSurface{ .mock_width = 3 };
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    try rend.handleCommand(.{ .draw_text = .{
        .row = 0,
        .col = 0,
        .fg = 0,
        .bg = 0,
        .attrs = 0,
        .text = "abcde", // 5 chars but width is 3
    } });
    try std.testing.expectEqual(@as(usize, 3), mock.cells_written);
}

test "handleCommand draw_text with empty text writes nothing" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    try rend.handleCommand(.{ .draw_text = .{
        .row = 0,
        .col = 0,
        .fg = 0,
        .bg = 0,
        .attrs = 0,
        .text = "",
    } });
    try std.testing.expectEqual(@as(usize, 0), mock.cells_written);
}

test "handleCommand draw_text passes attrs through to cell" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    const attrs = protocol.ATTR_BOLD | protocol.ATTR_ITALIC;
    try rend.handleCommand(.{ .draw_text = .{
        .row = 0,
        .col = 0,
        .fg = 0,
        .bg = 0,
        .attrs = attrs,
        .text = "x",
    } });
    const cell = mock.last_cell.?;
    try std.testing.expectEqual(attrs, cell.attrs);
}

test "set_default_bg stores default background" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    try std.testing.expectEqual(@as(u24, 0), rend.default_bg);
    try rend.handleCommand(.{ .set_default_bg = 0x282C34 });
    try std.testing.expectEqual(@as(u24, 0x282C34), rend.default_bg);
}

test "draw_text with bg=0 uses default_bg when set" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    // Set default bg to the theme color
    try rend.handleCommand(.{ .set_default_bg = 0x282C34 });

    // Draw text without an explicit bg (bg=0)
    try rend.handleCommand(.{ .draw_text = .{
        .row = 0,
        .col = 0,
        .fg = 0xFFFFFF,
        .bg = 0,
        .attrs = 0,
        .text = "A",
    } });

    const cell = mock.last_cell.?;
    // Cell should use the default bg, not 0
    try std.testing.expectEqual(@as(u24, 0x282C34), cell.bg);
}

test "draw_text with explicit bg ignores default_bg" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    try rend.handleCommand(.{ .set_default_bg = 0x282C34 });

    // Draw text with an explicit bg
    try rend.handleCommand(.{ .draw_text = .{
        .row = 0,
        .col = 0,
        .fg = 0xFFFFFF,
        .bg = 0x123456,
        .attrs = 0,
        .text = "B",
    } });

    const cell = mock.last_cell.?;
    // Cell should use the explicit bg, not default
    try std.testing.expectEqual(@as(u24, 0x123456), cell.bg);
}

test "clear then draw_text then batch_end full sequence" {
    var mock = MockSurface{};
    var rend = Renderer(MockSurface).init(&mock, std.testing.allocator);
    defer rend.deinit();

    try rend.handleCommand(.clear);
    try rend.handleCommand(.{ .draw_text = .{
        .row = 0,
        .col = 0,
        .fg = 0xABCDEF,
        .bg = 0x123456,
        .attrs = 0,
        .text = "hello",
    } });
    try rend.handleCommand(.{ .set_cursor = .{ .row = 0, .col = 3 } });
    try rend.handleCommand(.batch_end);

    try std.testing.expectEqual(@as(usize, 1), mock.clear_count);
    try std.testing.expectEqual(@as(usize, 5), mock.cells_written);
    try std.testing.expectEqual(@as(u16, 3), mock.last_cursor_col);
    try std.testing.expectEqual(@as(usize, 1), mock.render_count);
}
