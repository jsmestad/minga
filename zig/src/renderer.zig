/// Renderer — translates port protocol commands into libvaxis draw calls.
///
/// Receives decoded `RenderCommand` values from the protocol layer
/// and applies them to a libvaxis window. Calls `vaxis.render()` on
/// `batch_end` to flush changes to the terminal.
///
/// Memory: grapheme byte slices from Port messages are short-lived (the
/// message buffer is reused between commands). The renderer copies each
/// grapheme into an arena that is reset after every `batch_end` render,
/// ensuring the screen buffer's cell slices remain valid until render()
/// finishes consuming them.
const std = @import("std");
const vaxis = @import("vaxis");
const protocol = @import("protocol.zig");

pub const Renderer = struct {
    vx: *vaxis.Vaxis,
    tty_writer: *std.Io.Writer,
    arena: std.heap.ArenaAllocator,

    /// Initialize a renderer bound to a vaxis instance and tty writer.
    /// `alloc` backs the internal arena used for grapheme byte copies.
    pub fn init(vx: *vaxis.Vaxis, tty_writer: *std.Io.Writer, alloc: std.mem.Allocator) Renderer {
        return .{
            .vx = vx,
            .tty_writer = tty_writer,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    /// Free all arena memory.
    pub fn deinit(self: *Renderer) void {
        self.arena.deinit();
    }

    /// Process a single render command.
    pub fn handleCommand(self: *Renderer, cmd: protocol.RenderCommand) !void {
        switch (cmd) {
            .clear => {
                const win = self.vx.window();
                win.clear();
                // Safe to discard pending grapheme copies when the screen is cleared.
                _ = self.arena.reset(.retain_capacity);
            },

            .draw_text => |dt| {
                const win = self.vx.window();
                const style = buildStyle(dt.fg, dt.bg, dt.attrs);
                var col: u16 = dt.col;

                // Iterate over the text grapheme by grapheme and write each
                // one as a separate cell. We copy grapheme bytes into the
                // arena so they remain valid until the next batch_end render.
                var iter = vaxis.unicode.graphemeIterator(dt.text);
                while (iter.next()) |grapheme| {
                    if (col >= win.width) break;

                    const raw = grapheme.bytes(dt.text);

                    // Copy bytes to arena-backed memory so the cell slice
                    // outlives the message buffer.
                    const stable = try self.arena.allocator().dupe(u8, raw);

                    // Compute display width (0 → libvaxis measures at render time).
                    const w: u16 = vaxis.gwidth.gwidth(stable, .wcwidth);

                    win.writeCell(col, dt.row, .{
                        .char = .{
                            .grapheme = stable,
                            .width = @intCast(if (w == 0) 1 else w),
                        },
                        .style = style,
                    });

                    // Advance column, guarding against wrapping on unreasonably
                    // wide glyphs (practical terminal widths fit in u16).
                    col +|= if (w == 0) 1 else w;
                }
            },

            .set_cursor => |sc| {
                const win = self.vx.window();
                win.showCursor(sc.col, sc.row);
            },

            .set_cursor_shape => |shape| {
                const win = self.vx.window();
                win.setCursorShape(switch (shape) {
                    .block => .block,
                    .beam => .beam,
                    .underline => .underline,
                });
            },

            .batch_end => {
                try self.vx.render(self.tty_writer);
                // After render() all grapheme slices have been consumed —
                // reset the arena for the next batch.
                _ = self.arena.reset(.retain_capacity);
            },
        }
    }
};

/// Build a vaxis Style from protocol color/attribute values.
fn buildStyle(fg: u24, bg: u24, attrs: u8) vaxis.Cell.Style {
    var style: vaxis.Cell.Style = .{};

    // Set foreground color (0 means "default" in the protocol).
    if (fg != 0) {
        style.fg = .{ .rgb = .{
            @as(u8, @intCast((fg >> 16) & 0xFF)),
            @as(u8, @intCast((fg >> 8) & 0xFF)),
            @as(u8, @intCast(fg & 0xFF)),
        } };
    }

    // Set background color.
    if (bg != 0) {
        style.bg = .{ .rgb = .{
            @as(u8, @intCast((bg >> 16) & 0xFF)),
            @as(u8, @intCast((bg >> 8) & 0xFF)),
            @as(u8, @intCast(bg & 0xFF)),
        } };
    }

    // Map attribute flags.
    if (attrs & protocol.ATTR_BOLD != 0) style.bold = true;
    if (attrs & protocol.ATTR_ITALIC != 0) style.italic = true;
    if (attrs & protocol.ATTR_UNDERLINE != 0) style.ul_style = .single;
    if (attrs & protocol.ATTR_REVERSE != 0) style.reverse = true;

    return style;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "buildStyle with no attrs" {
    const style = buildStyle(0xFFFFFF, 0x000000, 0);
    try std.testing.expect(style.bold == false);
    try std.testing.expect(style.italic == false);
}

test "buildStyle with bold and italic" {
    const style = buildStyle(0, 0, protocol.ATTR_BOLD | protocol.ATTR_ITALIC);
    try std.testing.expect(style.bold == true);
    try std.testing.expect(style.italic == true);
}

test "buildStyle fg rgb encoding" {
    const style = buildStyle(0xFF8040, 0, 0);
    switch (style.fg) {
        .rgb => |rgb| {
            try std.testing.expectEqual(@as(u8, 0xFF), rgb[0]);
            try std.testing.expectEqual(@as(u8, 0x80), rgb[1]);
            try std.testing.expectEqual(@as(u8, 0x40), rgb[2]);
        },
        else => return error.UnexpectedColorKind,
    }
}

test "buildStyle underline and reverse" {
    const style = buildStyle(0, 0, protocol.ATTR_UNDERLINE | protocol.ATTR_REVERSE);
    try std.testing.expect(style.ul_style == .single);
    try std.testing.expect(style.reverse == true);
}

test "buildStyle with all attributes set (bold+italic+underline+reverse)" {
    const all = protocol.ATTR_BOLD | protocol.ATTR_ITALIC | protocol.ATTR_UNDERLINE | protocol.ATTR_REVERSE;
    const style = buildStyle(0, 0, all);
    try std.testing.expect(style.bold == true);
    try std.testing.expect(style.italic == true);
    try std.testing.expect(style.ul_style == .single);
    try std.testing.expect(style.reverse == true);
}

test "buildStyle with only bg color (fg=0)" {
    const style = buildStyle(0, 0x123456, 0);
    // fg should remain default (not rgb)
    try std.testing.expect(style.fg == .default);
    switch (style.bg) {
        .rgb => |rgb| {
            try std.testing.expectEqual(@as(u8, 0x12), rgb[0]);
            try std.testing.expectEqual(@as(u8, 0x34), rgb[1]);
            try std.testing.expectEqual(@as(u8, 0x56), rgb[2]);
        },
        else => return error.UnexpectedColorKind,
    }
}

test "buildStyle with only fg color (bg=0)" {
    const style = buildStyle(0xABCDEF, 0, 0);
    switch (style.fg) {
        .rgb => |rgb| {
            try std.testing.expectEqual(@as(u8, 0xAB), rgb[0]);
            try std.testing.expectEqual(@as(u8, 0xCD), rgb[1]);
            try std.testing.expectEqual(@as(u8, 0xEF), rgb[2]);
        },
        else => return error.UnexpectedColorKind,
    }
    // bg should remain default
    try std.testing.expect(style.bg == .default);
}

test "buildStyle default (all zeros) returns empty style" {
    const style = buildStyle(0, 0, 0);
    try std.testing.expect(style.fg == .default);
    try std.testing.expect(style.bg == .default);
    try std.testing.expect(style.bold == false);
    try std.testing.expect(style.italic == false);
    try std.testing.expect(style.ul_style == .off);
    try std.testing.expect(style.reverse == false);
}

test "buildStyle max color values (0xFFFFFF fg and bg)" {
    const style = buildStyle(0xFFFFFF, 0xFFFFFF, 0);
    switch (style.fg) {
        .rgb => |rgb| {
            try std.testing.expectEqual(@as(u8, 0xFF), rgb[0]);
            try std.testing.expectEqual(@as(u8, 0xFF), rgb[1]);
            try std.testing.expectEqual(@as(u8, 0xFF), rgb[2]);
        },
        else => return error.UnexpectedColorKind,
    }
    switch (style.bg) {
        .rgb => |rgb| {
            try std.testing.expectEqual(@as(u8, 0xFF), rgb[0]);
            try std.testing.expectEqual(@as(u8, 0xFF), rgb[1]);
            try std.testing.expectEqual(@as(u8, 0xFF), rgb[2]);
        },
        else => return error.UnexpectedColorKind,
    }
}

test "buildStyle bold only" {
    const style = buildStyle(0, 0, protocol.ATTR_BOLD);
    try std.testing.expect(style.bold == true);
    try std.testing.expect(style.italic == false);
    try std.testing.expect(style.ul_style == .off);
    try std.testing.expect(style.reverse == false);
}

test "buildStyle italic only" {
    const style = buildStyle(0, 0, protocol.ATTR_ITALIC);
    try std.testing.expect(style.bold == false);
    try std.testing.expect(style.italic == true);
    try std.testing.expect(style.ul_style == .off);
    try std.testing.expect(style.reverse == false);
}

test "buildStyle underline only" {
    const style = buildStyle(0, 0, protocol.ATTR_UNDERLINE);
    try std.testing.expect(style.bold == false);
    try std.testing.expect(style.italic == false);
    try std.testing.expect(style.ul_style == .single);
    try std.testing.expect(style.reverse == false);
}

test "buildStyle reverse only" {
    const style = buildStyle(0, 0, protocol.ATTR_REVERSE);
    try std.testing.expect(style.bold == false);
    try std.testing.expect(style.italic == false);
    try std.testing.expect(style.ul_style == .off);
    try std.testing.expect(style.reverse == true);
}
