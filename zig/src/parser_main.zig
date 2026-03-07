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
            const cmd = protocol.decodeCommand(remaining) catch {
                break;
            };
            handleCommand(&hl, cmd, stdout, alloc) catch {};
            offset += protocol.commandSize(remaining);
        }
    }
}

/// Dispatch a highlight-related command to the Highlighter and send responses.
fn handleCommand(
    hl: *highlighter_mod.Highlighter,
    cmd: protocol.RenderCommand,
    stdout: *std.Io.Writer,
    alloc: std.mem.Allocator,
) !void {
    switch (cmd) {
        .set_language => |name| {
            if (!hl.setLanguage(name)) {
                // Unknown language; silently ignore.
            }
        },
        .parse_buffer => |pb| {
            hl.parse(pb.source) catch return;

            if (hl.query != null) {
                var result = hl.highlightWithInjections() catch return;
                defer result.deinit();

                // Send capture names.
                const names_buf = try protocol.encodeHighlightNames(alloc, result.capture_names);
                defer alloc.free(names_buf);
                try protocol.writeMessage(stdout, names_buf);

                // Send spans with version.
                const spans_buf = try protocol.encodeHighlightSpans(alloc, pb.version, result.spans);
                defer alloc.free(spans_buf);
                try protocol.writeMessage(stdout, spans_buf);

                // Send injection ranges if any.
                if (hl.injection_ranges.len > 0) {
                    const inj_buf = try protocol.encodeInjectionRanges(alloc, hl.injection_ranges);
                    defer alloc.free(inj_buf);
                    try protocol.writeMessage(stdout, inj_buf);
                }

                try stdout.flush();
            }
        },
        .set_highlight_query => |source| {
            hl.setHighlightQuery(source) catch {};
        },
        .set_injection_query => |source| {
            hl.setInjectionQuery(source) catch {};
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
