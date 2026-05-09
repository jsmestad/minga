/// One-shot hook runner for Minga agent hooks.
///
/// Runs one `/bin/sh -c` command in its own POSIX session/process group, feeds the hook payload on stdin, discards stdout, captures bounded stderr, and emits one JSON result on stdout.
const std = @import("std");
const posix = std.posix;
const c = std.c;

// ---------------------------------------------------------------------------
// Thin wrappers for POSIX functions that moved from std.posix to std.c in
// Zig 0.16. Each wrapper preserves the error-handling style used by the
// call-sites (error union, void, or noreturn).
// ---------------------------------------------------------------------------

const PosixError = error{Unexpected};

fn pipeFds() PosixError![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.Unexpected;
    return fds;
}

fn forkPid() PosixError!posix.pid_t {
    const pid = c.fork();
    if (pid < 0) return error.Unexpected;
    return @intCast(pid);
}

fn closeFd(fd: posix.fd_t) void {
    _ = c.close(fd);
}

fn dup2Fd(old: posix.fd_t, new: posix.fd_t) PosixError!void {
    if (c.dup2(old, new) < 0) return error.Unexpected;
}

fn setsidSafe() void {
    _ = c.setsid();
}

const WriteFdError = error{ WouldBlock, BrokenPipe, Unexpected };

fn writeFd(fd: posix.fd_t, buf: []const u8) WriteFdError!usize {
    const result = c.write(fd, buf.ptr, buf.len);
    if (result >= 0) return @intCast(result);
    return switch (posix.errno(result)) {
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        else => error.Unexpected,
    };
}

fn setNonBlockingFd(fd: posix.fd_t) void {
    const flags = c.fcntl(fd, posix.F.GETFL);
    if (flags < 0) return;
    const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    _ = c.fcntl(fd, posix.F.SETFL, flags | @as(c_int, @intCast(nonblock)));
}

const WaitResult = struct { pid: posix.pid_t, status: u32 };

fn waitpidNonBlocking(pid: posix.pid_t) WaitResult {
    var raw_status: c_int = 0;
    const ret = c.waitpid(pid, &raw_status, c.W.NOHANG);
    return .{ .pid = ret, .status = @bitCast(raw_status) };
}

fn milliTimestamp() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

const stderr_limit: usize = 64 * 1024;
const truncation_marker = "\n[stderr truncated after 65536 bytes]\n";
const kill_grace_ms: i64 = 50;

const RunResult = struct {
    status: Status,
    exit_status: ?u8 = null,
    timed_out: bool = false,
    stderr: []const u8 = "",
};

const Status = enum { allow, veto };

const StderrCapture = struct {
    buf: std.ArrayList(u8),
    truncated: bool = false,

    fn init() StderrCapture {
        return .{ .buf = .empty };
    }

    fn deinit(self: *StderrCapture, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    fn append(self: *StderrCapture, alloc: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.truncated) return;

        const remaining = stderr_limit - self.buf.items.len;
        if (bytes.len <= remaining) {
            try self.buf.appendSlice(alloc, bytes);
            return;
        }

        if (remaining > 0) {
            try self.buf.appendSlice(alloc, bytes[0..remaining]);
        }

        try self.buf.appendSlice(alloc, truncation_marker);
        self.truncated = true;
    }
};

/// Module-level Io instance set during main(), used by writeResult/writeHelperError.
var g_io: std.Io = undefined;

/// Parses runner arguments, executes the hook, and writes the structured JSON result.
pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    const alloc = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 4) {
        try writeHelperError("usage: minga-hook-runner <timeout_ms> <payload_len> <command>");
        std.process.exit(2);
    }

    const timeout_ms = std.fmt.parseInt(u64, args[1], 10) catch {
        try writeHelperError("invalid timeout_ms");
        std.process.exit(2);
    };

    const payload_len = std.fmt.parseInt(usize, args[2], 10) catch {
        try writeHelperError("invalid payload_len");
        std.process.exit(2);
    };

    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);

    if (!try readExact(posix.STDIN_FILENO, payload)) {
        try writeHelperError("stdin ended before payload was complete");
        std.process.exit(2);
    }

    const result = runHook(alloc, args[3], payload, timeout_ms) catch |err| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "hook runner failed: {}", .{err}) catch "hook runner failed";
        try writeHelperError(msg);
        std.process.exit(2);
    };
    defer alloc.free(result.stderr);

    try writeResult(result);
}

fn runHook(alloc: std.mem.Allocator, command: []const u8, payload: []const u8, timeout_ms: u64) !RunResult {
    var stdin_pipe = try pipeFds();
    errdefer closePipe(&stdin_pipe);

    var stderr_pipe = try pipeFds();
    errdefer closePipe(&stderr_pipe);

    const devnull = try posix.openatZ(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    defer closeFd(devnull);

    const command_z = try alloc.dupeZ(u8, command);
    defer alloc.free(command_z);

    const pid = try forkPid();

    if (pid == 0) {
        childExec(stdin_pipe, stderr_pipe, devnull, command_z);
    }

    closeFd(stdin_pipe[0]);
    stdin_pipe[0] = -1;
    closeFd(stderr_pipe[1]);
    stderr_pipe[1] = -1;
    defer closeIfOpen(stdin_pipe[1]);
    defer closeIfOpen(stderr_pipe[0]);

    setNonBlockingFd(stdin_pipe[1]);
    setNonBlockingFd(stderr_pipe[0]);

    var stderr_capture = StderrCapture.init();
    defer stderr_capture.deinit(alloc);

    const start_ms = milliTimestamp();
    const timeout_i64: i64 = @intCast(timeout_ms);
    const deadline_ms = start_ms + timeout_i64;
    var payload_offset: usize = 0;
    var stdin_open = true;
    var stderr_open = true;
    var timed_out = false;
    var child_done = false;
    var status: u32 = 0;

    while (!child_done) {
        const now = milliTimestamp();
        if (now >= deadline_ms and !timed_out) {
            timed_out = true;
            killProcessGroup(pid, posix.SIG.TERM);
        }

        if (timed_out and now >= deadline_ms + kill_grace_ms) {
            killProcessGroup(pid, posix.SIG.KILL);
        }

        const wait = waitpidNonBlocking(pid);
        if (wait.pid == pid) {
            child_done = true;
            status = wait.status;
            break;
        }

        var pollfds = [_]posix.pollfd{
            .{ .fd = if (stdin_open and payload_offset < payload.len) stdin_pipe[1] else -1, .events = posix.POLL.OUT, .revents = 0 },
            .{ .fd = if (stderr_open) stderr_pipe[0] else -1, .events = posix.POLL.IN, .revents = 0 },
        };

        const remaining_ms = if (timed_out) kill_grace_ms else @max(deadline_ms - now, 0);
        const poll_timeout: i32 = @intCast(@min(remaining_ms, 50));
        _ = posix.poll(&pollfds, poll_timeout) catch 0;

        if (stdin_open and pollfds[0].revents & posix.POLL.OUT != 0) {
            const n = writeFd(stdin_pipe[1], payload[payload_offset..]) catch |err| switch (err) {
                error.WouldBlock => 0,
                error.BrokenPipe => blk: {
                    closeFd(stdin_pipe[1]);
                    stdin_pipe[1] = -1;
                    stdin_open = false;
                    break :blk 0;
                },
                else => return err,
            };

            payload_offset += n;
            if (payload_offset >= payload.len) {
                closeFd(stdin_pipe[1]);
                stdin_pipe[1] = -1;
                stdin_open = false;
            }
        }

        if (stdin_open and payload.len == 0) {
            closeFd(stdin_pipe[1]);
            stdin_pipe[1] = -1;
            stdin_open = false;
        }

        if (stderr_open and pollfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
            var read_buf: [4096]u8 = undefined;
            const n = posix.read(stderr_pipe[0], &read_buf) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };

            if (n == 0) {
                closeFd(stderr_pipe[0]);
                stderr_pipe[0] = -1;
                stderr_open = false;
            } else {
                try stderr_capture.append(alloc, read_buf[0..n]);
            }
        }
    }

    // Drain any stderr written just before the child exited.
    while (stderr_open) {
        var read_buf: [4096]u8 = undefined;
        const n = posix.read(stderr_pipe[0], &read_buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n == 0) break;
        try stderr_capture.append(alloc, read_buf[0..n]);
    }

    const stderr_copy = try alloc.dupe(u8, stderr_capture.buf.items);

    if (timed_out) {
        return .{ .status = .veto, .timed_out = true, .stderr = stderr_copy };
    }

    if (posix.W.IFEXITED(status)) {
        const code: u8 = @intCast(posix.W.EXITSTATUS(status));
        if (code == 0) {
            return .{ .status = .allow, .exit_status = 0, .stderr = stderr_copy };
        }
        return .{ .status = .veto, .exit_status = code, .stderr = stderr_copy };
    }

    return .{ .status = .veto, .stderr = stderr_copy };
}

fn childExec(stdin_pipe: [2]posix.fd_t, stderr_pipe: [2]posix.fd_t, devnull: posix.fd_t, command_z: [:0]const u8) noreturn {
    setsidSafe();

    closeFd(stdin_pipe[1]);
    closeFd(stderr_pipe[0]);

    dup2Fd(stdin_pipe[0], posix.STDIN_FILENO) catch std.process.exit(127);
    dup2Fd(devnull, posix.STDOUT_FILENO) catch std.process.exit(127);
    dup2Fd(stderr_pipe[1], posix.STDERR_FILENO) catch std.process.exit(127);

    closeFd(stdin_pipe[0]);
    closeFd(stderr_pipe[1]);
    closeFd(devnull);

    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command_z.ptr };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(c.environ);
    _ = c.execve("/bin/sh", &argv, envp);
    // execve only returns on error
    std.process.exit(127);
}

fn killProcessGroup(pid: posix.pid_t, signal: posix.SIG) void {
    const group_pid: posix.pid_t = -pid;
    posix.kill(group_pid, signal) catch {};
}

fn closePipe(pipe: *[2]posix.fd_t) void {
    closeIfOpen(pipe[0]);
    closeIfOpen(pipe[1]);
}

fn closeIfOpen(fd: posix.fd_t) void {
    if (fd >= 0) closeFd(fd);
}

fn readExact(fd: posix.fd_t, buf: []u8) !bool {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try posix.read(fd, buf[total..]);
        if (n == 0) return false;
        total += n;
    }
    return true;
}

fn writeResult(result: RunResult) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer_obj = std.Io.File.stdout().writer(g_io, &stdout_buf);
    const stdout = &stdout_writer_obj.interface;

    switch (result.status) {
        .allow => try stdout.writeAll("{\"status\":\"allow\",\"stderr\":"),
        .veto => try stdout.writeAll("{\"status\":\"veto\",\"stderr\":"),
    }

    try writeJsonString(stdout, result.stderr);

    if (result.status == .veto) {
        if (result.timed_out) {
            try stdout.writeAll(",\"reason\":{\"type\":\"timeout\"}}");
        } else if (result.exit_status) |code| {
            try stdout.writeAll(",\"reason\":{\"type\":\"exit\",\"status\":");
            try stdout.print("{d}", .{code});
            try stdout.writeAll("}}");
        } else {
            try stdout.writeAll(",\"reason\":{\"type\":\"failed\"}}");
        }
    } else {
        try stdout.writeAll("}");
    }

    try stdout.flush();
}

fn writeHelperError(message: []const u8) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer_obj = std.Io.File.stdout().writer(g_io, &stdout_buf);
    const stdout = &stdout_writer_obj.interface;
    try stdout.writeAll("{\"status\":\"error\",\"message\":");
    try writeJsonString(stdout, message);
    try stdout.writeAll("}");
    try stdout.flush();
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "stderr capture appends truncation marker once" {
    var cap = StderrCapture.init();
    defer cap.deinit(std.testing.allocator);

    const chunk = "0123456789abcdef" ** 5000;
    try cap.append(std.testing.allocator, chunk);
    try cap.append(std.testing.allocator, chunk);

    try std.testing.expect(cap.truncated);
    try std.testing.expect(cap.buf.items.len <= stderr_limit + truncation_marker.len);
    try std.testing.expect(std.mem.endsWith(u8, cap.buf.items, truncation_marker));
}

test "json string escapes stderr" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeJsonString(&out.writer, "hello \"world\"\n");
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\n\"", out.written());
}
