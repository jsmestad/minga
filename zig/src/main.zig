const std = @import("std");

/// Minga terminal renderer.
///
/// This binary runs as a BEAM Port, communicating with the Elixir
/// editor over stdin/stdout using a length-prefixed binary protocol.
/// Terminal I/O (rendering + input capture) goes through /dev/tty
/// via libvaxis.
pub fn main() !void {
    var buf: [256]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    try writer.interface.print("minga-renderer v0.1.0\n", .{});
    try writer.interface.flush();
}

test "smoke test" {
    // Verify the binary compiles and links correctly
    try std.testing.expect(true);
}
