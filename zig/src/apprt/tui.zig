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
const protocol = @import("../protocol.zig");
const renderer_mod = @import("../renderer.zig");
const surface_mod = @import("../surface.zig");
const highlighter_mod = @import("../highlighter.zig");
const terminal_mod = @import("../terminal.zig");
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
    hl: highlighter_mod.Highlighter,
    tty_write_buf: [4096]u8,
    term: ?terminal_mod.Terminal = null,
    terminal_focused: bool = false,

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

        // Install signal handlers.
        installSignalHandlers();

        // Initialize surface, renderer, and highlighter.
        self.surface = .{ .vx = &self.vx, .tty_writer = self.tty.writer() };
        self.rend = renderer_mod.Renderer(VaxisSurface).init(&self.surface, alloc);
        self.hl = try highlighter_mod.Highlighter.init(alloc);
        self.term = null;
        self.terminal_focused = false;

        return self;
    }

    /// Run the event loop. Blocks until quit signal or stdin EOF.
    pub fn run(self: *TuiRuntime) !void {
        // Fix up internal pointers after the struct has been moved to its
        // final location on the caller's stack.
        self.surface.vx = &self.vx;
        self.surface.tty_writer = self.tty.writer();
        self.rend.surface = &self.surface;
        self.hl.startPrewarm();

        // Stdout (Port protocol channel).
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer_obj = std.fs.File.stdout().writer(&stdout_buf);
        const stdout: *std.Io.Writer = &stdout_writer_obj.interface;

        // Send ready event with initial dimensions.
        const initial_ws = try vaxis.Tty.getWinsize(self.tty.fd);
        var ready_payload: [5]u8 = undefined;
        const ready_len = try protocol.encodeReady(&ready_payload, initial_ws.cols, initial_ws.rows);
        try protocol.writeMessage(stdout, ready_payload[0..ready_len]);
        try stdout.flush();

        try self.runEventLoop(stdout);
    }

    /// Clean up: free renderer, vaxis, and restore terminal.
    pub fn deinit(self: *TuiRuntime) void {
        if (self.term) |*t| t.deinit();
        self.hl.deinit();
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

        // pollfds: [0] = stdin (port), [1] = tty, [2] = pty (optional)
        var pollfds = [3]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.tty.fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = -1, .events = std.posix.POLL.IN, .revents = 0 },
        };

        // Track C-\ C-n escape sequence: saw_ctrl_backslash
        var saw_ctrl_backslash = false;

        main_loop: while (true) {
            if (g_quit.load(.acquire)) break :main_loop;

            if (g_winch.swap(false, .acq_rel)) {
                try self.handleResize(stdout);
            }

            // Update PTY pollfd
            const nfds: usize = if (self.term != null and self.term.?.alive) blk: {
                pollfds[2].fd = self.term.?.pty_fd;
                break :blk 3;
            } else blk: {
                pollfds[2].fd = -1;
                break :blk 2;
            };

            _ = try std.posix.poll(pollfds[0..nfds], 100);

            // PTY readable: read shell output and feed to libvterm
            if (nfds == 3 and pollfds[2].revents & std.posix.POLL.IN != 0) {
                if (self.term) |*t| {
                    _ = t.processOutput() catch {};
                    // Re-render terminal cells to surface
                    t.render(&self.surface);
                    self.surface.render() catch {};
                }
            }

            // Check if PTY has HUP (child exited)
            if (nfds == 3) {
                const pty_hup: i16 = std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;
                if (pollfds[2].revents & pty_hup != 0) {
                    if (self.term) |*t| {
                        t.alive = false;
                        // Notify Elixir
                        var ebuf: [5]u8 = undefined;
                        const elen = protocol.encodeTerminalExited(&ebuf, 0) catch 0;
                        if (elen > 0) {
                            protocol.writeMessage(stdout, ebuf[0..elen]) catch {};
                            stdout.flush() catch {};
                        }
                    }
                }
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

                var offset: usize = 0;
                while (offset < msg_len) {
                    const remaining = payload[offset..];
                    const cmd = protocol.decodeCommand(remaining) catch |err| {
                        std.log.warn("protocol decode error at offset {}: {}", .{ offset, err });
                        break;
                    };
                    switch (cmd) {
                        .set_language, .parse_buffer, .set_highlight_query, .load_grammar => {
                            self.handleHighlightCommand(cmd, stdout) catch |err| {
                                std.log.warn("highlight error: {}", .{err});
                            };
                        },
                        .open_terminal, .close_terminal, .resize_terminal, .terminal_input, .terminal_focus => {
                            self.handleTerminalCommand(cmd, stdout) catch |err| {
                                std.log.warn("terminal error: {}", .{err});
                            };
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

                // Always parse through vaxis. In terminal mode, key events
                // are converted to bytes and sent to the PTY. Mouse events
                // are always handled by the editor (never forwarded to PTY).
                {
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

                        if (self.terminal_focused and self.term != null and self.term.?.alive) {
                            switch (event) {
                                .key_press => |key| {
                                    // Check for C-\ C-n escape sequence
                                    if (saw_ctrl_backslash) {
                                        saw_ctrl_backslash = false;
                                        if (key.codepoint == 'n' and key.mods.ctrl) {
                                            // C-\ C-n: unfocus terminal
                                            self.terminal_focused = false;
                                            var kbuf: [6]u8 = undefined;
                                            const klen = protocol.encodeKeyPress(&kbuf, 27, 0) catch 0;
                                            if (klen > 0) {
                                                protocol.writeMessage(stdout, kbuf[0..klen]) catch {};
                                                stdout.flush() catch {};
                                            }
                                            continue;
                                        }
                                        // Not C-n, forward the pending C-\ and this key
                                        self.term.?.writeInput(&[_]u8{0x1C}) catch {};
                                    }

                                    if (key.codepoint == '\\' and key.mods.ctrl) {
                                        saw_ctrl_backslash = true;
                                        continue;
                                    }

                                    // Convert key event to bytes and send to PTY
                                    var input_buf: [16]u8 = undefined;
                                    const input_len = keyToBytes(key, &input_buf);
                                    if (input_len > 0) {
                                        self.term.?.writeInput(input_buf[0..input_len]) catch {};
                                    }
                                },
                                // Mouse events and capabilities always go to editor
                                else => {
                                    handleTtyEvent(&self.vx, event, stdout) catch |err| {
                                        std.log.warn("tty event error: {}", .{err});
                                    };
                                },
                            }
                        } else {
                            handleTtyEvent(&self.vx, event, stdout) catch |err| {
                                std.log.warn("tty event error: {}", .{err});
                            };
                        }
                    }
                }
            }
        }
    }

    /// Handle terminal lifecycle commands from the port protocol.
    fn handleTerminalCommand(self: *TuiRuntime, cmd: protocol.RenderCommand, stdout: *std.Io.Writer) !void {
        switch (cmd) {
            .open_terminal => |ot| {
                std.log.info("open_terminal: shell={s} rows={d} cols={d}", .{ ot.shell, ot.rows, ot.cols });
                // Close existing terminal if any
                if (self.term) |*t| {
                    std.log.info("open_terminal: closing existing terminal (alive={}, fd={d})", .{ t.alive, t.pty_fd });
                    t.deinit();
                    self.term = null;
                }

                // Need a null-terminated shell path for execvp
                var shell_buf: [256]u8 = undefined;
                if (ot.shell.len >= shell_buf.len) return error.Malformed;
                @memcpy(shell_buf[0..ot.shell.len], ot.shell);
                shell_buf[ot.shell.len] = 0;
                const shell_z: [*:0]const u8 = @ptrCast(shell_buf[0..ot.shell.len :0]);

                self.term = terminal_mod.Terminal.init(
                    shell_z,
                    ot.rows,
                    ot.cols,
                    ot.row_offset,
                    ot.col_offset,
                ) catch |err| {
                    std.log.err("Failed to open terminal: {}", .{err});
                    // Send terminal_exited immediately
                    var ebuf: [5]u8 = undefined;
                    const elen = try protocol.encodeTerminalExited(&ebuf, -1);
                    try protocol.writeMessage(stdout, ebuf[0..elen]);
                    try stdout.flush();
                    return;
                };
                self.terminal_focused = true;
            },
            .close_terminal => {
                if (self.term) |*t| {
                    t.deinit();
                    self.term = null;
                    self.terminal_focused = false;
                }
            },
            .resize_terminal => |rt| {
                if (self.term) |*t| {
                    t.resize(rt.rows, rt.cols, rt.row_offset, rt.col_offset);
                }
            },
            .terminal_input => |data| {
                if (self.term) |*t| {
                    t.writeInput(data) catch {};
                }
            },
            .terminal_focus => |focused| {
                self.terminal_focused = focused;
            },
            else => {},
        }
    }

    /// Dispatch a highlight-related command to the Highlighter and send responses.
    fn handleHighlightCommand(self: *TuiRuntime, cmd: protocol.RenderCommand, stdout: *std.Io.Writer) !void {
        switch (cmd) {
            .set_language => |name| {
                if (!self.hl.setLanguage(name)) {
                    std.log.warn("unknown language: {s}", .{name});
                }
            },
            .parse_buffer => |pb| {
                self.hl.parse(pb.source) catch |err| {
                    std.log.warn("parse failed: {}", .{err});
                    return;
                };

                // If a query is loaded, run highlighting and send results
                if (self.hl.query != null) {
                    var result = self.hl.highlight() catch |err| {
                        std.log.warn("highlight failed: {}", .{err});
                        return;
                    };
                    defer result.deinit();

                    // Send capture names first
                    const names_buf = try protocol.encodeHighlightNames(self.alloc, result.capture_names);
                    defer self.alloc.free(names_buf);
                    try protocol.writeMessage(stdout, names_buf);

                    // Send spans with version
                    const spans_buf = try protocol.encodeHighlightSpans(self.alloc, pb.version, result.spans);
                    defer self.alloc.free(spans_buf);
                    try protocol.writeMessage(stdout, spans_buf);

                    try stdout.flush();
                }
            },
            .set_highlight_query => |source| {
                self.hl.setHighlightQuery(source) catch |err| {
                    std.log.warn("query compile failed: {}", .{err});
                };
            },
            .load_grammar => |lg| {
                self.hl.loadGrammar(lg.name, lg.path) catch |err| {
                    std.log.warn("grammar load failed: {}", .{err});
                    var rbuf: [260]u8 = undefined;
                    const rlen = protocol.encodeGrammarLoaded(&rbuf, false, lg.name) catch return;
                    try protocol.writeMessage(stdout, rbuf[0..rlen]);
                    try stdout.flush();
                    return;
                };
                var rbuf: [260]u8 = undefined;
                const rlen = try protocol.encodeGrammarLoaded(&rbuf, true, lg.name);
                try protocol.writeMessage(stdout, rbuf[0..rlen]);
                try stdout.flush();
            },
            else => {},
        }
    }

    fn handleResize(self: *TuiRuntime, stdout: *std.Io.Writer) !void {
        const ws = try vaxis.Tty.getWinsize(self.tty.fd);
        try self.vx.resize(self.alloc, self.tty.writer(), ws);

        var rbuf: [5]u8 = undefined;
        const rlen = try protocol.encodeResize(&rbuf, ws.cols, ws.rows);
        try protocol.writeMessage(stdout, rbuf[0..rlen]);
        try stdout.flush();
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
fn installSignalHandlers() void {
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

/// Converts a vaxis key event to bytes suitable for writing to a PTY.
/// Returns the number of bytes written to `buf`.
fn keyToBytes(key: vaxis.Key, buf: *[16]u8) usize {
    const cp = key.codepoint;

    // Special keys (arrows, function keys, etc.) use codepoints >= 57348
    // Tab/Enter/Escape/Backspace use their ASCII values and are handled
    // by specialKeyToBytes too.
    if (cp >= 57348 or cp == vaxis.Key.escape or cp == vaxis.Key.enter or
        cp == vaxis.Key.tab or cp == vaxis.Key.backspace)
    {
        return specialKeyToBytes(key, buf);
    }

    // Ctrl+key → control code
    if (key.mods.ctrl and !key.mods.alt) {
        if (cp >= 'a' and cp <= 'z') {
            buf[0] = @intCast(cp - 'a' + 1);
            return 1;
        }
        if (cp >= 'A' and cp <= 'Z') {
            buf[0] = @intCast(cp - 'A' + 1);
            return 1;
        }
        // Ctrl+[ = Escape, Ctrl+] = 0x1D, etc.
        if (cp == '[') { buf[0] = 0x1B; return 1; }
        if (cp == ']') { buf[0] = 0x1D; return 1; }
        if (cp == '\\') { buf[0] = 0x1C; return 1; }
        if (cp == '@') { buf[0] = 0x00; return 1; }
        if (cp == '^') { buf[0] = 0x1E; return 1; }
        if (cp == '_') { buf[0] = 0x1F; return 1; }
    }

    // Alt+key → ESC prefix + key
    if (key.mods.alt) {
        buf[0] = 0x1B;
        if (cp < 0x80) {
            if (key.mods.ctrl and cp >= 'a' and cp <= 'z') {
                buf[1] = @intCast(cp - 'a' + 1);
            } else {
                buf[1] = @intCast(cp);
            }
            return 2;
        }
        // Alt + unicode: ESC + UTF-8
        const n = std.unicode.utf8Encode(@intCast(cp), buf[1..]) catch return 0;
        return 1 + n;
    }

    // Regular character → UTF-8
    const n = std.unicode.utf8Encode(@intCast(cp), buf[0..]) catch return 0;
    return n;
}

/// Encodes special keys (arrows, function keys, etc.) as ANSI escape sequences.
fn specialKeyToBytes(key: vaxis.Key, buf: *[16]u8) usize {
    // Map vaxis special key codepoints to escape sequences.
    // vaxis uses codepoints from its Key enum for special keys.
    const Seq = struct { seq: []const u8 };
    const mapping: ?Seq = switch (key.codepoint) {
        vaxis.Key.escape => .{ .seq = "\x1B" },
        vaxis.Key.enter => .{ .seq = "\r" },
        vaxis.Key.tab => .{ .seq = "\t" },
        vaxis.Key.backspace => .{ .seq = "\x7F" },
        vaxis.Key.delete => .{ .seq = "\x1B[3~" },
        vaxis.Key.up => .{ .seq = "\x1B[A" },
        vaxis.Key.down => .{ .seq = "\x1B[B" },
        vaxis.Key.right => .{ .seq = "\x1B[C" },
        vaxis.Key.left => .{ .seq = "\x1B[D" },
        vaxis.Key.home => .{ .seq = "\x1B[H" },
        vaxis.Key.end => .{ .seq = "\x1B[F" },
        vaxis.Key.page_up => .{ .seq = "\x1B[5~" },
        vaxis.Key.page_down => .{ .seq = "\x1B[6~" },
        vaxis.Key.insert => .{ .seq = "\x1B[2~" },
        vaxis.Key.f1 => .{ .seq = "\x1BOP" },
        vaxis.Key.f2 => .{ .seq = "\x1BOQ" },
        vaxis.Key.f3 => .{ .seq = "\x1BOR" },
        vaxis.Key.f4 => .{ .seq = "\x1BOS" },
        vaxis.Key.f5 => .{ .seq = "\x1B[15~" },
        vaxis.Key.f6 => .{ .seq = "\x1B[17~" },
        vaxis.Key.f7 => .{ .seq = "\x1B[18~" },
        vaxis.Key.f8 => .{ .seq = "\x1B[19~" },
        vaxis.Key.f9 => .{ .seq = "\x1B[20~" },
        vaxis.Key.f10 => .{ .seq = "\x1B[21~" },
        vaxis.Key.f11 => .{ .seq = "\x1B[23~" },
        vaxis.Key.f12 => .{ .seq = "\x1B[24~" },
        else => null,
    };

    if (mapping) |m| {
        @memcpy(buf[0..m.seq.len], m.seq);
        return m.seq.len;
    }

    // Unknown special key — try UTF-8 encoding the codepoint
    const n = std.unicode.utf8Encode(@intCast(key.codepoint), buf[0..]) catch return 0;
    return n;
}

/// Process a parsed terminal event.
fn handleTtyEvent(vx: *vaxis.Vaxis, event: vaxis.Event, stdout: *std.Io.Writer) !void {
    switch (event) {
        .key_press => |key| {
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

            var mbuf: [8]u8 = undefined;
            const mlen = try protocol.encodeMouseEvent(&mbuf, mouse.row, mouse.col, button, mods, event_type);
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
