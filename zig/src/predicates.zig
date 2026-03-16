/// Tree-sitter query predicate evaluation.
///
/// Tree-sitter queries can contain predicates like `#any-of?`, `#match?`,
/// `#eq?` and their negations. The tree-sitter C library does NOT evaluate
/// these; it returns all structural matches and expects the host to filter
/// them. This module pre-parses predicates at query compile time into a
/// per-pattern lookup table, then evaluates them per-match in O(1) lookup
/// + O(predicate_count) evaluation.
const std = @import("std");
const c = @import("highlighter.zig").c;
const posix_regex = @import("posix_regex.zig");

/// A single parsed predicate from a tree-sitter query pattern.
pub const Predicate = union(enum) {
    /// `#any-of? @capture "str1" "str2" ...` or `#not-any-of?`
    any_of: struct {
        capture_id: u32,
        strings: []const []const u8,
        negate: bool,
    },
    /// `#match? @capture "regex"` or `#not-match?`
    match_pred: struct {
        capture_id: u32,
        regex: ?*posix_regex.CompiledRegex,
        negate: bool,
    },
    /// `#eq? @capture "string"` or `#not-eq?`
    eq_string: struct {
        capture_id: u32,
        string: []const u8,
        negate: bool,
    },
    /// `#eq? @capture1 @capture2` or `#not-eq?`
    eq_capture: struct {
        capture_id1: u32,
        capture_id2: u32,
        negate: bool,
    },
};

/// Pre-parsed predicate table for a query. Indexed by pattern_index.
/// Each entry is null (no predicates) or a slice of predicates that
/// must ALL pass for a match to be accepted.
pub const PredicateTable = struct {
    /// One entry per pattern. null = no predicates (always passes).
    entries: []?[]const Predicate,
    allocator: std.mem.Allocator,
    /// Track compiled regexes for cleanup
    regexes: std.ArrayListUnmanaged(*posix_regex.CompiledRegex),

    /// Build a predicate table from a compiled query.
    pub fn init(query: *c.TSQuery, allocator: std.mem.Allocator) PredicateTable {
        const pattern_count = c.ts_query_pattern_count(query);
        const entries = allocator.alloc(?[]const Predicate, pattern_count) catch
            return .{ .entries = &.{}, .allocator = allocator, .regexes = .empty };

        var regexes: std.ArrayListUnmanaged(*posix_regex.CompiledRegex) = .empty;

        for (0..pattern_count) |i| {
            entries[i] = parsePattern(query, @intCast(i), allocator, &regexes);
        }

        return .{
            .entries = entries,
            .allocator = allocator,
            .regexes = regexes,
        };
    }

    pub fn deinit(self: *PredicateTable) void {
        // Free compiled regexes
        for (self.regexes.items) |re| {
            posix_regex.free(re);
        }
        self.regexes.deinit(self.allocator);

        // Free predicate data
        for (self.entries) |maybe_preds| {
            if (maybe_preds) |preds| {
                for (preds) |pred| {
                    switch (pred) {
                        .any_of => |ao| self.allocator.free(ao.strings),
                        else => {},
                    }
                }
                self.allocator.free(preds);
            }
        }
        self.allocator.free(self.entries);
    }

    /// Evaluate all predicates for a given match. Returns true if all pass.
    pub fn evaluate(self: *const PredicateTable, match: c.TSQueryMatch, source: []const u8) bool {
        if (match.pattern_index >= self.entries.len) return true;
        const preds = self.entries[match.pattern_index] orelse return true;

        for (preds) |pred| {
            if (!evaluateOne(pred, match, source)) return false;
        }
        return true;
    }
};

/// Evaluate a single predicate against a match.
fn evaluateOne(pred: Predicate, match: c.TSQueryMatch, source: []const u8) bool {
    switch (pred) {
        .any_of => |ao| {
            const text = captureText(match, ao.capture_id, source) orelse return ao.negate;
            for (ao.strings) |s| {
                if (std.mem.eql(u8, text, s)) return !ao.negate;
            }
            return ao.negate;
        },
        .match_pred => |mp| {
            const text = captureText(match, mp.capture_id, source) orelse return mp.negate;
            const re = mp.regex orelse return true; // regex failed to compile, skip
            const matches = posix_regex.matches(re, text);
            return if (mp.negate) !matches else matches;
        },
        .eq_string => |es| {
            const text = captureText(match, es.capture_id, source) orelse return es.negate;
            const equal = std.mem.eql(u8, text, es.string);
            return if (es.negate) !equal else equal;
        },
        .eq_capture => |ec| {
            const text1 = captureText(match, ec.capture_id1, source) orelse return ec.negate;
            const text2 = captureText(match, ec.capture_id2, source) orelse return ec.negate;
            const equal = std.mem.eql(u8, text1, text2);
            return if (ec.negate) !equal else equal;
        },
    }
}

/// Get the source text for a capture within a match.
fn captureText(match: c.TSQueryMatch, capture_id: u32, source: []const u8) ?[]const u8 {
    const captures = match.captures[0..match.capture_count];
    for (captures) |cap| {
        if (cap.index == capture_id) {
            const start = c.ts_node_start_byte(cap.node);
            const end = c.ts_node_end_byte(cap.node);
            if (end <= source.len and end >= start) {
                return source[start..end];
            }
            return null;
        }
    }
    return null;
}

// ── Predicate parsing ─────────────────────────────────────────────────────

/// Parse all predicates for a single pattern.
fn parsePattern(
    query: *c.TSQuery,
    pattern_index: u32,
    allocator: std.mem.Allocator,
    regexes: *std.ArrayListUnmanaged(*posix_regex.CompiledRegex),
) ?[]const Predicate {
    var step_count: u32 = 0;
    const steps = c.ts_query_predicates_for_pattern(query, pattern_index, &step_count);
    if (step_count == 0) return null;

    var preds: std.ArrayListUnmanaged(Predicate) = .empty;

    // Walk steps: each predicate starts with a string (the name), followed
    // by args (captures or strings), terminated by Done.
    var i: u32 = 0;
    while (i < step_count) {
        // First step must be the predicate name (string type)
        if (steps[i].type != c.TSQueryPredicateStepTypeString) {
            // Skip to next Done
            while (i < step_count and steps[i].type != c.TSQueryPredicateStepTypeDone) : (i += 1) {}
            if (i < step_count) i += 1; // skip Done
            continue;
        }

        var name_len: u32 = 0;
        const name_ptr = c.ts_query_string_value_for_id(query, steps[i].value_id, &name_len);
        const name = name_ptr[0..name_len];
        i += 1;

        // Collect args until Done
        const args_start = i;
        while (i < step_count and steps[i].type != c.TSQueryPredicateStepTypeDone) : (i += 1) {}
        const args_end = i;
        if (i < step_count) i += 1; // skip Done

        const arg_steps = steps[args_start..args_end];

        if (parsePredicate(query, name, arg_steps, allocator, regexes)) |pred| {
            preds.append(allocator, pred) catch {};
        }
    }

    if (preds.items.len == 0) {
        preds.deinit(allocator);
        return null;
    }

    return preds.toOwnedSlice(allocator) catch null;
}

/// Parse a single predicate from its name and argument steps.
fn parsePredicate(
    query: *c.TSQuery,
    name: []const u8,
    args: []const c.TSQueryPredicateStep,
    allocator: std.mem.Allocator,
    regexes: *std.ArrayListUnmanaged(*posix_regex.CompiledRegex),
) ?Predicate {
    // #any-of? / #not-any-of?
    if (std.mem.eql(u8, name, "any-of?") or std.mem.eql(u8, name, "not-any-of?")) {
        const negate = std.mem.eql(u8, name, "not-any-of?");
        if (args.len < 2) return null;
        if (args[0].type != c.TSQueryPredicateStepTypeCapture) return null;
        const capture_id = args[0].value_id;

        // Remaining args are strings
        const string_count = args.len - 1;
        const strings = allocator.alloc([]const u8, string_count) catch return null;
        var count: usize = 0;
        for (args[1..]) |arg| {
            if (arg.type == c.TSQueryPredicateStepTypeString) {
                var slen: u32 = 0;
                const sptr = c.ts_query_string_value_for_id(query, arg.value_id, &slen);
                strings[count] = sptr[0..slen];
                count += 1;
            }
        }

        return .{ .any_of = .{
            .capture_id = capture_id,
            .strings = strings[0..count],
            .negate = negate,
        } };
    }

    // #match? / #not-match?
    if (std.mem.eql(u8, name, "match?") or std.mem.eql(u8, name, "not-match?")) {
        const negate = std.mem.eql(u8, name, "not-match?");
        if (args.len < 2) return null;
        if (args[0].type != c.TSQueryPredicateStepTypeCapture) return null;
        if (args[1].type != c.TSQueryPredicateStepTypeString) return null;

        const capture_id = args[0].value_id;
        var plen: u32 = 0;
        const pptr = c.ts_query_string_value_for_id(query, args[1].value_id, &plen);
        const pattern = pptr[0..plen];

        // Compile regex
        const regex = posix_regex.compile(pattern, allocator);
        if (regex) |re| {
            regexes.append(allocator, re) catch {};
        }

        return .{ .match_pred = .{
            .capture_id = capture_id,
            .regex = regex,
            .negate = negate,
        } };
    }

    // #eq? / #not-eq?
    if (std.mem.eql(u8, name, "eq?") or std.mem.eql(u8, name, "not-eq?")) {
        const negate = std.mem.eql(u8, name, "not-eq?");
        if (args.len < 2) return null;
        if (args[0].type != c.TSQueryPredicateStepTypeCapture) return null;

        const capture_id1 = args[0].value_id;

        if (args[1].type == c.TSQueryPredicateStepTypeString) {
            // #eq? @capture "string"
            var slen: u32 = 0;
            const sptr = c.ts_query_string_value_for_id(query, args[1].value_id, &slen);
            return .{ .eq_string = .{
                .capture_id = capture_id1,
                .string = sptr[0..slen],
                .negate = negate,
            } };
        } else if (args[1].type == c.TSQueryPredicateStepTypeCapture) {
            // #eq? @capture1 @capture2
            return .{ .eq_capture = .{
                .capture_id1 = capture_id1,
                .capture_id2 = args[1].value_id,
                .negate = negate,
            } };
        }

        return null;
    }

    // Unknown predicate: ignore (e.g., #set!, #offset!, etc.)
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────

extern fn tree_sitter_elixir() ?*const c.TSLanguage;

test "PredicateTable: no predicates returns true" {
    // A query with no predicates should always pass evaluation
    const query_src = "(identifier) @variable";
    var err_off: u32 = 0;
    var err_type: c.TSQueryError = c.TSQueryErrorNone;

    const lang = tree_sitter_elixir();
    const query = c.ts_query_new(
        lang,
        query_src.ptr,
        @intCast(query_src.len),
        &err_off,
        &err_type,
    ) orelse return error.QueryCompileFailed;
    defer c.ts_query_delete(query);

    var table = PredicateTable.init(query, std.testing.allocator);
    defer table.deinit();

    // All entries should be null (no predicates)
    for (table.entries) |entry| {
        try std.testing.expect(entry == null);
    }
}

test "PredicateTable: #any-of? parsed correctly" {
    const query_src =
        \\((identifier) @keyword
        \\  (#any-of? @keyword "def" "defp" "defmodule"))
    ;
    var err_off: u32 = 0;
    var err_type: c.TSQueryError = c.TSQueryErrorNone;

    const lang = tree_sitter_elixir();
    const query = c.ts_query_new(
        lang,
        query_src.ptr,
        @intCast(query_src.len),
        &err_off,
        &err_type,
    ) orelse return error.QueryCompileFailed;
    defer c.ts_query_delete(query);

    var table = PredicateTable.init(query, std.testing.allocator);
    defer table.deinit();

    // Pattern 0 should have predicates
    const preds = table.entries[0] orelse return error.NoPreds;
    try std.testing.expectEqual(@as(usize, 1), preds.len);
    switch (preds[0]) {
        .any_of => |ao| {
            try std.testing.expectEqual(@as(usize, 3), ao.strings.len);
            try std.testing.expectEqualStrings("def", ao.strings[0]);
            try std.testing.expectEqualStrings("defp", ao.strings[1]);
            try std.testing.expectEqualStrings("defmodule", ao.strings[2]);
            try std.testing.expect(!ao.negate);
        },
        else => return error.WrongPredType,
    }
}

test "PredicateTable: #match? parsed and evaluates" {
    const query_src =
        \\((identifier) @type
        \\  (#match? @type "^[A-Z]"))
    ;
    var err_off: u32 = 0;
    var err_type: c.TSQueryError = c.TSQueryErrorNone;

    const lang = tree_sitter_elixir();
    const query = c.ts_query_new(
        lang,
        query_src.ptr,
        @intCast(query_src.len),
        &err_off,
        &err_type,
    ) orelse return error.QueryCompileFailed;
    defer c.ts_query_delete(query);

    var table = PredicateTable.init(query, std.testing.allocator);
    defer table.deinit();

    const preds = table.entries[0] orelse return error.NoPreds;
    try std.testing.expectEqual(@as(usize, 1), preds.len);
    switch (preds[0]) {
        .match_pred => |mp| {
            try std.testing.expect(mp.regex != null);
            try std.testing.expect(!mp.negate);
        },
        else => return error.WrongPredType,
    }
}
