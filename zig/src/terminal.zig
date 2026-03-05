/// Terminal — PTY management and libvterm integration.
///
/// Spawns a shell process attached to a pseudo-terminal, feeds its output
/// through libvterm for VT state machine parsing, and exposes a cell grid
/// that the renderer can draw to the surface.
const std = @import("std");
const builtin = @import("builtin");
const surface_mod = @import("surface.zig");
const Cell = surface_mod.Cell;
const protocol = @import("protocol.zig");

/// TIOCSWINSZ ioctl number. Zig's std.posix.T has this on Linux but not
/// macOS (stdlib gap: only IOCGWINSZ is exposed for Darwin). We use the
/// stdlib value when available, falling back to the well-known constant.
const TIOCSWINSZ = if (@hasDecl(std.posix.T, "IOCSWINSZ"))
    std.posix.T.IOCSWINSZ
else
    0x80087467; // _IOW('t', 103, struct winsize) — stable since 4.4BSD

const c = @cImport({
    @cInclude("vterm_wrapper.h");
    @cInclude("stdlib.h");
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/ttycom.h");
    @cInclude("sys/wait.h");
});

pub const Terminal = struct {
    vt: c.MingaVTerm,
    screen: c.MingaVTermScreen,
    pty_fd: std.posix.fd_t,
    child_pid: c.pid_t,
    rows: u16,
    cols: u16,
    /// Offset on the screen where this terminal region starts.
    row_offset: u16,
    col_offset: u16,
    alive: bool,

    /// Spawns a shell attached to a PTY and initializes libvterm.
    pub fn init(shell: [*:0]const u8, rows: u16, cols: u16, row_offset: u16, col_offset: u16) !Terminal {
        var ws: c.struct_winsize = .{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var master_fd: c_int = undefined;
        const pid = c.forkpty(&master_fd, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;

        if (pid == 0) {
            // Child process — exec the shell.
            _ = c.setenv("TERM", "xterm-256color", 1);
            const args = [_:null]?[*:0]const u8{shell};
            _ = c.execvp(shell, @ptrCast(&args));
            c._exit(1);
        }

        // Parent process.
        const vt = c.minga_vterm_new(@intCast(rows), @intCast(cols));
        if (vt == null) return error.VTermInitFailed;
        c.minga_vterm_set_utf8(vt, 1);

        const screen = c.minga_vterm_obtain_screen(vt);
        if (screen == null) return error.VTermScreenFailed;
        c.minga_vterm_screen_enable_altscreen(screen, 1);
        c.minga_vterm_screen_reset(screen, 1);

        return .{
            .vt = vt,
            .screen = screen,
            .pty_fd = master_fd,
            .child_pid = pid,
            .rows = rows,
            .cols = cols,
            .row_offset = row_offset,
            .col_offset = col_offset,
            .alive = true,
        };
    }

    /// Reads available output from the PTY and feeds it to libvterm.
    /// Returns the number of bytes processed, or 0 if nothing was available.
    pub fn processOutput(self: *Terminal) !usize {
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(self.pty_fd, &buf) catch |err| {
            if (err == error.WouldBlock) return 0;
            self.alive = false;
            return 0;
        };
        if (n == 0) {
            self.alive = false;
            return 0;
        }
        const written = c.minga_vterm_input_write(self.vt, @ptrCast(&buf), n);
        return @intCast(written);
    }

    /// Writes input (keystrokes) to the PTY.
    pub fn writeInput(self: *Terminal, data: []const u8) !void {
        var total: usize = 0;
        while (total < data.len) {
            const n = std.posix.write(self.pty_fd, data[total..]) catch |err| {
                if (err == error.WouldBlock) continue;
                return err;
            };
            total += n;
        }
    }

    /// Resizes the terminal and PTY.
    pub fn resize(self: *Terminal, rows: u16, cols: u16, row_offset: u16, col_offset: u16) void {
        self.rows = rows;
        self.cols = cols;
        self.row_offset = row_offset;
        self.col_offset = col_offset;

        c.minga_vterm_set_size(self.vt, @intCast(rows), @intCast(cols));

        var ws: c.struct_winsize = .{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        // Zig declares ioctl request as c_int, but macOS uses unsigned long.
        // @bitCast reinterprets the u32 value without range checking.
        _ = std.posix.system.ioctl(self.pty_fd, @bitCast(@as(u32, TIOCSWINSZ)), @intFromPtr(&ws));
    }

    /// Renders the libvterm screen buffer to the surface.
    pub fn render(self: *Terminal, surf: anytype) void {
        var cell: c.MingaCell = undefined;
        var grapheme_buf: [32]u8 = undefined;

        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            var col: u16 = 0;
            while (col < self.cols) : (col += 1) {
                if (c.minga_vterm_screen_get_cell(self.screen, @intCast(row), @intCast(col), &cell) == 0) continue;

                // Convert codepoints to UTF-8
                var grapheme_len: usize = 0;
                if (cell.chars[0] == 0) {
                    grapheme_buf[0] = ' ';
                    grapheme_len = 1;
                } else {
                    var i: usize = 0;
                    while (i < 6 and cell.chars[i] != 0) : (i += 1) {
                        const cp: u21 = @intCast(cell.chars[i]);
                        const n = std.unicode.utf8Encode(cp, grapheme_buf[grapheme_len..]) catch break;
                        grapheme_len += n;
                    }
                }

                // Build color values
                var fg: u24 = 0;
                if (cell.fg_is_rgb != 0) {
                    fg = @as(u24, cell.fg_red) << 16 | @as(u24, cell.fg_green) << 8 | @as(u24, cell.fg_blue);
                }
                var bg: u24 = 0;
                if (cell.bg_is_rgb != 0) {
                    bg = @as(u24, cell.bg_red) << 16 | @as(u24, cell.bg_green) << 8 | @as(u24, cell.bg_blue);
                }

                // Build attribute flags
                var attrs: u8 = 0;
                if (cell.bold != 0) attrs |= protocol.ATTR_BOLD;
                if (cell.italic != 0) attrs |= protocol.ATTR_ITALIC;
                if (cell.underline != 0) attrs |= protocol.ATTR_UNDERLINE;
                if (cell.reverse != 0) attrs |= protocol.ATTR_REVERSE;

                surf.writeCell(
                    self.col_offset + col,
                    self.row_offset + row,
                    .{
                        .grapheme = grapheme_buf[0..grapheme_len],
                        .width = if (cell.width > 0) @intCast(cell.width) else 1,
                        .fg = fg,
                        .bg = bg,
                        .attrs = attrs,
                    },
                );
            }
        }
    }

    /// Checks if the child process has exited.
    pub fn checkAlive(self: *Terminal) bool {
        if (!self.alive) return false;
        var status: c_int = 0;
        const result = c.waitpid(self.child_pid, &status, c.WNOHANG);
        if (result > 0) {
            self.alive = false;
            return false;
        }
        return true;
    }

    /// Cleans up the PTY and libvterm.
    pub fn deinit(self: *Terminal) void {
        std.log.info("Terminal.deinit: alive={} pty_fd={d} pid={d}", .{ self.alive, self.pty_fd, self.child_pid });
        if (self.alive) {
            _ = c.kill(self.child_pid, c.SIGTERM);
            _ = c.waitpid(self.child_pid, null, 0);
        }
        // Use C close() instead of std.posix.close() because the latter
        // panics on EBADF in safe mode. The PTY fd may already be closed
        // if the child process exited and the kernel cleaned up.
        if (self.pty_fd >= 0) {
            _ = c.close(self.pty_fd);
        }
        c.minga_vterm_free(self.vt);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Terminal: libvterm wrapper links and initializes" {
    const vt = c.minga_vterm_new(24, 80);
    try std.testing.expect(vt != null);
    defer c.minga_vterm_free(vt);

    const screen = c.minga_vterm_obtain_screen(vt);
    try std.testing.expect(screen != null);
}

test "Terminal: can get cell from initialized screen" {
    const vt = c.minga_vterm_new(24, 80);
    defer c.minga_vterm_free(vt);
    const screen = c.minga_vterm_obtain_screen(vt);
    c.minga_vterm_screen_reset(screen, 1);

    var cell: c.MingaCell = undefined;
    const result = c.minga_vterm_screen_get_cell(screen, 0, 0, &cell);
    try std.testing.expectEqual(@as(c_int, 1), result);
    // Empty cell should have width 1
    try std.testing.expect(cell.width >= 1);
}

test "Terminal: feeding input produces cells" {
    const vt = c.minga_vterm_new(24, 80);
    defer c.minga_vterm_free(vt);
    const screen = c.minga_vterm_obtain_screen(vt);
    c.minga_vterm_screen_reset(screen, 1);

    // Write "Hi" to the terminal
    const written = c.minga_vterm_input_write(vt, "Hi", 2);
    try std.testing.expectEqual(@as(usize, 2), written);

    // Cell at (0,0) should be 'H'
    var cell: c.MingaCell = undefined;
    _ = c.minga_vterm_screen_get_cell(screen, 0, 0, &cell);
    try std.testing.expectEqual(@as(u32, 'H'), cell.chars[0]);

    // Cell at (0,1) should be 'i'
    _ = c.minga_vterm_screen_get_cell(screen, 0, 1, &cell);
    try std.testing.expectEqual(@as(u32, 'i'), cell.chars[0]);
}
