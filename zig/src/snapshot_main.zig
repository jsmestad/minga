/// minga-snapshot — rasterizes a render command stream to a PNG.
///
/// Reads {:packet, 4} framed binary render commands from stdin (same
/// protocol as minga-renderer), renders them to an in-memory pixel
/// buffer using CoreText font rasterization, and writes the result
/// as a PNG file.
///
/// Usage:
///   cat fixture.bin | minga-snapshot --output snapshot.png [--cols 80] [--rows 24] [--font Menlo] [--size 14]
const std = @import("std");
const protocol = @import("protocol.zig");
const renderer_mod = @import("renderer.zig");
const surface_mod = @import("surface.zig");
const snapshot_surface_mod = @import("snapshot_surface.zig");
const font_mod = @import("font/main.zig");

const SnapshotSurface = snapshot_surface_mod;
const png_writer = @import("png_writer.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    // Parse CLI arguments.
    const args = try parseArgs(init);
    defer alloc.free(args.output);
    defer alloc.free(args.font_name);

    // Initialize font face.
    var face = try font_mod.Face.init(alloc, args.font_name, args.font_size, 1.0);
    defer face.deinit();
    try face.preloadAscii();

    // Initialize snapshot surface.
    var surface = try SnapshotSurface.init(alloc, args.cols, args.rows, &face, args.output, init.io);
    defer surface.deinit();

    // Initialize renderer.
    var rend = renderer_mod.Renderer(SnapshotSurface).init(&surface, alloc);
    defer rend.deinit();

    // Read render commands from stdin using POSIX fd reads (same pattern as parser_main).
    const stdin_fd = std.posix.STDIN_FILENO;
    var msg_buf: [65536]u8 = undefined;

    while (true) {
        var len_buf: [4]u8 = undefined;
        if (!try readExact(stdin_fd, &len_buf)) break;

        const msg_len: usize = std.mem.readInt(u32, &len_buf, .big);
        if (msg_len == 0) continue;
        if (msg_len > msg_buf.len) {
            var skip_remaining = msg_len;
            while (skip_remaining > 0) {
                const chunk = @min(skip_remaining, msg_buf.len);
                if (!try readExact(stdin_fd, msg_buf[0..chunk])) break;
                skip_remaining -= chunk;
            }
            continue;
        }

        const payload = msg_buf[0..msg_len];
        if (!try readExact(stdin_fd, payload)) break;

        const cmd = protocol.decodeCommand(payload) catch continue;
        rend.handleCommand(cmd) catch continue;
    }

    // Flush the final frame if the stream ended without a batch_end.
    try surface.render();
    std.debug.print("Snapshot written to: {s}\n", .{args.output});
}

const Args = struct {
    output: []u8,
    cols: u16,
    rows: u16,
    font_name: []u8,
    font_size: f64,
};

fn parseArgs(init: std.process.Init) !Args {
    const alloc = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var output: ?[]const u8 = null;
    var cols: u16 = 80;
    var rows: u16 = 24;
    var font_name: []const u8 = "Menlo";
    var font_size: f64 = 14.0;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: --output requires a path argument\n", .{});
                std.process.exit(1);
            }
            output = argv[i];
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: --cols requires a number\n", .{});
                std.process.exit(1);
            }
            cols = std.fmt.parseInt(u16, argv[i], 10) catch {
                std.debug.print("error: invalid --cols value: {s}\n", .{argv[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: --rows requires a number\n", .{});
                std.process.exit(1);
            }
            rows = std.fmt.parseInt(u16, argv[i], 10) catch {
                std.debug.print("error: invalid --rows value: {s}\n", .{argv[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--font")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: --font requires a name\n", .{});
                std.process.exit(1);
            }
            font_name = argv[i];
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: --size requires a number\n", .{});
                std.process.exit(1);
            }
            font_size = std.fmt.parseFloat(f64, argv[i]) catch {
                std.debug.print("error: invalid --size value: {s}\n", .{argv[i]});
                std.process.exit(1);
            };
        }
    }

    // Also check MINGA_SNAPSHOT_OUTPUT env var.
    if (output == null) {
        if (std.c.getenv("MINGA_SNAPSHOT_OUTPUT")) |env_val| {
            output = std.mem.span(env_val);
        }
    }

    if (output == null) {
        std.debug.print("error: --output path or MINGA_SNAPSHOT_OUTPUT env var required\n", .{});
        std.process.exit(1);
    }

    return .{
        .output = try alloc.dupe(u8, output.?),
        .cols = cols,
        .rows = rows,
        .font_name = try alloc.dupe(u8, font_name),
        .font_size = font_size,
    };
}

fn readExact(fd: std.posix.fd_t, buf: []u8) !bool {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(fd, buf[total..]);
        if (n == 0) return false;
        total += n;
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test {
    _ = png_writer;
    _ = snapshot_surface_mod;
    _ = protocol;
    _ = renderer_mod;
    _ = surface_mod;
}
