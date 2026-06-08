/// ZigZag-backed TUI runtime.
///
/// This mirrors the Go/Bubble Tea renderer boundary: ZigZag owns terminal IO
/// and frame presentation on the TTY, stdout remains reserved for BEAM Port
/// packets, and BEAM semantic payloads remain the source of truth.
const std = @import("std");
const vaxis = @import("vaxis");
const zz = @import("zigzag");
const root = @import("../main.zig");
const protocol = @import("../protocol.zig");
const port_writer = @import("../port_writer.zig");
const recovery_mod = @import("../recovery.zig");
const semantic_mod = @import("../semantic.zig");
const surface_mod = @import("../surface.zig");

const Cell = surface_mod.Cell;
const arrow_left: u32 = 57_350;
const arrow_right: u32 = 57_351;
const arrow_up: u32 = 57_352;
const arrow_down: u32 = 57_353;

var g_quit: std.atomic.Value(bool) = .init(false);
var g_winch: std.atomic.Value(bool) = .init(false);

fn sigwinchHandler(_: std.posix.SIG) callconv(.c) void {
    g_winch.store(true, .release);
}

fn sigquitHandler(_: std.posix.SIG) callconv(.c) void {
    g_quit.store(true, .release);
}

/// TUI runtime backed by ZigZag Program and Terminal.
pub const TuiRuntime = struct {
    alloc: std.mem.Allocator,

    /// Initialize the TUI runtime.
    pub fn init(alloc: std.mem.Allocator) !TuiRuntime {
        return .{ .alloc = alloc };
    }

    /// Clean up runtime-owned resources.
    pub fn deinit(_: *TuiRuntime) void {}

    /// Run the ZigZag terminal adapter until stdin closes or the renderer exits.
    pub fn run(self: *TuiRuntime) !void {
        installSignalHandlers();

        const tty = try openTty();
        defer std.posix.close(tty.handle);
        const stdout_fd = std.posix.STDOUT_FILENO;

        var program = try zz.Program(MingaModel).initWithOptions(self.alloc, root.g_io, root.g_env_map, .{
            .mouse = true,
            .cursor = false,
            .alt_screen = true,
            .bracketed_paste = true,
            .kitty_keyboard = true,
            .input = tty,
            .output = tty,
            .title = "Minga",
        });
        defer program.deinit();

        try program.start();

        var pw = try port_writer.init(self.alloc, stdout_fd);
        defer pw.deinit();

        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer_obj = std.Io.File.stdout().writer(root.g_io, &stdout_buf);
        const blocking_stdout: *std.Io.Writer = &stdout_writer_obj.interface;
        root.g_port_writer = blocking_stdout;

        const initial_width: u16 = program.context.width;
        const initial_height: u16 = program.context.height;
        program.model.last_cols = initial_width;
        program.model.last_rows = initial_height;
        try program.model.resize(initial_width, initial_height);

        var ready_payload: [13]u8 = undefined;
        const ready_len = try protocol.encodeReadyWithCaps(&ready_payload, initial_width, initial_height, .{
            .frontend_type = protocol.FRONTEND_TUI,
            .color_depth = protocol.COLOR_RGB,
            .unicode_width = protocol.UNICODE_WCWIDTH,
            .image_support = protocol.IMAGE_NONE,
            .float_support = protocol.FLOAT_EMULATED,
            .text_rendering = protocol.TEXT_MONOSPACE,
        });
        try protocol.writeMessage(blocking_stdout, ready_payload[0..ready_len]);
        try blocking_stdout.flush();

        port_writer.setNonBlocking(stdout_fd);
        root.g_port_writer_nb = &pw;
        root.g_port_writer = null;
        program.model.port_writer = &pw;

        var adapter = ProgramAdapter{ .program = &program };
        try adapter.run(&pw);
    }
};

const ProgramAdapter = struct {
    program: *zz.Program(MingaModel),
    last_view_hash: u64 = 0,
    last_line_count: usize = 0,

    fn run(self: *ProgramAdapter, pw: *port_writer) !void {
        const stdin_fd = std.posix.STDIN_FILENO;
        const stdout_fd = std.posix.STDOUT_FILENO;
        var msg_buf: [65536]u8 = undefined;
        var input_buf: [1024]u8 = undefined;

        while (self.program.isRunning()) {
            if (g_quit.load(.acquire)) break;
            if (g_winch.swap(false, .acq_rel)) {
                try self.applyResize(pw);
            }

            try self.pumpPort(stdin_fd, stdout_fd, pw, &msg_buf);
            try self.pumpTerminal(&input_buf);
            try self.render();
            _ = pw.drain() catch |err| {
                std.log.warn("stdout drain error: {}", .{err});
                break;
            };

            std.Thread.sleep(8 * std.time.ns_per_ms);
        }
    }

    fn pumpPort(self: *ProgramAdapter, stdin_fd: std.posix.fd_t, stdout_fd: std.posix.fd_t, pw: *port_writer, msg_buf: []u8) !void {
        var pollfds = [2]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = stdout_fd, .events = if (pw.hasPending()) std.posix.POLL.OUT else 0, .revents = 0 },
        };
        const poll_rc = std.posix.system.poll(@ptrCast(&pollfds), pollfds.len, 0);
        const poll_errno = std.posix.errno(poll_rc);
        if (poll_errno != .SUCCESS and poll_errno != .INTR) return error.PollError;

        if (pollfds[1].revents & std.posix.POLL.OUT != 0) {
            _ = try pw.drain();
        }

        if (pollfds[0].revents & std.posix.POLL.IN != 0) {
            var len_buf: [4]u8 = undefined;
            const ok = try readExact(stdin_fd, &len_buf);
            if (!ok) {
                self.program.quit();
                return;
            }

            const msg_len: usize = std.mem.readInt(u32, &len_buf, .big);
            if (msg_len == 0) return;
            if (msg_len > msg_buf.len) {
                std.log.err("Port message too large: {} bytes", .{msg_len});
                self.program.quit();
                return;
            }

            const payload = msg_buf[0..msg_len];
            if (!try readExact(stdin_fd, payload)) {
                self.program.quit();
                return;
            }
            try self.program.model.applyPortPayload(payload);
        }

        const hup_mask: i16 = std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;
        if (pollfds[0].revents & hup_mask != 0) self.program.quit();
    }

    fn pumpTerminal(self: *ProgramAdapter, input_buf: []u8) !void {
        const terminal = &(self.program.terminal orelse return);
        if (terminal.checkResize()) {
            try self.applyResize(self.program.model.port_writer orelse return);
        }

        const n = try terminal.readInput(input_buf, 0);
        if (n == 0) return;

        const events = try zz.input.keyboard.parseAll(self.program.context.allocator, input_buf[0..n]);
        for (events) |event| {
            switch (event) {
                .key => |key| try self.program.send(.{ .key = key }),
                .mouse => |mouse| try self.program.send(.{ .mouse = mouse }),
                .none => {},
            }
        }
    }

    fn applyResize(self: *ProgramAdapter, pw: *port_writer) !void {
        const terminal = &(self.program.terminal orelse return);
        const size = try terminal.getSize();
        const cols = size.cols;
        const rows = size.rows;
        if (cols == self.program.model.last_cols and rows == self.program.model.last_rows) return;

        self.program.context.width = cols;
        self.program.context.height = rows;
        self.program.model.last_cols = cols;
        self.program.model.last_rows = rows;
        try self.program.model.resize(cols, rows);

        var rbuf: [5]u8 = undefined;
        const rlen = try protocol.encodeResize(&rbuf, cols, rows);
        try pw.enqueue(rbuf[0..rlen]);
        self.last_view_hash = 0;
    }

    fn render(self: *ProgramAdapter) !void {
        const terminal = &(self.program.terminal orelse return);
        _ = self.program.arena.reset(.retain_capacity);
        self.program.context.allocator = self.program.arena.allocator();
        const view_output = self.program.model.view(&self.program.context);
        const view_hash = std.hash.Wyhash.hash(0, view_output);
        if (view_hash == self.last_view_hash) return;

        const writer = terminal.writer();
        try writer.writeAll("\x1b[?2026h");
        try writer.writeAll("\x1b[H");

        var lines = std.mem.splitScalar(u8, view_output, '\n');
        var first = true;
        var line_count: usize = 0;
        while (lines.next()) |line| {
            if (!first) try writer.writeAll("\r\n");
            first = false;
            try writer.writeAll(line);
            try writer.writeAll("\x1b[K");
            line_count += 1;
        }

        if (self.last_line_count > line_count) {
            var remaining = self.last_line_count - line_count;
            while (remaining > 0) : (remaining -= 1) {
                try writer.writeAll("\r\n\x1b[2K");
            }
        }
        self.last_line_count = line_count;
        try writer.writeAll("\x1b[?2026l");
        try terminal.flush();
        self.last_view_hash = view_hash;
    }
};

const MingaModel = struct {
    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
        paste: []const u8,
    };

    alloc: std.mem.Allocator,
    semantic: semantic_mod.State,
    surface: AnsiSurface,
    port_writer: ?*port_writer = null,
    recovery: recovery_mod = recovery_mod.init(),
    last_cols: u16 = 0,
    last_rows: u16 = 0,

    pub fn init(self: *MingaModel, ctx: *zz.Context) zz.Cmd(Msg) {
        self.* = .{
            .alloc = ctx.persistent_allocator,
            .semantic = semantic_mod.State.init(ctx.persistent_allocator),
            .surface = AnsiSurface.init(ctx.persistent_allocator, ctx.width, ctx.height) catch AnsiSurface.empty(ctx.persistent_allocator),
        };
        return .none;
    }

    pub fn deinit(self: *MingaModel) void {
        self.semantic.deinit();
        self.surface.deinit();
    }

    pub fn update(self: *MingaModel, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |key| self.handleKey(key) catch |err| std.log.warn("key event error: {}", .{err}),
            .mouse => |mouse| self.handleMouse(mouse) catch |err| std.log.warn("mouse event error: {}", .{err}),
            .paste => |bytes| self.handlePaste(bytes) catch |err| std.log.warn("paste event error: {}", .{err}),
        }
        return .none;
    }

    pub fn view(self: *const MingaModel, ctx: *const zz.Context) []const u8 {
        return self.surface.view(ctx.allocator, self.recovery.showing) catch "";
    }

    fn resize(self: *MingaModel, width: u16, height: u16) !void {
        try self.surface.resize(width, height);
    }

    fn applyPortPayload(self: *MingaModel, payload: []const u8) !void {
        var offset: usize = 0;
        while (offset < payload.len) {
            const remaining = payload[offset..];
            const cmd = protocol.decodeCommand(remaining) catch |err| {
                std.log.warn("protocol decode error at offset {}: {}", .{ offset, err });
                break;
            };
            switch (cmd) {
                .clear => {
                    self.semantic.clear();
                    self.surface.clear();
                },
                .batch_end => {
                    self.recovery.onRenderReceived();
                    self.surface.beginFrame();
                    self.semantic.render(AnsiSurface, &self.surface);
                },
                .noop => {
                    const cmd_size = protocol.commandSize(remaining);
                    self.semantic.applyRetainedSemanticPacket(remaining[0..cmd_size]) catch |err| {
                        std.log.warn("semantic retained packet decode error: {}", .{err});
                    };
                },
                .measure_text => |mt| {
                    self.handleMeasureText(mt) catch |err| std.log.warn("measure_text error: {}", .{err});
                },
                .set_language, .parse_buffer, .set_highlight_query, .set_injection_query, .load_grammar, .query_language_at, .edit_buffer => {
                    std.log.warn("TUI received parser command (should go to parser)", .{});
                },
                else => {
                    std.log.warn("semantic TUI ignored non-semantic render command: {s}", .{@tagName(cmd)});
                },
            }
            const advance = protocol.commandSize(remaining);
            if (advance == 0) {
                std.log.warn("protocol command made no progress at offset {}", .{offset});
                break;
            }
            offset += advance;
        }
    }

    fn handleMeasureText(self: *MingaModel, mt: protocol.MeasureText) !void {
        var total_width: u16 = 0;
        var iter = vaxis.unicode.graphemeIterator(mt.text);
        while (iter.next()) |grapheme| {
            const raw = grapheme.bytes(mt.text);
            const w: u16 = vaxis.gwidth.gwidth(raw, .wcwidth);
            total_width +|= if (w == 0) 1 else w;
        }
        var rbuf: [7]u8 = undefined;
        const rlen = try protocol.encodeTextWidth(&rbuf, mt.request_id, total_width);
        try (self.port_writer orelse return).enqueue(rbuf[0..rlen]);
    }

    fn handleKey(self: *MingaModel, key: zz.KeyEvent) !void {
        const pw = self.port_writer orelse return;
        if (key.key == .paste) {
            try self.handlePaste(key.key.paste);
            return;
        }

        if (keyCodepoint(key.key)) |codepoint| {
            if (self.recovery.showing) {
                switch (self.recovery.handleRecoveryKey(@intCast(codepoint))) {
                    .restart => recovery_mod.sendRestartSignal(),
                    .quit => g_quit.store(true, .release),
                    .wait, .none => {},
                }
                return;
            }

            if (codepoint == 7 and self.recovery.isUnresponsive()) {
                self.recovery.show();
                return;
            }

            var kbuf: [6]u8 = undefined;
            const klen = try protocol.encodeKeyPress(&kbuf, codepoint, keyModifiers(key.modifiers));
            try pw.enqueue(kbuf[0..klen]);
            self.recovery.onKeySent();
        }
    }

    fn handlePaste(self: *MingaModel, bytes: []const u8) !void {
        const pw = self.port_writer orelse return;
        const paste_msg = try protocol.encodePasteEvent(self.alloc, bytes);
        defer self.alloc.free(paste_msg);
        try pw.enqueue(paste_msg);
    }

    fn handleMouse(self: *MingaModel, mouse: zz.MouseEvent) !void {
        const pw = self.port_writer orelse return;
        const button = mouseButton(mouse.button) orelse return;
        const event_type = mouseEventType(mouse.event_type);
        const row: i16 = @intCast(mouse.y);
        const col: i16 = @intCast(mouse.x);

        if (button == protocol.MOUSE_LEFT and event_type == protocol.MOUSE_PRESS) {
            if (self.semantic.hitTest(@intCast(row), @intCast(col), self.surface.width(), self.surface.height())) |action| {
                try enqueueSemanticHitAction(pw, action);
                return;
            }
        }

        var mbuf: [9]u8 = undefined;
        const mlen = try protocol.encodeMouseEvent(&mbuf, row, col, button, keyModifiers(mouse.modifiers), event_type, 1);
        try pw.enqueue(mbuf[0..mlen]);
    }
};

const AnsiSurface = struct {
    alloc: std.mem.Allocator,
    width_cells: u16,
    height_cells: u16,
    cells: []Cell,
    frame_arena: std.heap.ArenaAllocator,
    cursor_col: u16 = 0,
    cursor_row: u16 = 0,
    cursor_visible: bool = false,
    cursor_shape: surface_mod.CursorShape = .block,
    default_bg: u24 = 0,

    fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !AnsiSurface {
        var self = empty(alloc);
        try self.resize(cols, rows);
        return self;
    }

    fn empty(alloc: std.mem.Allocator) AnsiSurface {
        return .{
            .alloc = alloc,
            .width_cells = 0,
            .height_cells = 0,
            .cells = &.{},
            .frame_arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    fn deinit(self: *AnsiSurface) void {
        if (self.cells.len > 0) self.alloc.free(self.cells);
        self.frame_arena.deinit();
    }

    fn resize(self: *AnsiSurface, cols: u16, rows: u16) !void {
        if (self.width_cells == cols and self.height_cells == rows and self.cells.len > 0) return;
        if (self.cells.len > 0) self.alloc.free(self.cells);
        self.width_cells = cols;
        self.height_cells = rows;
        const len = @as(usize, cols) * @as(usize, rows);
        self.cells = try self.alloc.alloc(Cell, len);
        self.clear();
    }

    pub fn beginFrame(self: *AnsiSurface) void {
        _ = self.frame_arena.reset(.retain_capacity);
        self.clear();
    }

    pub fn clear(self: *AnsiSurface) void {
        for (self.cells) |*cell| cell.* = .{ .grapheme = "", .bg = self.default_bg };
        self.cursor_visible = false;
    }

    pub fn fillBg(self: *AnsiSurface, bg: u24) void {
        self.default_bg = bg;
        for (self.cells) |*cell| cell.bg = bg;
    }

    pub fn writeCell(self: *AnsiSurface, col: u16, row: u16, cell: Cell) void {
        if (col >= self.width_cells or row >= self.height_cells) return;
        const cell_index = self.index(col, row);
        var stable = cell;
        stable.grapheme = self.frame_arena.allocator().dupe(u8, cell.grapheme) catch cell.grapheme;
        self.cells[cell_index] = stable;
        if (stable.width > 1) {
            var extra: u16 = 1;
            while (extra < stable.width and col + extra < self.width_cells) : (extra += 1) {
                self.cells[self.index(col + extra, row)] = .{ .width = 0, .bg = stable.bg };
            }
        }
    }

    pub fn showCursor(self: *AnsiSurface, col: u16, row: u16) void {
        self.cursor_col = col;
        self.cursor_row = row;
        self.cursor_visible = true;
    }

    pub fn setCursorShape(self: *AnsiSurface, shape: surface_mod.CursorShape) void {
        self.cursor_shape = shape;
    }

    pub fn scrollRegion(self: *AnsiSurface, top: u16, bottom: u16, delta: i16) void {
        if (delta == 0 or top >= bottom or self.width_cells == 0) return;
        const clamped_bottom = @min(bottom, self.height_cells -| 1);
        if (top >= self.height_cells or top > clamped_bottom) return;
        const abs_delta: u16 = @intCast(if (delta < 0) -delta else delta);
        const region_height = clamped_bottom - top + 1;
        if (abs_delta >= region_height) {
            var row = top;
            while (row <= clamped_bottom) : (row += 1) self.blankRow(row);
            return;
        }
        if (delta > 0) {
            var row = top;
            while (row <= clamped_bottom - abs_delta) : (row += 1) self.copyRow(row, row + abs_delta);
            while (row <= clamped_bottom) : (row += 1) self.blankRow(row);
        } else {
            var row = clamped_bottom;
            while (row >= top + abs_delta) : (row -= 1) {
                self.copyRow(row, row - abs_delta);
                if (row == top + abs_delta) break;
            }
            row = top;
            while (row < top + abs_delta) : (row += 1) self.blankRow(row);
        }
    }

    pub fn render(_: *AnsiSurface) !void {}

    pub fn width(self: *AnsiSurface) u16 {
        return self.width_cells;
    }

    pub fn height(self: *AnsiSurface) u16 {
        return self.height_cells;
    }

    fn view(self: *const AnsiSurface, alloc: std.mem.Allocator, show_recovery: bool) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var active: StyleKey = .{};
        var row: u16 = 0;
        while (row < self.height_cells) : (row += 1) {
            if (row > 0) try out.append(alloc, '\n');
            var col: u16 = 0;
            while (col < self.width_cells) : (col += 1) {
                var cell = if (show_recovery) recoveryOverlayCell(self.width_cells, self.height_cells, col, row) orelse self.cells[self.index(col, row)] else self.cells[self.index(col, row)];
                if (cell.width == 0) continue;
                if (!show_recovery and self.cursor_visible and row == self.cursor_row and col == self.cursor_col) {
                    if (cell.grapheme.len == 0) cell.grapheme = " ";
                    cell.attrs |= protocol.ATTR_REVERSE;
                }
                const wanted = StyleKey.fromCell(cell);
                if (!active.eql(wanted)) {
                    try appendStyle(&out, alloc, wanted);
                    active = wanted;
                }
                if (cell.grapheme.len == 0) {
                    try out.append(alloc, ' ');
                } else {
                    try out.appendSlice(alloc, cell.grapheme);
                }
            }
            if (!active.eql(.{})) {
                try out.appendSlice(alloc, "\x1b[0m");
                active = .{};
            }
        }
        return out.toOwnedSlice(alloc);
    }

    fn index(self: *const AnsiSurface, col: u16, row: u16) usize {
        return @as(usize, row) * @as(usize, self.width_cells) + @as(usize, col);
    }

    fn blankRow(self: *AnsiSurface, row: u16) void {
        var col: u16 = 0;
        while (col < self.width_cells) : (col += 1) self.cells[self.index(col, row)] = .{ .bg = self.default_bg };
    }

    fn copyRow(self: *AnsiSurface, dst: u16, src: u16) void {
        const w: usize = @intCast(self.width_cells);
        const dst_start = @as(usize, dst) * w;
        const src_start = @as(usize, src) * w;
        std.mem.copyForwards(Cell, self.cells[dst_start .. dst_start + w], self.cells[src_start .. src_start + w]);
    }
};

fn recoveryOverlayCell(width: u16, height: u16, col: u16, row: u16) ?Cell {
    const box_width: u16 = 46;
    const box_height: u16 = recovery_lines.len;
    const start_col: u16 = if (width > box_width) (width - box_width) / 2 else 0;
    const start_row: u16 = if (height > box_height) (height - box_height) / 2 else 0;
    if (row < start_row or row >= start_row + box_height) return null;
    if (col < start_col or col >= start_col + box_width) return null;

    const line = recovery_lines[row - start_row];
    const offset: usize = col - start_col;
    if (offset >= line.len) return null;
    const ch = line[offset .. offset + 1];
    return .{
        .grapheme = ch,
        .fg = if (ch[0] == 'r' or ch[0] == 'q' or ch[0] == 'w') 0x66FF66 else 0xCCCCCC,
        .bg = 0x1A1A2E,
        .attrs = if (row == start_row or row == start_row + box_height - 1) protocol.ATTR_BOLD else 0,
    };
}

const recovery_lines = [_][]const u8{
    "+------------ Editor Unresponsive ------------+",
    "|                                            |",
    "|  [r] Restart editor (buffers preserved)   |",
    "|  [q] Quit minga                           |",
    "|  [w] Wait and continue trying             |",
    "|                                            |",
    "+--------------------------------------------+",
};

const StyleKey = struct {
    fg: u24 = 0,
    bg: u24 = 0,
    attrs: u8 = 0,
    ul_style: u3 = 0,
    ul_color: u24 = 0,
    strikethrough: bool = false,
    dim: bool = false,

    fn fromCell(cell: Cell) StyleKey {
        return .{
            .fg = cell.fg,
            .bg = cell.bg,
            .attrs = cell.attrs,
            .ul_style = cell.ul_style,
            .ul_color = cell.ul_color,
            .strikethrough = cell.strikethrough,
            .dim = cell.blend < 50,
        };
    }

    fn eql(self: StyleKey, other: StyleKey) bool {
        return self.fg == other.fg and self.bg == other.bg and self.attrs == other.attrs and self.ul_style == other.ul_style and self.ul_color == other.ul_color and self.strikethrough == other.strikethrough and self.dim == other.dim;
    }
};

fn appendStyle(out: *std.ArrayList(u8), alloc: std.mem.Allocator, style: StyleKey) !void {
    try out.appendSlice(alloc, "\x1b[0m");
    if (style.fg != 0) try appendFmt(out, alloc, "\x1b[38;2;{d};{d};{d}m", .{ (style.fg >> 16) & 0xFF, (style.fg >> 8) & 0xFF, style.fg & 0xFF });
    if (style.bg != 0) try appendFmt(out, alloc, "\x1b[48;2;{d};{d};{d}m", .{ (style.bg >> 16) & 0xFF, (style.bg >> 8) & 0xFF, style.bg & 0xFF });
    if (style.attrs & protocol.ATTR_BOLD != 0) try out.appendSlice(alloc, "\x1b[1m");
    if (style.attrs & protocol.ATTR_ITALIC != 0) try out.appendSlice(alloc, "\x1b[3m");
    if (style.attrs & protocol.ATTR_UNDERLINE != 0 or style.ul_style != 0) try out.appendSlice(alloc, "\x1b[4m");
    if (style.attrs & protocol.ATTR_REVERSE != 0) try out.appendSlice(alloc, "\x1b[7m");
    if (style.strikethrough) try out.appendSlice(alloc, "\x1b[9m");
    if (style.dim) try out.appendSlice(alloc, "\x1b[2m");
    if (style.ul_color != 0) try appendFmt(out, alloc, "\x1b[58;2;{d};{d};{d}m", .{ (style.ul_color >> 16) & 0xFF, (style.ul_color >> 8) & 0xFF, style.ul_color & 0xFF });
    switch (style.ul_style) {
        2 => try out.appendSlice(alloc, "\x1b[4:3m"),
        3 => try out.appendSlice(alloc, "\x1b[4:4m"),
        4 => try out.appendSlice(alloc, "\x1b[4:2m"),
        else => {},
    }
}

fn appendFmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const bytes = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(bytes);
    try out.appendSlice(alloc, bytes);
}

fn keyCodepoint(key: zz.input.keys.Key) ?u32 {
    return switch (key) {
        .char => |c| c,
        .space => ' ',
        .enter => 13,
        .tab => 9,
        .escape => 27,
        .backspace => 127,
        .up => arrow_up,
        .down => arrow_down,
        .left => arrow_left,
        .right => arrow_right,
        else => null,
    };
}

fn keyModifiers(modifiers: zz.Modifiers) u8 {
    var mods: u8 = 0;
    if (modifiers.shift) mods |= protocol.MOD_SHIFT;
    if (modifiers.ctrl) mods |= protocol.MOD_CTRL;
    if (modifiers.alt) mods |= protocol.MOD_ALT;
    if (modifiers.super) mods |= protocol.MOD_SUPER;
    return mods;
}

fn mouseButton(button: zz.MouseButton) ?u8 {
    return switch (button) {
        .left => protocol.MOUSE_LEFT,
        .middle => protocol.MOUSE_MIDDLE,
        .right => protocol.MOUSE_RIGHT,
        .none => protocol.MOUSE_NONE,
        .wheel_up => protocol.MOUSE_WHEEL_UP,
        .wheel_down => protocol.MOUSE_WHEEL_DOWN,
        .wheel_right => protocol.MOUSE_WHEEL_RIGHT,
        .wheel_left => protocol.MOUSE_WHEEL_LEFT,
        else => null,
    };
}

fn mouseEventType(event_type: zz.MouseEventType) u8 {
    return switch (event_type) {
        .press => protocol.MOUSE_PRESS,
        .release => protocol.MOUSE_RELEASE,
        .move => protocol.MOUSE_MOTION,
        .drag => protocol.MOUSE_DRAG,
    };
}

fn enqueueSemanticHitAction(pw: *port_writer, action: semantic_mod.HitAction) !void {
    var buf: [512]u8 = undefined;
    const len = switch (action) {
        .no_payload => |action_id| try protocol.encodeGuiAction(&buf, action_id),
        .u16_payload => |payload| try protocol.encodeGuiActionU16(&buf, payload.action, payload.value),
        .u32_payload => |payload| try protocol.encodeGuiActionU32(&buf, payload.action, payload.value),
        .fold_toggle => |payload| try protocol.encodeGuiActionFoldToggle(&buf, payload.window_id, payload.buffer_line),
        .string_payload => |payload| try protocol.encodeGuiActionString(&buf, payload.action, payload.value),
    };
    try pw.enqueue(buf[0..len]);
}

fn openTty() !std.Io.File {
    const tty_path: [*:0]const u8 = std.c.getenv("MINGA_TTY") orelse "/dev/tty";
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, tty_path, .{ .ACCMODE = .RDWR }, 0);
    return std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn installSignalHandlers() void {
    var unblock_set = std.posix.sigemptyset();
    std.posix.sigaddset(&unblock_set, std.posix.SIG.WINCH);
    std.posix.sigaddset(&unblock_set, std.posix.SIG.TERM);
    std.posix.sigaddset(&unblock_set, std.posix.SIG.INT);
    const SIG_UNBLOCK = 2;
    std.posix.sigprocmask(SIG_UNBLOCK, &unblock_set, null);

    const mask = switch (@import("builtin").os.tag) {
        .macos => @as(u32, 0),
        else => std.posix.sigemptyset(),
    };

    var winch_act = std.posix.Sigaction{ .handler = .{ .handler = sigwinchHandler }, .mask = mask, .flags = 0 };
    std.posix.sigaction(std.posix.SIG.WINCH, &winch_act, null);

    var quit_act = std.posix.Sigaction{ .handler = .{ .handler = sigquitHandler }, .mask = mask, .flags = 0 };
    std.posix.sigaction(std.posix.SIG.TERM, &quit_act, null);
    std.posix.sigaction(std.posix.SIG.INT, &quit_act, null);
}

fn readExact(fd: std.posix.fd_t, buf: []u8) !bool {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(fd, buf[total..]);
        if (n == 0) return false;
        total += n;
    }
    return true;
}

test "ansi surface renders styled cells and cursor overlay" {
    const alloc = std.testing.allocator;
    var surface = try AnsiSurface.init(alloc, 3, 1);
    defer surface.deinit();

    surface.writeCell(0, 0, .{ .grapheme = "A", .fg = 0xFF0000 });
    surface.showCursor(1, 0);
    const rendered = try surface.view(alloc, false);
    defer alloc.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[7m") != null);
}

test "key mapping mirrors Go Bubble Tea renderer arrows" {
    try std.testing.expectEqual(@as(?u32, arrow_left), keyCodepoint(.left));
    try std.testing.expectEqual(@as(?u32, arrow_right), keyCodepoint(.right));
    try std.testing.expectEqual(@as(?u32, arrow_up), keyCodepoint(.up));
    try std.testing.expectEqual(@as(?u32, arrow_down), keyCodepoint(.down));
    try std.testing.expectEqual(@as(?u32, 13), keyCodepoint(.enter));
    try std.testing.expectEqual(@as(?u32, 127), keyCodepoint(.backspace));
}
