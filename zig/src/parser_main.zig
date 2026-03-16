/// Minga parser process — tree-sitter parsing and highlighting.
///
/// Runs as a BEAM Port (separate from the renderer):
///   stdin  ← highlight commands (4-byte big-endian length-prefixed binary)
///   stdout → highlight responses (4-byte big-endian length-prefixed binary)
///
/// This process handles only tree-sitter operations. It does not render
/// anything or interact with a terminal. All grammars are compiled in.
///
/// Supports multiple buffers simultaneously via buffer IDs in the protocol.
/// Each buffer maintains independent source content, parse tree, and language.
const std = @import("std");
const protocol = @import("protocol.zig");
const highlighter_mod = @import("highlighter.zig");
const c = highlighter_mod.c;

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

    // Per-buffer state: each buffer_id maps to its own source mirror.
    var buffers = BufferMap{};
    defer {
        var it = buffers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(alloc);
        }
        buffers.deinit(alloc);
    }

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
                handleEditBuffer(&hl, remaining[1..cmd_size], stdout, alloc, &buffers) catch {};
            } else if (remaining[0] == protocol.OP_CLOSE_BUFFER) {
                handleCloseBuffer(remaining[1..cmd_size], alloc, &buffers);
            } else {
                const cmd = protocol.decodeCommand(remaining) catch break;
                handleCommand(&hl, cmd, stdout, alloc, &buffers) catch {};
            }
            offset += cmd_size;
        }
    }
}

/// Map from buffer_id to per-buffer state.
const BufferMap = std.AutoHashMapUnmanaged(u32, BufferState);

/// Per-buffer state: keeps a mutable copy of the source, the parse tree,
/// and the language name. Each buffer owns its tree independently so
/// parsing buffer A never destroys buffer B's tree.
const BufferState = struct {
    source: std.ArrayListUnmanaged(u8) = .empty,
    /// Owned copy of the language name (allocated from `alloc`).
    language_name: ?[]u8 = null,
    tree: ?*c.TSTree = null,

    /// Replace the entire source (used by parse_buffer).
    fn setSource(self: *BufferState, alloc: std.mem.Allocator, content: []const u8) !void {
        self.source.clearRetainingCapacity();
        try self.source.appendSlice(alloc, content);
    }

    /// Apply edit deltas to the stored source, in order.
    fn applyEdits(self: *BufferState, alloc: std.mem.Allocator, edits: []const protocol.EditDelta) !void {
        for (edits) |edit| {
            const start: usize = @intCast(edit.start_byte);
            const old_end: usize = @intCast(edit.old_end_byte);

            if (start > self.source.items.len) continue;
            const clamped_old_end = @min(old_end, self.source.items.len);

            // Replace [start..old_end) with inserted_text.
            try self.source.replaceRange(alloc, start, clamped_old_end - start, edit.inserted_text);
        }
    }

    /// Set the language name, taking an owned copy.
    fn setLanguageName(self: *BufferState, alloc: std.mem.Allocator, name: []const u8) !void {
        if (self.language_name) |old| alloc.free(old);
        const copy = try alloc.alloc(u8, name.len);
        @memcpy(copy, name);
        self.language_name = copy;
    }

    fn deinit(self: *BufferState, alloc: std.mem.Allocator) void {
        if (self.tree) |t| c.ts_tree_delete(t);
        if (self.language_name) |name| alloc.free(name);
        self.source.deinit(alloc);
    }
};

/// Get or create a BufferState for the given buffer_id.
fn getOrCreateBuffer(buffers: *BufferMap, alloc: std.mem.Allocator, buffer_id: u32) !*BufferState {
    const gop = try buffers.getOrPut(alloc, buffer_id);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    return gop.value_ptr;
}

/// Switch the highlighter's active language to match a buffer's language
/// and install the buffer's tree (so incremental parsing works correctly).
/// Returns true if the highlighter is ready (language set), false otherwise.
fn activateBuffer(hl: *highlighter_mod.Highlighter, bs: *BufferState) bool {
    const lang_name = bs.language_name orelse return false;

    // Switch language if needed (this loads cached queries).
    const lang_changed = if (hl.current_language_name) |current|
        !std.mem.eql(u8, current, lang_name)
    else
        true;

    if (lang_changed) {
        // setLanguage deletes hl.tree, but we're about to replace it
        // with the buffer's tree anyway.
        _ = hl.setLanguage(lang_name);
    }

    // Install this buffer's tree into the highlighter (may be null for first parse).
    // We transfer ownership: the highlighter holds it during the operation,
    // and we save it back to BufferState after.
    hl.tree = bs.tree;
    bs.tree = null;
    hl.current_source = if (bs.source.items.len > 0) bs.source.items else null;

    return hl.current_language != null;
}

/// Save the highlighter's tree back to the buffer state after a parse/query operation.
fn saveTreeToBuffer(hl: *highlighter_mod.Highlighter, bs: *BufferState) void {
    bs.tree = hl.tree;
    hl.tree = null;
}

/// Dispatch a highlight-related command to the Highlighter and send responses.
fn handleCommand(
    hl: *highlighter_mod.Highlighter,
    cmd: protocol.RenderCommand,
    stdout: *std.Io.Writer,
    alloc: std.mem.Allocator,
    buffers: *BufferMap,
) !void {
    switch (cmd) {
        .set_language => |sl| {
            const bs = try getOrCreateBuffer(buffers, alloc, sl.buffer_id);
            bs.setLanguageName(alloc, sl.name) catch return;
            // Set the highlighter's active language so queries get loaded.
            _ = hl.setLanguage(sl.name);
        },
        .parse_buffer => |pb| {
            const bs = try getOrCreateBuffer(buffers, alloc, pb.buffer_id);
            bs.setSource(alloc, pb.source) catch return;

            // Activate this buffer (sets language, installs its tree).
            if (!activateBuffer(hl, bs)) return;

            hl.parse(bs.source.items) catch {
                saveTreeToBuffer(hl, bs);
                return;
            };

            if (hl.query != null) {
                sendHighlightResults(hl, pb.buffer_id, pb.version, stdout, alloc) catch {};
            }
            if (hl.fold_query != null) {
                sendFoldResults(hl, pb.buffer_id, pb.version, stdout, alloc) catch {};
            }
            if (hl.textobject_query != null) {
                sendTextobjectPositions(hl, pb.buffer_id, pb.version, stdout, alloc) catch {};
            }

            // Save tree back to buffer state.
            saveTreeToBuffer(hl, bs);
        },
        .edit_buffer => {
            // Handled at dispatch level via handleEditBuffer().
        },
        .set_highlight_query => |shq| {
            if (buffers.getPtr(shq.buffer_id)) |bs| {
                _ = activateBuffer(hl, bs);
                hl.setHighlightQuery(shq.source) catch {};
                saveTreeToBuffer(hl, bs);
            } else {
                hl.setHighlightQuery(shq.source) catch {};
            }
        },
        .set_injection_query => |siq| {
            if (buffers.getPtr(siq.buffer_id)) |bs| {
                _ = activateBuffer(hl, bs);
                hl.setInjectionQuery(siq.source) catch {};
                saveTreeToBuffer(hl, bs);
            } else {
                hl.setInjectionQuery(siq.source) catch {};
            }
        },
        .set_fold_query => |sfq| {
            if (buffers.getPtr(sfq.buffer_id)) |bs| {
                _ = activateBuffer(hl, bs);
                hl.setFoldQuery(sfq.source) catch {};
                saveTreeToBuffer(hl, bs);
            } else {
                hl.setFoldQuery(sfq.source) catch {};
            }
        },
        .set_indent_query => |siq_cmd| {
            if (buffers.getPtr(siq_cmd.buffer_id)) |bs| {
                _ = activateBuffer(hl, bs);
                hl.setIndentQuery(siq_cmd.source) catch {};
                saveTreeToBuffer(hl, bs);
            } else {
                hl.setIndentQuery(siq_cmd.source) catch {};
            }
        },
        .request_indent => |req| {
            const bs = buffers.getPtr(req.buffer_id) orelse return;
            if (!activateBuffer(hl, bs)) return;
            const level = hl.computeIndent(req.line, bs.source.items);
            saveTreeToBuffer(hl, bs);
            var rbuf: [13]u8 = undefined;
            const rlen = protocol.encodeIndentResult(&rbuf, req.request_id, req.line, level);
            try protocol.writeMessage(stdout, rbuf[0..rlen]);
            try stdout.flush();
        },
        .set_textobject_query => |stq| {
            if (buffers.getPtr(stq.buffer_id)) |bs| {
                _ = activateBuffer(hl, bs);
                hl.setTextobjectQuery(stq.source) catch {};
                saveTreeToBuffer(hl, bs);
            } else {
                hl.setTextobjectQuery(stq.source) catch {};
            }
        },
        .request_textobject => |req| {
            const bs = buffers.getPtr(req.buffer_id) orelse {
                var rbuf: [22]u8 = undefined;
                const rlen = protocol.encodeTextobjectResult(&rbuf, req.request_id, null);
                try protocol.writeMessage(stdout, rbuf[0..rlen]);
                try stdout.flush();
                return;
            };
            if (!activateBuffer(hl, bs)) return;
            const result = hl.findTextobject(req.row, req.col, req.capture_name);
            saveTreeToBuffer(hl, bs);
            var rbuf: [22]u8 = undefined;
            const rlen = protocol.encodeTextobjectResult(&rbuf, req.request_id, result);
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
            if (buffers.getPtr(q.buffer_id)) |bs| {
                _ = activateBuffer(hl, bs);
                const lang = hl.languageAt(q.byte_offset);
                saveTreeToBuffer(hl, bs);
                var rbuf: [260]u8 = undefined;
                const rlen = protocol.encodeLanguageAtResponse(&rbuf, q.request_id, lang) catch return;
                try protocol.writeMessage(stdout, rbuf[0..rlen]);
                try stdout.flush();
            } else {
                var rbuf: [260]u8 = undefined;
                const rlen = protocol.encodeLanguageAtResponse(&rbuf, q.request_id, null) catch return;
                try protocol.writeMessage(stdout, rbuf[0..rlen]);
                try stdout.flush();
            }
        },
        .close_buffer => {
            // Handled at dispatch level via handleCloseBuffer().
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
    buffers: *BufferMap,
) !void {
    const decoded = protocol.decodeEditBuffer(data, alloc) catch return;
    defer alloc.free(decoded.edits);

    const bs = try getOrCreateBuffer(buffers, alloc, decoded.buffer_id);

    // Apply edits to stored source.
    bs.applyEdits(alloc, decoded.edits) catch return;

    // Activate this buffer (sets language, installs its tree for incremental parsing).
    if (!activateBuffer(hl, bs)) return;

    // Incremental parse using the patched source.
    hl.parseIncremental(decoded.edits, bs.source.items) catch {
        // Fallback: full parse on the patched source.
        hl.parse(bs.source.items) catch {
            saveTreeToBuffer(hl, bs);
            return;
        };
    };

    if (hl.query != null) {
        sendHighlightResults(hl, decoded.buffer_id, decoded.version, stdout, alloc) catch {};
    }
    if (hl.fold_query != null) {
        sendFoldResults(hl, decoded.buffer_id, decoded.version, stdout, alloc) catch {};
    }
    if (hl.textobject_query != null) {
        sendTextobjectPositions(hl, decoded.buffer_id, decoded.version, stdout, alloc) catch {};
    }

    // Save tree back to buffer state.
    saveTreeToBuffer(hl, bs);
}

/// Handle a close_buffer command: free the buffer's state and tree.
fn handleCloseBuffer(
    data: []const u8,
    alloc: std.mem.Allocator,
    buffers: *BufferMap,
) void {
    if (data.len < 4) return;
    const buffer_id = std.mem.readInt(u32, data[0..4], .big);

    if (buffers.fetchRemove(buffer_id)) |kv| {
        var bs = kv.value;
        // BufferState.deinit frees the tree (if any) and source.
        bs.deinit(alloc);
    }
}

/// Send textobject positions to stdout.
fn sendTextobjectPositions(
    hl: *highlighter_mod.Highlighter,
    buffer_id: u32,
    version: u32,
    stdout: *std.Io.Writer,
    alloc: std.mem.Allocator,
) !void {
    const entries = hl.collectTextobjectPositions(alloc);
    defer if (entries.len > 0) alloc.free(entries);

    const buf = try protocol.encodeTextobjectPositions(alloc, buffer_id, version, entries);
    defer alloc.free(buf);
    try protocol.writeMessage(stdout, buf);
    try stdout.flush();
}

/// Send fold range results to stdout.
fn sendFoldResults(
    hl: *highlighter_mod.Highlighter,
    buffer_id: u32,
    version: u32,
    stdout: *std.Io.Writer,
    alloc: std.mem.Allocator,
) !void {
    const ranges = hl.runFoldQuery(alloc) catch return orelse return;
    defer alloc.free(ranges);

    const buf = try protocol.encodeFoldRanges(alloc, buffer_id, version, ranges);
    defer alloc.free(buf);
    try protocol.writeMessage(stdout, buf);
    try stdout.flush();
}

/// Send highlight results (names, spans, injection ranges) to stdout.
fn sendHighlightResults(
    hl: *highlighter_mod.Highlighter,
    buffer_id: u32,
    version: u32,
    stdout: *std.Io.Writer,
    alloc: std.mem.Allocator,
) !void {
    var result = hl.highlightWithInjections() catch return;
    defer result.deinit();

    const names_buf = try protocol.encodeHighlightNames(alloc, buffer_id, result.capture_names);
    defer alloc.free(names_buf);
    try protocol.writeMessage(stdout, names_buf);

    const spans_buf = try protocol.encodeHighlightSpans(alloc, buffer_id, version, result.spans);
    defer alloc.free(spans_buf);
    try protocol.writeMessage(stdout, spans_buf);

    if (hl.injection_ranges.len > 0) {
        const inj_buf = try protocol.encodeInjectionRanges(alloc, buffer_id, hl.injection_ranges);
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
