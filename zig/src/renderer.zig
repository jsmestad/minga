/// Renderer — translates port protocol commands into libvaxis draw calls.
///
/// Receives decoded `RenderCommand` values from the protocol layer
/// and applies them to a libvaxis window. Calls `vaxis.render()` on
/// `batch_end` to flush changes to the terminal.
const std = @import("std");
const vaxis = @import("vaxis");
const protocol = @import("protocol.zig");

pub const Renderer = struct {
    vx: *vaxis.Vaxis,

    /// Initialize a renderer bound to a vaxis instance.
    pub fn init(vx: *vaxis.Vaxis) Renderer {
        return .{ .vx = vx };
    }

    /// Process a single render command.
    pub fn handleCommand(self: *Renderer, cmd: protocol.RenderCommand) !void {
        switch (cmd) {
            .clear => {
                const win = self.vx.window();
                win.clear();
            },
            .draw_text => |dt| {
                const win = self.vx.window();
                const style = buildStyle(dt.fg, dt.bg, dt.attrs);
                var col: usize = dt.col;

                // Write text grapheme by grapheme
                var iter = vaxis.Unicode.graphemeIterator(dt.text);
                while (iter.next()) |grapheme| {
                    if (col >= win.screen.width) break;
                    win.writeCell(.{
                        .column = col,
                        .row = .{ .grapheme = dt.row },
                    }, .{
                        .char = .{ .grapheme = grapheme.bytes(dt.text) },
                        .style = style,
                    });
                    col += grapheme.width;
                }
            },
            .set_cursor => |sc| {
                self.vx.setCursorPos(.{
                    .row = sc.row,
                    .col = sc.col,
                });
            },
            .batch_end => {
                try self.vx.render();
            },
        }
    }
};

/// Build a vaxis Style from protocol color/attribute values.
fn buildStyle(fg: u24, bg: u24, attrs: u8) vaxis.Cell.Style {
    var style: vaxis.Cell.Style = .{};

    // Set foreground color
    if (fg != 0) {
        style.fg = .{ .rgb = .{
            @as(u8, @intCast((fg >> 16) & 0xFF)),
            @as(u8, @intCast((fg >> 8) & 0xFF)),
            @as(u8, @intCast(fg & 0xFF)),
        } };
    }

    // Set background color
    if (bg != 0) {
        style.bg = .{ .rgb = .{
            @as(u8, @intCast((bg >> 16) & 0xFF)),
            @as(u8, @intCast((bg >> 8) & 0xFF)),
            @as(u8, @intCast(bg & 0xFF)),
        } };
    }

    // Set attributes
    if (attrs & protocol.ATTR_BOLD != 0) style.bold = true;
    if (attrs & protocol.ATTR_ITALIC != 0) style.italic = true;
    if (attrs & protocol.ATTR_UNDERLINE != 0) style.ul_style = .single;
    if (attrs & protocol.ATTR_REVERSE != 0) style.reverse = true;

    return style;
}

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
