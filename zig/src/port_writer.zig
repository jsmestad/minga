/// Non-blocking write buffer for the Port protocol channel (stdout).
///
/// Accumulates complete `{:packet, 4}` framed messages in an internal
/// buffer and drains them to the stdout fd when it becomes writable.
/// This prevents the Zig event loop from blocking on `write()` when the
/// BEAM is not reading the pipe fast enough (pipe backpressure).
///
/// Usage:
///   1. Call `enqueue()` to add a complete protocol message (with length prefix)
///   2. Add `stdout_fd` to poll with POLL.OUT when `hasPending()` is true
///   3. Call `drain()` when poll says stdout is writable
///   4. If the buffer exceeds `max_size`, oldest whole messages are dropped
const std = @import("std");
const protocol = @import("protocol.zig");

const Self = @This();

/// Internal byte buffer for pending writes.
buf: []u8,
/// Number of valid bytes in `buf` (write position).
len: usize,
/// Read position: bytes before this have been successfully written.
read_pos: usize,
/// Allocator for buffer resizing.
alloc: std.mem.Allocator,
/// Maximum buffer size. Beyond this, oldest messages are dropped.
max_size: usize,
/// File descriptor for stdout (the port channel).
fd: std.posix.fd_t,
/// Count of messages dropped due to buffer overflow.
dropped_count: u64,

/// Initial buffer capacity.
const INITIAL_CAPACITY: usize = 8192;

/// Default max buffer size (64KB). If the BEAM is this far behind,
/// dropping old key events is acceptable.
const DEFAULT_MAX_SIZE: usize = 65536;

/// Initialize a new PortWriter for the given fd.
pub fn init(alloc: std.mem.Allocator, fd: std.posix.fd_t) !Self {
    const buf_mem = try alloc.alloc(u8, INITIAL_CAPACITY);
    return .{
        .buf = buf_mem,
        .len = 0,
        .read_pos = 0,
        .alloc = alloc,
        .max_size = DEFAULT_MAX_SIZE,
        .fd = fd,
        .dropped_count = 0,
    };
}

/// Clean up the buffer.
pub fn deinit(self: *Self) void {
    self.alloc.free(self.buf);
    self.buf = &.{};
    self.len = 0;
    self.read_pos = 0;
}

/// Enqueue a complete protocol message payload. Adds the 4-byte length
/// prefix automatically (matching `{:packet, 4}` framing).
///
/// If the buffer would exceed `max_size`, drops whole messages from the
/// front (oldest first) to make room. Message boundaries are preserved
/// so the BEAM never sees a corrupt frame.
pub fn enqueue(self: *Self, payload: []const u8) !void {
    const frame_len = 4 + payload.len;

    // Compact: move unread data to the front of the buffer.
    if (self.read_pos > 0) {
        self.compact();
    }

    // Check if we need to drop old messages to make room.
    const pending = self.len;
    const needed = pending + frame_len;

    if (needed > self.max_size) {
        // Drop whole messages from the front until enough space is free.
        var drop_pos: usize = 0;
        while (drop_pos < pending and (pending - drop_pos + frame_len) > self.max_size) {
            if (drop_pos + 4 > pending) {
                // Not enough bytes for a length prefix; drop everything.
                drop_pos = pending;
                break;
            }
            const msg_len = std.mem.readInt(u32, self.buf[drop_pos..][0..4], .big);
            const total_msg = 4 + @as(usize, msg_len);
            if (drop_pos + total_msg > pending) {
                // Partial message at end; drop everything.
                drop_pos = pending;
                break;
            }
            drop_pos += total_msg;
            self.dropped_count += 1;
        }

        if (drop_pos >= pending) {
            self.len = 0;
            self.read_pos = 0;
        } else if (drop_pos > 0) {
            const remaining_after_drop = pending - drop_pos;
            std.mem.copyForwards(u8, self.buf[0..remaining_after_drop], self.buf[drop_pos..pending]);
            self.len = remaining_after_drop;
        }
    }

    // Grow the buffer if needed (up to max_size).
    const space_needed = self.len + frame_len;
    if (space_needed > self.buf.len) {
        const new_cap = @min(self.max_size, @max(self.buf.len * 2, space_needed));
        const new_buf = try self.alloc.realloc(self.buf, new_cap);
        self.buf = new_buf;
    }

    // Write the 4-byte big-endian length prefix.
    const msg_len: u32 = @intCast(payload.len);
    std.mem.writeInt(u32, self.buf[self.len..][0..4], msg_len, .big);
    self.len += 4;

    // Write the payload.
    @memcpy(self.buf[self.len..][0..payload.len], payload);
    self.len += payload.len;
}

/// Returns true if there are bytes waiting to be written.
pub fn hasPending(self: *const Self) bool {
    return self.len > self.read_pos;
}

/// Number of pending bytes.
pub fn pendingBytes(self: *const Self) usize {
    return self.len - self.read_pos;
}

/// Try to write as many pending bytes as possible to the fd.
/// Returns the number of bytes written. Handles EAGAIN gracefully
/// (returns 0). Other errors are propagated.
pub fn drain(self: *Self) !usize {
    if (!self.hasPending()) return 0;

    const data = self.buf[self.read_pos..self.len];
    const n = std.posix.write(self.fd, data) catch |err| {
        if (err == error.WouldBlock) return 0;
        return err;
    };

    self.read_pos += n;

    // If everything is drained, reset positions.
    if (self.read_pos == self.len) {
        self.read_pos = 0;
        self.len = 0;
    }

    return n;
}

/// Flush all pending data, blocking until complete.
/// Used during startup (ready event) when we need guaranteed delivery
/// before entering the non-blocking event loop.
pub fn flushBlocking(self: *Self) !void {
    while (self.hasPending()) {
        const data = self.buf[self.read_pos..self.len];
        const n = try std.posix.write(self.fd, data);
        self.read_pos += n;
    }
    self.read_pos = 0;
    self.len = 0;
}

/// Compact the buffer by moving unread data to the front.
fn compact(self: *Self) void {
    const pending = self.len - self.read_pos;
    if (pending == 0) {
        self.len = 0;
        self.read_pos = 0;
        return;
    }
    std.mem.copyForwards(u8, self.buf[0..pending], self.buf[self.read_pos..self.len]);
    self.len = pending;
    self.read_pos = 0;
}

/// Set a file descriptor to non-blocking mode.
pub fn setNonBlocking(fd: std.posix.fd_t) void {
    const flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, flags | @as(usize, nonblock)) catch return;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "enqueue adds length prefix" {
    var pw = try init(std.testing.allocator, 1);
    defer pw.deinit();

    try pw.enqueue("hello");
    try std.testing.expectEqual(@as(usize, 9), pw.pendingBytes()); // 4 + 5
    try std.testing.expectEqual(@as(u8, 0), pw.buf[0]);
    try std.testing.expectEqual(@as(u8, 0), pw.buf[1]);
    try std.testing.expectEqual(@as(u8, 0), pw.buf[2]);
    try std.testing.expectEqual(@as(u8, 5), pw.buf[3]);
    try std.testing.expectEqualSlices(u8, "hello", pw.buf[4..9]);
}

test "hasPending is false when empty" {
    var pw = try init(std.testing.allocator, 1);
    defer pw.deinit();
    try std.testing.expect(!pw.hasPending());
}

test "hasPending is true after enqueue" {
    var pw = try init(std.testing.allocator, 1);
    defer pw.deinit();
    try pw.enqueue("x");
    try std.testing.expect(pw.hasPending());
}

test "multiple enqueues accumulate" {
    var pw = try init(std.testing.allocator, 1);
    defer pw.deinit();

    try pw.enqueue("AB");
    try pw.enqueue("CD");
    // 4+2 + 4+2 = 12
    try std.testing.expectEqual(@as(usize, 12), pw.pendingBytes());
}

test "drain writes to a pipe" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    setNonBlocking(fds[1]);

    var pw = try init(std.testing.allocator, fds[1]);
    defer pw.deinit();

    try pw.enqueue("test");
    const written = try pw.drain();
    try std.testing.expectEqual(@as(usize, 8), written); // 4 + 4
    try std.testing.expect(!pw.hasPending());

    var read_buf: [8]u8 = undefined;
    const n = try std.posix.read(fds[0], &read_buf);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqual(@as(u8, 0), read_buf[0]);
    try std.testing.expectEqual(@as(u8, 0), read_buf[1]);
    try std.testing.expectEqual(@as(u8, 0), read_buf[2]);
    try std.testing.expectEqual(@as(u8, 4), read_buf[3]);
    try std.testing.expectEqualSlices(u8, "test", read_buf[4..8]);
}

test "compact moves data to front" {
    var pw = try init(std.testing.allocator, 1);
    defer pw.deinit();

    try pw.enqueue("ABCD");
    pw.read_pos = 4;
    pw.compact();
    try std.testing.expectEqual(@as(usize, 0), pw.read_pos);
    try std.testing.expectEqual(@as(usize, 4), pw.len);
}
