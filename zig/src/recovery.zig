/// Recovery overlay for unresponsive BEAM.
///
/// When the BEAM stops processing events (no render response for
/// `TIMEOUT_MS` after key events were sent), this module detects the
/// condition and provides a recovery menu rendered directly on the
/// terminal via vaxis, bypassing the protocol entirely.
///
/// Recovery options:
///   [r] Restart editor — sends SIGUSR1 to parent BEAM process
///   [q] Quit minga    — exits the Zig process cleanly
///   [w] Wait          — dismiss overlay and keep trying
const std = @import("std");
const vaxis = @import("vaxis");

const Self = @This();

/// How long to wait (in ms) after the last key was sent before
/// considering the BEAM unresponsive. Only triggers if at least
/// one key was sent since the last render.
const TIMEOUT_MS: i64 = 3000;

/// Timestamp (ms) of the last render received from BEAM.
/// Updated when a batch_end command arrives on stdin.
last_render_ms: i64,

/// Timestamp (ms) of the last key event sent to BEAM.
/// Updated when a key_press is enqueued to the PortWriter.
last_key_sent_ms: i64,

/// Number of key events sent since the last render response.
keys_since_render: u32,

/// Whether the recovery overlay is currently displayed.
showing: bool,

/// Initialize with current time.
pub fn init() Self {
    const now = std.time.milliTimestamp();
    return .{
        .last_render_ms = now,
        .last_key_sent_ms = 0,
        .keys_since_render = 0,
        .showing = false,
    };
}

/// Called when a batch_end command is received from the BEAM.
/// Resets the unresponsive timer.
pub fn onRenderReceived(self: *Self) void {
    self.last_render_ms = std.time.milliTimestamp();
    self.keys_since_render = 0;
    self.showing = false;
}

/// Called when a key event is enqueued to the PortWriter.
pub fn onKeySent(self: *Self) void {
    self.last_key_sent_ms = std.time.milliTimestamp();
    self.keys_since_render += 1;
}

/// Returns true if the BEAM appears unresponsive.
pub fn isUnresponsive(self: *const Self) bool {
    if (self.keys_since_render == 0) return false;
    const now = std.time.milliTimestamp();
    const elapsed = now - self.last_render_ms;
    return elapsed > TIMEOUT_MS;
}

/// Action chosen by the user from the recovery menu.
pub const Action = enum {
    restart,
    quit,
    wait,
    none,
};

/// Handle a key press while the recovery overlay is showing.
/// Returns the action chosen, or .none if the key wasn't a menu key.
pub fn handleRecoveryKey(self: *Self, codepoint: u21) Action {
    if (!self.showing) return .none;

    return switch (codepoint) {
        'r', 'R' => blk: {
            self.showing = false;
            break :blk .restart;
        },
        'q', 'Q' => blk: {
            self.showing = false;
            break :blk .quit;
        },
        'w', 'W', 0x1b => blk: { // 0x1b = Escape
            self.showing = false;
            break :blk .wait;
        },
        else => .none,
    };
}

/// Show the recovery overlay.
pub fn show(self: *Self) void {
    self.showing = true;
}

/// Render the recovery overlay directly on the terminal using vaxis.
/// This bypasses the port protocol entirely, writing straight to the tty.
pub fn render(vx: *vaxis.Vaxis, tty_writer: anytype) !void {
    const win = vx.window();
    const total_w = win.width;
    const total_h = win.height;

    // Box dimensions.
    const box_w: u16 = 46;
    const box_h: u16 = 7;

    // Center the box.
    const x: u16 = if (total_w > box_w) (total_w - box_w) / 2 else 0;
    const y: u16 = if (total_h > box_h) (total_h - box_h) / 2 else 0;

    const border_style: vaxis.Cell.Style = .{
        .fg = .{ .rgb = .{ 0xFF, 0x66, 0x66 } }, // red
        .bg = .{ .rgb = .{ 0x1a, 0x1a, 0x2e } }, // dark bg
        .bold = true,
    };

    const text_style: vaxis.Cell.Style = .{
        .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } }, // light gray
        .bg = .{ .rgb = .{ 0x1a, 0x1a, 0x2e } },
    };

    const key_style: vaxis.Cell.Style = .{
        .fg = .{ .rgb = .{ 0x66, 0xFF, 0x66 } }, // green
        .bg = .{ .rgb = .{ 0x1a, 0x1a, 0x2e } },
        .bold = true,
    };

    // Top border
    writeAt(win, x, y, "\xe2\x94\x8c\xe2\x94\x80 Editor Unresponsive \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x90", border_style);
    // Empty line
    writeAt(win, x, y + 1, "\xe2\x94\x82                                            \xe2\x94\x82", border_style);
    // Option lines with mixed styles
    writeAt(win, x, y + 2, "\xe2\x94\x82  ", border_style);
    writeAt(win, x + 3, y + 2, "[r]", key_style);
    writeAt(win, x + 6, y + 2, " Restart editor (buffers preserved)  ", text_style);
    writeAt(win, x + box_w - 1, y + 2, "\xe2\x94\x82", border_style);

    writeAt(win, x, y + 3, "\xe2\x94\x82  ", border_style);
    writeAt(win, x + 3, y + 3, "[q]", key_style);
    writeAt(win, x + 6, y + 3, " Quit minga                          ", text_style);
    writeAt(win, x + box_w - 1, y + 3, "\xe2\x94\x82", border_style);

    writeAt(win, x, y + 4, "\xe2\x94\x82  ", border_style);
    writeAt(win, x + 3, y + 4, "[w]", key_style);
    writeAt(win, x + 6, y + 4, " Wait (continue trying)              ", text_style);
    writeAt(win, x + box_w - 1, y + 4, "\xe2\x94\x82", border_style);

    // Empty line
    writeAt(win, x, y + 5, "\xe2\x94\x82                                            \xe2\x94\x82", border_style);
    // Bottom border
    writeAt(win, x, y + 6, "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x98", border_style);

    try vx.render(tty_writer);
}

/// Write a string at a given position with a style.
fn writeAt(win: vaxis.Window, col: u16, row: u16, text: []const u8, style: vaxis.Cell.Style) void {
    var c: u16 = col;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const raw = grapheme.bytes(text);
        const w: u16 = vaxis.gwidth.gwidth(raw, .wcwidth);
        if (c + w <= win.width and row < win.height) {
            win.writeCell(c, row, .{
                .char = .{ .grapheme = raw, .width = @intCast(w) },
                .style = style,
            });
        }
        c +|= if (w == 0) 1 else w;
    }
}

/// Send SIGUSR1 to the parent process (the BEAM VM).
/// Uses raw syscalls on Linux to avoid requiring libc linkage.
/// On macOS, libc is always linked so std.c.getppid() is fine.
pub fn sendRestartSignal() void {
    const parent_pid = getParentPid();
    if (parent_pid > 1) {
        std.posix.kill(parent_pid, std.posix.SIG.USR1) catch {};
    }
}

/// Get the parent process ID. Uses a raw syscall on Linux (no libc
/// dependency) and the libc wrapper on macOS (always available).
fn getParentPid() std.posix.pid_t {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .linux => @bitCast(@as(u32, @truncate(std.os.linux.syscall0(.getppid)))),
        .macos, .ios => std.c.getppid(),
        else => 0,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "init starts non-unresponsive" {
    const r = init();
    try std.testing.expect(!r.isUnresponsive());
    try std.testing.expect(!r.showing);
}

test "becomes unresponsive after timeout with pending keys" {
    var r = init();
    // Simulate: render came 4 seconds ago, key sent 1 second ago
    r.last_render_ms = std.time.milliTimestamp() - 4000;
    r.last_key_sent_ms = std.time.milliTimestamp() - 1000;
    r.keys_since_render = 3;
    try std.testing.expect(r.isUnresponsive());
}

test "not unresponsive if no keys sent" {
    var r = init();
    r.last_render_ms = std.time.milliTimestamp() - 10000;
    r.keys_since_render = 0;
    try std.testing.expect(!r.isUnresponsive());
}

test "render resets unresponsive state" {
    var r = init();
    r.last_render_ms = std.time.milliTimestamp() - 4000;
    r.keys_since_render = 5;
    r.showing = true;
    r.onRenderReceived();
    try std.testing.expect(!r.isUnresponsive());
    try std.testing.expect(!r.showing);
    try std.testing.expectEqual(@as(u32, 0), r.keys_since_render);
}

test "handleRecoveryKey returns correct actions" {
    var r = init();
    r.showing = true;
    try std.testing.expectEqual(Action.restart, r.handleRecoveryKey('r'));

    r.showing = true;
    try std.testing.expectEqual(Action.quit, r.handleRecoveryKey('q'));

    r.showing = true;
    try std.testing.expectEqual(Action.wait, r.handleRecoveryKey('w'));

    r.showing = true;
    try std.testing.expectEqual(Action.wait, r.handleRecoveryKey(0x1b)); // Escape

    r.showing = true;
    try std.testing.expectEqual(Action.none, r.handleRecoveryKey('x'));
}

test "handleRecoveryKey returns none when not showing" {
    var r = init();
    r.showing = false;
    try std.testing.expectEqual(Action.none, r.handleRecoveryKey('r'));
}
