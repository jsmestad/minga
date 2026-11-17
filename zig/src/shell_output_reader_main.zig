//! Demand-driven shell-output transport. The producer's lifetime belongs to BEAM;
//! this process owns only its private FIFO and the packet4 control channel.
const std = @import("std");
const posix = std.posix;
const c = std.c;

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn mkfifo(path: [*:0]const u8, mode: c.mode_t) c_int;
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

const max_payload = 65_536;
const Tag = enum(u8) { ready = 0x01, data = 0x02, eof = 0x03, failure = 0x04, demand = 0x05 };
const closed_events = posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;

/// Serves one-credit raw output frames, cleaning up on every terminal outcome.
pub fn main() void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &action, null);

    run() catch |err| {
        switch (err) {
            error.ParentClosed, error.OutputClosed => return,
            else => {
                // The error name is a bounded diagnostic, never producer data.
                // A disconnected parent cannot receive the failure frame.
                writeFrame(.failure, @errorName(err)) catch {};
                std.process.exit(1);
            },
        }
    };
}

fn run() !void {
    try setNonBlocking(posix.STDIN_FILENO);
    try setNonBlocking(posix.STDOUT_FILENO);

    var temp_root: [std.fs.max_path_bytes]u8 = undefined;
    const root_z = realpath(c.getenv("TMPDIR") orelse "/tmp", &temp_root) orelse return error.InvalidTemporaryDirectory;
    const root = std.mem.span(root_z);
    if (!std.unicode.utf8ValidateSlice(root)) return error.InvalidTemporaryDirectoryEncoding;

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrintZ(&directory_buffer, "{s}/minga-shell-output-XXXXXX", .{root});
    if (mkdtemp(directory) == null) return error.CreatePrivateDirectoryFailed;
    defer _ = c.rmdir(directory);
    if (c.chmod(directory, 0o700) != 0) return error.SetDirectoryPermissionsFailed;

    var fifo_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fifo = try std.fmt.bufPrintZ(&fifo_buffer, "{s}/output", .{directory});
    if (mkfifo(fifo, 0o600) != 0) return error.CreateFifoFailed;
    defer _ = c.unlink(fifo);
    if (c.chmod(fifo, 0o600) != 0) return error.SetFifoPermissionsFailed;

    const reader = try posix.openatZ(posix.AT.FDCWD, fifo, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    defer _ = c.close(reader);
    var dummy = try posix.openatZ(posix.AT.FDCWD, fifo, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    defer if (dummy >= 0) {
        _ = c.close(dummy);
    };

    try writeFrame(.ready, fifo);

    // Read directly into the sole payload buffer, with no text interpretation,
    // prefetch, fill-to-capacity loop, or producer-output allocation.
    var payload: [max_payload]u8 = undefined;
    var request: [5]u8 = undefined;
    var request_len: usize = 0;
    var pending = false;
    while (true) {
        var fds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (pending) reader else -1, .events = posix.POLL.IN, .revents = 0 },
            // Detect a closed parent output even while no demand is pending.
            .{ .fd = posix.STDOUT_FILENO, .events = 0, .revents = 0 },
        };
        _ = try posix.poll(&fds, -1);
        if (fds[2].revents & closed_events != 0) return error.OutputClosed;

        // Control has priority over FIFO availability, including parent death.
        if (fds[0].revents & (posix.POLL.IN | closed_events) != 0) {
            const n = posix.read(posix.STDIN_FILENO, request[request_len..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) {
                if (request_len != 0) return error.TruncatedRequest;
                return error.ParentClosed;
            }
            request_len += n;
            if (request_len >= 4 and std.mem.readInt(u32, request[0..4], .big) != 1) return error.InvalidRequestLength;
            if (request_len == request.len) {
                if (request[4] != @intFromEnum(Tag.demand)) return error.InvalidRequestTag;
                if (pending) return error.DemandAlreadyPending;
                request_len = 0;
                pending = true;
                // BEAM sends first demand only after its producer has opened
                // the FIFO. Until then the dummy writer prevents startup EOF.
                if (dummy >= 0) {
                    _ = c.close(dummy);
                    dummy = -1;
                }
            }
            if (fds[0].revents & closed_events != 0) {
                if (request_len != 0) return error.TruncatedRequest;
                return error.ParentClosed;
            }
        }

        if (pending and fds[1].revents & (posix.POLL.IN | closed_events) != 0) {
            const n = posix.read(reader, &payload) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) {
                try writeFrame(.eof, "");
                return;
            }
            try writeFrame(.data, payload[0..n]);
            pending = false;
        }
    }
}

fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = c.fcntl(fd, posix.F.GETFL);
    if (flags < 0) return error.GetDescriptorFlagsFailed;
    const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    if (c.fcntl(fd, posix.F.SETFL, flags | @as(c_int, @intCast(nonblock))) < 0) return error.SetDescriptorFlagsFailed;
}

fn writeFrame(tag: Tag, payload: []const u8) !void {
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(payload.len + 1), .big);
    header[4] = @intFromEnum(tag);
    try writeAll(&header);
    try writeAll(payload);
}

fn writeAll(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(posix.STDOUT_FILENO, bytes[offset..].ptr, bytes.len - offset);
        if (n > 0) {
            offset += @intCast(n);
            continue;
        }
        if (n == 0) return error.OutputClosed;
        switch (posix.errno(n)) {
            .INTR => continue,
            .PIPE => return error.OutputClosed,
            .AGAIN => {
                // A full output pipe must not hide control-channel closure.
                // Do not consume control bytes here; the request parser owns them.
                var fds = [_]posix.pollfd{
                    .{ .fd = posix.STDIN_FILENO, .events = 0, .revents = 0 },
                    .{ .fd = posix.STDOUT_FILENO, .events = posix.POLL.OUT, .revents = 0 },
                };
                _ = try posix.poll(&fds, -1);
                if (fds[0].revents & closed_events != 0) return error.ParentClosed;
                if (fds[1].revents & closed_events != 0) return error.OutputClosed;
            },
            else => return error.WriteFrameFailed,
        }
    }
}
