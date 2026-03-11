/// TUI backend — libvaxis terminal rendering and input.
///
/// Implements the AppRuntime lifecycle (init/run/deinit) and provides
/// a VaxisSurface that implements the Surface interface for the generic
/// Renderer.
///
/// This is a direct extraction of the original main.zig event loop with
/// no behavioral changes.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const root = @import("../main.zig");
const protocol = @import("../protocol.zig");
const renderer_mod = @import("../renderer.zig");
const surface_mod = @import("../surface.zig");
// Note: tree-sitter highlighting is handled by the separate minga-parser
// process. The renderer does not embed any grammars or the highlighter.
const Cell = surface_mod.Cell;

// ── VaxisSurface ──────────────────────────────────────────────────────────────

/// Surface implementation backed by libvaxis.
/// Wraps vaxis.Vaxis and a tty writer, translating abstract Cell writes
/// into vaxis draw calls.
pub const VaxisSurface = struct {
    vx: *vaxis.Vaxis,
    tty_writer: *std.Io.Writer,

    pub fn clear(self: *VaxisSurface) void {
        const win = self.vx.window();
        win.clear();
    }

    /// Fills every cell in the window with a background color.
    /// Used after clear() to replace the terminal's default background
    /// with the editor theme's background, so empty cells match.
    pub fn fillBg(self: *VaxisSurface, bg: u24) void {
        const win = self.vx.window();
        win.fill(.{
            .style = .{
                .bg = .{ .rgb = .{
                    @as(u8, @intCast((bg >> 16) & 0xFF)),
                    @as(u8, @intCast((bg >> 8) & 0xFF)),
                    @as(u8, @intCast(bg & 0xFF)),
                } },
            },
        });
    }

    pub fn writeCell(self: *VaxisSurface, col: u16, row: u16, cell: Cell) void {
        const win = self.vx.window();
        const style = cellToStyle(cell);
        win.writeCell(col, row, .{
            .char = .{
                .grapheme = cell.grapheme,
                .width = @intCast(cell.width),
            },
            .style = style,
        });
    }

    pub fn showCursor(self: *VaxisSurface, col: u16, row: u16) void {
        const win = self.vx.window();
        win.showCursor(col, row);
    }

    pub fn setCursorShape(self: *VaxisSurface, shape: surface_mod.CursorShape) void {
        const win = self.vx.window();
        win.setCursorShape(switch (shape) {
            .block => .block,
            .beam => .beam,
            .underline => .underline,
        });
    }

    pub fn render(self: *VaxisSurface) !void {
        try self.vx.render(self.tty_writer);
    }

    pub fn width(self: *VaxisSurface) u16 {
        const win = self.vx.window();
        return @intCast(win.width);
    }

    pub fn height(self: *VaxisSurface) u16 {
        const win = self.vx.window();
        return @intCast(win.height);
    }
};

/// Convert a surface Cell to a vaxis Cell.Style.
fn cellToStyle(cell: Cell) vaxis.Cell.Style {
    var style: vaxis.Cell.Style = .{};

    if (cell.fg != 0) {
        style.fg = .{ .rgb = .{
            @as(u8, @intCast((cell.fg >> 16) & 0xFF)),
            @as(u8, @intCast((cell.fg >> 8) & 0xFF)),
            @as(u8, @intCast(cell.fg & 0xFF)),
        } };
    }

    if (cell.bg != 0) {
        style.bg = .{ .rgb = .{
            @as(u8, @intCast((cell.bg >> 16) & 0xFF)),
            @as(u8, @intCast((cell.bg >> 8) & 0xFF)),
            @as(u8, @intCast(cell.bg & 0xFF)),
        } };
    }

    if (cell.attrs & protocol.ATTR_BOLD != 0) style.bold = true;
    if (cell.attrs & protocol.ATTR_ITALIC != 0) style.italic = true;
    if (cell.attrs & protocol.ATTR_UNDERLINE != 0) style.ul_style = .single;
    if (cell.attrs & protocol.ATTR_REVERSE != 0) style.reverse = true;

    return style;
}

// ── Global signal flags ───────────────────────────────────────────────────────

var g_winch: std.atomic.Value(bool) = .init(false);
var g_quit: std.atomic.Value(bool) = .init(false);

fn sigwinchHandler(_: c_int) callconv(.c) void {
    g_winch.store(true, .release);
}

fn sigquitHandler(_: c_int) callconv(.c) void {
    g_quit.store(true, .release);
}

// ── TUI Runtime ───────────────────────────────────────────────────────────────

/// TUI application runtime — owns the terminal, vaxis instance, and event loop.
pub const TuiRuntime = struct {
    alloc: std.mem.Allocator,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    surface: VaxisSurface,
    rend: renderer_mod.Renderer(VaxisSurface),
    tty_write_buf: [4096]u8,
    /// Number of render batches remaining that need a full repaint after
    /// a resize. Set to 2 on resize (enough for one stale pre-resize
    /// batch + the correct post-resize batch). Decremented per batch.
    refresh_batches: u8 = 0,

    /// True while inside a bracketed paste (between paste_start and paste_end).
    /// Key press events during this state are accumulated into `paste_buf`
    /// instead of being sent as individual key_press messages.
    pasting: bool = false,

    /// Accumulates UTF-8 bytes from key_press events during a bracketed paste.
    /// Cleared on paste_start, sent as a single paste_event on paste_end.
    paste_buf: std.ArrayList(u8) = .empty,

    /// Initialize the TUI runtime: open TTY, set up vaxis, enter alt screen.
    pub fn init(alloc: std.mem.Allocator) !TuiRuntime {
        // We need a stable pointer for the tty_write_buf, but since TuiRuntime
        // is returned by value and immediately used, the caller must ensure
        // it lives at a stable address. We initialize fields step by step.
        var self: TuiRuntime = undefined;
        self.alloc = alloc;
        self.tty_write_buf = undefined;

        self.tty = initTty(&self.tty_write_buf) catch |err| {
            std.log.err("Failed to initialize TTY: {}", .{err});
            return err;
        };

        self.vx = try vaxis.init(alloc, .{});

        // Allocate screen buffers at the real terminal size.
        const initial_ws = try vaxis.Tty.getWinsize(self.tty.fd);
        try self.vx.resize(alloc, self.tty.writer(), initial_ws);

        // Save the current terminal title so we can restore it on exit.
        self.tty.writer().writeAll("\x1b[22;0t") catch {};

        // Alternate screen keeps existing terminal output intact.
        try self.vx.enterAltScreen(self.tty.writer());

        // Enable mouse mode.
        try self.vx.setMouseMode(self.tty.writer(), true);

        // Enable bracketed paste so multi-line pastes arrive as
        // paste_start / key_press* / paste_end instead of bare key_press.
        try self.vx.setBracketedPaste(self.tty.writer(), true);

        // Query terminal capabilities (Kitty keyboard protocol, RGB color,
        // Unicode width, graphics support, etc.). We use the non-blocking
        // queryTerminalSend() because we run a custom event loop. The
        // terminal's responses arrive as cap_* events; when cap_da1 fires
        // (the final response), we call enableDetectedFeatures() to activate
        // everything the terminal supports.
        try self.vx.queryTerminalSend(self.tty.writer());

        // Paste buffer uses the runtime allocator for dynamic accumulation.
        self.paste_buf = .empty;

        // Install signal handlers.
        installSignalHandlers();

        // Initialize surface and renderer.
        self.surface = .{ .vx = &self.vx, .tty_writer = self.tty.writer() };
        self.rend = renderer_mod.Renderer(VaxisSurface).init(&self.surface, alloc);

        return self;
    }

    /// Run the event loop. Blocks until quit signal or stdin EOF.
    pub fn run(self: *TuiRuntime) !void {
        // Fix up internal pointers after the struct has been moved to its
        // final location on the caller's stack.
        self.surface.vx = &self.vx;
        self.surface.tty_writer = self.tty.writer();
        self.rend.surface = &self.surface;

        // Stdout (Port protocol channel).
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer_obj = std.fs.File.stdout().writer(&stdout_buf);
        const stdout: *std.Io.Writer = &stdout_writer_obj.interface;

        // Enable log routing over the port protocol now that stdout is ready.
        root.g_port_writer = stdout;

        // Send ready event with initial dimensions and default capabilities.
        // Actual capabilities are detected asynchronously (DA1 response).
        // We send a capabilities_updated event once detection completes.
        const initial_ws = try vaxis.Tty.getWinsize(self.tty.fd);
        var ready_payload: [13]u8 = undefined;
        const ready_len = try protocol.encodeReadyWithCaps(
            &ready_payload,
            initial_ws.cols,
            initial_ws.rows,
            .{}, // defaults: tui, rgb, wcwidth, no images, emulated floats, monospace
        );
        try protocol.writeMessage(stdout, ready_payload[0..ready_len]);
        try stdout.flush();

        try self.runEventLoop(stdout);
    }

    /// Clean up: free renderer, vaxis, and restore terminal.
    pub fn deinit(self: *TuiRuntime) void {
        self.paste_buf.deinit(self.alloc);
        self.rend.deinit();
        // Restore the terminal title saved at init.
        self.tty.writer().writeAll("\x1b[23;0t") catch {};
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.deinit();
    }

    // ── Event loop ────────────────────────────────────────────────────────────

    fn runEventLoop(self: *TuiRuntime, stdout: *std.Io.Writer) !void {
        const stdin_fd = std.posix.STDIN_FILENO;

        var tty_parser: vaxis.Parser = .{};
        var tty_read_buf: [1024]u8 = undefined;
        var tty_read_start: usize = 0;

        var msg_buf: [65536]u8 = undefined;

        var pollfds = [2]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.tty.fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        main_loop: while (true) {
            if (g_quit.load(.acquire)) break :main_loop;

            if (g_winch.swap(false, .acq_rel)) {
                try self.handleResize(stdout);
            }

            // Use raw poll to avoid std.posix.poll's automatic EINTR retry.
            // SIGWINCH sets g_winch and interrupts poll with EINTR. We need
            // to break out of poll immediately so we can process the resize
            // before rendering the next frame. With the standard retry, each
            // SIGWINCH during a window drag resets the 1000ms timeout, delaying
            // resize processing by seconds.
            pollfds[0].revents = 0;
            pollfds[1].revents = 0;
            const poll_rc = std.posix.system.poll(@ptrCast(&pollfds), 2, 1000);
            const poll_errno = std.posix.errno(poll_rc);
            if (poll_errno != .SUCCESS and poll_errno != .INTR) {
                return error.PollError;
            }

            // Check for resize after poll (SIGWINCH can fire during poll).
            // On EINTR, revents are undefined, so we skip fd processing and
            // just handle the resize. On success, revents are valid.
            if (g_winch.swap(false, .acq_rel)) {
                try self.handleResize(stdout);
            }

            // stdin readable (Port command from BEAM)
            if (pollfds[0].revents & std.posix.POLL.IN != 0) {
                var len_buf: [4]u8 = undefined;
                const ok = try readExact(stdin_fd, &len_buf);
                if (!ok) break :main_loop;

                const msg_len: usize = std.mem.readInt(u32, &len_buf, .big);
                if (msg_len == 0) continue :main_loop;
                if (msg_len > msg_buf.len) {
                    std.log.err("Port message too large: {} bytes", .{msg_len});
                    break :main_loop;
                }

                const payload = msg_buf[0..msg_len];
                if (!try readExact(stdin_fd, payload)) break :main_loop;

                // After a resize, force libvaxis to fully repaint. The
                // physical terminal was already cleared in handleResize,
                // but vx.refresh ensures libvaxis writes every cell (not
                // just the diff). We allow up to 2 batches with refresh:
                // one for a possibly stale pre-resize batch already in the
                // pipe, one for the correct post-resize batch from BEAM.
                if (self.refresh_batches > 0) {
                    self.vx.refresh = true;
                    self.refresh_batches -= 1;
                }

                var offset: usize = 0;
                while (offset < msg_len) {
                    const remaining = payload[offset..];
                    const cmd = protocol.decodeCommand(remaining) catch |err| {
                        std.log.warn("protocol decode error at offset {}: {}", .{ offset, err });
                        break;
                    };
                    switch (cmd) {
                        .measure_text => |mt| {
                            self.handleMeasureText(mt, stdout) catch |err| {
                                std.log.warn("measure_text error: {}", .{err});
                            };
                        },
                        // Highlight commands should not arrive at the renderer
                        // (they go to the parser process), but handle gracefully.
                        .set_language, .parse_buffer, .set_highlight_query, .set_injection_query, .load_grammar, .query_language_at, .edit_buffer => {
                            std.log.warn("renderer received highlight command (should go to parser)", .{});
                        },
                        else => {
                            self.rend.handleCommand(cmd) catch |err| {
                                std.log.warn("renderer error: {}", .{err});
                            };
                        },
                    }
                    offset += protocol.commandSize(remaining);
                }

            }

            // stdin HUP / error
            const hup_mask: i16 = std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;
            if (pollfds[0].revents & hup_mask != 0) break :main_loop;

            // tty readable (terminal input)
            if (pollfds[1].revents & std.posix.POLL.IN != 0) {
                const n = try std.posix.read(self.tty.fd, tty_read_buf[tty_read_start..]);
                if (n == 0) break :main_loop;

                var seq_start: usize = 0;
                tty_parse_loop: while (seq_start < n) {
                    const result = try tty_parser.parse(tty_read_buf[seq_start..n], null);
                    if (result.n == 0) {
                        const remaining = n - seq_start;
                        std.mem.copyForwards(u8, tty_read_buf[0..remaining], tty_read_buf[seq_start..n]);
                        tty_read_start = remaining;
                        break :tty_parse_loop;
                    }
                    tty_read_start = 0;
                    seq_start += result.n;

                    const event = result.event orelse continue;
                    handleTtyEvent(self, event, stdout) catch |err| {
                        std.log.warn("tty event error: {}", .{err});
                    };
                }
            }
        }
    }

    /// Compute monospace display width and send a text_width response.
    fn handleMeasureText(_: *TuiRuntime, mt: protocol.MeasureText, stdout: *std.Io.Writer) !void {
        var total_width: u16 = 0;
        var iter = vaxis.unicode.graphemeIterator(mt.text);
        while (iter.next()) |grapheme| {
            const raw = grapheme.bytes(mt.text);
            const w: u16 = vaxis.gwidth.gwidth(raw, .wcwidth);
            total_width +|= if (w == 0) 1 else w;
        }
        var rbuf: [7]u8 = undefined;
        const rlen = try protocol.encodeTextWidth(&rbuf, mt.request_id, total_width);
        try protocol.writeMessage(stdout, rbuf[0..rlen]);
        try stdout.flush();
    }

    fn handleResize(self: *TuiRuntime, stdout: *std.Io.Writer) !void {
        const ws = try vaxis.Tty.getWinsize(self.tty.fd);
        std.log.info("handleResize: cols={d} rows={d}", .{ ws.cols, ws.rows });
        try self.vx.resize(self.alloc, self.tty.writer(), ws);
        // Clear the physical terminal immediately. vx.resize() reinitializes
        // the screen buffers but does NOT erase the terminal. If a stale
        // render batch (generated before the resize) arrives before the
        // BEAM's resize-triggered batch, it would paint old content into
        // the new area. Clearing the terminal here ensures no ghost content
        // persists regardless of frame ordering.
        try self.tty.writer().writeAll("\x1b[2J\x1b[H"); // ED 2 (clear screen) + cursor home
        self.refresh_batches = 2;

        var rbuf: [5]u8 = undefined;
        const rlen = try protocol.encodeResize(&rbuf, ws.cols, ws.rows);
        try protocol.writeMessage(stdout, rbuf[0..rlen]);
        try stdout.flush();
        std.log.info("handleResize: sent resize event to BEAM", .{});
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Initializes a PosixTty, preferring the MINGA_TTY env var over /dev/tty.
fn initTty(buffer: []u8) !vaxis.Tty {
    const posix = std.posix;

    const tty_path: [*:0]const u8 = std.posix.getenvZ("MINGA_TTY") orelse "/dev/tty";
    std.log.info("Opening tty: {s}", .{tty_path});

    const fd = try posix.openZ(tty_path, .{ .ACCMODE = .RDWR }, 0);
    const termios = try vaxis.Tty.makeRaw(fd);

    const file = std.fs.File{ .handle = fd };

    const tty: vaxis.Tty = .{
        .fd = fd,
        .termios = termios,
        .tty_writer = .initStreaming(file, buffer),
    };

    vaxis.tty.global_tty = tty;
    return tty;
}

/// Install SIGWINCH (resize), SIGTERM, and SIGINT handlers.
///
/// The BEAM VM blocks most signals (including SIGWINCH) in its thread
/// signal mask. Child processes inherit this mask after fork+exec, so
/// SIGWINCH would never be delivered unless we explicitly unblock it.
fn installSignalHandlers() void {
    // Unblock SIGWINCH (and SIGTERM/SIGINT) in case the parent (BEAM)
    // blocked them. The BEAM VM blocks most signals in worker threads
    // via sigprocmask, and child processes inherit that mask after
    // fork+exec. Without this, SIGWINCH never reaches our handler and
    // the editor never learns about terminal resizes.
    {
        var unblock_set = std.posix.sigemptyset();
        std.posix.sigaddset(&unblock_set, std.posix.SIG.WINCH);
        std.posix.sigaddset(&unblock_set, std.posix.SIG.TERM);
        std.posix.sigaddset(&unblock_set, std.posix.SIG.INT);
        const SIG_UNBLOCK = 2;
        std.posix.sigprocmask(SIG_UNBLOCK, &unblock_set, null);
    }

    const mask = switch (builtin.os.tag) {
        .macos => @as(u32, 0),
        else => std.posix.sigemptyset(),
    };

    var winch_act = std.posix.Sigaction{
        .handler = .{ .handler = sigwinchHandler },
        .mask = mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &winch_act, null);

    var quit_act = std.posix.Sigaction{
        .handler = .{ .handler = sigquitHandler },
        .mask = mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &quit_act, null);
    std.posix.sigaction(std.posix.SIG.INT, &quit_act, null);
}

/// Process a parsed terminal event.
///
/// During a bracketed paste (between paste_start and paste_end), key_press
/// events are accumulated in `self.paste_buf` instead of being sent
/// individually. On paste_end, the accumulated text is sent as a single
/// paste_event message.
fn handleTtyEvent(self: *TuiRuntime, event: vaxis.Event, stdout: *std.Io.Writer) !void {
    const vx = &self.vx;

    switch (event) {
        .paste_start => {
            self.pasting = true;
            self.paste_buf.clearRetainingCapacity();
        },

        .paste_end => {
            self.pasting = false;
            if (self.paste_buf.items.len > 0) {
                const paste_msg = try protocol.encodePasteEvent(self.alloc, self.paste_buf.items);
                defer self.alloc.free(paste_msg);
                try protocol.writeMessage(stdout, paste_msg);
                try stdout.flush();
            }
            self.paste_buf.clearRetainingCapacity();
        },

        .key_press => |key| {
            if (self.pasting) {
                // During a bracketed paste, accumulate the character into
                // the paste buffer instead of sending a key_press event.
                // Encode the codepoint as UTF-8.
                var cp_buf: [4]u8 = undefined;
                const cp_len = std.unicode.utf8Encode(key.codepoint, &cp_buf) catch return;
                try self.paste_buf.appendSlice(self.alloc, cp_buf[0..cp_len]);
                return;
            }

            var mods: u8 = 0;
            if (key.mods.shift) mods |= protocol.MOD_SHIFT;
            if (key.mods.ctrl) mods |= protocol.MOD_CTRL;
            if (key.mods.alt) mods |= protocol.MOD_ALT;
            if (key.mods.super) mods |= protocol.MOD_SUPER;

            var kbuf: [6]u8 = undefined;
            const klen = try protocol.encodeKeyPress(&kbuf, key.codepoint, mods);
            try protocol.writeMessage(stdout, kbuf[0..klen]);
            try stdout.flush();
        },

        .cap_kitty_keyboard => vx.caps.kitty_keyboard = true,
        .cap_kitty_graphics => vx.caps.kitty_graphics = true,
        .cap_rgb => vx.caps.rgb = true,
        .cap_sgr_pixels => vx.caps.sgr_pixels = true,
        .cap_unicode => {
            vx.caps.unicode = .unicode;
            vx.screen.width_method = .unicode;
        },
        .cap_color_scheme_updates => vx.caps.color_scheme_updates = true,
        .cap_multi_cursor => vx.caps.multi_cursor = true,
        .cap_da1 => {
            std.Thread.Futex.wake(&vx.query_futex, 10);
            vx.queries_done.store(true, .unordered);

            // Terminal capability detection is complete. Enable all
            // detected features (Kitty keyboard protocol, Unicode
            // mode 2027, etc.). This is the custom-event-loop
            // counterpart to the blocking queryTerminal() call.
            try vx.enableDetectedFeatures(self.tty.writer());

            std.log.info("terminal caps: kitty_kb={} rgb={} unicode={s} kitty_gfx={}", .{
                vx.caps.kitty_keyboard,
                vx.caps.rgb,
                @tagName(vx.caps.unicode),
                vx.caps.kitty_graphics,
            });

            // Send a capabilities_updated event with the actual detected caps.
            const caps = protocol.Capabilities{
                .frontend_type = protocol.FRONTEND_TUI,
                .color_depth = if (vx.caps.rgb) protocol.COLOR_RGB else protocol.COLOR_256,
                .unicode_width = if (vx.caps.unicode == .unicode) protocol.UNICODE_15 else protocol.UNICODE_WCWIDTH,
                .image_support = if (vx.caps.kitty_graphics) protocol.IMAGE_KITTY else protocol.IMAGE_NONE,
                .float_support = protocol.FLOAT_EMULATED,
                .text_rendering = protocol.TEXT_MONOSPACE,
            };
            var caps_buf: [9]u8 = undefined;
            const caps_len = protocol.encodeCapabilitiesUpdated(&caps_buf, caps) catch return;
            protocol.writeMessage(stdout, caps_buf[0..caps_len]) catch return;
            stdout.flush() catch return;
        },

        .mouse => |mouse| {
            var mods: u8 = 0;
            if (mouse.mods.shift) mods |= protocol.MOD_SHIFT;
            if (mouse.mods.ctrl) mods |= protocol.MOD_CTRL;
            if (mouse.mods.alt) mods |= protocol.MOD_ALT;

            const button: u8 = switch (mouse.button) {
                .left => protocol.MOUSE_LEFT,
                .middle => protocol.MOUSE_MIDDLE,
                .right => protocol.MOUSE_RIGHT,
                .none => protocol.MOUSE_NONE,
                .wheel_up => protocol.MOUSE_WHEEL_UP,
                .wheel_down => protocol.MOUSE_WHEEL_DOWN,
                .wheel_right => protocol.MOUSE_WHEEL_RIGHT,
                .wheel_left => protocol.MOUSE_WHEEL_LEFT,
                else => return,
            };

            const event_type: u8 = switch (mouse.type) {
                .press => protocol.MOUSE_PRESS,
                .release => protocol.MOUSE_RELEASE,
                .motion => protocol.MOUSE_MOTION,
                .drag => protocol.MOUSE_DRAG,
            };

            var mbuf: [9]u8 = undefined;
            // TUI always sends click_count=1; the BEAM does multi-click detection
            const mlen = try protocol.encodeMouseEvent(&mbuf, mouse.row, mouse.col, button, mods, event_type, 1);
            try protocol.writeMessage(stdout, mbuf[0..mlen]);
            try stdout.flush();
        },

        else => {},
    }
}

/// Read exactly `buf.len` bytes from `fd`, blocking until done.
/// Returns `false` on EOF, `true` when all bytes are read.
pub fn readExact(fd: std.posix.fd_t, buf: []u8) !bool {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(fd, buf[total..]);
        if (n == 0) return false;
        total += n;
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "cellToStyle with no attrs" {
    const style = cellToStyle(.{ .fg = 0xFFFFFF, .bg = 0x000000 });
    try std.testing.expect(style.bold == false);
    try std.testing.expect(style.italic == false);
}

test "cellToStyle with bold and italic" {
    const style = cellToStyle(.{ .attrs = protocol.ATTR_BOLD | protocol.ATTR_ITALIC });
    try std.testing.expect(style.bold == true);
    try std.testing.expect(style.italic == true);
}

test "cellToStyle fg rgb encoding" {
    const style = cellToStyle(.{ .fg = 0xFF8040 });
    switch (style.fg) {
        .rgb => |rgb| {
            try std.testing.expectEqual(@as(u8, 0xFF), rgb[0]);
            try std.testing.expectEqual(@as(u8, 0x80), rgb[1]);
            try std.testing.expectEqual(@as(u8, 0x40), rgb[2]);
        },
        else => return error.UnexpectedColorKind,
    }
}

test "cellToStyle underline and reverse" {
    const style = cellToStyle(.{ .attrs = protocol.ATTR_UNDERLINE | protocol.ATTR_REVERSE });
    try std.testing.expect(style.ul_style == .single);
    try std.testing.expect(style.reverse == true);
}

test "cellToStyle default (all zeros) returns empty style" {
    const style = cellToStyle(.{});
    try std.testing.expect(style.fg == .default);
    try std.testing.expect(style.bg == .default);
    try std.testing.expect(style.bold == false);
    try std.testing.expect(style.italic == false);
    try std.testing.expect(style.ul_style == .off);
    try std.testing.expect(style.reverse == false);
}

test "cellToStyle with all attributes set" {
    const all = protocol.ATTR_BOLD | protocol.ATTR_ITALIC | protocol.ATTR_UNDERLINE | protocol.ATTR_REVERSE;
    const style = cellToStyle(.{ .attrs = all });
    try std.testing.expect(style.bold == true);
    try std.testing.expect(style.italic == true);
    try std.testing.expect(style.ul_style == .single);
    try std.testing.expect(style.reverse == true);
}

test "cellToStyle max color values" {
    const style = cellToStyle(.{ .fg = 0xFFFFFF, .bg = 0xFFFFFF });
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

test "readExact on empty buf succeeds immediately" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fd = try std.posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(fd);
    const result = try readExact(fd, &[_]u8{});
    try std.testing.expect(result == true);
}

test "readExact returns false on EOF reading from /dev/null" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fd = try std.posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(fd);
    var buf: [4]u8 = undefined;
    const result = try readExact(fd, &buf);
    try std.testing.expect(result == false);
}

test "readExact pipe: reads exact bytes written" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    const payload: []const u8 = "ABCD";
    _ = try std.posix.write(fds[1], payload);
    var buf: [4]u8 = undefined;
    const result = try readExact(fds[0], &buf);
    try std.testing.expect(result == true);
    try std.testing.expectEqualSlices(u8, payload, &buf);
}

test "readExact assembles bytes from partial writes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);
    _ = try std.posix.write(fds[1], "AB");
    _ = try std.posix.write(fds[1], "CD");
    var buf: [4]u8 = undefined;
    const result = try readExact(fds[0], &buf);
    try std.testing.expect(result == true);
    try std.testing.expectEqualSlices(u8, "ABCD", &buf);
}

test "g_winch starts as false" {
    try std.testing.expect(g_winch.load(.acquire) == false);
}

test "g_quit starts as false" {
    try std.testing.expect(g_quit.load(.acquire) == false);
}

test "g_winch can be set and read back" {
    g_winch.store(true, .release);
    try std.testing.expect(g_winch.load(.acquire) == true);
    g_winch.store(false, .release);
}

test "g_quit can be set and read back" {
    g_quit.store(true, .release);
    try std.testing.expect(g_quit.load(.acquire) == true);
    g_quit.store(false, .release);
}
