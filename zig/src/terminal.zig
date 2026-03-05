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

const c = @cImport({
    @cInclude("vterm.h");
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
});

pub const Terminal = struct {
    vt: *c.VTerm,
    screen: *c.VTermScreen,
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
            // Set TERM so programs know they have color support.
            _ = c.setenv("TERM", "xterm-256color", 1);
            const args = [_:null]?[*:0]const u8{ shell, null };
            _ = c.execvp(shell, &args);
            // If exec fails, exit the child.
            c._exit(1);
        }

        // Parent process.
        const vt = c.vterm_new(@intCast(rows), @intCast(cols)) orelse return error.VTermInitFailed;
        c.vterm_set_utf8(vt, 1);

        const screen = c.vterm_obtain_screen(vt) orelse return error.VTermScreenFailed;
        c.vterm_screen_enable_altscreen(screen, 1);
        c.vterm_screen_reset(screen, 1);

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
            // PTY closed — child exited
            self.alive = false;
            return 0;
        };
        if (n == 0) {
            self.alive = false;
            return 0;
        }
        const written = c.vterm_input_write(self.vt, &buf, n);
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

        // Resize libvterm
        c.vterm_set_size(self.vt, @intCast(rows), @intCast(cols));

        // Resize the PTY so the child process knows
        var ws: c.struct_winsize = .{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = std.c.ioctl(self.pty_fd, std.posix.T.IOCSWINSZ, @intFromPtr(&ws));
    }

    /// Renders the libvterm screen buffer to the surface.
    pub fn render(self: *Terminal, surf: anytype) void {
        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            var col: u16 = 0;
            while (col < self.cols) : (col += 1) {
                var vt_cell: c.VTermScreenCell = undefined;
                const pos = c.VTermPos{ .row = @intCast(row), .col = @intCast(col) };
                _ = c.vterm_screen_get_cell(self.screen, pos, &vt_cell);

                const cell = vtermCellToSurfaceCell(&vt_cell);
                surf.writeCell(
                    self.col_offset + col,
                    self.row_offset + row,
                    cell,
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
        if (self.alive) {
            _ = c.kill(self.child_pid, c.SIGTERM);
            _ = c.waitpid(self.child_pid, null, 0);
        }
        std.posix.close(self.pty_fd);
        c.vterm_free(self.vt);
    }
};

/// Converts a libvterm screen cell to a surface Cell.
fn vtermCellToSurfaceCell(vt_cell: *const c.VTermScreenCell) Cell {
    // Extract the character (UTF-8 encode the codepoints)
    var grapheme_buf: [16]u8 = undefined;
    var grapheme_len: usize = 0;

    if (vt_cell.chars[0] == 0) {
        // Empty cell — use space
        grapheme_buf[0] = ' ';
        grapheme_len = 1;
    } else {
        // Encode each codepoint as UTF-8
        var i: usize = 0;
        while (i < c.VTERM_MAX_CHARS_PER_CELL and vt_cell.chars[i] != 0) : (i += 1) {
            const cp: u21 = @intCast(vt_cell.chars[i]);
            const n = std.unicode.utf8Encode(cp, grapheme_buf[grapheme_len..]) catch break;
            grapheme_len += n;
        }
    }

    // Extract colors
    const fg = vtermColorToRgb(&vt_cell.fg);
    const bg = vtermColorToRgb(&vt_cell.bg);

    // Extract attributes — access via @bitCast to handle C bitfield layout.
    // libvterm's VTermScreenCellAttrs is a packed bitfield struct that Zig's
    // cImport may not translate perfectly. We read the raw bits and mask.
    const attrs_raw: u32 = @bitCast(vt_cell.attrs);
    var attrs: u8 = 0;
    if (attrs_raw & 1 != 0) attrs |= protocol.ATTR_BOLD; // bit 0: bold
    if (attrs_raw & 2 != 0) attrs |= protocol.ATTR_UNDERLINE; // bit 1: underline
    if (attrs_raw & 4 != 0) attrs |= protocol.ATTR_ITALIC; // bit 2: italic
    // bit 4: reverse
    if (attrs_raw & 16 != 0) attrs |= protocol.ATTR_REVERSE;

    return .{
        .grapheme = grapheme_buf[0..grapheme_len],
        .width = if (vt_cell.width > 0) @intCast(vt_cell.width) else 1,
        .fg = fg,
        .bg = bg,
        .attrs = attrs,
    };
}

/// Converts a VTermColor to a 24-bit RGB value.
fn vtermColorToRgb(color: *const c.VTermColor) u24 {
    // libvterm colors can be indexed or RGB. Check the type field.
    if (c.VTERM_COLOR_IS_RGB(color)) {
        return @as(u24, color.rgb.red) << 16 |
            @as(u24, color.rgb.green) << 8 |
            @as(u24, color.rgb.blue);
    }
    // For indexed colors, return 0 (default terminal color).
    // A more complete implementation would map the 256-color palette.
    return 0;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Terminal: libvterm links and initializes" {
    // Verify libvterm is linked correctly by creating and freeing a VTerm.
    const vt = c.vterm_new(24, 80) orelse return error.VTermInitFailed;
    defer c.vterm_free(vt);

    const screen = c.vterm_obtain_screen(vt);
    try std.testing.expect(screen != null);
}
