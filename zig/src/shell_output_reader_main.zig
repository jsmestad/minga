//! Demand-driven shell-output transport. The producer's lifetime belongs to BEAM;
//! this process owns only its private FIFO and the packet4 control channel.
const std = @import("std");
const posix = std.posix;
const c = std.c;
const is_darwin = @import("builtin").os.tag == .macos;
const darwin = if (is_darwin) @cImport({
    @cInclude("sys/select.h");
}) else struct {};

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
            else => std.process.exit(1),
        }
    };
}

fn run() !void {
    try setNonBlocking(posix.STDIN_FILENO);
    try setNonBlocking(posix.STDOUT_FILENO);
    var channel = try Channel.init();
    defer channel.deinit();

    serve(&channel) catch |err| {
        switch (err) {
            error.ParentClosed, error.OutputClosed => {},
            else => {
                // Never insert a diagnostic into an unfinished response frame.
                if (!channel.frame_in_progress) channel.writeFrame(.failure, @errorName(err)) catch {};
            },
        }
        return err;
    };
}

fn serve(channel: *Channel) !void {
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

    try channel.writeFrame(.ready, fifo);

    // Read directly into the sole payload buffer, with no text interpretation,
    // prefetch, fill-to-capacity loop, or producer-output allocation.
    var payload: [max_payload]u8 = undefined;
    var request: [5]u8 = undefined;
    var request_len: usize = 0;
    var pending = false;
    while (true) {
        const ready = try channel.wait(if (pending) reader else -1, false);

        // Control has priority over FIFO availability, including parent death.
        if (ready.control) {
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
            if (channel.control_closed) {
                if (request_len != 0) return error.TruncatedRequest;
                return error.ParentClosed;
            }
        }

        if (pending and ready.fifo) {
            const n = posix.read(reader, &payload) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) {
                try channel.writeFrame(.eof, "");
                return;
            }
            try channel.writeFrame(.data, payload[0..n]);
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

const Readiness = struct {
    control: bool = false,
    fifo: bool = false,
};

// This owner monitors only the transport. It never observes or signals producers.
const Channel = struct {
    queue: c_int = -1,
    control_closed: bool = false,
    output_closed: bool = false,
    frame_in_progress: bool = false,

    fn init() !Channel {
        if (is_darwin) {
            const queue = c.kqueue();
            if (queue < 0) return error.CreateEventQueueFailed;
            errdefer _ = c.close(queue);
            if (queue >= darwin.FD_SETSIZE) return error.SelectDescriptorOutOfRange;
            const changes = [_]c.Kevent{
                .{ .ident = posix.STDIN_FILENO, .filter = c.EVFILT.READ, .flags = c.EV.ADD | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = 0 },
                .{ .ident = posix.STDOUT_FILENO, .filter = c.EVFILT.WRITE, .flags = c.EV.ADD | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = 0 },
            };
            var events: [0]c.Kevent = .{};
            if (c.kevent(queue, &changes, changes.len, &events, 0, null) < 0) return error.RegisterChannelEventsFailed;
            return .{ .queue = queue };
        }
        return .{};
    }

    fn deinit(self: *Channel) void {
        if (self.queue >= 0) _ = c.close(self.queue);
    }

    fn requireOpen(self: *Channel, blocked_write: bool) !void {
        if (self.output_closed) return error.OutputClosed;
        if (blocked_write and self.control_closed) return error.ParentClosed;
    }

    fn wait(self: *Channel, fifo: posix.fd_t, blocked_write: bool) !Readiness {
        try self.requireOpen(blocked_write);
        if (is_darwin) return self.waitDarwin(fifo, blocked_write);

        var fds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = if (blocked_write) 0 else posix.POLL.IN, .revents = 0 },
            .{ .fd = fifo, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = posix.STDOUT_FILENO, .events = if (blocked_write) posix.POLL.OUT else 0, .revents = 0 },
        };
        _ = try posix.poll(&fds, -1);
        self.control_closed = self.control_closed or fds[0].revents & closed_events != 0;
        self.output_closed = self.output_closed or fds[2].revents & closed_events != 0;
        try self.requireOpen(blocked_write);
        return .{
            .control = fds[0].revents & (posix.POLL.IN | closed_events) != 0,
            .fifo = fds[1].revents & (posix.POLL.IN | closed_events) != 0,
        };
    }

    fn waitDarwin(self: *Channel, fifo: posix.fd_t, blocked_write: bool) !Readiness {
        if (blocked_write) {
            // Queued control bytes remain the parser's property. Selecting stdin here would spin while stdout is full instead of waiting for EOF.
            try self.channelEvents(null);
            try self.requireOpen(true);
            return .{};
        }

        // Darwin's FIFO poll/kqueue filter counts bytes but omits last-writer EOF. select uses the backing socket's receive-shutdown readiness.
        // Do not speculatively read: an empty FIFO read clears that indication.
        if (fifo >= darwin.FD_SETSIZE) return error.SelectDescriptorOutOfRange;
        while (true) {
            var reads = std.mem.zeroes(darwin.fd_set);
            addDescriptor(&reads, posix.STDIN_FILENO);
            addDescriptor(&reads, self.queue);
            var highest = self.queue;
            if (fifo >= 0) {
                addDescriptor(&reads, fifo);
                highest = @max(highest, fifo);
            }
            const result = darwin.select(highest + 1, &reads, null, null, null);
            if (result < 0) {
                if (posix.errno(result) == .INTR) continue;
                return error.SelectChannelFailed;
            }
            if (hasDescriptor(&reads, self.queue)) {
                const immediate = std.mem.zeroes(c.timespec);
                try self.channelEvents(&immediate);
            }
            try self.requireOpen(false);
            return .{
                // Raw stdin remains level-triggered, even if a blocked response consumed its kqueue edge without consuming its request bytes.
                .control = self.control_closed or hasDescriptor(&reads, posix.STDIN_FILENO),
                .fifo = fifo >= 0 and hasDescriptor(&reads, fifo),
            };
        }
    }

    // Keep the SDK's fd_set ABI, but avoid Zig's incorrect translation of the FD_SET inline compound assignment. Its imported mask words are int32_t.
    fn addDescriptor(reads: *darwin.fd_set, fd: c_int) void {
        const index: usize = @intCast(fd);
        const mask = @as(u32, 1) << @as(u5, @intCast(index % 32));
        reads.fds_bits[index / 32] |= @bitCast(mask);
    }

    fn hasDescriptor(reads: *const darwin.fd_set, fd: c_int) bool {
        const index: usize = @intCast(fd);
        const mask = @as(u32, 1) << @as(u5, @intCast(index % 32));
        return @as(u32, @bitCast(reads.fds_bits[index / 32])) & mask != 0;
    }

    fn channelEvents(self: *Channel, timeout: ?*const c.timespec) !void {
        var events: [2]c.Kevent = undefined;
        while (true) {
            const count = c.kevent(self.queue, &.{}, 0, &events, events.len, timeout);
            if (count < 0) {
                if (posix.errno(count) == .INTR) continue;
                return error.ReadChannelEventsFailed;
            }
            for (events[0..@intCast(count)]) |event| {
                if (event.flags & c.EV.ERROR != 0) return error.ChannelEventFailed;
                if (event.flags & c.EV.EOF != 0) {
                    if (event.ident == posix.STDIN_FILENO) self.control_closed = true;
                    if (event.ident == posix.STDOUT_FILENO) self.output_closed = true;
                }
            }
            return;
        }
    }

    fn writeFrame(self: *Channel, tag: Tag, bytes: []const u8) !void {
        var header: [5]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(bytes.len + 1), .big);
        header[4] = @intFromEnum(tag);
        self.frame_in_progress = true;
        try self.writeAll(&header);
        try self.writeAll(bytes);
        self.frame_in_progress = false;
    }

    fn writeAll(self: *Channel, bytes: []const u8) !void {
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
                    // Share closure monitoring with idle and pending-read waits.
                    _ = try self.wait(-1, true);
                },
                else => return error.WriteFrameFailed,
            }
        }
    }
};
