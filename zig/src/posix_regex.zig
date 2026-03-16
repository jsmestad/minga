/// Thin wrapper around POSIX regex (regcomp/regexec/regfree).
///
/// Available on macOS and Linux via libc. Used by the predicate evaluator
/// for `#match?` / `#not-match?` predicates in tree-sitter queries.
const std = @import("std");
const regex_h = @cImport(@cInclude("regex.h"));

pub const CompiledRegex = regex_h.regex_t;

/// Compile a regex pattern. Returns null if compilation fails.
/// The caller owns the returned pointer and must call `free()` when done.
pub fn compile(pattern: []const u8, allocator: std.mem.Allocator) ?*CompiledRegex {
    // POSIX regcomp needs a null-terminated string
    const z_pattern = allocator.allocSentinel(u8, pattern.len, 0) catch return null;
    defer allocator.free(z_pattern[0 .. pattern.len + 1]);
    @memcpy(z_pattern[0..pattern.len], pattern);

    const regex = allocator.create(CompiledRegex) catch return null;
    const result = regex_h.regcomp(regex, z_pattern.ptr, regex_h.REG_EXTENDED | regex_h.REG_NOSUB);
    if (result != 0) {
        allocator.destroy(regex);
        return null;
    }
    return regex;
}

/// Test if text matches the compiled regex.
pub fn matches(regex: *const CompiledRegex, text: []const u8) bool {
    // regexec needs a null-terminated string. For short identifiers (the
    // common case), use a stack buffer to avoid allocation.
    var stack_buf: [256]u8 = undefined;
    if (text.len < stack_buf.len) {
        @memcpy(stack_buf[0..text.len], text);
        stack_buf[text.len] = 0;
        return regex_h.regexec(regex, &stack_buf, 0, null, 0) == 0;
    }

    // Fallback: heap-allocate for very long text (rare)
    var gpa = std.heap.c_allocator;
    const z_text = gpa.allocSentinel(u8, text.len, 0) catch return false;
    defer gpa.free(z_text[0 .. text.len + 1]);
    @memcpy(z_text[0..text.len], text);
    return regex_h.regexec(regex, z_text.ptr, 0, null, 0) == 0;
}

/// Free a compiled regex.
pub fn free(regex: *CompiledRegex) void {
    regex_h.regfree(regex);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "compile and match simple pattern" {
    const re = compile("^[A-Z]", std.testing.allocator) orelse return error.CompileFailed;
    defer {
        free(re);
        std.testing.allocator.destroy(re);
    }

    try std.testing.expect(matches(re, "Foo"));
    try std.testing.expect(matches(re, "A"));
    try std.testing.expect(!matches(re, "foo"));
    try std.testing.expect(!matches(re, "123"));
}

test "compile and match anchored pattern" {
    const re = compile("^[A-Z][A-Z0-9_]+$", std.testing.allocator) orelse return error.CompileFailed;
    defer {
        free(re);
        std.testing.allocator.destroy(re);
    }

    try std.testing.expect(matches(re, "FOO_BAR"));
    try std.testing.expect(matches(re, "ABC123"));
    try std.testing.expect(!matches(re, "FooBar"));
    try std.testing.expect(!matches(re, "foo"));
}

test "compile and match underscore prefix" {
    const re = compile("^_", std.testing.allocator) orelse return error.CompileFailed;
    defer {
        free(re);
        std.testing.allocator.destroy(re);
    }

    try std.testing.expect(matches(re, "_unused"));
    try std.testing.expect(matches(re, "_"));
    try std.testing.expect(!matches(re, "used"));
}

test "invalid regex returns null" {
    const result = compile("[invalid", std.testing.allocator);
    try std.testing.expect(result == null);
}
