/// Comptime query loader with `; inherits:` resolution.
///
/// Tree-sitter query files can declare `; inherits: lang1,lang2` on their
/// first line. This is a convention from nvim-treesitter, adopted by Helix
/// and Zed. The tree-sitter C library ignores it (it's a comment), but
/// editors resolve the directive by prepending parent queries before
/// compilation.
///
/// This module resolves inheritance at comptime using Zig's `@embedFile`.
/// The result is a single concatenated query string baked into the binary
/// with zero runtime overhead. Multi-level inheritance (e.g., TSX ->
/// typescript -> ecma) is resolved recursively.
const std = @import("std");

const query_dir = "queries/";

/// Query type selector (which file to load from a language's query directory).
pub const QueryType = enum {
    highlights,
    injections,
    locals,
    folds,
};

/// Resolve a query with inheritance. Returns the fully concatenated query
/// string with all parent queries prepended, computed entirely at comptime.
/// Returns null if the language has no query of the requested type.
pub fn resolve(comptime name: []const u8, comptime qtype: QueryType) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(10000);
        return resolveImpl(name, qtype, 0);
    }
}

fn resolveImpl(comptime name: []const u8, comptime qtype: QueryType, comptime depth: usize) ?[]const u8 {
    if (depth > 8) @compileError("Query inheritance depth exceeded 8 levels (circular?): " ++ name);

    const raw = queryLookup(name, qtype) orelse return null;

    // Check for inherits directive on first line
    const prefix = "; inherits: ";
    const has_inherits = raw.len >= prefix.len and std.mem.eql(u8, raw[0..prefix.len], prefix);

    if (!has_inherits) return raw;

    // Find end of first line to extract parent names
    const line_end = comptime blk: {
        var i: usize = prefix.len;
        while (i < raw.len and raw[i] != '\n') : (i += 1) {}
        break :blk i;
    };

    const parents_str = raw[prefix.len..line_end];
    const own_query = if (line_end + 1 < raw.len) raw[line_end + 1 ..] else "";

    // Parse comma-separated parent names and resolve each
    const parents = comptime splitParents(parents_str);
    comptime var result: []const u8 = "";
    inline for (parents) |parent| {
        const resolved_parent = resolveImpl(parent, qtype, depth + 1);
        if (resolved_parent) |pq| {
            result = result ++ pq ++ "\n";
        }
    }
    return result ++ own_query;
}

/// Split "lang1, lang2" into a comptime tuple of trimmed strings.
fn splitParents(comptime s: []const u8) []const []const u8 {
    comptime {
        // Count fields
        var count: usize = 1;
        for (s) |ch| {
            if (ch == ',') count += 1;
        }

        var result: [count][]const u8 = undefined;
        var idx: usize = 0;
        var start: usize = 0;
        for (s, 0..) |ch, i| {
            if (ch == ',') {
                result[idx] = trimSlice(s[start..i]);
                idx += 1;
                start = i + 1;
            }
        }
        result[idx] = trimSlice(s[start..]);
        return &result;
    }
}

/// Trim leading/trailing whitespace from a comptime string slice.
fn trimSlice(comptime s: []const u8) []const u8 {
    comptime {
        var start: usize = 0;
        while (start < s.len and (s[start] == ' ' or s[start] == '\t')) {
            start += 1;
        }
        var end: usize = s.len;
        while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) {
            end -= 1;
        }
        return s[start..end];
    }
}

// ── Query lookup table ────────────────────────────────────────────────────
//
// Since @embedFile fails at comptime if the file doesn't exist, we use an
// explicit lookup function. This is the single place where query files are
// registered. Add new languages or query types here.

fn queryLookup(comptime name: []const u8, comptime qtype: QueryType) ?[]const u8 {
    // Virtual languages (query-only, no grammar; exist for inheritance)
    if (comptime std.mem.eql(u8, name, "ecma")) return switch (qtype) {
        .highlights => @embedFile(query_dir ++ "ecma/highlights.scm"),
        .injections => @embedFile(query_dir ++ "ecma/injections.scm"),
        .locals => @embedFile(query_dir ++ "ecma/locals.scm"),
        .folds => @embedFile(query_dir ++ "ecma/folds.scm"),
    };
    if (comptime std.mem.eql(u8, name, "jsx")) return switch (qtype) {
        .highlights => @embedFile(query_dir ++ "jsx/highlights.scm"),
        .injections => @embedFile(query_dir ++ "jsx/injections.scm"),
        .folds => @embedFile(query_dir ++ "jsx/folds.scm"),
        .locals => null,
    };
    if (comptime std.mem.eql(u8, name, "html_tags")) return switch (qtype) {
        .highlights => @embedFile(query_dir ++ "html_tags/highlights.scm"),
        .injections => @embedFile(query_dir ++ "html_tags/injections.scm"),
        .locals, .folds => null,
    };
    if (comptime std.mem.eql(u8, name, "php_only")) return switch (qtype) {
        .highlights => @embedFile(query_dir ++ "php_only/highlights.scm"),
        .injections => @embedFile(query_dir ++ "php_only/injections.scm"),
        .locals => @embedFile(query_dir ++ "php_only/locals.scm"),
        .folds => @embedFile(query_dir ++ "php_only/folds.scm"),
    };

    // Real languages (alphabetical)
    if (comptime std.mem.eql(u8, name, "bash")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "bash/highlights.scm"), .folds => @embedFile(query_dir ++ "bash/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "c")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "c/highlights.scm"), .folds => @embedFile(query_dir ++ "c/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "c_sharp")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "c_sharp/highlights.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "cpp")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "cpp/highlights.scm"), .injections => @embedFile(query_dir ++ "cpp/injections.scm"), .folds => @embedFile(query_dir ++ "cpp/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "css")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "css/highlights.scm"), .folds => @embedFile(query_dir ++ "css/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "dart")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "dart/highlights.scm"), .folds => @embedFile(query_dir ++ "dart/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "diff")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "diff/highlights.scm"), .folds => @embedFile(query_dir ++ "diff/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "dockerfile")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "dockerfile/highlights.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "elisp")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "elisp/highlights.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "elixir")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "elixir/highlights.scm"), .injections => @embedFile(query_dir ++ "elixir/injections.scm"), .folds => @embedFile(query_dir ++ "elixir/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "erlang")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "erlang/highlights.scm"), .folds => @embedFile(query_dir ++ "erlang/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "gleam")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "gleam/highlights.scm"), .injections => @embedFile(query_dir ++ "gleam/injections.scm"), .locals => @embedFile(query_dir ++ "gleam/locals.scm"), .folds => @embedFile(query_dir ++ "gleam/folds.scm") };
    if (comptime std.mem.eql(u8, name, "go")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "go/highlights.scm"), .folds => @embedFile(query_dir ++ "go/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "graphql")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "graphql/highlights.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "haskell")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "haskell/highlights.scm"), .folds => @embedFile(query_dir ++ "haskell/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "hcl")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "hcl/highlights.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "html")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "html/highlights.scm"), .injections => @embedFile(query_dir ++ "html/injections.scm"), .folds => @embedFile(query_dir ++ "html/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "java")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "java/highlights.scm"), .folds => @embedFile(query_dir ++ "java/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "javascript")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "javascript/highlights.scm"), .injections => @embedFile(query_dir ++ "javascript/injections.scm"), .locals => @embedFile(query_dir ++ "javascript/locals.scm"), .folds => @embedFile(query_dir ++ "javascript/folds.scm") };
    if (comptime std.mem.eql(u8, name, "json")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "json/highlights.scm"), .folds => @embedFile(query_dir ++ "json/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "kotlin")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "kotlin/highlights.scm"), .folds => @embedFile(query_dir ++ "kotlin/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "lua")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "lua/highlights.scm"), .injections => @embedFile(query_dir ++ "lua/injections.scm"), .locals => @embedFile(query_dir ++ "lua/locals.scm"), .folds => @embedFile(query_dir ++ "lua/folds.scm") };
    if (comptime std.mem.eql(u8, name, "make")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "make/highlights.scm"), .folds => @embedFile(query_dir ++ "make/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "markdown")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "markdown/highlights.scm"), .injections => @embedFile(query_dir ++ "markdown/injections.scm"), .folds => @embedFile(query_dir ++ "markdown/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "markdown_inline")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "markdown_inline/highlights.scm"), .injections => @embedFile(query_dir ++ "markdown_inline/injections.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "nix")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "nix/highlights.scm"), .folds => @embedFile(query_dir ++ "nix/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "ocaml")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "ocaml/highlights.scm"), .folds => @embedFile(query_dir ++ "ocaml/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "php")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "php/highlights.scm"), .folds => @embedFile(query_dir ++ "php/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "python")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "python/highlights.scm"), .folds => @embedFile(query_dir ++ "python/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "r")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "r/highlights.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "ruby")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "ruby/highlights.scm"), .locals => @embedFile(query_dir ++ "ruby/locals.scm"), .folds => @embedFile(query_dir ++ "ruby/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "rust")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "rust/highlights.scm"), .injections => @embedFile(query_dir ++ "rust/injections.scm"), .folds => @embedFile(query_dir ++ "rust/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "scala")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "scala/highlights.scm"), .folds => @embedFile(query_dir ++ "scala/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "scss")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "scss/highlights.scm"), .folds => @embedFile(query_dir ++ "scss/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "toml")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "toml/highlights.scm"), .folds => @embedFile(query_dir ++ "toml/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "tsx")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "tsx/highlights.scm"), .locals => @embedFile(query_dir ++ "tsx/locals.scm"), .folds => @embedFile(query_dir ++ "tsx/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "typescript")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "typescript/highlights.scm"), .locals => @embedFile(query_dir ++ "typescript/locals.scm"), .folds => @embedFile(query_dir ++ "typescript/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "yaml")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "yaml/highlights.scm"), .folds => @embedFile(query_dir ++ "yaml/folds.scm"), else => null };
    if (comptime std.mem.eql(u8, name, "zig")) return switch (qtype) { .highlights => @embedFile(query_dir ++ "zig/highlights.scm"), .injections => @embedFile(query_dir ++ "zig/injections.scm"), .folds => @embedFile(query_dir ++ "zig/folds.scm"), else => null };

    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "resolve: no inheritance returns raw query" {
    const result = comptime resolve("elixir", .highlights) orelse unreachable;
    try std.testing.expect(!std.mem.startsWith(u8, result, "; inherits:"));
    try std.testing.expect(result.len > 0);
}

test "resolve: typescript inherits ecma" {
    const result = comptime resolve("typescript", .highlights) orelse unreachable;
    // ecma content (arrow_function is in ecma, not TS-specific)
    try std.testing.expect(std.mem.indexOf(u8, result, "arrow_function") != null);
    // typescript-specific content
    try std.testing.expect(std.mem.indexOf(u8, result, "type_identifier") != null);
    // no inherits directive leaked through
    try std.testing.expect(!std.mem.startsWith(u8, result, "; inherits:"));
}

test "resolve: tsx multi-level (tsx -> typescript -> ecma, tsx -> jsx)" {
    const result = comptime resolve("tsx", .highlights) orelse unreachable;
    // ecma content (via typescript -> ecma chain)
    try std.testing.expect(std.mem.indexOf(u8, result, "arrow_function") != null);
    // jsx content (direct parent)
    try std.testing.expect(std.mem.indexOf(u8, result, "jsx_element") != null);
    try std.testing.expect(!std.mem.startsWith(u8, result, "; inherits:"));
}

test "resolve: javascript inherits ecma and jsx" {
    const result = comptime resolve("javascript", .highlights) orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, result, "arrow_function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "jsx_element") != null);
}

test "resolve: cpp inherits c" {
    const result = comptime resolve("cpp", .highlights) orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, result, "primitive_type") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "namespace_identifier") != null);
}

test "resolve: scss inherits css" {
    const result = comptime resolve("scss", .highlights) orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, result, "property_name") != null);
}

test "resolve: html inherits html_tags" {
    const result = comptime resolve("html", .highlights) orelse unreachable;
    try std.testing.expect(result.len > 0);
    try std.testing.expect(!std.mem.startsWith(u8, result, "; inherits:"));
}

test "resolve: php inherits php_only" {
    const result = comptime resolve("php", .highlights) orelse unreachable;
    try std.testing.expect(result.len > 0);
    try std.testing.expect(!std.mem.startsWith(u8, result, "; inherits:"));
}

test "resolve: nonexistent language returns null" {
    const result = comptime resolve("nonexistent", .highlights);
    try std.testing.expect(result == null);
}

test "resolve: missing query type returns null" {
    const result = comptime resolve("bash", .folds);
    try std.testing.expect(result == null);
}

test "resolve: zig folds (no inheritance)" {
    const result = comptime resolve("zig", .folds) orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, result, "@fold") != null);
}

test "splitParents: single parent" {
    const parents = comptime splitParents("ecma");
    try std.testing.expectEqual(@as(usize, 1), parents.len);
    try std.testing.expectEqualStrings("ecma", parents[0]);
}

test "splitParents: multiple parents" {
    const parents = comptime splitParents("typescript,jsx");
    try std.testing.expectEqual(@as(usize, 2), parents.len);
    try std.testing.expectEqualStrings("typescript", parents[0]);
    try std.testing.expectEqualStrings("jsx", parents[1]);
}

test "splitParents: parents with spaces" {
    const parents = comptime splitParents("typescript, jsx");
    try std.testing.expectEqual(@as(usize, 2), parents.len);
    try std.testing.expectEqualStrings("typescript", parents[0]);
    try std.testing.expectEqualStrings("jsx", parents[1]);
}
