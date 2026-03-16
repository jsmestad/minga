/// Thin wrapper around POSIX regex (regcomp/regexec/regfree).
///
/// Available on macOS and Linux via libc. Used by the predicate evaluator
/// for `#match?` / `#not-match?` predicates in tree-sitter queries.
///
/// On Linux/glibc, `regex_t` is opaque to Zig's C import, so we cannot
/// use `@sizeOf`. Instead we allocate via the C allocator (malloc) which
/// sees the real struct layout from the system headers.
const std = @import("std");
const c = @cImport(@cInclude("regex.h"));

pub const CompiledRegex = c.regex_t;

/// Compile a regex pattern. Returns null if compilation fails.
/// The caller owns the returned pointer and must call `free()` when done.
pub fn compile(pattern: []const u8, allocator: std.mem.Allocator) ?*CompiledRegex {
    // POSIX regcomp needs a null-terminated string
    const z_pattern = allocator.allocSentinel(u8, pattern.len, 0) catch return null;
    defer allocator.free(z_pattern[0 .. pattern.len + 1]);
    @memcpy(z_pattern[0..pattern.len], pattern);

    // Use C allocator for regex_t: on Linux/glibc the struct is opaque to
    // Zig, so std.mem.Allocator.create() can't determine its size. The C
    // allocator (malloc) always works because it uses the system headers.
    const regex: *CompiledRegex = std.heap.c_allocator.create(CompiledRegex) catch return null;
    const result = c.regcomp(regex, z_pattern.ptr, c.REG_EXTENDED | c.REG_NOSUB);
    if (result != 0) {
        std.heap.c_allocator.destroy(regex);
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
        return c.regexec(regex, &stack_buf, 0, null, 0) == 0;
    }

    // Fallback: heap-allocate for very long text (rare)
    const z_text = std.heap.c_allocator.allocSentinel(u8, text.len, 0) catch return false;
    defer std.heap.c_allocator.free(z_text[0 .. text.len + 1]);
    @memcpy(z_text[0..text.len], text);
    return c.regexec(regex, z_text.ptr, 0, null, 0) == 0;
}

/// Free a compiled regex. The regex_t was allocated via C allocator.
pub fn free(regex: *CompiledRegex) void {
    c.regfree(regex);
    std.heap.c_allocator.destroy(regex);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "compile and match simple pattern" {
    const re = compile("^[A-Z]", std.testing.allocator) orelse return error.CompileFailed;
    defer free(re);

    try std.testing.expect(matches(re, "Foo"));
    try std.testing.expect(matches(re, "A"));
    try std.testing.expect(!matches(re, "foo"));
    try std.testing.expect(!matches(re, "123"));
}

test "compile and match anchored pattern" {
    const re = compile("^[A-Z][A-Z0-9_]+$", std.testing.allocator) orelse return error.CompileFailed;
    defer free(re);

    try std.testing.expect(matches(re, "FOO_BAR"));
    try std.testing.expect(matches(re, "ABC123"));
    try std.testing.expect(!matches(re, "FooBar"));
    try std.testing.expect(!matches(re, "foo"));
}

test "compile and match underscore prefix" {
    const re = compile("^_", std.testing.allocator) orelse return error.CompileFailed;
    defer free(re);

    try std.testing.expect(matches(re, "_unused"));
    try std.testing.expect(matches(re, "_"));
    try std.testing.expect(!matches(re, "used"));
}

test "invalid regex returns null" {
    const result = compile("[invalid", std.testing.allocator);
    try std.testing.expect(result == null);
}
