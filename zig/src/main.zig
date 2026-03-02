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
pub const highlighter = @import("highlighter.zig");

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

// Suppress vaxis debug log messages (they bleed into the terminal).
pub const std_options = std.Options{
    .log_level = .info,
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
    _ = highlighter;
    if (build_options.backend == .gui) {
        _ = font;
    }
}
