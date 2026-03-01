/// GUI backend — native macOS window via Swift/AppKit bridge.
///
/// Implements the AppRuntime lifecycle (init/run/deinit) and provides
/// a GuiSurface that implements the Surface interface. For this initial
/// version, render() is a no-op (solid background in Swift). Text
/// rendering via Metal comes in #63.
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
const Cell = surface_mod.Cell;

// ── C imports (Swift bridge) ──────────────────────────────────────────────────

const c = @cImport({
    @cInclude("minga_gui.h");
});

// ── Constants ─────────────────────────────────────────────────────────────────

/// Hardcoded cell dimensions in pixels until font loading (#61).
const CELL_WIDTH: u16 = 8;
const CELL_HEIGHT: u16 = 16;

/// Default window dimensions in pixels.
const DEFAULT_WINDOW_WIDTH: u16 = 800;
const DEFAULT_WINDOW_HEIGHT: u16 = 600;

// ── Global runtime pointer ────────────────────────────────────────────────────
// C-ABI callbacks from Swift need access to the runtime. Zig exports
// cannot capture closures, so we use a global pointer. Only one runtime
// instance exists per process.

var g_runtime: ?*GuiRuntime = null;

// ── GuiSurface ────────────────────────────────────────────────────────────────

/// Surface implementation backed by an in-memory cell grid.
/// For this issue, render() is a no-op — the Swift side draws a solid
/// background. In #63, render() will upload the cell grid to a Metal
/// texture and present.
pub const GuiSurface = struct {
    grid: []Cell,
    grid_width: u16,
    grid_height: u16,
    cursor_col: u16 = 0,
    cursor_row: u16 = 0,
    cursor_shape: surface_mod.CursorShape = .block,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !GuiSurface {
        const size = @as(usize, cols) * @as(usize, rows);
        const grid = try alloc.alloc(Cell, size);
        @memset(grid, Cell{});

        return .{
            .grid = grid,
            .grid_width = cols,
            .grid_height = rows,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *GuiSurface) void {
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

    pub fn render(_: *GuiSurface) !void {
        // No-op for now. In #63, this will trigger Metal rendering:
        // upload cell grid to GPU buffer, draw instanced quads, present.
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

// ── GuiRuntime ────────────────────────────────────────────────────────────────

/// GUI application runtime — owns the surface, renderer, stdout, and
/// coordinates between the background stdin thread and the main AppKit thread.
pub const GuiRuntime = struct {
    alloc: std.mem.Allocator,
    surface: GuiSurface,
    rend: renderer_mod.Renderer(GuiSurface),
    stdout_mutex: std.Thread.Mutex = .{},
    quit: std.atomic.Value(bool) = .init(false),
    stdin_thread: ?std.Thread = null,

    // Stdout writer — initialized in run().
    stdout_buf: [4096]u8 = undefined,

    pub fn init(alloc: std.mem.Allocator) !GuiRuntime {
        const cols = DEFAULT_WINDOW_WIDTH / CELL_WIDTH;
        const rows = DEFAULT_WINDOW_HEIGHT / CELL_HEIGHT;

        var self: GuiRuntime = undefined;
        self.alloc = alloc;
        self.stdout_mutex = .{};
        self.quit = .init(false);
        self.stdin_thread = null;
        self.stdout_buf = undefined;

        self.surface = try GuiSurface.init(alloc, cols, rows);
        self.rend = renderer_mod.Renderer(GuiSurface).init(&self.surface, alloc);

        return self;
    }

    pub fn run(self: *GuiRuntime) !void {
        // Fix up internal pointers after struct has been moved to its final location.
        self.rend.surface = &self.surface;

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
    }

    // ── Stdout (Port protocol output) ─────────────────────────────────────

    /// Write a Port protocol message to stdout (thread-safe).
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
            // Poll stdin with a 1-second timeout so we check quit regularly.
            var pollfds = [1]std.posix.pollfd{
                .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = try std.posix.poll(&pollfds, 1000);

            if (pollfds[0].revents & std.posix.POLL.IN != 0) {
                var len_buf: [4]u8 = undefined;
                if (!try readExact(stdin_fd, &len_buf)) {
                    // EOF — BEAM closed the port.
                    self.quit.store(true, .release);
                    // TODO: post NSApp.terminate from here
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

                // Decode and dispatch render commands.
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

            // Check for stdin HUP/error.
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

    // Resize the surface grid.
    rt.surface.resize(width_cells, height_cells) catch |err| {
        std.log.warn("failed to resize surface: {}", .{err});
        return;
    };

    // Send resize event to BEAM.
    var buf: [5]u8 = undefined;
    const len = protocol.encodeResize(&buf, width_cells, height_cells) catch return;
    rt.writeStdout(buf[0..len]) catch |err| {
        std.log.warn("failed to write resize event: {}", .{err});
    };
}

export fn minga_on_window_close() void {
    const rt = g_runtime orelse return;
    rt.quit.store(true, .release);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Read exactly `buf.len` bytes from `fd`, blocking until done.
/// Returns `false` on EOF, `true` when all bytes are read.
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

    // Should not crash or corrupt memory.
    surf.writeCell(10, 0, Cell{ .grapheme = "A" }); // col out of bounds
    surf.writeCell(0, 5, Cell{ .grapheme = "B" }); // row out of bounds
    surf.writeCell(100, 100, Cell{ .grapheme = "C" }); // both out of bounds

    // All cells should still be default.
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

test "GuiSurface render is no-op (does not error)" {
    var surf = try GuiSurface.init(std.testing.allocator, 80, 24);
    defer surf.deinit();

    try surf.render(); // Should succeed silently.
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
    try std.testing.expectEqual(old_ptr, surf.grid.ptr); // No reallocation.
}

test "GuiSurface resize to zero dimensions is no-op" {
    var surf = try GuiSurface.init(std.testing.allocator, 80, 24);
    defer surf.deinit();

    try surf.resize(0, 24);
    try std.testing.expectEqual(@as(u16, 80), surf.width()); // Unchanged.
    try surf.resize(80, 0);
    try std.testing.expectEqual(@as(u16, 24), surf.height()); // Unchanged.
}

test "GuiSurface default cursor values" {
    var surf = try GuiSurface.init(std.testing.allocator, 80, 24);
    defer surf.deinit();

    try std.testing.expectEqual(@as(u16, 0), surf.cursor_col);
    try std.testing.expectEqual(@as(u16, 0), surf.cursor_row);
    try std.testing.expectEqual(surface_mod.CursorShape.block, surf.cursor_shape);
}
