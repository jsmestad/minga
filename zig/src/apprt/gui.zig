/// GUI backend — native macOS window via Swift/AppKit + Metal bridge.
///
/// Implements the AppRuntime lifecycle (init/run/deinit) and provides
/// a GuiSurface that implements the Surface interface. On render(),
/// the cell grid is converted to GPU cell data and sent to Swift for
/// Metal rendering.
///
/// Threading model:
///   Main thread: NSRunLoop (AppKit events) — entered via minga_gui_start()
///   Background thread: reads stdin Port commands → renderer
///
/// Communication with Swift is via C-ABI functions declared in minga_gui.h.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../protocol.zig");
const renderer_mod = @import("../renderer.zig");
const surface_mod = @import("../surface.zig");
const font_mod = @import("../font/main.zig");
const Cell = surface_mod.Cell;

// ── C imports (Swift bridge) ──────────────────────────────────────────────────

const c = @cImport({
    @cInclude("minga_gui.h");
});

// ── Constants ─────────────────────────────────────────────────────────────────

/// Default window dimensions in pixels.
const DEFAULT_WINDOW_WIDTH: u16 = 800;
const DEFAULT_WINDOW_HEIGHT: u16 = 600;

/// Default font settings.
const DEFAULT_FONT_NAME = "Menlo";
const DEFAULT_FONT_SIZE: f64 = 14.0;

// ── Global runtime pointer ────────────────────────────────────────────────────

var g_runtime: ?*GuiRuntime = null;

// ── GPU cell data (must match MingaCellGPU in minga_gui.h) ────────────────────

const CellGPU = extern struct {
    uv_origin: [2]f32 = .{ 0, 0 },
    uv_size: [2]f32 = .{ 0, 0 },
    glyph_size: [2]f32 = .{ 0, 0 },
    glyph_offset: [2]f32 = .{ 0, 0 },
    fg_color: [3]f32 = .{ 1, 1, 1 },
    bg_color: [3]f32 = .{ 0.12, 0.12, 0.14 },
    grid_pos: [2]f32 = .{ 0, 0 },
    has_glyph: f32 = 0,
};

// ── GuiSurface ────────────────────────────────────────────────────────────────

/// Surface implementation backed by an in-memory cell grid.
/// On render(), converts the grid to GPU cell data and calls into Swift
/// for Metal rendering.
pub const GuiSurface = struct {
    grid: []Cell,
    grid_width: u16,
    grid_height: u16,
    cursor_col: u16 = 0,
    cursor_row: u16 = 0,
    cursor_shape: surface_mod.CursorShape = .block,
    cursor_visible: bool = true,
    alloc: std.mem.Allocator,

    /// Font face for glyph lookup during render.
    face: ?*font_mod.Face = null,

    /// GPU cell buffer — reused between frames.
    gpu_cells: []CellGPU = &.{},

    /// Track whether atlas has been uploaded.
    atlas_version: usize = 0,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !GuiSurface {
        const size = @as(usize, cols) * @as(usize, rows);
        const grid = try alloc.alloc(Cell, size);
        @memset(grid, Cell{});

        const gpu_cells = try alloc.alloc(CellGPU, size);
        @memset(gpu_cells, CellGPU{});

        return .{
            .grid = grid,
            .grid_width = cols,
            .grid_height = rows,
            .alloc = alloc,
            .gpu_cells = gpu_cells,
        };
    }

    pub fn deinit(self: *GuiSurface) void {
        if (self.gpu_cells.len > 0) self.alloc.free(self.gpu_cells);
        self.alloc.free(self.grid);
    }

    pub fn clear(self: *GuiSurface) void {
        @memset(self.grid, Cell{});
    }

    pub fn writeCell(self: *GuiSurface, col: u16, row: u16, cell: Cell) void {
        if (col >= self.grid_width or row >= self.grid_height) return;
        const idx = @as(usize, row) * @as(usize, self.grid_width) + @as(usize, col);
        self.grid[idx] = cell;
    }

    pub fn showCursor(self: *GuiSurface, col: u16, row: u16) void {
        self.cursor_col = col;
        self.cursor_row = row;
    }

    pub fn setCursorShape(self: *GuiSurface, shape: surface_mod.CursorShape) void {
        self.cursor_shape = shape;
    }

    pub fn render(self: *GuiSurface) !void {
        const face = self.face orelse return;
        const cell_w: f32 = @floatFromInt(face.cell_width);
        const cell_h: f32 = @floatFromInt(face.cell_height);
        const atlas_size_f: f32 = @floatFromInt(face.atlas.size);

        // Re-upload atlas if it changed.
        if (face.atlas.modified != self.atlas_version) {
            c.minga_upload_atlas(
                face.atlas.data.ptr,
                face.atlas.size,
                face.atlas.size,
            );
            self.atlas_version = face.atlas.modified;
        }

        // Build GPU cell buffer.
        const count = @as(usize, self.grid_width) * @as(usize, self.grid_height);
        if (self.gpu_cells.len != count) {
            if (self.gpu_cells.len > 0) self.alloc.free(self.gpu_cells);
            self.gpu_cells = try self.alloc.alloc(CellGPU, count);
        }

        for (0..count) |i| {
            const row: u16 = @intCast(i / self.grid_width);
            const col: u16 = @intCast(i % self.grid_width);
            const cell = self.grid[i];

            var gpu = CellGPU{
                .grid_pos = .{ @floatFromInt(col), @floatFromInt(row) },
                .bg_color = colorFromU24(cell.bg),
                .fg_color = colorFromU24(cell.fg),
            };

            // Look up glyph if cell has content.
            if (cell.grapheme.len > 0 and cell.grapheme[0] != 0) {
                // Decode first codepoint from UTF-8 grapheme.
                const seq_len = std.unicode.utf8ByteSequenceLength(cell.grapheme[0]) catch 1;
                const decode_len = @min(seq_len, cell.grapheme.len);
                const cp: u32 = @intCast(std.unicode.utf8Decode(cell.grapheme[0..decode_len]) catch ' ');

                if (face.getGlyph(cp)) |glyph| {
                    gpu.has_glyph = 1.0;
                    gpu.uv_origin = .{
                        @as(f32, @floatFromInt(glyph.atlas_x)) / atlas_size_f,
                        @as(f32, @floatFromInt(glyph.atlas_y)) / atlas_size_f,
                    };
                    gpu.uv_size = .{
                        @as(f32, @floatFromInt(glyph.width)) / atlas_size_f,
                        @as(f32, @floatFromInt(glyph.height)) / atlas_size_f,
                    };
                    gpu.glyph_size = .{
                        @as(f32, @floatFromInt(glyph.width)),
                        @as(f32, @floatFromInt(glyph.height)),
                    };
                    // Bearing: offset_x is horizontal, offset_y is from baseline (top-down).
                    const baseline_y: f32 = @floatCast(face.loader.ascent);
                    gpu.glyph_offset = .{
                        @as(f32, @floatFromInt(glyph.offset_x)),
                        baseline_y - @as(f32, @floatFromInt(glyph.offset_y)),
                    };
                } else |_| {}
            }

            self.gpu_cells[i] = gpu;
        }

        // Call into Swift to do the Metal draw.
        c.minga_render_frame(
            @ptrCast(self.gpu_cells.ptr),
            @intCast(count),
            cell_w,
            cell_h,
            self.cursor_col,
            self.cursor_row,
            if (self.cursor_visible) 1 else 0,
        );
    }

    pub fn width(self: *GuiSurface) u16 {
        return self.grid_width;
    }

    pub fn height(self: *GuiSurface) u16 {
        return self.grid_height;
    }

    /// Resize the cell grid. Allocates a new grid and frees the old one.
    pub fn resize(self: *GuiSurface, new_cols: u16, new_rows: u16) !void {
        if (new_cols == self.grid_width and new_rows == self.grid_height) return;
        if (new_cols == 0 or new_rows == 0) return;

        const new_size = @as(usize, new_cols) * @as(usize, new_rows);
        const new_grid = try self.alloc.alloc(Cell, new_size);
        @memset(new_grid, Cell{});

        self.alloc.free(self.grid);
        self.grid = new_grid;
        self.grid_width = new_cols;
        self.grid_height = new_rows;
    }
};

// ── Color helpers ─────────────────────────────────────────────────────────────

/// Convert a 24-bit RGB color to 3 floats. 0 maps to the default dark bg/white fg.
fn colorFromU24(color: u24) [3]f32 {
    if (color == 0) return .{ 0.12, 0.12, 0.14 }; // default background
    const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;
    return .{ r, g, b };
}

// ── GuiRuntime ────────────────────────────────────────────────────────────────

/// GUI application runtime — owns the surface, renderer, font, stdout, and
/// coordinates between the background stdin thread and the main AppKit thread.
pub const GuiRuntime = struct {
    alloc: std.mem.Allocator,
    surface: GuiSurface,
    rend: renderer_mod.Renderer(GuiSurface),
    face: font_mod.Face,
    stdout_mutex: std.Thread.Mutex = .{},
    quit: std.atomic.Value(bool) = .init(false),
    stdin_thread: ?std.Thread = null,
    stdout_buf: [4096]u8 = undefined,

    pub fn init(alloc: std.mem.Allocator) !GuiRuntime {
        // Load font first to get real cell metrics.
        var face = try font_mod.Face.init(alloc, DEFAULT_FONT_NAME, DEFAULT_FONT_SIZE);
        errdefer face.deinit();

        // Pre-rasterize ASCII glyphs.
        try face.preloadAscii();

        const cols = DEFAULT_WINDOW_WIDTH / @as(u16, @intCast(face.cell_width));
        const rows = DEFAULT_WINDOW_HEIGHT / @as(u16, @intCast(face.cell_height));

        var self: GuiRuntime = undefined;
        self.alloc = alloc;
        self.stdout_mutex = .{};
        self.quit = .init(false);
        self.stdin_thread = null;
        self.stdout_buf = undefined;
        self.face = face;

        self.surface = try GuiSurface.init(alloc, cols, rows);
        self.rend = renderer_mod.Renderer(GuiSurface).init(&self.surface, alloc);

        return self;
    }

    pub fn run(self: *GuiRuntime) !void {
        // Fix up internal pointers after struct has been moved to its final location.
        self.rend.surface = &self.surface;
        self.surface.face = &self.face;

        // Set global pointer for C-ABI callbacks.
        g_runtime = self;
        defer g_runtime = null;

        // Send ready event with initial dimensions.
        {
            const cols = self.surface.grid_width;
            const rows = self.surface.grid_height;
            var ready_payload: [5]u8 = undefined;
            const ready_len = try protocol.encodeReady(&ready_payload, cols, rows);
            try self.writeStdout(ready_payload[0..ready_len]);
        }

        // Spawn background thread for stdin Port command reading.
        self.stdin_thread = try std.Thread.spawn(.{}, stdinThreadFn, .{self});

        // Enter AppKit event loop. Blocks until NSApp.terminate().
        c.minga_gui_start(DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT);

        // After NSApp exits, signal and join stdin thread.
        self.quit.store(true, .release);
        if (self.stdin_thread) |thread| {
            thread.join();
        }
    }

    pub fn deinit(self: *GuiRuntime) void {
        self.rend.deinit();
        self.surface.deinit();
        self.face.deinit();
    }

    // ── Stdout (Port protocol output) ─────────────────────────────────────

    fn writeStdout(self: *GuiRuntime, payload: []const u8) !void {
        self.stdout_mutex.lock();
        defer self.stdout_mutex.unlock();

        const stdout_file = std.fs.File.stdout();
        const len: u32 = @intCast(payload.len);
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, len, .big);
        try stdout_file.writeAll(&len_buf);
        try stdout_file.writeAll(payload);
    }

    // ── Background stdin thread ───────────────────────────────────────────

    fn stdinThreadFn(self: *GuiRuntime) void {
        self.stdinLoop() catch |err| {
            std.log.err("stdin thread error: {}", .{err});
        };
    }

    fn stdinLoop(self: *GuiRuntime) !void {
        const stdin_fd = std.posix.STDIN_FILENO;
        var msg_buf: [65536]u8 = undefined;

        while (!self.quit.load(.acquire)) {
            var pollfds = [1]std.posix.pollfd{
                .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = try std.posix.poll(&pollfds, 1000);

            if (pollfds[0].revents & std.posix.POLL.IN != 0) {
                var len_buf: [4]u8 = undefined;
                if (!try readExact(stdin_fd, &len_buf)) {
                    self.quit.store(true, .release);
                    break;
                }

                const msg_len: usize = std.mem.readInt(u32, &len_buf, .big);
                if (msg_len == 0) continue;
                if (msg_len > msg_buf.len) {
                    std.log.err("Port message too large: {} bytes", .{msg_len});
                    break;
                }

                const payload = msg_buf[0..msg_len];
                if (!try readExact(stdin_fd, payload)) break;

                var offset: usize = 0;
                while (offset < msg_len) {
                    const remaining = payload[offset..];
                    const cmd = protocol.decodeCommand(remaining) catch |err| {
                        std.log.warn("protocol decode error at offset {}: {}", .{ offset, err });
                        break;
                    };
                    self.rend.handleCommand(cmd) catch |err| {
                        std.log.warn("renderer error: {}", .{err});
                    };
                    offset += protocol.commandSize(remaining);
                }
            }

            const hup_mask: i16 = std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;
            if (pollfds[0].revents & hup_mask != 0) {
                self.quit.store(true, .release);
                break;
            }
        }
    }
};

// ── C-ABI exports (called from Swift) ─────────────────────────────────────────

export fn minga_on_key_event(codepoint: u32, modifiers: u8) void {
    const rt = g_runtime orelse return;
    var buf: [6]u8 = undefined;
    const len = protocol.encodeKeyPress(&buf, codepoint, modifiers) catch return;
    rt.writeStdout(buf[0..len]) catch |err| {
        std.log.warn("failed to write key event: {}", .{err});
    };
}

export fn minga_on_mouse_event(row: i16, col: i16, button: u8, modifiers: u8, event_type: u8) void {
    const rt = g_runtime orelse return;
    var buf: [8]u8 = undefined;
    const len = protocol.encodeMouseEvent(&buf, row, col, button, modifiers, event_type) catch return;
    rt.writeStdout(buf[0..len]) catch |err| {
        std.log.warn("failed to write mouse event: {}", .{err});
    };
}

export fn minga_on_resize(width_cells: u16, height_cells: u16) void {
    const rt = g_runtime orelse return;

    rt.surface.resize(width_cells, height_cells) catch |err| {
        std.log.warn("failed to resize surface: {}", .{err});
        return;
    };

    var buf: [5]u8 = undefined;
    const len = protocol.encodeResize(&buf, width_cells, height_cells) catch return;
    rt.writeStdout(buf[0..len]) catch |err| {
        std.log.warn("failed to write resize event: {}", .{err});
    };
}

/// Returns a pointer to the embedded Metal shader source (null-terminated).
/// Called by Swift during Metal setup to compile shaders at runtime.
export fn minga_get_shader_source() [*:0]const u8 {
    return @ptrCast(@embedFile("../font/shaders.metal"));
}

export fn minga_on_window_close() void {
    const rt = g_runtime orelse return;
    rt.quit.store(true, .release);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn readExact(fd: std.posix.fd_t, buf: []u8) !bool {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(fd, buf[total..]);
        if (n == 0) return false;
        total += n;
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "GuiSurface init creates correct grid dimensions" {
    var surf = try GuiSurface.init(std.testing.allocator, 80, 24);
    defer surf.deinit();

    try std.testing.expectEqual(@as(u16, 80), surf.width());
    try std.testing.expectEqual(@as(u16, 24), surf.height());
    try std.testing.expectEqual(@as(usize, 80 * 24), surf.grid.len);
}

test "GuiSurface writeCell stores cell at correct position" {
    var surf = try GuiSurface.init(std.testing.allocator, 10, 5);
    defer surf.deinit();

    const cell = Cell{ .grapheme = "X", .fg = 0xFF0000, .bg = 0x00FF00, .attrs = 0x01 };
    surf.writeCell(3, 2, cell);

    const idx: usize = 2 * 10 + 3;
    try std.testing.expectEqualStrings("X", surf.grid[idx].grapheme);
    try std.testing.expectEqual(@as(u24, 0xFF0000), surf.grid[idx].fg);
    try std.testing.expectEqual(@as(u24, 0x00FF00), surf.grid[idx].bg);
    try std.testing.expectEqual(@as(u8, 0x01), surf.grid[idx].attrs);
}

test "GuiSurface writeCell out of bounds is a no-op" {
    var surf = try GuiSurface.init(std.testing.allocator, 10, 5);
    defer surf.deinit();

    surf.writeCell(10, 0, Cell{ .grapheme = "A" });
    surf.writeCell(0, 5, Cell{ .grapheme = "B" });
    surf.writeCell(100, 100, Cell{ .grapheme = "C" });

    for (surf.grid) |cell| {
        try std.testing.expectEqualStrings("", cell.grapheme);
    }
}

test "GuiSurface clear zeroes all cells" {
    var surf = try GuiSurface.init(std.testing.allocator, 5, 3);
    defer surf.deinit();

    surf.writeCell(1, 1, Cell{ .grapheme = "Z", .fg = 0xABCDEF });
    surf.clear();

    for (surf.grid) |cell| {
        try std.testing.expectEqualStrings("", cell.grapheme);
        try std.testing.expectEqual(@as(u24, 0), cell.fg);
    }
}

test "GuiSurface showCursor stores position" {
    var surf = try GuiSurface.init(std.testing.allocator, 80, 24);
    defer surf.deinit();

    surf.showCursor(15, 7);
    try std.testing.expectEqual(@as(u16, 15), surf.cursor_col);
    try std.testing.expectEqual(@as(u16, 7), surf.cursor_row);
}

test "GuiSurface setCursorShape stores shape" {
    var surf = try GuiSurface.init(std.testing.allocator, 80, 24);
    defer surf.deinit();

    surf.setCursorShape(.beam);
    try std.testing.expectEqual(surface_mod.CursorShape.beam, surf.cursor_shape);
}

test "GuiSurface resize changes grid dimensions" {
    var surf = try GuiSurface.init(std.testing.allocator, 80, 24);
    defer surf.deinit();

    try surf.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), surf.width());
    try std.testing.expectEqual(@as(u16, 40), surf.height());
    try std.testing.expectEqual(@as(usize, 120 * 40), surf.grid.len);
}

test "GuiSurface resize to same dimensions is no-op" {
    var surf = try GuiSurface.init(std.testing.allocator, 80, 24);
    defer surf.deinit();

    const old_ptr = surf.grid.ptr;
    try surf.resize(80, 24);
    try std.testing.expectEqual(old_ptr, surf.grid.ptr);
}

test "GuiSurface resize to zero dimensions is no-op" {
    var surf = try GuiSurface.init(std.testing.allocator, 80, 24);
    defer surf.deinit();

    try surf.resize(0, 24);
    try std.testing.expectEqual(@as(u16, 80), surf.width());
    try surf.resize(80, 0);
    try std.testing.expectEqual(@as(u16, 24), surf.height());
}

test "colorFromU24 converts correctly" {
    const white = colorFromU24(0xFFFFFF);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), white[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), white[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), white[2], 0.01);

    const red = colorFromU24(0xFF0000);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), red[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), red[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), red[2], 0.01);
}

test "CellGPU has expected size" {
    // 17 floats × 4 bytes = 68 bytes.
    try std.testing.expectEqual(@as(usize, 68), @sizeOf(CellGPU));
}
