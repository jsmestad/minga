/// Minga terminal renderer — entry point and event loop.
///
/// Runs as a BEAM Port:
///   stdin  ← render commands (4-byte big-endian length-prefixed binary)
///   stdout → input events   (4-byte big-endian length-prefixed binary)
///   /dev/tty                terminal I/O via libvaxis
///
/// Event loop overview:
///   1. Open /dev/tty via libvaxis Tty; enter alternate screen.
///   2. Send a `ready` event (opcode 0x03) to BEAM with initial dimensions.
///   3. poll() on stdin fd + tty fd simultaneously:
///        • tty fd readable  → parse bytes with vaxis.Parser → encode key events
///                             → write length-prefixed message to stdout.
///        • stdin fd readable → read length-prefixed Port message → decode →
///                             pass to Renderer.handleCommand().
///   4. SIGWINCH → resize vx screen, send `resize` event to BEAM.
///   5. SIGTERM / SIGINT → set quit flag, break loop.
///   6. stdin EOF (BEAM closed the port) → break loop.
///   7. Deferred vx.deinit() + tty.deinit() restore terminal state on all paths.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
pub const protocol = @import("protocol.zig");
pub const renderer = @import("renderer.zig");

// ── Panic handler ─────────────────────────────────────────────────────────────
// Restores terminal state via libvaxis's global tty reference before printing
// the panic message.  Covers crashes that bypass defer.
//
// Uses std.debug.FullPanic (Zig 0.15 API) which wraps our 2-arg function and
// auto-generates the safety-panic entry points (outOfBounds, unwrapError, …).

fn panicImpl(msg: []const u8, ret_addr: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(msg, ret_addr);
}

pub const panic = std.debug.FullPanic(panicImpl);

// ── Global signal flags ───────────────────────────────────────────────────────

var g_winch: std.atomic.Value(bool) = .init(false);
var g_quit: std.atomic.Value(bool) = .init(false);

fn sigwinchHandler(_: c_int) callconv(.c) void {
    g_winch.store(true, .release);
}

fn sigquitHandler(_: c_int) callconv(.c) void {
    g_quit.store(true, .release);
}

// ── TTY initialization ────────────────────────────────────────────────────────

/// Initializes a PosixTty, preferring the MINGA_TTY env var (set by the BEAM
/// Port Manager) over the default /dev/tty.  This is necessary because Erlang's
/// port spawning may disconnect the child from the controlling terminal.
fn initTty(buffer: []u8) !vaxis.Tty {
    const posix = std.posix;

    // Try MINGA_TTY first (explicit device path from parent), then /dev/tty.
    const tty_path: [*:0]const u8 = std.posix.getenvZ("MINGA_TTY") orelse "/dev/tty";
    std.log.info("Opening tty: {s}", .{tty_path});

    const fd = try posix.openZ(tty_path, .{ .ACCMODE = .RDWR }, 0);

    // Make the terminal raw (same as PosixTty.init does internally).
    const termios = try vaxis.Tty.makeRaw(fd);

    // Note: we skip installing libvaxis's SIGWINCH handler here because
    // installSignalHandlers() in main() installs our own handler that sets
    // g_winch and is checked in the event loop.

    const file = std.fs.File{ .handle = fd };

    const tty: vaxis.Tty = .{
        .fd = fd,
        .termios = termios,
        .tty_writer = .initStreaming(file, buffer),
    };

    // Set the global tty reference so vaxis.recover() works in panics.
    vaxis.tty.global_tty = tty;

    return tty;
}

// ── Entry point ───────────────────────────────────────────────────────────────

/// Main entry point for the Minga renderer process.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // ── Terminal setup ────────────────────────────────────────────────────────

    // 4 KiB write buffer for the TTY; libvaxis flushes it on each render.
    var tty_write_buf: [4096]u8 = undefined;

    // When spawned as a BEAM Port, the child process may not have a controlling
    // terminal (Erlang's port spawning can call setsid()), so /dev/tty fails
    // with ENXIO.  The Port Manager passes the real tty device path (e.g.
    // /dev/ttys003) via the MINGA_TTY environment variable.
    var tty = initTty(&tty_write_buf) catch |err| {
        std.log.err("Failed to initialize TTY: {}", .{err});
        return err;
    };
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    // deinit frees screen buffers and resets terminal escape sequences.
    defer vx.deinit(alloc, tty.writer());

    // Allocate screen buffers at the real terminal size.
    const initial_ws = try vaxis.Tty.getWinsize(tty.fd);
    try vx.resize(alloc, tty.writer(), initial_ws);

    // Alternate screen keeps existing terminal output intact.
    try vx.enterAltScreen(tty.writer());

    // ── Signal handlers ───────────────────────────────────────────────────────

    installSignalHandlers();

    // ── Stdout (Port protocol channel) ────────────────────────────────────────

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer_obj = std.fs.File.stdout().writer(&stdout_buf);
    const stdout: *std.Io.Writer = &stdout_writer_obj.interface;

    // Inform BEAM we are ready and supply our initial terminal dimensions.
    var ready_payload: [5]u8 = undefined;
    const ready_len = try protocol.encodeReady(&ready_payload, initial_ws.cols, initial_ws.rows);
    try protocol.writeMessage(stdout, ready_payload[0..ready_len]);
    try stdout.flush();

    // ── Renderer ─────────────────────────────────────────────────────────────

    var rend = renderer.Renderer.init(&vx, tty.writer(), alloc);
    defer rend.deinit();

    // ── Event loop ────────────────────────────────────────────────────────────

    try runEventLoop(alloc, &vx, &tty, &rend, stdout);
}

// ── Event loop ────────────────────────────────────────────────────────────────

/// Concurrent poll loop: handles tty input events and Port render commands.
fn runEventLoop(
    alloc: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    rend: *renderer.Renderer,
    stdout: *std.Io.Writer,
) !void {
    const stdin_fd = std.posix.STDIN_FILENO;

    // Parser state for decoding terminal escape sequences.
    var tty_parser: vaxis.Parser = .{};
    var tty_read_buf: [1024]u8 = undefined;
    var tty_read_start: usize = 0;

    // Fixed 64 KiB buffer for Port message payloads.
    // Protocol messages are bounded by typical terminal render batch sizes.
    var msg_buf: [65536]u8 = undefined;

    var pollfds = [2]std.posix.pollfd{
        .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = tty.fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    main_loop: while (true) {
        // ── Check quit signal ─────────────────────────────────────────────
        if (g_quit.load(.acquire)) break :main_loop;

        // ── Handle pending SIGWINCH ───────────────────────────────────────
        if (g_winch.swap(false, .acq_rel)) {
            try handleResize(alloc, vx, tty, stdout);
        }

        // Wait up to 1 second so SIGWINCH / g_quit are polled regularly.
        // std.posix.poll() retries automatically on EINTR, so signal
        // delivery will be noticed on the next loop iteration (within ~1 s).
        _ = try std.posix.poll(&pollfds, 1000);

        // ── stdin readable (Port command from BEAM) ───────────────────────
        if (pollfds[0].revents & std.posix.POLL.IN != 0) {
            // Read 4-byte big-endian length prefix.
            var len_buf: [4]u8 = undefined;
            const ok = try readExact(stdin_fd, &len_buf);
            if (!ok) break :main_loop; // stdin EOF → BEAM closed the port

            const msg_len: usize = std.mem.readInt(u32, &len_buf, .big);
            if (msg_len == 0) continue :main_loop;
            if (msg_len > msg_buf.len) {
                std.log.err("Port message too large: {} bytes", .{msg_len});
                break :main_loop;
            }

            const payload = msg_buf[0..msg_len];
            if (!try readExact(stdin_fd, payload)) break :main_loop;

            const cmd = protocol.decodeCommand(payload) catch |err| {
                std.log.warn("protocol decode error: {}", .{err});
                continue :main_loop;
            };

            rend.handleCommand(cmd) catch |err| {
                std.log.warn("renderer error: {}", .{err});
            };
        }

        // ── stdin HUP / error (BEAM closed the port) ──────────────────────
        const hup_mask: i16 = std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;
        if (pollfds[0].revents & hup_mask != 0) break :main_loop;

        // ── tty readable (key press / escape sequence from user) ──────────
        if (pollfds[1].revents & std.posix.POLL.IN != 0) {
            const n = try std.posix.read(tty.fd, tty_read_buf[tty_read_start..]);
            if (n == 0) break :main_loop; // tty closed unexpectedly

            // The parser may need multiple passes if a sequence is split
            // across reads.  We mirror the Loop.ttyRun algorithm exactly.
            var seq_start: usize = 0;
            tty_parse_loop: while (seq_start < n) {
                const result = try tty_parser.parse(tty_read_buf[seq_start..n], null);
                if (result.n == 0) {
                    // Incomplete sequence: shift remaining bytes to front and
                    // remember where to continue next read.
                    const remaining = n - seq_start;
                    std.mem.copyForwards(u8, tty_read_buf[0..remaining], tty_read_buf[seq_start..n]);
                    tty_read_start = remaining;
                    break :tty_parse_loop;
                }
                tty_read_start = 0;
                seq_start += result.n;

                const event = result.event orelse continue;
                handleTtyEvent(vx, event, stdout) catch |err| {
                    std.log.warn("tty event error: {}", .{err});
                };
            }
        }
    }
    // Deferred cleanup in main() restores the terminal on all exit paths.
}

// ── Helpers ───────────────────────────────────────────────────────────────────

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

/// Resize the vaxis screen and notify BEAM of the new dimensions.
fn handleResize(
    alloc: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    stdout: *std.Io.Writer,
) !void {
    const ws = try vaxis.Tty.getWinsize(tty.fd);
    try vx.resize(alloc, tty.writer(), ws);

    var rbuf: [5]u8 = undefined;
    const rlen = try protocol.encodeResize(&rbuf, ws.cols, ws.rows);
    try protocol.writeMessage(stdout, rbuf[0..rlen]);
    try stdout.flush();
}

/// Process a parsed terminal event.
///
/// Key presses are encoded and sent to the BEAM over stdout.
/// Terminal capability advertisements update vx.caps in-place.
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

        // Update capability flags so vx.render() uses optimal escape sequences.
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
            // Wake any thread blocked in vx.queryTerminal() (none in our
            // single-threaded loop, but safe to call unconditionally).
            std.Thread.Futex.wake(&vx.query_futex, 10);
            vx.queries_done.store(true, .unordered);
        },

        // We don't forward mouse / focus / paste to BEAM in this MVP.
        else => {},
    }
}

/// Read exactly `buf.len` bytes from `fd`, blocking until done.
///
/// Returns `false` on EOF (zero-length read), `true` when all bytes are read.
fn readExact(fd: std.posix.fd_t, buf: []u8) !bool {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(fd, buf[total..]);
        if (n == 0) return false; // EOF
        total += n;
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "smoke test: main module compiles" {
    try std.testing.expect(true);
}

test "readExact on empty buf succeeds immediately" {
    // readExact with a zero-length buffer should return true without reading.
    // We simulate with /dev/null on POSIX.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fd = try std.posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer std.posix.close(fd);
    const result = try readExact(fd, &[_]u8{});
    try std.testing.expect(result == true);
}

test "readExact returns false on EOF reading from /dev/null" {
    // /dev/null returns 0 bytes immediately, so readExact on a non-empty
    // buffer returns false (EOF) without blocking.
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
    // Two writes of 2 bytes each; readExact must collect all 4.
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
    g_winch.store(false, .release); // restore
}

test "g_quit can be set and read back" {
    g_quit.store(true, .release);
    try std.testing.expect(g_quit.load(.acquire) == true);
    g_quit.store(false, .release); // restore
}

// Pull in all module tests (protocol.zig + renderer.zig).
test {
    _ = protocol;
    _ = renderer;
}
