/// Minga renderer — entry point and backend dispatch.
///
/// Runs as a BEAM Port:
///   stdin  ← render commands (4-byte big-endian length-prefixed binary)
///   stdout → input events   (4-byte big-endian length-prefixed binary)
///
/// The backend is selected at build time via `-Dbackend=tui` (default).
/// Each backend owns its event loop and rendering surface.
const std = @import("std");
const vaxis = @import("vaxis");
pub const protocol = @import("protocol.zig");
pub const renderer = @import("renderer.zig");
pub const surface = @import("surface.zig");
pub const apprt = @import("apprt.zig");

// ── Panic handler ─────────────────────────────────────────────────────────────
// Restores terminal state via libvaxis's global tty reference before printing
// the panic message. Covers crashes that bypass defer.

fn panicImpl(msg: []const u8, ret_addr: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(msg, ret_addr);
}

pub const panic = std.debug.FullPanic(panicImpl);

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var runtime = try apprt.Backend.TuiRuntime.init(alloc);
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
}
