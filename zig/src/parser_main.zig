/// Minga parser process — tree-sitter parsing and highlighting.
///
/// Runs as a BEAM Port (separate from the renderer):
///   stdin  ← highlight commands (4-byte big-endian length-prefixed binary)
///   stdout → highlight responses (4-byte big-endian length-prefixed binary)
///
/// This process handles only tree-sitter operations. It does not render
/// anything or interact with a terminal. All grammars are compiled in.
const std = @import("std");
const protocol = @import("protocol.zig");
const highlighter_mod = @import("highlighter.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var hl = try highlighter_mod.Highlighter.init(alloc);
    defer hl.deinit();
    hl.startPrewarm();

    // Stdout (Port protocol channel).
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer_obj = std.fs.File.stdout().writer(&stdout_buf);
    const stdout: *std.Io.Writer = &stdout_writer_obj.interface;

    const stdin_fd = std.posix.STDIN_FILENO;
    var msg_buf: [65536]u8 = undefined;
    var ps = ParserState.init(alloc);
    defer ps.deinit();

    while (true) {
        // Read the 4-byte length header.
        var len_buf: [4]u8 = undefined;
        if (!try readExact(stdin_fd, &len_buf)) break;

        const msg_len: usize = std.mem.readInt(u32, &len_buf, .big);
        if (msg_len == 0) continue;
        if (msg_len > msg_buf.len) {
            // Message too large; skip it.
            var skip_remaining = msg_len;
            while (skip_remaining > 0) {
                const chunk = @min(skip_remaining, msg_buf.len);
                if (!try readExact(stdin_fd, msg_buf[0..chunk])) return;
                skip_remaining -= chunk;
            }
            continue;
        }

        const payload = msg_buf[0..msg_len];
        if (!try readExact(stdin_fd, payload)) break;

        // Dispatch commands within the payload.
        var offset: usize = 0;
        while (offset < msg_len) {
            const remaining = payload[offset..];
            const cmd_size = protocol.commandSize(remaining);

            // edit_buffer needs special handling: decode full edits from raw payload.
            if (remaining[0] == protocol.OP_EDIT_BUFFER) {
                handleEditBuffer(&hl, remaining[1..cmd_size], stdout, alloc, &ps) catch {};
            } else {
                const cmd = protocol.decodeCommand(remaining) catch break;
                handleCommand(&hl, cmd, stdout, alloc, &ps) catch {};
            }
            offset += cmd_size;
        }
    }
}

/// Parser state: keeps a mutable copy of the source so edit_buffer can
/// patch it in-place instead of receiving the full content each time.
const ParserState = struct {
    source: std.ArrayListUnmanaged(u8) = .empty,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) ParserState {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *ParserState) void {
        self.source.deinit(self.alloc);
    }

    /// Replace the entire source (used by parse_buffer).
    fn setSource(self: *ParserState, content: []const u8) !void {
        self.source.clearRetainingCapacity();
        try self.source.appendSlice(self.alloc, content);
    }

    /// Apply edit deltas to the stored source, in order.
    fn applyEdits(self: *ParserState, edits: []const protocol.EditDelta) !void {
        for (edits) |edit| {
            const start: usize = @intCast(edit.start_byte);
            const old_end: usize = @intCast(edit.old_end_byte);

            if (start > self.source.items.len) continue;
            const clamped_old_end = @min(old_end, self.source.items.len);

            // Replace [start..old_end) with inserted_text.
            try self.source.replaceRange(self.alloc, start, clamped_old_end - start, edit.inserted_text);
        }
    }
};

/// Dispatch a highlight-related command to the Highlighter and send responses.
fn handleCommand(
    hl: *highlighter_mod.Highlighter,
    cmd: protocol.RenderCommand,
    stdout: *std.Io.Writer,
    alloc: std.mem.Allocator,
    ps: *ParserState,
) !void {
    switch (cmd) {
        .set_language => |name| {
            if (!hl.setLanguage(name)) {
                // Unknown language; silently ignore.
            }
        },
        .parse_buffer => |pb| {
            // Full content sync: update stored source and do a full parse.
            ps.setSource(pb.source) catch return;
            hl.parse(ps.source.items) catch return;

            if (hl.query != null) {
                try sendHighlightResults(hl, pb.version, stdout, alloc);
            }
            if (hl.fold_query != null) {
                try sendFoldResults(hl, pb.version, stdout, alloc);
            }
        },
        .edit_buffer => {
            // Handled at dispatch level via handleEditBuffer().
        },
        .set_highlight_query => |source| {
            hl.setHighlightQuery(source) catch {};
        },
        .set_injection_query => |source| {
            hl.setInjectionQuery(source) catch {};
        },
        .set_fold_query => |source| {
            hl.setFoldQuery(source) catch {};
        },
        .set_indent_query => |source| {
            hl.setIndentQuery(source) catch {};
        },
        .request_indent => |req| {
            const level = hl.computeIndent(req.line, ps.source.items);
            var rbuf: [13]u8 = undefined;
            const rlen = protocol.encodeIndentResult(&rbuf, req.request_id, req.line, level);
            try protocol.writeMessage(stdout, rbuf[0..rlen]);
            try stdout.flush();
        },
        .load_grammar => |lg| {
            hl.loadGrammar(lg.name, lg.path) catch {
                var rbuf: [260]u8 = undefined;
                const rlen = protocol.encodeGrammarLoaded(&rbuf, false, lg.name) catch return;
                try protocol.writeMessage(stdout, rbuf[0..rlen]);
                try stdout.flush();
                return;
            };
            var rbuf: [260]u8 = undefined;
            const rlen = try protocol.encodeGrammarLoaded(&rbuf, true, lg.name);
            try protocol.writeMessage(stdout, rbuf[0..rlen]);
            try stdout.flush();
        },
        .query_language_at => |q| {
            const lang = hl.languageAt(q.byte_offset);
            var rbuf: [260]u8 = undefined;
            const rlen = protocol.encodeLanguageAtResponse(&rbuf, q.request_id, lang) catch return;
            try protocol.writeMessage(stdout, rbuf[0..rlen]);
            try stdout.flush();
        },
        // Render commands are not handled by the parser process.
        else => {},
    }
}

/// Handle an edit_buffer command: decode edits, patch stored source,
/// incrementally reparse, send highlight results.
fn handleEditBuffer(
    hl: *highlighter_mod.Highlighter,
    data: []const u8,
    stdout: *std.Io.Writer,
    alloc: std.mem.Allocator,
    ps: *ParserState,
) !void {
    const decoded = protocol.decodeEditBuffer(data, alloc) catch return;
    defer alloc.free(decoded.edits);

    // Apply edits to stored source.
    ps.applyEdits(decoded.edits) catch return;

    // Incremental parse using the patched source.
    hl.parseIncremental(decoded.edits, ps.source.items) catch {
        // Fallback: full parse on the patched source.
        hl.parse(ps.source.items) catch return;
    };

    if (hl.query != null) {
        try sendHighlightResults(hl, decoded.version, stdout, alloc);
    }
    if (hl.fold_query != null) {
        try sendFoldResults(hl, decoded.version, stdout, alloc);
    }
}

/// Send fold range results to stdout.
fn sendFoldResults(
    hl: *highlighter_mod.Highlighter,
    version: u32,
    stdout: *std.Io.Writer,
    alloc: std.mem.Allocator,
) !void {
    const ranges = hl.runFoldQuery(alloc) catch return orelse return;
    defer alloc.free(ranges);

    const buf = try protocol.encodeFoldRanges(alloc, version, ranges);
    defer alloc.free(buf);
    try protocol.writeMessage(stdout, buf);
    try stdout.flush();
}

/// Send highlight results (names, spans, injection ranges) to stdout.
fn sendHighlightResults(
    hl: *highlighter_mod.Highlighter,
    version: u32,
    stdout: *std.Io.Writer,
    alloc: std.mem.Allocator,
) !void {
    var result = hl.highlightWithInjections() catch return;
    defer result.deinit();

    const names_buf = try protocol.encodeHighlightNames(alloc, result.capture_names);
    defer alloc.free(names_buf);
    try protocol.writeMessage(stdout, names_buf);

    const spans_buf = try protocol.encodeHighlightSpans(alloc, version, result.spans);
    defer alloc.free(spans_buf);
    try protocol.writeMessage(stdout, spans_buf);

    if (hl.injection_ranges.len > 0) {
        const inj_buf = try protocol.encodeInjectionRanges(alloc, hl.injection_ranges);
        defer alloc.free(inj_buf);
        try protocol.writeMessage(stdout, inj_buf);
    }

    try stdout.flush();
}

/// Read exactly `buf.len` bytes from `fd`, blocking until done.
/// Returns `false` on EOF, `true` when all bytes are read.
fn readExact(fd: std.posix.fd_t, buf: []u8) !bool {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try std.posix.read(fd, buf[total..]);
        if (n == 0) return false;
        total += n;
    }
    return true;
}
