/// Minga renderer — entry point and backend dispatch.
///
/// Runs as a BEAM Port:
///   stdin  ← render commands (4-byte big-endian length-prefixed binary)
///   stdout → input events   (4-byte big-endian length-prefixed binary)
///
/// The backend is selected at build time via `-Dbackend=tui` (default).
/// Each backend owns its event loop and rendering surface.
const std = @import("std");
const build_options = @import("build_options");
pub const protocol = @import("protocol.zig");
pub const renderer = @import("renderer.zig");
pub const surface = @import("surface.zig");
pub const apprt = @import("apprt.zig");
pub const font = if (build_options.backend == .gui) @import("font/main.zig") else struct {};
// Note: highlighter.zig is compiled into minga-parser, not the renderer.


// Vaxis is only needed for the TUI panic recovery path.
const vaxis = if (build_options.backend == .tui) @import("vaxis") else struct {};

// ── Panic handler ─────────────────────────────────────────────────────────────
// Restores terminal state (TUI only) before printing the panic message.

fn panicImpl(msg: []const u8, ret_addr: ?usize) noreturn {
    if (build_options.backend == .tui) {
        vaxis.recover();
    }
    std.debug.defaultPanic(msg, ret_addr);
}

pub const panic = std.debug.FullPanic(panicImpl);

// ── Custom log function ───────────────────────────────────────────────────────
// Routes std.log calls over the port protocol to the BEAM instead of stderr.
// Before the port writer is initialized, messages are silently discarded.

/// Module-level writer for the port channel (stdout). Set by the TUI runtime
/// during startup, before the event loop begins.
pub var g_port_writer: ?*std.Io.Writer = null;

fn mingaLogFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = scope;

    const writer = g_port_writer orelse return;

    const level: u8 = switch (message_level) {
        .err => protocol.LOG_LEVEL_ERR,
        .warn => protocol.LOG_LEVEL_WARN,
        .info => protocol.LOG_LEVEL_INFO,
        .debug => protocol.LOG_LEVEL_DEBUG,
    };

    // Format the message into a stack buffer. Truncate if it doesn't fit.
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, format, args) catch msg_buf[0..msg_buf.len];

    var payload_buf: [4096 + 4]u8 = undefined;
    const payload_len = protocol.encodeLogMessage(&payload_buf, level, msg) catch return;
    protocol.writeMessage(writer, payload_buf[0..payload_len]) catch return;
    writer.flush() catch {};
}

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = mingaLogFn,
};

// ── Runtime type selection ────────────────────────────────────────────────────

const Runtime = switch (build_options.backend) {
    .tui => apprt.Backend.TuiRuntime,
    .gui => apprt.Backend.GuiRuntime,
};

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var runtime = try Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.run();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

// Pull in all module tests.
test {
    _ = protocol;
    _ = renderer;
    _ = surface;
    _ = apprt;
    if (build_options.backend == .gui) {
        _ = font;
    }
}
