//! Copy-on-write clone of one file system entry, for agent overlays.
//!
//! Usage: `minga-clone-tree SOURCE TARGET`
//!
//! Clones SOURCE (a directory, a regular file, or a symlink) to TARGET, which must not exist yet. Symlinks are cloned as links and never followed. The helper never copies file bytes: when the file system cannot share blocks between SOURCE and TARGET, it fails, and the caller links the entry instead.
//!
//! - macOS: one `clonefile(2)` call with `CLONE_NOFOLLOW` clones the whole tree.
//! - Linux: there is no directory clone call, so the helper walks the tree. It creates each directory and symlink, and clones each regular file with the `FICLONE` ioctl.
//!
//! Exit status, read by `MingaAgent.Changeset.Overlay.NativeCloner`:
//!
//! - 0: TARGET is a complete clone.
//! - 2: usage error.
//! - 3: cloning is unsupported here. The file system cannot clone, SOURCE and TARGET are on different file systems, the tree holds a special file, or the platform has no clone call.
//! - 4: any other failure, such as a missing SOURCE, an existing TARGET, or a permission error.
//!
//! On failure, stderr holds one line that names the operation, the path, and the errno. TARGET may then hold a partial clone, which the caller removes.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const linux = std.os.linux;

const is_darwin = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

/// Exit status for a complete clone.
pub const exit_cloned: u8 = 0;
/// Exit status for wrong arguments.
pub const exit_usage: u8 = 2;
/// Exit status when the file system or platform cannot clone; the caller falls back.
pub const exit_unsupported: u8 = 3;
/// Exit status for every other failure.
pub const exit_failed: u8 = 4;

/// `clonefile(2)` from `<sys/clonefile.h>`; Zig's standard library does not declare it.
extern "c" fn clonefile(source: [*:0]const u8, target: [*:0]const u8, flags: u32) c_int;

/// `CLONE_NOFOLLOW` from `<sys/clonefile.h>`: clone a symlink itself, not its target.
const CLONE_NOFOLLOW: u32 = 0x0001;

/// `FICLONE` from `<linux/fs.h>`, `_IOW(0x94, 9, int)` in the generic ioctl encoding that x86_64 and aarch64 use.
const FICLONE: c_int = (1 << 30) | (@sizeOf(c_int) << 16) | (0x94 << 8) | 9;

comptime {
    std.debug.assert(FICLONE == 0x40049409);
}

const path_max = std.fs.max_path_bytes;

/// Why a clone stopped. `Unsupported` maps to `exit_unsupported`, `Failed` to `exit_failed`.
pub const Failure = error{ Unsupported, Failed };

/// The step that failed, named in the diagnostic.
pub const Operation = enum { clonefile, ficlone, stat, mkdir, opendir, readdir, open, readlink, symlink, chmod, utimens, file_type, path_length };

/// Whether a failed operation means "cloning is not possible here" or a real error.
///
/// Only the clone calls can report that cloning is unsupported, and only for the errno values their manual pages give for that case. A special file (a FIFO, socket, or device) is unsupported too: the helper never copies one. Every other failure is real.
pub fn classify(operation: Operation, err: c.E) Failure {
    return switch (operation) {
        // clonefile(2): ENOTSUP (the volume cannot clone) or EXDEV (different volumes).
        .clonefile => switch (err) {
            .OPNOTSUPP, .XDEV => error.Unsupported,
            else => error.Failed,
        },
        // ioctl_ficlone(2): EOPNOTSUPP (no reflink support), EXDEV (different file systems), EINVAL (the
        // file system cannot reflink these files). ENOTTY and ENOSYS come from file systems without the ioctl.
        .ficlone => switch (err) {
            .OPNOTSUPP, .XDEV, .INVAL, .NOTTY, .NOSYS => error.Unsupported,
            else => error.Failed,
        },
        .file_type => error.Unsupported,
        else => error.Failed,
    };
}

/// Maps a clone result to the process exit status.
pub fn exitStatus(result: Failure!void) u8 {
    result catch |err| return switch (err) {
        error.Unsupported => exit_unsupported,
        error.Failed => exit_failed,
    };
    return exit_cloned;
}

/// Clones `source` to `target` and exits with the status the module documentation lists.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 3) {
        writeStderr("usage: minga-clone-tree SOURCE TARGET\n");
        std.process.exit(exit_usage);
    }

    std.process.exit(exitStatus(clone(args[1], args[2])));
}

/// Clones `source` to `target` with the platform's clone call.
pub fn clone(source_arg: []const u8, target_arg: []const u8) Failure!void {
    var source = try PathBuf.init(source_arg);
    var target = try PathBuf.init(target_arg);

    if (is_darwin) {
        if (clonefile(source.z(), target.z(), CLONE_NOFOLLOW) != 0) return failClone(&source, &target, errno());
    } else if (is_linux) {
        try cloneTree(&source, &target);
    } else {
        writeStderr("minga-clone-tree: this platform has no clone call\n");
        return error.Unsupported;
    }
}

/// Clones an entry by walking it: directories and symlinks are created, and each regular file is cloned on its own.
///
/// Linux uses this because it has no directory clone call. On macOS, each file is cloned with `clonefile(2)`, which lets the walk run in tests there.
pub fn cloneTree(source: *PathBuf, target: *PathBuf) Failure!void {
    const metadata = try lstat(source);

    switch (metadata.kind) {
        .directory => try cloneDirectory(source, target, metadata),
        .regular => try cloneFile(source, target, metadata),
        .symlink => try cloneSymlink(source, target, metadata),
        .other => return fail(.file_type, source, null),
    }
}

/// Children are cloned before the directory gets its mode and times, so a read-only directory can still be filled, and adding children does not change its recorded modification time.
fn cloneDirectory(source: *PathBuf, target: *PathBuf, metadata: Metadata) Failure!void {
    if (c.mkdir(target.z(), 0o700) != 0) return fail(.mkdir, target, errno());

    const dir = c.opendir(source.z()) orelse return fail(.opendir, source, errno());
    defer _ = c.closedir(dir);

    while (true) {
        c._errno().* = 0;
        const entry = c.readdir(dir) orelse {
            const err = errno();
            if (err != .SUCCESS) return fail(.readdir, source, err);
            break;
        };

        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const source_len = try source.push(name);
        defer source.pop(source_len);
        const target_len = try target.push(name);
        defer target.pop(target_len);

        try cloneTree(source, target);
    }

    if (c.chmod(target.z(), metadata.mode) != 0) return fail(.chmod, target, errno());
    try setTimes(target, metadata, 0);
}

fn cloneFile(source: *PathBuf, target: *PathBuf, metadata: Metadata) Failure!void {
    if (is_darwin) {
        if (clonefile(source.z(), target.z(), CLONE_NOFOLLOW) != 0) return failClone(source, target, errno());
        return;
    }

    const source_fd = c.open(source.z(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true });
    if (source_fd < 0) return fail(.open, source, errno());
    defer _ = c.close(source_fd);

    const target_flags: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true };
    const target_fd = c.open(target.z(), target_flags, @as(c_uint, 0o600));
    if (target_fd < 0) return fail(.open, target, errno());
    defer _ = c.close(target_fd);

    if (c.ioctl(target_fd, FICLONE, source_fd) != 0) return fail(.ficlone, target, errno());
    if (c.fchmod(target_fd, metadata.mode) != 0) return fail(.chmod, target, errno());

    const times = [2]c.timespec{ metadata.atime, metadata.mtime };
    if (c.futimens(target_fd, &times) != 0) return fail(.utimens, target, errno());
}

fn cloneSymlink(source: *PathBuf, target: *PathBuf, metadata: Metadata) Failure!void {
    var link: [path_max:0]u8 = undefined;
    const read = c.readlink(source.z(), &link, link.len);
    if (read < 0) return fail(.readlink, source, errno());

    const len: usize = @intCast(read);
    if (len >= link.len) return fail(.path_length, source, null);
    link[len] = 0;

    if (c.symlink(link[0..len :0], target.z()) != 0) return fail(.symlink, target, errno());
    try setTimes(target, metadata, c.AT.SYMLINK_NOFOLLOW);
}

fn setTimes(target: *PathBuf, metadata: Metadata, flags: u32) Failure!void {
    const times = [2]c.timespec{ metadata.atime, metadata.mtime };
    if (c.utimensat(c.AT.FDCWD, target.z(), &times, flags) != 0) return fail(.utimens, target, errno());
}

/// The parts of an entry's metadata a clone keeps.
const Metadata = struct {
    kind: enum { directory, regular, symlink, other },
    /// Permission bits only, without the file type.
    mode: c.mode_t,
    atime: c.timespec,
    mtime: c.timespec,
};

/// Reads an entry's metadata without following a symlink. Zig's libc bindings have no `fstatat` on Linux, so Linux uses `statx(2)`.
fn lstat(path: *PathBuf) Failure!Metadata {
    if (is_linux) {
        var stx: linux.Statx = undefined;
        const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .ATIME = true, .MTIME = true };
        const rc = linux.statx(c.AT.FDCWD, path.z(), c.AT.SYMLINK_NOFOLLOW, mask, &stx);
        const err = linux.errno(rc);
        if (err != .SUCCESS) return fail(.stat, path, err);

        return .{
            .kind = kindOf(stx.mode),
            .mode = @intCast(stx.mode & 0o7777),
            .atime = .{ .sec = @intCast(stx.atime.sec), .nsec = @intCast(stx.atime.nsec) },
            .mtime = .{ .sec = @intCast(stx.mtime.sec), .nsec = @intCast(stx.mtime.nsec) },
        };
    }

    var st: c.Stat = undefined;
    if (c.fstatat(c.AT.FDCWD, path.z(), &st, c.AT.SYMLINK_NOFOLLOW) != 0) return fail(.stat, path, errno());

    return .{ .kind = kindOf(st.mode), .mode = @intCast(st.mode & 0o7777), .atime = st.atime(), .mtime = st.mtime() };
}

fn kindOf(mode: anytype) @FieldType(Metadata, "kind") {
    return switch (mode & c.S.IFMT) {
        c.S.IFDIR => .directory,
        c.S.IFREG => .regular,
        c.S.IFLNK => .symlink,
        else => .other,
    };
}

/// A NUL-terminated path that grows and shrinks by one component as the walk descends and returns.
pub const PathBuf = struct {
    bytes: [path_max:0]u8 = undefined,
    len: usize = 0,

    /// Copies `path`, failing when it does not fit.
    pub fn init(path: []const u8) Failure!PathBuf {
        var buf: PathBuf = .{};
        if (path.len >= buf.bytes.len) {
            writeStderr("minga-clone-tree: path is too long\n");
            return error.Failed;
        }
        @memcpy(buf.bytes[0..path.len], path);
        buf.len = path.len;
        buf.bytes[buf.len] = 0;
        return buf;
    }

    /// The path as a C string.
    pub fn z(self: *const PathBuf) [:0]const u8 {
        return self.bytes[0..self.len :0];
    }

    /// Appends `/name` and returns the previous length for `pop`.
    pub fn push(self: *PathBuf, name: []const u8) Failure!usize {
        const previous = self.len;
        if (previous + 1 + name.len >= self.bytes.len) return fail(.path_length, self, null);
        self.bytes[previous] = '/';
        @memcpy(self.bytes[previous + 1 ..][0..name.len], name);
        self.len = previous + 1 + name.len;
        self.bytes[self.len] = 0;
        return previous;
    }

    /// Restores the length `push` returned.
    pub fn pop(self: *PathBuf, previous: usize) void {
        self.len = previous;
        self.bytes[previous] = 0;
    }
};

fn errno() c.E {
    return @enumFromInt(c._errno().*);
}

/// Writes one diagnostic line and returns the classified failure.
fn fail(operation: Operation, path: *const PathBuf, err: ?c.E) Failure {
    var line: [path_max + 128]u8 = undefined;
    const message = if (err) |code|
        std.fmt.bufPrint(&line, "minga-clone-tree: {s} {s}: {s} ({d})\n", .{ @tagName(operation), path.z(), errnoName(code), @intFromEnum(code) })
    else
        std.fmt.bufPrint(&line, "minga-clone-tree: {s} {s}\n", .{ @tagName(operation), path.z() });
    writeStderr(message catch "minga-clone-tree: failed\n");

    return classify(operation, err orelse .SUCCESS);
}

/// A `clonefile(2)` failure names both paths, because either one can be the cause.
fn failClone(source: *const PathBuf, target: *const PathBuf, err: c.E) Failure {
    var line: [2 * path_max + 128]u8 = undefined;
    const message = std.fmt.bufPrint(&line, "minga-clone-tree: clonefile {s} -> {s}: {s} ({d})\n", .{ source.z(), target.z(), errnoName(err), @intFromEnum(err) });
    writeStderr(message catch "minga-clone-tree: clonefile failed\n");

    return classify(.clonefile, err);
}

fn errnoName(err: c.E) []const u8 {
    return std.enums.tagName(c.E, err) orelse "unknown errno";
}

fn writeStderr(bytes: []const u8) void {
    _ = c.write(2, bytes.ptr, bytes.len);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "only clone calls report unsupported, and only for their unsupported errno values" {
    try std.testing.expectEqual(error.Unsupported, classify(.clonefile, .OPNOTSUPP));
    try std.testing.expectEqual(error.Unsupported, classify(.clonefile, .XDEV));
    try std.testing.expectEqual(error.Failed, classify(.clonefile, .EXIST));
    try std.testing.expectEqual(error.Failed, classify(.clonefile, .ACCES));

    for ([_]c.E{ .OPNOTSUPP, .XDEV, .INVAL, .NOTTY, .NOSYS }) |err| {
        try std.testing.expectEqual(error.Unsupported, classify(.ficlone, err));
    }
    try std.testing.expectEqual(error.Failed, classify(.ficlone, .NOSPC));

    try std.testing.expectEqual(error.Unsupported, classify(.file_type, .SUCCESS));
    try std.testing.expectEqual(error.Failed, classify(.mkdir, .OPNOTSUPP));
    try std.testing.expectEqual(error.Failed, classify(.open, .XDEV));
}

test "exit status separates unsupported from failed" {
    try std.testing.expectEqual(exit_cloned, exitStatus({}));
    try std.testing.expectEqual(exit_unsupported, exitStatus(error.Unsupported));
    try std.testing.expectEqual(exit_failed, exitStatus(error.Failed));
}

test "path buffer pushes and pops components" {
    var path = try PathBuf.init("/tmp/a");
    const previous = try path.push("node_modules");
    try std.testing.expectEqualStrings("/tmp/a/node_modules", path.z());
    path.pop(previous);
    try std.testing.expectEqualStrings("/tmp/a", path.z());
}

/// A private scratch directory under TMPDIR, removed by `deinit`.
const Scratch = struct {
    root: PathBuf,

    extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

    fn init() !Scratch {
        var root = try PathBuf.init(std.mem.span(c.getenv("TMPDIR") orelse "/tmp"));
        while (root.len > 1 and root.bytes[root.len - 1] == '/') root.pop(root.len - 1);
        _ = try root.push("minga-clone-tree-XXXXXX");
        if (mkdtemp(&root.bytes) == null) return error.ScratchFailed;
        return .{ .root = root };
    }

    fn path(self: *const Scratch, relative: []const u8) !PathBuf {
        var result = self.root;
        _ = try result.push(relative);
        return result;
    }

    fn deinit(self: *Scratch) void {
        var argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", self.root.z() };
        const pid = c.fork();
        if (pid == 0) {
            _ = c.execve("/bin/rm", &argv, @ptrCast(c.environ));
            c._exit(127);
        }
        if (pid > 0) {
            var status: c_int = 0;
            _ = c.waitpid(pid, &status, 0);
        }
    }

    fn write(self: *const Scratch, relative: []const u8, contents: []const u8, mode: c_uint) !void {
        const file = try self.path(relative);
        const fd = c.open(file.z(), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, mode);
        if (fd < 0) return error.WriteFailed;
        defer _ = c.close(fd);
        if (c.write(fd, contents.ptr, contents.len) != @as(isize, @intCast(contents.len))) return error.WriteFailed;
    }

    fn mkdir(self: *const Scratch, relative: []const u8) !void {
        const dir = try self.path(relative);
        if (c.mkdir(dir.z(), 0o755) != 0) return error.MkdirFailed;
    }

    fn symlink(self: *const Scratch, target: [:0]const u8, relative: []const u8) !void {
        const link = try self.path(relative);
        if (c.symlink(target, link.z()) != 0) return error.SymlinkFailed;
    }

    fn read(self: *const Scratch, relative: []const u8, buffer: []u8) ![]const u8 {
        const file = try self.path(relative);
        const fd = c.open(file.z(), .{ .ACCMODE = .RDONLY });
        if (fd < 0) return error.ReadFailed;
        defer _ = c.close(fd);
        const count = c.read(fd, buffer.ptr, buffer.len);
        if (count < 0) return error.ReadFailed;
        return buffer[0..@intCast(count)];
    }

    fn readLink(self: *const Scratch, relative: []const u8, buffer: []u8) ![]const u8 {
        const link = try self.path(relative);
        const count = c.readlink(link.z(), buffer.ptr, buffer.len);
        if (count < 0) return error.ReadLinkFailed;
        return buffer[0..@intCast(count)];
    }
};

test "the walk clones directories and symlinks, and keeps links unresolved" {
    var scratch = try Scratch.init();
    defer scratch.deinit();

    try scratch.mkdir("source");
    try scratch.mkdir("source/.bin");
    try scratch.mkdir("source/@scope");
    try scratch.mkdir("source/@scope/pkg");
    try scratch.symlink("../@scope/pkg/cli.js", "source/.bin/pkg");
    try scratch.symlink("/absolute/outside", "source/linked");

    var source = try scratch.path("source");
    var target = try scratch.path("target");
    try cloneTree(&source, &target);

    var buffer: [path_max]u8 = undefined;
    try std.testing.expectEqualStrings("../@scope/pkg/cli.js", try scratch.readLink("target/.bin/pkg", &buffer));
    try std.testing.expectEqualStrings("/absolute/outside", try scratch.readLink("target/linked", &buffer));

    var pkg = try scratch.path("target/@scope/pkg");
    try std.testing.expectEqual(.directory, (try lstat(&pkg)).kind);
}

test "the walk clones regular files with their mode, or reports that the file system cannot" {
    var scratch = try Scratch.init();
    defer scratch.deinit();

    try scratch.mkdir("source");
    try scratch.write("source/index.js", "original\n", 0o755);

    var source = try scratch.path("source");
    var target = try scratch.path("target");
    cloneTree(&source, &target) catch |err| {
        // Linux CI runs on ext4, which cannot reflink: the walk stops at the first file and says so.
        try std.testing.expect(is_linux);
        try std.testing.expectEqual(error.Unsupported, err);
        return;
    };

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("original\n", try scratch.read("target/index.js", &buffer));

    var file = try scratch.path("target/index.js");
    try std.testing.expectEqual(@as(c.mode_t, 0o755), (try lstat(&file)).mode);
}

test "an existing target is a real failure, not an unsupported clone" {
    var scratch = try Scratch.init();
    defer scratch.deinit();

    try scratch.mkdir("source");
    try scratch.mkdir("target");

    var source = try scratch.path("source");
    var target = try scratch.path("target");
    try std.testing.expectEqual(error.Failed, cloneTree(&source, &target));
    try std.testing.expectEqual(error.Failed, clone(source.z(), target.z()));
}
