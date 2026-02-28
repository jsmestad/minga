const std = @import("std");
const vaxis = @import("vaxis");
pub const protocol = @import("protocol.zig");
pub const renderer = @import("renderer.zig");

/// Minga terminal renderer.
///
/// Runs as a BEAM Port. Uses stdin/stdout for the Port protocol
/// (length-prefixed binary messages) and /dev/tty for terminal I/O
/// via libvaxis.
///
/// Event loop:
/// 1. Read render commands from stdin → decode → draw via libvaxis
/// 2. Capture terminal input from libvaxis → encode → write to stdout
/// 3. On batch_end command → call vaxis.render() to flush
pub fn main() !void {
    // For now, just print version and exit.
    // The full event loop with libvaxis /dev/tty integration
    // will be wired up when we do the end-to-end integration (commit 8).
    //
    // The protocol and renderer modules are fully implemented and tested.
    // What remains is the event loop that:
    //   - Opens /dev/tty for libvaxis (not stdin/stdout)
    //   - Reads Port messages from stdin
    //   - Writes input events to stdout
    //   - Runs both concurrently

    var buf: [256]u8 = undefined;
    var writer_obj = std.fs.File.stdout().writer(&buf);
    try writer_obj.interface.print("minga-renderer v0.1.0\n", .{});
    try writer_obj.interface.flush();
}

test "smoke test" {
    try std.testing.expect(true);
}

// Pull in all module tests
test {
    _ = protocol;
    _ = renderer;
}
