/// Surface — abstract rendering interface for backend-independent drawing.
///
/// A Surface represents a grid of cells that can be drawn to. The TUI backend
/// implements this by wrapping libvaxis; a future GPU backend would implement
/// it with Metal/OpenGL draw calls.
///
/// Backends implement the required methods and are selected at comptime via
/// `Renderer(SurfaceT)` generic parameterization.
///
/// Required methods for a Surface implementation:
///   fn clear(*Self) void
///   fn writeCell(*Self, col: u16, row: u16, Cell) void
///   fn showCursor(*Self, col: u16, row: u16) void
///   fn setCursorShape(*Self, CursorShape) void
///   fn render(*Self) Error!void
///   fn width(*Self) u16
///   fn height(*Self) u16

const protocol = @import("protocol.zig");

/// Cursor shape, matching the port protocol values.
pub const CursorShape = protocol.CursorShape;

/// A single styled cell for rendering. Backend-independent — each Surface
/// implementation maps this to its native representation.
pub const Cell = struct {
    /// UTF-8 encoded grapheme cluster. The slice must remain valid until
    /// the next `render()` call (the renderer's arena guarantees this).
    grapheme: []const u8 = "",

    /// Display width in terminal columns (1 for most characters, 2 for
    /// CJK/emoji). 0 means the backend should measure it.
    width: u16 = 1,

    /// Foreground color as 24-bit RGB. 0 = default/terminal foreground.
    fg: u24 = 0,

    /// Background color as 24-bit RGB. 0 = default/terminal background.
    bg: u24 = 0,

    /// Style attribute flags (bold, italic, underline, reverse).
    /// Uses protocol.ATTR_* constants.
    attrs: u8 = 0,
};

/// Validates at comptime that a type implements the Surface interface.
/// Call as: `comptime { surface.assertSurface(@TypeOf(my_surface)); }`
pub fn assertSurface(comptime T: type) void {
    if (!@hasDecl(T, "clear")) @compileError("Surface missing method: clear");
    if (!@hasDecl(T, "fillBg")) @compileError("Surface missing method: fillBg");
    if (!@hasDecl(T, "writeCell")) @compileError("Surface missing method: writeCell");
    if (!@hasDecl(T, "showCursor")) @compileError("Surface missing method: showCursor");
    if (!@hasDecl(T, "setCursorShape")) @compileError("Surface missing method: setCursorShape");
    if (!@hasDecl(T, "render")) @compileError("Surface missing method: render");
    if (!@hasDecl(T, "width")) @compileError("Surface missing method: width");
    if (!@hasDecl(T, "height")) @compileError("Surface missing method: height");
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Cell default values" {
    const cell = Cell{};
    const std = @import("std");
    try std.testing.expectEqual(@as(u16, 1), cell.width);
    try std.testing.expectEqual(@as(u24, 0), cell.fg);
    try std.testing.expectEqual(@as(u24, 0), cell.bg);
    try std.testing.expectEqual(@as(u8, 0), cell.attrs);
    try std.testing.expectEqualStrings("", cell.grapheme);
}

test "Cell with values" {
    const cell = Cell{
        .grapheme = "A",
        .width = 1,
        .fg = 0xFF0000,
        .bg = 0x00FF00,
        .attrs = protocol.ATTR_BOLD | protocol.ATTR_ITALIC,
    };
    const std = @import("std");
    try std.testing.expectEqualStrings("A", cell.grapheme);
    try std.testing.expectEqual(@as(u24, 0xFF0000), cell.fg);
    try std.testing.expect(cell.attrs & protocol.ATTR_BOLD != 0);
    try std.testing.expect(cell.attrs & protocol.ATTR_ITALIC != 0);
}
