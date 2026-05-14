const std = @import("std");
const builtin = @import("builtin");
pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});
const predicates_mod = @import("predicates.zig");
const query_loader = @import("query_loader.zig");

/// A highlight span: byte range + capture index.
/// `pattern_index` is used for priority sorting (higher = more specific)
/// but is NOT serialized in the port protocol.
const protocol = @import("protocol.zig");
pub const Span = protocol.Span;

/// A conceal span: byte range + replacement text from `#set! conceal "X"`.
pub const ConcealSpan = struct {
    start_byte: u32,
    end_byte: u32,
    /// Replacement text (from the query's string table, not owned).
    /// Empty string means hide entirely (no replacement character).
    replacement: []const u8,
};

/// Result of a highlight operation.
pub const HighlightResult = struct {
    spans: []Span,
    capture_names: [][]const u8,
    conceal_spans: []ConcealSpan,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HighlightResult) void {
        self.allocator.free(self.spans);
        self.allocator.free(self.capture_names);
        self.allocator.free(self.conceal_spans);
    }
};

/// Compiled-in grammar language function type.
const LanguageFn = *const fn () callconv(.c) ?*const c.TSLanguage;

/// Built-in grammar entry with optional embedded highlight, injection, fold, and indent queries.
const BuiltinGrammar = struct {
    name: []const u8,
    func: LanguageFn,
    query: ?[]const u8 = null,
    injection_query: ?[]const u8 = null,
    fold_query: ?[]const u8 = null,
    indent_query: ?[]const u8 = null,
    textobject_query: ?[]const u8 = null,
};

pub const InjectionRange = protocol.InjectionRange;

/// Tree-sitter highlighter. Owns a parser, optional tree, and query.
/// Grammar languages are registered at init time (compiled-in) or
/// loaded dynamically via `loadGrammar`.
pub const Highlighter = struct {
    parser: *c.TSParser,
    tree: ?*c.TSTree = null,
    query: ?*c.TSQuery = null,
    injection_query: ?*c.TSQuery = null,
    fold_query: ?*c.TSQuery = null,
    indent_query: ?*c.TSQuery = null,
    textobject_query: ?*c.TSQuery = null,
    current_language: ?*const c.TSLanguage = null,
    current_language_name: ?[]const u8 = null,
    current_source: ?[]const u8 = null,
    languages: std.StringHashMapUnmanaged(*const c.TSLanguage),
    query_cache: std.StringHashMapUnmanaged(*c.TSQuery),
    predicate_cache: std.StringHashMapUnmanaged(predicates_mod.PredicateTable),
    injection_query_cache: std.StringHashMapUnmanaged(*c.TSQuery),
    fold_query_cache: std.StringHashMapUnmanaged(*c.TSQuery),
    indent_query_cache: std.StringHashMapUnmanaged(*c.TSQuery),
    textobject_query_cache: std.StringHashMapUnmanaged(*c.TSQuery),
    /// Currently active predicate table (set during setLanguage)
    current_predicates: ?*const predicates_mod.PredicateTable = null,
    /// Capture id for @conceal in the active highlight query, if present.
    current_conceal_capture_id: ?u32 = null,
    /// Last highlight result sizes, used to pre-size hot-path result buffers.
    last_highlight_span_count: usize = 0,
    last_highlight_conceal_count: usize = 0,
    /// Cached full highlight spans used to merge single-line incremental updates.
    cached_highlight_spans: []Span = &.{},
    cached_has_active_injections: bool = false,
    has_changed_range: bool = false,
    changed_old_start_byte: u32 = 0,
    changed_old_end_byte: u32 = 0,
    changed_new_start_byte: u32 = 0,
    changed_new_end_byte: u32 = 0,
    changed_byte_delta: i64 = 0,
    cache_mutex: std.atomic.Mutex = .unlocked,
    allocator: std.mem.Allocator,

    /// After `highlightWithInjections`, holds the injection language regions.
    /// Callers can read this to determine which language is at a given byte offset.
    /// Owned by the Highlighter; freed on the next call to `highlightWithInjections`.
    injection_ranges: []InjectionRange = &.{},

    /// Tracks background pre-compilation state.
    prewarm_thread: ?std.Thread = null,

    /// Initialize with compiled-in grammars registered.
    /// Spawns a background thread to pre-compile all embedded queries.
    pub fn init(allocator: std.mem.Allocator) !Highlighter {
        const parser = c.ts_parser_new() orelse return error.ParserCreateFailed;

        var hl = Highlighter{
            .parser = parser,
            .languages = .empty,
            .query_cache = .empty,
            .predicate_cache = .empty,
            .injection_query_cache = .empty,
            .fold_query_cache = .empty,
            .indent_query_cache = .empty,
            .textobject_query_cache = .empty,
            .allocator = allocator,
        };

        // Register all compiled-in grammars (instant).
        inline for (builtin_grammars) |entry| {
            if (entry.func()) |lang| {
                hl.languages.put(allocator, entry.name, lang) catch {};
            }
        }

        return hl;
    }

    /// Start background pre-compilation of all embedded queries.
    /// Must be called after the Highlighter is at its final memory location
    /// (not inside init, which returns by value).
    pub fn startPrewarm(self: *Highlighter) void {
        if (builtin.is_test) return;
        self.prewarm_thread = std.Thread.spawn(.{}, prewarmQueries, .{self}) catch null;
    }

    /// Background thread: pre-compiles all embedded queries into the cache.
    fn prewarmQueries(self: *Highlighter) void {
        inline for (builtin_grammars) |entry| {
            if (entry.query) |query_source| {
                self.prewarmOne(entry.name, query_source, &self.query_cache);
                // Build predicate table for highlight queries
                self.prewarmPredicates(entry.name);
            }
            if (entry.injection_query) |inj_source| {
                self.prewarmOne(entry.name, inj_source, &self.injection_query_cache);
            }
            if (entry.fold_query) |fold_source| {
                self.prewarmOne(entry.name, fold_source, &self.fold_query_cache);
            }
            if (entry.indent_query) |indent_source| {
                self.prewarmOne(entry.name, indent_source, &self.indent_query_cache);
            }
            if (entry.textobject_query) |textobj_source| {
                self.prewarmOne(entry.name, textobj_source, &self.textobject_query_cache);
            }
        }
    }

    fn prewarmOne(
        self: *Highlighter,
        name: []const u8,
        query_source: []const u8,
        cache: *std.StringHashMapUnmanaged(*c.TSQuery),
    ) void {
        // Check if already compiled (e.g. by a setLanguage call on the main thread)
        {
            while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
            defer self.cache_mutex.unlock();
            if (cache.get(name) != null) return;
        }

        const lang = self.languages.get(name) orelse return;
        var err_off: u32 = 0;
        var err_type: c.TSQueryError = c.TSQueryErrorNone;

        // Compile without holding the lock (this is the expensive part)
        const compiled = c.ts_query_new(
            lang,
            query_source.ptr,
            @intCast(query_source.len),
            &err_off,
            &err_type,
        ) orelse return;

        // Insert into cache under lock
        {
            while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
            defer self.cache_mutex.unlock();
            // Double-check: main thread may have compiled it while we worked
            if (cache.get(name) != null) {
                c.ts_query_delete(compiled);
            } else {
                cache.put(self.allocator, name, compiled) catch {
                    c.ts_query_delete(compiled);
                };
            }
        }
    }

    /// Build predicate table for a language's highlight query (background thread).
    fn prewarmPredicates(self: *Highlighter, name: []const u8) void {
        while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.cache_mutex.unlock();
        if (self.predicate_cache.get(name) != null) return;
        const query = self.query_cache.get(name) orelse return;
        const table = predicates_mod.PredicateTable.init(query, self.allocator);
        self.predicate_cache.put(self.allocator, name, table) catch {};
    }

    /// Free all resources.
    pub fn deinit(self: *Highlighter) void {
        // Wait for background pre-compilation to finish
        if (self.prewarm_thread) |t| t.join();

        // Free all cached queries
        var qit = self.query_cache.iterator();
        while (qit.next()) |entry| {
            c.ts_query_delete(entry.value_ptr.*);
        }
        self.query_cache.deinit(self.allocator);

        // Free all cached predicate tables
        var pit = self.predicate_cache.iterator();
        while (pit.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.predicate_cache.deinit(self.allocator);

        // Free all cached injection queries
        var iqit = self.injection_query_cache.iterator();
        while (iqit.next()) |entry| {
            c.ts_query_delete(entry.value_ptr.*);
        }
        self.injection_query_cache.deinit(self.allocator);

        // Free all cached fold queries
        var fqit = self.fold_query_cache.iterator();
        while (fqit.next()) |entry| {
            c.ts_query_delete(entry.value_ptr.*);
        }
        self.fold_query_cache.deinit(self.allocator);

        // Free all cached indent queries
        var idit = self.indent_query_cache.iterator();
        while (idit.next()) |entry| {
            c.ts_query_delete(entry.value_ptr.*);
        }
        self.indent_query_cache.deinit(self.allocator);

        // Free all cached textobject queries
        var toit = self.textobject_query_cache.iterator();
        while (toit.next()) |entry| {
            c.ts_query_delete(entry.value_ptr.*);
        }
        self.textobject_query_cache.deinit(self.allocator);

        if (self.injection_ranges.len > 0) {
            self.allocator.free(self.injection_ranges);
        }
        if (self.cached_highlight_spans.len > 0) {
            self.allocator.free(self.cached_highlight_spans);
        }

        if (self.tree) |t| c.ts_tree_delete(t);
        c.ts_parser_delete(self.parser);
        self.languages.deinit(self.allocator);
    }

    /// Set the active language by name. Returns false if not found.
    /// Restores cached highlight and injection queries for this language.
    pub fn setLanguage(self: *Highlighter, name: []const u8) bool {
        const lang = self.languages.get(name) orelse return false;
        _ = c.ts_parser_set_language(self.parser, lang);
        self.current_language = lang;
        self.current_language_name = name;
        // Invalidate existing tree since language changed
        if (self.tree) |t| {
            c.ts_tree_delete(t);
            self.tree = null;
        }
        self.clearHighlightCache();
        // Restore cached queries (may have been pre-compiled on background thread),
        // or lazily compile from embedded source.
        {
            while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
            defer self.cache_mutex.unlock();

            // Highlight query
            if (self.query_cache.get(name)) |cached| {
                self.query = cached;
            } else {
                self.query = null;
                inline for (builtin_grammars) |entry| {
                    if (std.mem.eql(u8, entry.name, name)) {
                        if (entry.query) |query_source| {
                            var err_off: u32 = 0;
                            var err_type: c.TSQueryError = c.TSQueryErrorNone;
                            if (c.ts_query_new(lang, query_source.ptr, @intCast(query_source.len), &err_off, &err_type)) |compiled| {
                                self.query = compiled;
                                self.query_cache.put(self.allocator, entry.name, compiled) catch {};
                                // Build predicate table alongside the query
                                if (self.predicate_cache.get(entry.name) == null) {
                                    const table = predicates_mod.PredicateTable.init(compiled, self.allocator);
                                    self.predicate_cache.put(self.allocator, entry.name, table) catch {};
                                }
                            }
                        }
                    }
                }
            }
            // Restore predicate table and hot capture metadata for current language
            if (self.predicate_cache.getPtr(name)) |cached_ptr| {
                self.current_predicates = cached_ptr;
            } else {
                self.current_predicates = null;
            }
            self.current_conceal_capture_id = findCaptureId(self.query, "conceal");

            // Injection query
            if (self.injection_query_cache.get(name)) |cached| {
                self.injection_query = cached;
            } else {
                self.injection_query = null;
                inline for (builtin_grammars) |entry| {
                    if (std.mem.eql(u8, entry.name, name)) {
                        if (entry.injection_query) |inj_source| {
                            var err_off: u32 = 0;
                            var err_type: c.TSQueryError = c.TSQueryErrorNone;
                            if (c.ts_query_new(lang, inj_source.ptr, @intCast(inj_source.len), &err_off, &err_type)) |compiled| {
                                self.injection_query = compiled;
                                self.injection_query_cache.put(self.allocator, entry.name, compiled) catch {};
                            }
                        }
                    }
                }
            }

            // Fold query
            if (self.fold_query_cache.get(name)) |cached| {
                self.fold_query = cached;
            } else {
                self.fold_query = null;
                inline for (builtin_grammars) |entry| {
                    if (std.mem.eql(u8, entry.name, name)) {
                        if (entry.fold_query) |fold_source| {
                            var err_off: u32 = 0;
                            var err_type: c.TSQueryError = c.TSQueryErrorNone;
                            if (c.ts_query_new(lang, fold_source.ptr, @intCast(fold_source.len), &err_off, &err_type)) |compiled| {
                                self.fold_query = compiled;
                                self.fold_query_cache.put(self.allocator, entry.name, compiled) catch {};
                            }
                        }
                    }
                }
            }

            // Indent query
            if (self.indent_query_cache.get(name)) |cached| {
                self.indent_query = cached;
            } else {
                self.indent_query = null;
                inline for (builtin_grammars) |entry| {
                    if (std.mem.eql(u8, entry.name, name)) {
                        if (entry.indent_query) |indent_source| {
                            var err_off: u32 = 0;
                            var err_type: c.TSQueryError = c.TSQueryErrorNone;
                            if (c.ts_query_new(lang, indent_source.ptr, @intCast(indent_source.len), &err_off, &err_type)) |compiled| {
                                self.indent_query = compiled;
                                self.indent_query_cache.put(self.allocator, entry.name, compiled) catch {};
                            }
                        }
                    }
                }
            }

            // Textobject query
            if (self.textobject_query_cache.get(name)) |cached| {
                self.textobject_query = cached;
            } else {
                self.textobject_query = null;
                inline for (builtin_grammars) |entry| {
                    if (std.mem.eql(u8, entry.name, name)) {
                        if (entry.textobject_query) |textobj_source| {
                            var err_off: u32 = 0;
                            var err_type: c.TSQueryError = c.TSQueryErrorNone;
                            if (c.ts_query_new(lang, textobj_source.ptr, @intCast(textobj_source.len), &err_off, &err_type)) |compiled| {
                                self.textobject_query = compiled;
                                self.textobject_query_cache.put(self.allocator, entry.name, compiled) catch {};
                            }
                        }
                    }
                }
            }
        }
        return true;
    }

    /// Compile a highlight query (.scm source) for the current language.
    /// Caches the compiled query so subsequent `setLanguage` calls restore it.
    pub fn setHighlightQuery(self: *Highlighter, source: []const u8) !void {
        const lang = self.current_language orelse return error.NoLanguageSet;
        const name = self.current_language_name orelse return error.NoLanguageSet;

        while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.cache_mutex.unlock();

        // If we already have a cached query for this language, skip recompilation
        if (self.query_cache.get(name)) |cached| {
            self.query = cached;
            return;
        }

        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = c.TSQueryErrorNone;

        const new_query = c.ts_query_new(
            lang,
            source.ptr,
            @intCast(source.len),
            &error_offset,
            &error_type,
        ) orelse {
            std.log.warn("Query compile error at offset {d}, type {d}", .{
                error_offset, error_type,
            });
            return error.QueryCompileFailed;
        };

        self.query = new_query;
        self.query_cache.put(self.allocator, name, new_query) catch {};
    }

    /// Compile an injection query (.scm source) for the current language.
    /// Caches the compiled query so subsequent `setLanguage` calls restore it.
    pub fn setInjectionQuery(self: *Highlighter, source: []const u8) !void {
        const lang = self.current_language orelse return error.NoLanguageSet;
        const name = self.current_language_name orelse return error.NoLanguageSet;

        while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.cache_mutex.unlock();

        // If we already have a cached injection query, skip recompilation
        if (self.injection_query_cache.get(name)) |cached| {
            self.injection_query = cached;
            return;
        }

        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = c.TSQueryErrorNone;

        const new_query = c.ts_query_new(
            lang,
            source.ptr,
            @intCast(source.len),
            &error_offset,
            &error_type,
        ) orelse {
            std.log.warn("Injection query compile error at offset {d}, type {d}", .{
                error_offset, error_type,
            });
            return error.QueryCompileFailed;
        };

        self.injection_query = new_query;
        self.injection_query_cache.put(self.allocator, name, new_query) catch {};
    }

    /// Compile a fold query (.scm source) for the current language.
    /// Caches the compiled query so subsequent `setLanguage` calls restore it.
    pub fn setFoldQuery(self: *Highlighter, source: []const u8) !void {
        const lang = self.current_language orelse return error.NoLanguageSet;
        const name = self.current_language_name orelse return error.NoLanguageSet;

        while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.cache_mutex.unlock();

        if (self.fold_query_cache.get(name)) |cached| {
            self.fold_query = cached;
            return;
        }

        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = c.TSQueryErrorNone;

        const new_query = c.ts_query_new(
            lang,
            source.ptr,
            @intCast(source.len),
            &error_offset,
            &error_type,
        ) orelse {
            std.log.warn("Fold query compile error at offset {d}, type {d}", .{
                error_offset, error_type,
            });
            return error.QueryCompileFailed;
        };

        self.fold_query = new_query;
        self.fold_query_cache.put(self.allocator, name, new_query) catch {};
    }

    /// A single fold range: start_line .. end_line (0-indexed).
    pub const FoldRange = protocol.FoldRange;

    /// Run the fold query against the current tree and return fold ranges.
    /// Returns null if no fold query is set or no tree exists.
    /// Caller owns the returned slice and must free it.
    pub fn runFoldQuery(self: *Highlighter, alloc: std.mem.Allocator) !?[]FoldRange {
        const fq = self.fold_query orelse return null;
        const tree = self.tree orelse return null;

        const root = c.ts_tree_root_node(tree);
        const cursor = c.ts_query_cursor_new() orelse return error.CursorCreateFailed;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, fq, root);

        var ranges: std.ArrayListUnmanaged(FoldRange) = .empty;
        errdefer ranges.deinit(alloc);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            const captures = if (match.captures == null) continue else match.captures[0..@intCast(match.capture_count)];
            for (captures) |cap| {
                const node = cap.node;
                const start_line: u32 = @intCast(c.ts_node_start_point(node).row);
                const end_line: u32 = @intCast(c.ts_node_end_point(node).row);
                // Only include folds spanning multiple lines.
                if (end_line > start_line) {
                    try ranges.append(alloc, .{
                        .start_line = start_line,
                        .end_line = end_line,
                    });
                }
            }
        }

        if (ranges.items.len == 0) {
            ranges.deinit(alloc);
            return null;
        }

        return try ranges.toOwnedSlice(alloc);
    }

    /// Compile an indent query (.scm source) for the current language.
    pub fn setIndentQuery(self: *Highlighter, source: []const u8) !void {
        const lang = self.current_language orelse return error.NoLanguageSet;
        const name = self.current_language_name orelse return error.NoLanguageSet;

        while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.cache_mutex.unlock();

        if (self.indent_query_cache.get(name)) |cached| {
            self.indent_query = cached;
            return;
        }

        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = c.TSQueryErrorNone;

        const new_query = c.ts_query_new(
            lang,
            source.ptr,
            @intCast(source.len),
            &error_offset,
            &error_type,
        ) orelse {
            std.log.warn("Indent query compile error at offset {d}, type {d}", .{
                error_offset, error_type,
            });
            return error.QueryCompileFailed;
        };

        self.indent_query = new_query;
        self.indent_query_cache.put(self.allocator, name, new_query) catch {};
    }

    /// Compute the indent level for a given line using the indent query.
    /// Returns the indent delta: positive means indent, negative means outdent.
    /// The BEAM side multiplies this by tab_size to get whitespace columns.
    ///
    /// Algorithm (simplified Helix approach):
    /// 1. Find the deepest node at the start of the given line
    /// 2. Walk up ancestors, checking which ones match @indent or @outdent captures
    /// 3. Net indent = count of @indent ancestors - count of @outdent on this line
    pub fn computeIndent(self: *Highlighter, line: u32) i32 {
        const iq = self.indent_query orelse return 0;
        const tree = self.tree orelse return 0;
        const root = c.ts_tree_root_node(tree);

        // Find capture IDs for @indent and @outdent
        const pattern_count = c.ts_query_capture_count(iq);
        var indent_id: ?u32 = null;
        var outdent_id: ?u32 = null;

        for (0..pattern_count) |i| {
            var name_len: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(iq, @intCast(i), &name_len);
            if (name_ptr == null) continue;
            const cap_name = name_ptr[0..name_len];
            if (std.mem.eql(u8, cap_name, "indent")) indent_id = @intCast(i);
            if (std.mem.eql(u8, cap_name, "outdent")) outdent_id = @intCast(i);
        }

        if (indent_id == null and outdent_id == null) return 0;

        // Run the query, scoped to the area around this line
        const cursor = c.ts_query_cursor_new() orelse return 0;
        defer c.ts_query_cursor_delete(cursor);

        // Set range to a few lines before and after for context
        const context_start = if (line > 0) line - 1 else 0;
        _ = c.ts_query_cursor_set_point_range(
            cursor,
            .{ .row = context_start, .column = 0 },
            .{ .row = line + 1, .column = 0 },
        );
        c.ts_query_cursor_exec(cursor, iq, root);

        var indent_count: i32 = 0;
        var match: c.TSQueryMatch = undefined;

        while (c.ts_query_cursor_next_match(cursor, &match)) {
            const captures = if (match.captures == null) continue else match.captures[0..@intCast(match.capture_count)];
            for (captures) |cap| {
                const node = cap.node;
                const node_start = c.ts_node_start_point(node).row;
                const node_end = c.ts_node_end_point(node).row;

                if (indent_id) |iid| {
                    if (cap.index == iid) {
                        // If the indent node starts before our line and ends
                        // at or after our line, we're inside it: indent.
                        if (node_start < line and node_end >= line) {
                            indent_count += 1;
                        }
                    }
                }
                if (outdent_id) |oid| {
                    if (cap.index == oid) {
                        // If the outdent node starts on our line, dedent.
                        if (node_start == line) {
                            indent_count -= 1;
                        }
                    }
                }
            }
        }

        return indent_count;
    }

    /// Compile and cache a user-provided textobject query for the current language.
    pub fn setTextobjectQuery(self: *Highlighter, source: []const u8) !void {
        const lang = self.current_language orelse return error.NoLanguageSet;
        const name = self.current_language_name orelse return error.NoLanguageSet;

        while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.cache_mutex.unlock();

        if (self.textobject_query_cache.get(name)) |cached| {
            self.textobject_query = cached;
            return;
        }

        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = c.TSQueryErrorNone;

        const new_query = c.ts_query_new(
            lang,
            source.ptr,
            @intCast(source.len),
            &error_offset,
            &error_type,
        ) orelse {
            std.log.warn("Textobject query compile error at offset {d}, type {d}", .{
                error_offset, error_type,
            });
            return error.QueryCompileFailed;
        };

        self.textobject_query = new_query;
        self.textobject_query_cache.put(self.allocator, name, new_query) catch {};
    }

    /// Alias for the shared TextobjectResult type.
    pub const TextobjectResult = protocol.TextobjectResult;

    /// Find the smallest text object matching `capture_name` (e.g., "function.inside",
    /// "class.around") that contains the cursor position (row, col).
    ///
    /// Returns null if no matching capture spans the cursor position.
    pub fn findTextobject(self: *Highlighter, row: u32, col: u32, capture_name: []const u8) ?TextobjectResult {
        const tq = self.textobject_query orelse return null;
        const tree = self.tree orelse return null;
        const root = c.ts_tree_root_node(tree);

        // Find the capture ID matching the requested name.
        const cap_count = c.ts_query_capture_count(tq);
        var target_id: ?u32 = null;

        for (0..cap_count) |i| {
            var name_len: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(tq, @intCast(i), &name_len);
            if (name_ptr == null) continue;
            const cap_name = name_ptr[0..name_len];
            if (std.mem.eql(u8, cap_name, capture_name)) {
                target_id = @intCast(i);
                break;
            }
        }

        const tid = target_id orelse return null;

        const cursor = c.ts_query_cursor_new() orelse return null;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, tq, root);

        // Find the smallest (innermost) capture that contains the cursor.
        var best: ?TextobjectResult = null;
        var best_size: u64 = std.math.maxInt(u64);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            const captures = if (match.captures == null) continue else match.captures[0..@intCast(match.capture_count)];
            for (captures) |cap| {
                if (cap.index != tid) continue;

                const node = cap.node;
                const start = c.ts_node_start_point(node);
                const end = c.ts_node_end_point(node);

                // Check if cursor is within this node
                const cursor_after_start = (row > start.row) or (row == start.row and col >= start.column);
                const cursor_before_end = (row < end.row) or (row == end.row and col <= end.column);

                if (cursor_after_start and cursor_before_end) {
                    const start_byte = c.ts_node_start_byte(node);
                    const end_byte = c.ts_node_end_byte(node);
                    const size: u64 = end_byte - start_byte;

                    if (size < best_size) {
                        best = .{
                            .start_row = start.row,
                            .start_col = start.column,
                            .end_row = end.row,
                            .end_col = end.column,
                        };
                        best_size = size;
                    }
                }
            }
        }

        return best;
    }

    /// Alias for the shared MatchItemResult type.
    pub const MatchItemResult = protocol.MatchItemResult;

    /// Find the tree-sitter item that structurally matches the delimiter, keyword, quote, or tag at the cursor.
    pub fn findMatchingItem(self: *Highlighter, row: u32, col: u32) ?MatchItemResult {
        const tree = self.tree orelse return null;
        const source = self.current_source orelse return null;
        const root = c.ts_tree_root_node(tree);
        const node = nodeAtPoint(root, row, col);
        if (isNullNode(node)) return null;
        if (hasCommentAncestor(node)) return null;

        if (matchStringBoundary(node, source, row, col)) |matched| return matched;
        if (matchHtmlTag(node)) |matched| return resultForNodeStart(matched);

        if (!hasStringAncestorBeforeInterpolation(node)) {
            if (matchBracketToken(node, source)) |matched| return resultForNodeStart(matched);
            if (matchKeywordToken(node, source, self.current_language_name)) |matched| return resultForNodeStart(matched);
        }

        return null;
    }

    /// Alias for the shared TextobjectEntry type (defined in protocol to avoid circular imports).
    pub const TextobjectEntry = protocol.TextobjectEntry;

    /// Well-known textobject type IDs (match order in around_types below).
    pub const TEXTOBJ_FUNCTION: u8 = 0;
    pub const TEXTOBJ_CLASS: u8 = 1;
    pub const TEXTOBJ_PARAMETER: u8 = 2;
    pub const TEXTOBJ_BLOCK: u8 = 3;
    pub const TEXTOBJ_COMMENT: u8 = 4;
    pub const TEXTOBJ_TEST: u8 = 5;
    pub const TEXTOBJ_TYPE_COUNT: u8 = 6;

    const around_types = [_][]const u8{
        "function.around",
        "class.around",
        "parameter.around",
        "block.around",
        "comment.around",
        "test.around",
    };

    /// Collect all `.around` textobject positions from the current tree.
    ///
    /// Returns a flat array of entries sorted by (row, col). Each entry has a
    /// type_id matching the constants above. Only `.around` captures are
    /// collected since navigation (`]f`/`[f`) targets the start of the outer
    /// structure.
    ///
    /// Caller owns the returned slice and must free it with `allocator`.
    pub fn collectTextobjectPositions(self: *Highlighter, allocator: std.mem.Allocator) []TextobjectEntry {
        const tq = self.textobject_query orelse return &.{};
        const tree = self.tree orelse return &.{};
        const root = c.ts_tree_root_node(tree);

        // Map capture index → type_id for .around captures.
        const cap_count = c.ts_query_capture_count(tq);
        var cap_to_type: [64]?u8 = .{null} ** 64;
        var has_any = false;

        for (0..@min(cap_count, 64)) |i| {
            var name_len: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(tq, @intCast(i), &name_len);
            if (name_ptr == null) continue;
            const cap_name = name_ptr[0..name_len];

            for (around_types, 0..) |atype, tidx| {
                if (std.mem.eql(u8, cap_name, atype)) {
                    cap_to_type[i] = @intCast(tidx);
                    has_any = true;
                    break;
                }
            }
        }

        if (!has_any) return &.{};

        const cursor = c.ts_query_cursor_new() orelse return &.{};
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, tq, root);

        var entries: std.ArrayListUnmanaged(TextobjectEntry) = .empty;

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            const captures = if (match.captures == null) continue else match.captures[0..@intCast(match.capture_count)];
            for (captures) |cap| {
                if (cap.index >= 64) continue;
                const type_id = cap_to_type[cap.index] orelse continue;
                const start = c.ts_node_start_point(cap.node);
                entries.append(allocator, .{
                    .type_id = type_id,
                    .row = start.row,
                    .col = start.column,
                }) catch continue;
            }
        }

        // Sort by (row, col) for binary search on the BEAM side.
        const items = entries.items;
        std.mem.sortUnstable(TextobjectEntry, items, {}, struct {
            fn lessThan(_: void, a: TextobjectEntry, b: TextobjectEntry) bool {
                if (a.row != b.row) return a.row < b.row;
                return a.col < b.col;
            }
        }.lessThan);

        return entries.toOwnedSlice(allocator) catch &.{};
    }

    /// Parse source text. Full re-parse (no incremental).
    /// Stores a reference to the source for injection highlighting.
    pub fn parse(self: *Highlighter, source: []const u8) !void {
        if (self.tree) |t| c.ts_tree_delete(t);
        self.has_changed_range = false;

        self.tree = c.ts_parser_parse_string(
            self.parser,
            null,
            source.ptr,
            @intCast(source.len),
        ) orelse return error.ParseFailed;

        self.current_source = source;
    }

    /// Apply edit deltas to the existing tree and incrementally reparse.
    /// Falls back to full reparse if no tree exists.
    pub fn parseIncremental(self: *Highlighter, edits: []const @import("protocol.zig").EditDelta, new_source: []const u8) !void {
        const old_tree = self.tree orelse {
            // No existing tree; fall back to full parse.
            return self.parse(new_source);
        };

        // Apply each edit to the old tree (tells tree-sitter what changed).
        for (edits) |edit| {
            const input_edit = c.TSInputEdit{
                .start_byte = edit.start_byte,
                .old_end_byte = edit.old_end_byte,
                .new_end_byte = edit.new_end_byte,
                .start_point = .{ .row = edit.start_row, .column = edit.start_col },
                .old_end_point = .{ .row = edit.old_end_row, .column = edit.old_end_col },
                .new_end_point = .{ .row = edit.new_end_row, .column = edit.new_end_col },
            };
            c.ts_tree_edit(old_tree, &input_edit);
        }

        // Incremental parse: pass old_tree so tree-sitter reuses unchanged subtrees.
        const new_tree = c.ts_parser_parse_string(
            self.parser,
            old_tree,
            new_source.ptr,
            @intCast(new_source.len),
        ) orelse {
            // Incremental parse failed; fall back to full parse.
            c.ts_tree_delete(old_tree);
            self.tree = null;
            return self.parse(new_source);
        };

        c.ts_tree_delete(old_tree);
        self.tree = new_tree;
        self.current_source = new_source;
        self.setChangedRangeForEdits(edits, new_source);
    }

    fn clearHighlightCache(self: *Highlighter) void {
        if (self.cached_highlight_spans.len > 0) {
            self.allocator.free(self.cached_highlight_spans);
            self.cached_highlight_spans = &.{};
        }
        self.has_changed_range = false;
        self.cached_has_active_injections = false;
    }

    fn setChangedRangeForEdits(self: *Highlighter, edits: []const @import("protocol.zig").EditDelta, source: []const u8) void {
        if (edits.len != 1 or edits[0].start_row != edits[0].new_end_row) {
            self.has_changed_range = false;
            return;
        }

        const edit = edits[0];
        var line_start: usize = @min(edit.start_byte, source.len);
        while (line_start > 0 and source[line_start - 1] != '\n') : (line_start -= 1) {}
        var line_end: usize = @min(edit.new_end_byte, source.len);
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

        const delta = @as(i64, edit.new_end_byte) - @as(i64, edit.old_end_byte);
        const old_line_end = @as(i64, @intCast(line_end)) - delta;
        if (old_line_end < @as(i64, @intCast(line_start))) {
            self.has_changed_range = false;
            return;
        }

        self.changed_old_start_byte = @intCast(line_start);
        self.changed_old_end_byte = @intCast(old_line_end);
        self.changed_new_start_byte = @intCast(line_start);
        self.changed_new_end_byte = @intCast(line_end);
        self.changed_byte_delta = delta;
        self.has_changed_range = true;
    }

    fn refreshHighlightCache(self: *Highlighter, spans: []const Span) !void {
        if (self.cached_highlight_spans.len > 0) self.allocator.free(self.cached_highlight_spans);
        self.cached_highlight_spans = try self.allocator.dupe(Span, spans);
    }

    /// Run highlight query on the current tree, returning spans and conceal spans.
    pub fn highlight(self: *Highlighter) !HighlightResult {
        const tree = self.tree orelse return error.NoTree;
        const query = self.query orelse return error.NoQuery;
        const alloc = self.allocator;

        const root = c.ts_tree_root_node(tree);
        const cursor = c.ts_query_cursor_new() orelse return error.CursorCreateFailed;
        defer c.ts_query_cursor_delete(cursor);

        c.ts_query_cursor_exec(cursor, query, root);

        // Collect spans and conceal spans
        var spans: std.ArrayListUnmanaged(Span) = .empty;
        errdefer spans.deinit(alloc);
        if (self.last_highlight_span_count > 0) try spans.ensureTotalCapacity(alloc, self.last_highlight_span_count);
        var conceals: std.ArrayListUnmanaged(ConcealSpan) = .empty;
        errdefer conceals.deinit(alloc);
        if (self.last_highlight_conceal_count > 0) try conceals.ensureTotalCapacity(alloc, self.last_highlight_conceal_count);

        const source = self.current_source orelse &.{};

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            // Evaluate predicates (#any-of?, #match?, #eq?, etc.)
            if (self.current_predicates) |preds| {
                if (!preds.evaluate(match, source)) continue;
            }

            // Check for #set! conceal directive on this pattern.
            const conceal_replacement: ?[]const u8 = if (self.current_predicates) |preds|
                if (preds.has_conceal_replacements) preds.getConcealReplacement(@intCast(match.pattern_index)) else null
            else
                null;

            const captures = if (match.captures == null) continue else match.captures[0..match.capture_count];
            for (captures) |cap| {
                const node = cap.node;
                const start = c.ts_node_start_byte(node);
                const end = c.ts_node_end_byte(node);

                const is_conceal_capture = self.current_conceal_capture_id != null and cap.index == self.current_conceal_capture_id.?;

                if (is_conceal_capture and conceal_replacement != null) {
                    // Emit a conceal span instead of a regular highlight span.
                    try conceals.append(alloc, .{
                        .start_byte = start,
                        .end_byte = end,
                        .replacement = conceal_replacement.?,
                    });
                } else {
                    try spans.append(alloc, .{
                        .start_byte = start,
                        .end_byte = end,
                        .capture_id = @intCast(cap.index),
                        .pattern_index = @intCast(match.pattern_index),
                    });
                }
            }
        }

        // Sort by (start_byte ASC, layer DESC, pattern_index DESC, end_byte ASC).
        if (!spansAreSorted(spans.items)) std.mem.sortUnstable(Span, spans.items, {}, spanLessThan);
        self.last_highlight_span_count = spans.items.len;
        self.last_highlight_conceal_count = conceals.items.len;
        try self.refreshHighlightCache(spans.items);

        // Collect capture names
        const pattern_count = c.ts_query_capture_count(query);
        const names = try alloc.alloc([]const u8, pattern_count);
        for (0..pattern_count) |i| {
            var length: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(query, @intCast(i), &length);
            names[i] = name_ptr[0..length];
        }

        return .{
            .spans = try spans.toOwnedSlice(alloc),
            .capture_names = names,
            .conceal_spans = try conceals.toOwnedSlice(alloc),
            .allocator = alloc,
        };
    }

    /// Run highlight query on the current tree with injection support.
    /// If the current language has an injection query, finds embedded language
    /// regions, highlights them with the appropriate grammar, and merges all
    /// spans into a single sorted result with correct capture name remapping.
    /// Falls back to plain `highlight()` when no injection query exists.
    pub fn highlightWithInjections(self: *Highlighter) !HighlightResult {
        const inj_query = self.injection_query orelse return self.highlight();
        const tree = self.tree orelse return error.NoTree;
        const query = self.query orelse return error.NoQuery;
        const source = self.current_source orelse return error.NoTree;
        const alloc = self.allocator;

        const root = c.ts_tree_root_node(tree);

        if (self.has_changed_range and self.cached_highlight_spans.len > 0 and !self.cached_has_active_injections and !try self.hasActiveInjectionRegions(inj_query, root, source)) {
            return self.highlightChangedRange(query, root, source);
        }

        // ── Phase 1: Outer highlight ──────────────────────────────────────
        const cursor = c.ts_query_cursor_new() orelse return error.CursorCreateFailed;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, query, root);

        var spans: std.ArrayListUnmanaged(Span) = .empty;
        errdefer spans.deinit(alloc);
        if (self.last_highlight_span_count > 0) try spans.ensureTotalCapacity(alloc, self.last_highlight_span_count);
        var conceals: std.ArrayListUnmanaged(ConcealSpan) = .empty;
        errdefer conceals.deinit(alloc);
        if (self.last_highlight_conceal_count > 0) try conceals.ensureTotalCapacity(alloc, self.last_highlight_conceal_count);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            // Evaluate predicates (#any-of?, #match?, #eq?, etc.)
            if (self.current_predicates) |preds| {
                if (!preds.evaluate(match, source)) continue;
            }

            // Check for #set! conceal directive on this pattern.
            const conceal_replacement: ?[]const u8 = if (self.current_predicates) |preds|
                if (preds.has_conceal_replacements) preds.getConcealReplacement(@intCast(match.pattern_index)) else null
            else
                null;

            const captures = if (match.captures == null) continue else match.captures[0..match.capture_count];
            for (captures) |cap| {
                const start = c.ts_node_start_byte(cap.node);
                const end = c.ts_node_end_byte(cap.node);

                const is_conceal = self.current_conceal_capture_id != null and cap.index == self.current_conceal_capture_id.?;

                if (is_conceal and conceal_replacement != null) {
                    try conceals.append(alloc, .{
                        .start_byte = start,
                        .end_byte = end,
                        .replacement = conceal_replacement.?,
                    });
                } else {
                    try spans.append(alloc, .{
                        .start_byte = start,
                        .end_byte = end,
                        .capture_id = @intCast(cap.index),
                        .pattern_index = @intCast(match.pattern_index),
                        .layer = 0,
                    });
                }
            }
        }

        // Build unified capture name list, starting with outer query names
        var name_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer name_list.deinit(alloc);

        const outer_capture_count = c.ts_query_capture_count(query);
        try name_list.ensureTotalCapacity(alloc, outer_capture_count + 16);
        for (0..outer_capture_count) |i| {
            var length: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(query, @intCast(i), &length);
            try name_list.append(alloc, name_ptr[0..length]);
        }

        // ── Phase 2: Injection query ─────────────────────────────────────
        const inj_cursor = c.ts_query_cursor_new() orelse return error.CursorCreateFailed;
        defer c.ts_query_cursor_delete(inj_cursor);
        c.ts_query_cursor_exec(inj_cursor, inj_query, root);

        // Find capture indices for @injection.content and @injection.language
        const inj_capture_count = c.ts_query_capture_count(inj_query);
        var content_capture_id: ?u32 = null;
        var language_capture_id: ?u32 = null;
        for (0..inj_capture_count) |i| {
            var length: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(inj_query, @intCast(i), &length);
            const name = name_ptr[0..length];
            if (std.mem.eql(u8, name, "injection.content")) {
                content_capture_id = @intCast(i);
            } else if (std.mem.eql(u8, name, "injection.language")) {
                language_capture_id = @intCast(i);
            }
        }

        if (content_capture_id == null) {
            // Injection query has no @injection.content — nothing to inject.
            // Return plain highlight result.
            if (!spansAreSorted(spans.items)) std.mem.sortUnstable(Span, spans.items, {}, spanLessThan);
            self.last_highlight_span_count = spans.items.len;
            self.last_highlight_conceal_count = conceals.items.len;
            try self.refreshHighlightCache(spans.items);
            const names = try alloc.alloc([]const u8, name_list.items.len);
            @memcpy(names, name_list.items);
            return .{
                .spans = try spans.toOwnedSlice(alloc),
                .capture_names = names,
                .conceal_spans = try conceals.toOwnedSlice(alloc),
                .allocator = alloc,
            };
        }

        // Collect injection regions: (content_range, language_name)
        const InjectionRegion = struct {
            start_byte: u32,
            end_byte: u32,
            start_point: c.TSPoint,
            end_point: c.TSPoint,
            language: []const u8,
        };
        var regions: std.ArrayListUnmanaged(InjectionRegion) = .empty;
        defer regions.deinit(alloc);

        var inj_match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(inj_cursor, &inj_match)) {
            var content_node: ?c.TSNode = null;
            var lang_from_capture: ?[]const u8 = null;

            const caps = if (inj_match.captures == null) continue else inj_match.captures[0..inj_match.capture_count];
            for (caps) |cap| {
                if (cap.index == content_capture_id.?) {
                    content_node = cap.node;
                } else if (language_capture_id != null and cap.index == language_capture_id.?) {
                    // Language name from captured node text (e.g. fenced code info string)
                    const start = c.ts_node_start_byte(cap.node);
                    const end = c.ts_node_end_byte(cap.node);
                    if (end > start and end <= source.len) {
                        lang_from_capture = source[start..end];
                    }
                }
            }

            const cnode = content_node orelse continue;

            // Determine language: captured text takes priority, then #set! predicate
            const lang_name = lang_from_capture orelse
                getInjectionLanguagePredicate(inj_query, inj_match.pattern_index) orelse
                continue;

            // Skip if we don't have this grammar
            if (self.languages.get(lang_name) == null) continue;

            try regions.append(alloc, .{
                .start_byte = c.ts_node_start_byte(cnode),
                .end_byte = c.ts_node_end_byte(cnode),
                .start_point = c.ts_node_start_point(cnode),
                .end_point = c.ts_node_end_point(cnode),
                .language = lang_name,
            });
        }

        self.cached_has_active_injections = regions.items.len > 0;

        // ── Expose injection regions for language-at-position queries ──
        // Free previous injection ranges, then save current ones.
        if (self.injection_ranges.len > 0) {
            alloc.free(self.injection_ranges);
        }
        if (regions.items.len > 0) {
            const inj_ranges = try alloc.alloc(InjectionRange, regions.items.len);
            for (regions.items, 0..) |reg, i| {
                inj_ranges[i] = .{
                    .start_byte = reg.start_byte,
                    .end_byte = reg.end_byte,
                    .language = reg.language,
                };
            }
            self.injection_ranges = inj_ranges;
        } else {
            self.injection_ranges = &.{};
        }

        // ── Phase 3: Highlight injected regions ──────────────────────────
        // Group regions by language for combined parsing
        var lang_regions = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(InjectionRegion)).empty;
        defer {
            var it = lang_regions.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(alloc);
            }
            lang_regions.deinit(alloc);
        }

        for (regions.items) |region| {
            const gop = try lang_regions.getOrPut(alloc, region.language);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(alloc, region);
        }

        // Process each injected language
        var lang_it = lang_regions.iterator();
        while (lang_it.next()) |entry| {
            const lang_name = entry.key_ptr.*;
            const lang_regs = entry.value_ptr.items;

            const lang = self.languages.get(lang_name) orelse continue;

            // Look up the highlight query for this injection language
            const inj_hl_query = blk: {
                while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
                defer self.cache_mutex.unlock();
                if (self.query_cache.get(lang_name)) |cached| break :blk cached;

                // Try compiling from embedded source
                inline for (builtin_grammars) |bg| {
                    if (std.mem.eql(u8, bg.name, lang_name)) {
                        if (bg.query) |qs| {
                            var err_off: u32 = 0;
                            var err_type: c.TSQueryError = c.TSQueryErrorNone;
                            if (c.ts_query_new(lang, qs.ptr, @intCast(qs.len), &err_off, &err_type)) |compiled| {
                                self.query_cache.put(alloc, bg.name, compiled) catch {};
                                // Build predicate table alongside query
                                if (self.predicate_cache.get(bg.name) == null) {
                                    const pt = predicates_mod.PredicateTable.init(compiled, alloc);
                                    self.predicate_cache.put(alloc, bg.name, pt) catch {};
                                }
                                break :blk compiled;
                            }
                        }
                    }
                }
                break :blk null;
            };
            const hl_query = inj_hl_query orelse continue;

            // Create a temporary parser for this injection language
            const inj_parser = c.ts_parser_new() orelse continue;
            defer c.ts_parser_delete(inj_parser);
            _ = c.ts_parser_set_language(inj_parser, lang);

            // Build TSRange array for included ranges
            var ts_ranges = try alloc.alloc(c.TSRange, lang_regs.len);
            defer alloc.free(ts_ranges);
            for (lang_regs, 0..) |reg, i| {
                ts_ranges[i] = .{
                    .start_byte = reg.start_byte,
                    .end_byte = reg.end_byte,
                    .start_point = reg.start_point,
                    .end_point = reg.end_point,
                };
            }

            _ = c.ts_parser_set_included_ranges(inj_parser, ts_ranges.ptr, @intCast(ts_ranges.len));

            // Parse the full source with included ranges limiting what gets parsed
            const inj_tree = c.ts_parser_parse_string(
                inj_parser,
                null,
                source.ptr,
                @intCast(source.len),
            ) orelse continue;
            defer c.ts_tree_delete(inj_tree);

            // Run highlight query on the injection tree
            const hl_cursor = c.ts_query_cursor_new() orelse continue;
            defer c.ts_query_cursor_delete(hl_cursor);

            const inj_root = c.ts_tree_root_node(inj_tree);
            c.ts_query_cursor_exec(hl_cursor, hl_query, inj_root);

            // Build capture ID remap: injection capture names → unified name list
            const inj_cap_count = c.ts_query_capture_count(hl_query);
            var id_remap = try alloc.alloc(u16, inj_cap_count);
            defer alloc.free(id_remap);

            for (0..inj_cap_count) |i| {
                var length: u32 = 0;
                const name_ptr = c.ts_query_capture_name_for_id(hl_query, @intCast(i), &length);
                const cap_name = name_ptr[0..length];

                // Find existing name or add new one
                var found: ?u16 = null;
                for (name_list.items, 0..) |existing, idx| {
                    if (std.mem.eql(u8, existing, cap_name)) {
                        found = @intCast(idx);
                        break;
                    }
                }
                if (found) |idx| {
                    id_remap[i] = idx;
                } else {
                    id_remap[i] = @intCast(name_list.items.len);
                    try name_list.append(alloc, cap_name);
                }
            }

            // Lookup predicate table for this injection language
            const inj_preds: ?*const predicates_mod.PredicateTable = blk: {
                while (!self.cache_mutex.tryLock()) std.atomic.spinLoopHint();
                defer self.cache_mutex.unlock();
                break :blk self.predicate_cache.getPtr(lang_name);
            };

            // Collect injection spans with remapped capture IDs
            var hl_match: c.TSQueryMatch = undefined;
            while (c.ts_query_cursor_next_match(hl_cursor, &hl_match)) {
                // Evaluate predicates for injection language
                if (inj_preds) |preds| {
                    if (!preds.evaluate(hl_match, source)) continue;
                }
                const caps = if (hl_match.captures == null) continue else hl_match.captures[0..hl_match.capture_count];
                for (caps) |cap| {
                    const start = c.ts_node_start_byte(cap.node);
                    const end = c.ts_node_end_byte(cap.node);
                    // Only include spans within the injection ranges
                    var in_range = false;
                    for (lang_regs) |reg| {
                        if (start >= reg.start_byte and end <= reg.end_byte) {
                            in_range = true;
                            break;
                        }
                    }
                    if (!in_range) continue;

                    try spans.append(alloc, .{
                        .start_byte = start,
                        .end_byte = end,
                        .capture_id = id_remap[cap.index],
                        .pattern_index = @intCast(hl_match.pattern_index),
                        .layer = 1,
                    });
                }
            }
        }

        // ── Phase 4: Sort and return ─────────────────────────────────────
        // All spans (outer layer=0 + injection layer=1) are sent to the BEAM
        // with full metadata. The BEAM-side innermost-wins sweep resolves
        // overlaps using (layer DESC, width ASC, pattern_index DESC).
        if (!spansAreSorted(spans.items)) std.mem.sortUnstable(Span, spans.items, {}, spanLessThan);
        self.last_highlight_span_count = spans.items.len;
        self.last_highlight_conceal_count = conceals.items.len;
        try self.refreshHighlightCache(spans.items);

        const names = try alloc.alloc([]const u8, name_list.items.len);
        @memcpy(names, name_list.items);

        return .{
            .spans = try spans.toOwnedSlice(alloc),
            .capture_names = names,
            .conceal_spans = try conceals.toOwnedSlice(alloc),
            .allocator = alloc,
        };
    }

    fn hasActiveInjectionRegions(self: *Highlighter, inj_query: *c.TSQuery, root: c.TSNode, source: []const u8) !bool {
        const inj_cursor = c.ts_query_cursor_new() orelse return error.CursorCreateFailed;
        defer c.ts_query_cursor_delete(inj_cursor);
        if (self.has_changed_range) _ = c.ts_query_cursor_set_byte_range(inj_cursor, self.changed_new_start_byte, self.changed_new_end_byte);
        c.ts_query_cursor_exec(inj_cursor, inj_query, root);

        const inj_capture_count = c.ts_query_capture_count(inj_query);
        var content_capture_id: ?u32 = null;
        var language_capture_id: ?u32 = null;
        for (0..inj_capture_count) |i| {
            var length: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(inj_query, @intCast(i), &length);
            const name = name_ptr[0..length];
            if (std.mem.eql(u8, name, "injection.content")) {
                content_capture_id = @intCast(i);
            } else if (std.mem.eql(u8, name, "injection.language")) {
                language_capture_id = @intCast(i);
            }
        }
        if (content_capture_id == null) return false;

        var inj_match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(inj_cursor, &inj_match)) {
            var has_content = false;
            var lang_from_capture: ?[]const u8 = null;
            const caps = if (inj_match.captures == null) continue else inj_match.captures[0..inj_match.capture_count];
            for (caps) |cap| {
                if (cap.index == content_capture_id.?) {
                    has_content = true;
                } else if (language_capture_id != null and cap.index == language_capture_id.?) {
                    const start = c.ts_node_start_byte(cap.node);
                    const end = c.ts_node_end_byte(cap.node);
                    if (end > start and end <= source.len) lang_from_capture = source[start..end];
                }
            }
            if (!has_content) continue;
            const lang_name = lang_from_capture orelse getInjectionLanguagePredicate(inj_query, inj_match.pattern_index) orelse continue;
            if (self.languages.get(lang_name) != null) return true;
        }
        return false;
    }

    fn highlightChangedRange(self: *Highlighter, query: *c.TSQuery, root: c.TSNode, source: []const u8) !HighlightResult {
        const alloc = self.allocator;
        const old_start_byte = self.changed_old_start_byte;
        const old_end_byte = self.changed_old_end_byte;
        const start_byte = self.changed_new_start_byte;
        const end_byte = self.changed_new_end_byte;

        const cursor = c.ts_query_cursor_new() orelse return error.CursorCreateFailed;
        defer c.ts_query_cursor_delete(cursor);
        _ = c.ts_query_cursor_set_byte_range(cursor, start_byte, end_byte);
        c.ts_query_cursor_exec(cursor, query, root);

        var changed_spans: std.ArrayListUnmanaged(Span) = .empty;
        defer changed_spans.deinit(alloc);
        if (self.last_highlight_span_count > 0) try changed_spans.ensureTotalCapacity(alloc, @min(self.last_highlight_span_count, 256));

        var conceals: std.ArrayListUnmanaged(ConcealSpan) = .empty;
        errdefer conceals.deinit(alloc);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            if (self.current_predicates) |preds| {
                if (!preds.evaluate(match, source)) continue;
            }

            const captures = if (match.captures == null) continue else match.captures[0..match.capture_count];
            for (captures) |cap| {
                const node = cap.node;
                const span_start = c.ts_node_start_byte(node);
                const span_end = c.ts_node_end_byte(node);
                if (span_end < start_byte or span_start > end_byte) continue;
                try changed_spans.append(alloc, .{
                    .start_byte = span_start,
                    .end_byte = span_end,
                    .capture_id = @intCast(cap.index),
                    .pattern_index = @intCast(match.pattern_index),
                    .layer = 0,
                });
            }
        }

        const cached = self.cached_highlight_spans;
        var remove_start = lowerBoundSpanStart(cached, old_start_byte);
        while (remove_start > 0 and cached[remove_start - 1].end_byte > old_start_byte) : (remove_start -= 1) {}
        var remove_end = remove_start;
        while (remove_end < cached.len and cached[remove_end].start_byte < old_end_byte) : (remove_end += 1) {}

        var merged: std.ArrayListUnmanaged(Span) = .empty;
        errdefer merged.deinit(alloc);
        const merged_len = cached.len - (remove_end - remove_start) + changed_spans.items.len;
        try merged.ensureTotalCapacity(alloc, merged_len);
        try merged.appendSlice(alloc, cached[0..remove_start]);
        try merged.appendSlice(alloc, changed_spans.items);
        for (cached[remove_end..]) |span| {
            merged.appendAssumeCapacity(shiftSpan(span, self.changed_byte_delta));
        }
        if (!spansAreSorted(merged.items)) std.mem.sortUnstable(Span, merged.items, {}, spanLessThan);
        self.last_highlight_span_count = merged.items.len;
        self.last_highlight_conceal_count = conceals.items.len;
        try self.refreshHighlightCache(merged.items);

        const capture_count = c.ts_query_capture_count(query);
        const names = try alloc.alloc([]const u8, capture_count);
        for (0..capture_count) |i| {
            var length: u32 = 0;
            const name_ptr = c.ts_query_capture_name_for_id(query, @intCast(i), &length);
            names[i] = name_ptr[0..length];
        }

        return .{
            .spans = try merged.toOwnedSlice(alloc),
            .capture_names = names,
            .conceal_spans = try conceals.toOwnedSlice(alloc),
            .allocator = alloc,
        };
    }

    /// Returns the language name at a given byte offset.
    /// Checks injection regions first; falls back to the current (outer) language.
    /// Returns null only if no language is set at all.
    pub fn languageAt(self: *const Highlighter, byte_offset: u32) ?[]const u8 {
        // Check injection regions (inner languages win over outer)
        for (self.injection_ranges) |range| {
            if (byte_offset >= range.start_byte and byte_offset < range.end_byte) {
                return range.language;
            }
        }
        // Fall back to the outer language
        return self.current_language_name;
    }

    /// Dynamically load a grammar from a shared library.
    /// The library must export `tree_sitter_{name}() -> *TSLanguage`.
    pub fn loadGrammar(self: *Highlighter, name: []const u8, lib_path: []const u8) !void {
        var buf: [256]u8 = undefined;
        const symbol_name = std.fmt.bufPrint(&buf, "tree_sitter_{s}", .{name}) catch
            return error.NameTooLong;

        // Null-terminate for dlopen/dlsym
        var path_buf: [4096]u8 = undefined;
        if (lib_path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..lib_path.len], lib_path);
        path_buf[lib_path.len] = 0;

        var lib = std.DynLib.open(path_buf[0..lib_path.len :0]) catch
            return error.LibraryLoadFailed;

        // Null-terminate symbol name
        var sym_buf: [256]u8 = undefined;
        @memcpy(sym_buf[0..symbol_name.len], symbol_name);
        sym_buf[symbol_name.len] = 0;

        const func = lib.lookup(LanguageFn, sym_buf[0..symbol_name.len :0]) orelse
            return error.SymbolNotFound;

        const lang = func() orelse return error.LanguageInitFailed;

        // Note: we intentionally don't close the DynLib — the language
        // struct points into the library's memory and must stay loaded.

        try self.languages.put(self.allocator, name, lang);
    }
};

// ── Match-item helpers ────────────────────────────────────────────────────

fn nodeAtPoint(root: c.TSNode, row: u32, col: u32) c.TSNode {
    const start = c.TSPoint{ .row = row, .column = col };
    const end = c.TSPoint{ .row = row, .column = col + 1 };
    return c.ts_node_descendant_for_point_range(root, start, end);
}

fn isNullNode(node: c.TSNode) bool {
    return c.ts_node_is_null(node);
}

fn nodeType(node: c.TSNode) []const u8 {
    return std.mem.span(c.ts_node_type(node));
}

fn nodeText(source: []const u8, node: c.TSNode) []const u8 {
    const start: usize = @intCast(c.ts_node_start_byte(node));
    const end: usize = @intCast(c.ts_node_end_byte(node));
    if (start > end or end > source.len) return "";
    return source[start..end];
}

fn resultForNodeStart(node: c.TSNode) protocol.MatchItemResult {
    const point = c.ts_node_start_point(node);
    return .{ .row = point.row, .col = point.column };
}

fn resultForByte(source: []const u8, byte_offset: usize) protocol.MatchItemResult {
    const point = pointForByte(source, byte_offset);
    return .{ .row = point.row, .col = point.column };
}

fn pointForByte(source: []const u8, byte_offset: usize) c.TSPoint {
    var row: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    const target = @min(byte_offset, source.len);
    while (i < target) : (i += 1) {
        if (source[i] == '\n') {
            row += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .row = row, .column = col };
}

fn byteForPoint(source: []const u8, row: u32, col: u32) usize {
    var current_row: u32 = 0;
    var current_col: u32 = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (current_row == row and current_col == col) return i;
        if (source[i] == '\n') {
            current_row += 1;
            current_col = 0;
        } else {
            current_col += 1;
        }
    }
    return source.len;
}

fn hasCommentAncestor(node: c.TSNode) bool {
    var current = node;
    while (!isNullNode(current)) {
        if (isCommentType(nodeType(current))) return true;
        current = c.ts_node_parent(current);
    }
    return false;
}

fn isCommentType(typ: []const u8) bool {
    return std.mem.indexOf(u8, typ, "comment") != null;
}

fn hasStringAncestorBeforeInterpolation(node: c.TSNode) bool {
    var current = node;
    while (!isNullNode(current)) {
        const typ = nodeType(current);
        if (isInterpolationType(typ)) return false;
        if (isStringLikeType(typ)) return true;
        current = c.ts_node_parent(current);
    }
    return false;
}

fn isInterpolationType(typ: []const u8) bool {
    return std.mem.indexOf(u8, typ, "interpolation") != null or std.mem.eql(u8, typ, "interpolated_expression");
}

fn isStringLikeType(typ: []const u8) bool {
    if (std.mem.indexOf(u8, typ, "string") != null and std.mem.indexOf(u8, typ, "content") == null) return true;
    if (std.mem.indexOf(u8, typ, "heredoc") != null) return true;
    return std.mem.eql(u8, typ, "char") or std.mem.eql(u8, typ, "quoted_content");
}

fn matchStringBoundary(node: c.TSNode, source: []const u8, row: u32, col: u32) ?protocol.MatchItemResult {
    const string_node = nearestStringLikeNode(node) orelse return null;
    const start: usize = @intCast(c.ts_node_start_byte(string_node));
    const end: usize = @intCast(c.ts_node_end_byte(string_node));
    if (end <= start or end > source.len) return null;

    const text = source[start..end];
    const delim_len = stringDelimiterLen(text);
    if (delim_len == 0 or text.len < delim_len * 2) return null;

    const cursor_byte = byteForPoint(source, row, col);
    const close_start = end - delim_len;

    if (cursor_byte >= start and cursor_byte < start + delim_len) {
        return resultForByte(source, close_start);
    }
    if (cursor_byte >= close_start and cursor_byte < end) {
        return resultForByte(source, start);
    }
    return null;
}

fn nearestStringLikeNode(node: c.TSNode) ?c.TSNode {
    var current = node;
    while (!isNullNode(current)) {
        const typ = nodeType(current);
        if (isInterpolationType(typ)) return null;
        if (isStringContentType(typ)) {
            current = c.ts_node_parent(current);
            continue;
        }
        if (isStringLikeType(typ)) return current;
        current = c.ts_node_parent(current);
    }
    return null;
}

fn isStringContentType(typ: []const u8) bool {
    return std.mem.indexOf(u8, typ, "fragment") != null or
        std.mem.indexOf(u8, typ, "content") != null or
        std.mem.indexOf(u8, typ, "escape") != null;
}

fn stringDelimiterLen(text: []const u8) usize {
    if (std.mem.startsWith(u8, text, "\"\"\"") and std.mem.endsWith(u8, text, "\"\"\"")) return 3;
    if (std.mem.startsWith(u8, text, "'''") and std.mem.endsWith(u8, text, "'''")) return 3;
    if (std.mem.startsWith(u8, text, "\"") and std.mem.endsWith(u8, text, "\"")) return 1;
    if (std.mem.startsWith(u8, text, "'") and std.mem.endsWith(u8, text, "'")) return 1;
    if (std.mem.startsWith(u8, text, "`") and std.mem.endsWith(u8, text, "`")) return 1;
    return 0;
}

fn matchBracketToken(node: c.TSNode, source: []const u8) ?c.TSNode {
    const token = tokenText(source, node);
    const pair = bracketPair(token) orelse return null;
    return matchSiblingToken(node, pair.open, pair.close, pair.forward);
}

const BracketPair = struct { open: []const u8, close: []const u8, forward: bool };

fn bracketPair(token: []const u8) ?BracketPair {
    if (std.mem.eql(u8, token, "(")) return .{ .open = "(", .close = ")", .forward = true };
    if (std.mem.eql(u8, token, ")")) return .{ .open = "(", .close = ")", .forward = false };
    if (std.mem.eql(u8, token, "[")) return .{ .open = "[", .close = "]", .forward = true };
    if (std.mem.eql(u8, token, "]")) return .{ .open = "[", .close = "]", .forward = false };
    if (std.mem.eql(u8, token, "{")) return .{ .open = "{", .close = "}", .forward = true };
    if (std.mem.eql(u8, token, "}")) return .{ .open = "{", .close = "}", .forward = false };
    return null;
}

fn matchSiblingToken(node: c.TSNode, open: []const u8, close: []const u8, forward: bool) ?c.TSNode {
    const parent = c.ts_node_parent(node);
    if (isNullNode(parent)) return null;
    const count = c.ts_node_child_count(parent);
    const idx = childIndex(parent, node) orelse return null;
    var depth: i32 = 1;

    if (forward) {
        var i = idx + 1;
        while (i < count) : (i += 1) {
            const child = c.ts_node_child(parent, i);
            const typ = nodeType(child);
            if (std.mem.eql(u8, typ, open)) depth += 1;
            if (std.mem.eql(u8, typ, close)) {
                depth -= 1;
                if (depth == 0) return child;
            }
        }
    } else {
        var i = idx;
        while (i > 0) {
            i -= 1;
            const child = c.ts_node_child(parent, i);
            const typ = nodeType(child);
            if (std.mem.eql(u8, typ, close)) depth += 1;
            if (std.mem.eql(u8, typ, open)) {
                depth -= 1;
                if (depth == 0) return child;
            }
        }
    }
    return null;
}

fn childIndex(parent: c.TSNode, node: c.TSNode) ?u32 {
    const count = c.ts_node_child_count(parent);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (c.ts_node_eq(c.ts_node_child(parent, i), node)) return i;
    }
    return null;
}

fn tokenText(source: []const u8, node: c.TSNode) []const u8 {
    const typ = nodeType(node);
    if (!c.ts_node_is_named(node) and typ.len <= 8) return typ;
    const text = nodeText(source, node);
    if (text.len <= 32) return text;
    return "";
}

fn matchKeywordToken(node: c.TSNode, source: []const u8, language_name: ?[]const u8) ?c.TSNode {
    const allow_named_keywords = languageAllowsNamedMatchKeywords(language_name);
    if (c.ts_node_is_named(node) and !allow_named_keywords) return null;

    const token = tokenText(source, node);
    if (!isKnownMatchKeyword(token)) return null;

    if (language_name) |lang| {
        if (std.mem.eql(u8, lang, "elixir") and std.mem.eql(u8, token, "end")) {
            if (matchElixirEndToHead(node, source)) |head| return head;
        }
    }

    if (matchKeywordInAncestors(node, source, token, allow_named_keywords)) |matched| return matched;
    return null;
}

fn languageAllowsNamedMatchKeywords(language_name: ?[]const u8) bool {
    const lang = language_name orelse return false;
    return std.mem.eql(u8, lang, "elixir");
}

fn isKnownMatchKeyword(token: []const u8) bool {
    return std.mem.eql(u8, token, "do") or std.mem.eql(u8, token, "end") or
        std.mem.eql(u8, token, "fn") or std.mem.eql(u8, token, "def") or
        std.mem.eql(u8, token, "defp") or std.mem.eql(u8, token, "defmodule") or
        std.mem.eql(u8, token, "if") or std.mem.eql(u8, token, "unless") or
        std.mem.eql(u8, token, "begin") or std.mem.eql(u8, token, "case") or
        std.mem.eql(u8, token, "fi") or std.mem.eql(u8, token, "done") or
        std.mem.eql(u8, token, "esac") or std.mem.eql(u8, token, "else") or
        std.mem.eql(u8, token, "elif") or std.mem.eql(u8, token, "class") or
        std.mem.eql(u8, token, "module") or std.mem.eql(u8, token, "for") or
        std.mem.eql(u8, token, "while");
}

fn matchKeywordInAncestors(node: c.TSNode, source: []const u8, token: []const u8, allow_named_keywords: bool) ?c.TSNode {
    var parent = c.ts_node_parent(node);
    while (!isNullNode(parent)) : (parent = c.ts_node_parent(parent)) {
        if (matchKeywordInNode(parent, source, node, token, allow_named_keywords)) |matched| return matched;
    }
    return null;
}

fn matchKeywordInNode(parent: c.TSNode, source: []const u8, original: c.TSNode, token: []const u8, allow_named_keywords: bool) ?c.TSNode {
    if (std.mem.eql(u8, token, "if")) {
        if (findLastToken(parent, source, original, matchesFi, allow_named_keywords)) |matched| return matched;
        if (findLastToken(parent, source, original, matchesEnd, allow_named_keywords)) |matched| return matched;
        if (findLastToken(parent, source, original, matchesPythonElse, allow_named_keywords)) |matched| return matched;
    }
    if (std.mem.eql(u8, token, "do")) {
        if (findLastToken(parent, source, original, matchesDone, allow_named_keywords)) |matched| return matched;
        if (findLastToken(parent, source, original, matchesEnd, allow_named_keywords)) |matched| return matched;
    }
    if (std.mem.eql(u8, token, "case")) {
        if (findLastToken(parent, source, original, matchesEsac, allow_named_keywords)) |matched| return matched;
        if (findLastToken(parent, source, original, matchesEnd, allow_named_keywords)) |matched| return matched;
    }
    if (isEndKeyword(token)) return findFirstToken(parent, source, original, matchesEndOpenKeyword, allow_named_keywords);
    if (std.mem.eql(u8, token, "fi")) return findFirstToken(parent, source, original, matchesIf, allow_named_keywords);
    if (std.mem.eql(u8, token, "done")) return findFirstToken(parent, source, original, matchesDo, allow_named_keywords);
    if (std.mem.eql(u8, token, "esac")) return findFirstToken(parent, source, original, matchesCase, allow_named_keywords);
    if (std.mem.eql(u8, token, "else") or std.mem.eql(u8, token, "elif")) return findFirstToken(parent, source, original, matchesIf, allow_named_keywords);
    return findLastToken(parent, source, original, matchesEnd, allow_named_keywords);
}

fn isEndKeyword(token: []const u8) bool {
    return std.mem.eql(u8, token, "end");
}

fn matchElixirEndToHead(node: c.TSNode, source: []const u8) ?c.TSNode {
    const block = c.ts_node_parent(node);
    if (isNullNode(block) or !std.mem.eql(u8, nodeType(block), "do_block")) return null;
    const owner = c.ts_node_parent(block);
    if (isNullNode(owner)) return null;
    return findFirstToken(owner, source, block, matchesElixirBlockHead, true);
}

const TokenMatcher = *const fn ([]const u8) bool;

fn findFirstToken(node: c.TSNode, source: []const u8, skip: c.TSNode, matcher: TokenMatcher, allow_named_keywords: bool) ?c.TSNode {
    if (!c.ts_node_eq(node, skip) and tokenNodeMatches(node, source, matcher, allow_named_keywords)) return node;
    const count = c.ts_node_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = c.ts_node_child(node, i);
        if (c.ts_node_eq(child, skip)) continue;
        if (findFirstToken(child, source, skip, matcher, allow_named_keywords)) |matched| return matched;
    }
    return null;
}

fn findLastToken(node: c.TSNode, source: []const u8, skip: c.TSNode, matcher: TokenMatcher, allow_named_keywords: bool) ?c.TSNode {
    var result: ?c.TSNode = null;
    if (!c.ts_node_eq(node, skip) and tokenNodeMatches(node, source, matcher, allow_named_keywords)) result = node;
    const count = c.ts_node_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = c.ts_node_child(node, i);
        if (c.ts_node_eq(child, skip)) continue;
        if (findLastToken(child, source, skip, matcher, allow_named_keywords)) |matched| result = matched;
    }
    return result;
}

fn tokenNodeMatches(node: c.TSNode, source: []const u8, matcher: TokenMatcher, allow_named_keywords: bool) bool {
    if (c.ts_node_is_named(node) and !allow_named_keywords) return false;
    return matcher(tokenText(source, node));
}

fn matchesEnd(token: []const u8) bool {
    return std.mem.eql(u8, token, "end");
}
fn matchesDone(token: []const u8) bool {
    return std.mem.eql(u8, token, "done");
}
fn matchesFi(token: []const u8) bool {
    return std.mem.eql(u8, token, "fi");
}
fn matchesEsac(token: []const u8) bool {
    return std.mem.eql(u8, token, "esac");
}
fn matchesIf(token: []const u8) bool {
    return std.mem.eql(u8, token, "if");
}
fn matchesDo(token: []const u8) bool {
    return std.mem.eql(u8, token, "do");
}
fn matchesCase(token: []const u8) bool {
    return std.mem.eql(u8, token, "case");
}
fn matchesPythonElse(token: []const u8) bool {
    return std.mem.eql(u8, token, "else") or std.mem.eql(u8, token, "elif");
}

fn matchesElixirBlockHead(token: []const u8) bool {
    return std.mem.eql(u8, token, "def") or std.mem.eql(u8, token, "defp") or
        std.mem.eql(u8, token, "defmodule") or std.mem.eql(u8, token, "fn") or
        std.mem.eql(u8, token, "if") or std.mem.eql(u8, token, "unless") or
        std.mem.eql(u8, token, "case") or std.mem.eql(u8, token, "for") or
        std.mem.eql(u8, token, "while");
}

fn matchesEndOpenKeyword(token: []const u8) bool {
    return matchesElixirBlockHead(token) or std.mem.eql(u8, token, "do") or
        std.mem.eql(u8, token, "begin") or std.mem.eql(u8, token, "class") or
        std.mem.eql(u8, token, "module");
}

fn matchHtmlTag(node: c.TSNode) ?c.TSNode {
    if (!std.mem.eql(u8, nodeType(node), "tag_name")) return null;
    const tag = nearestTagNode(node) orelse return null;
    const tag_type = nodeType(tag);
    if (std.mem.eql(u8, tag_type, "self_closing_tag")) return null;

    const element = c.ts_node_parent(tag);
    if (isNullNode(element)) return null;
    const want_end = std.mem.eql(u8, tag_type, "start_tag");
    const count = c.ts_node_child_count(element);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = c.ts_node_child(element, i);
        const typ = nodeType(child);
        if (want_end and std.mem.eql(u8, typ, "end_tag")) return tagNameChild(child) orelse child;
        if (!want_end and std.mem.eql(u8, typ, "start_tag")) return tagNameChild(child) orelse child;
    }
    return null;
}

fn nearestTagNode(node: c.TSNode) ?c.TSNode {
    var current = node;
    while (!isNullNode(current)) : (current = c.ts_node_parent(current)) {
        const typ = nodeType(current);
        if (std.mem.eql(u8, typ, "start_tag") or std.mem.eql(u8, typ, "end_tag") or std.mem.eql(u8, typ, "self_closing_tag")) return current;
        if (std.mem.eql(u8, typ, "element")) return null;
    }
    return null;
}

fn tagNameChild(tag: c.TSNode) ?c.TSNode {
    const count = c.ts_node_child_count(tag);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = c.ts_node_child(tag, i);
        if (std.mem.eql(u8, nodeType(child), "tag_name")) return child;
    }
    return null;
}

// ── Injection helpers ─────────────────────────────────────────────────────

/// Reads `#set! injection.language "..."` predicates from a query pattern.
/// Returns the language name string if found, or null.
fn getInjectionLanguagePredicate(query: *c.TSQuery, pattern_index: u32) ?[]const u8 {
    var step_count: u32 = 0;
    const steps = c.ts_query_predicates_for_pattern(query, pattern_index, &step_count);
    if (step_count == 0) return null;

    // Walk predicate steps looking for: "set!" "injection.language" "<value>"
    var i: u32 = 0;
    while (i < step_count) {
        const step = steps[i];
        if (step.type == c.TSQueryPredicateStepTypeDone) {
            i += 1;
            continue;
        }

        // Check for a "set!" string step
        if (step.type == c.TSQueryPredicateStepTypeString) {
            var len: u32 = 0;
            const str = c.ts_query_string_value_for_id(query, step.value_id, &len);
            const name = str[0..len];

            if (std.mem.eql(u8, name, "set!") and i + 2 < step_count) {
                const key_step = steps[i + 1];
                const val_step = steps[i + 2];

                if (key_step.type == c.TSQueryPredicateStepTypeString and
                    val_step.type == c.TSQueryPredicateStepTypeString)
                {
                    var key_len: u32 = 0;
                    const key_str = c.ts_query_string_value_for_id(query, key_step.value_id, &key_len);
                    const key = key_str[0..key_len];

                    if (std.mem.eql(u8, key, "injection.language")) {
                        var val_len: u32 = 0;
                        const val_str = c.ts_query_string_value_for_id(query, val_step.value_id, &val_len);
                        return val_str[0..val_len];
                    }
                }
            }
        }
        i += 1;
    }
    return null;
}

/// A byte range representing an injection region (for internal trimming).

// ── Span ordering ─────────────────────────────────────────────────────────

/// Find a capture id by name in a compiled query.
fn findCaptureId(query: ?*c.TSQuery, target: []const u8) ?u32 {
    const q = query orelse return null;
    const count = c.ts_query_capture_count(q);
    for (0..count) |i| {
        var length: u32 = 0;
        const name_ptr = c.ts_query_capture_name_for_id(q, @intCast(i), &length);
        if (std.mem.eql(u8, name_ptr[0..length], target)) return @intCast(i);
    }
    return null;
}

fn lowerBoundSpanStart(spans: []const Span, start_byte: u32) usize {
    var low: usize = 0;
    var high: usize = spans.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (spans[mid].start_byte < start_byte) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

fn shiftSpan(span: Span, delta: i64) Span {
    const start = @as(i64, span.start_byte) + delta;
    const end = @as(i64, span.end_byte) + delta;
    return .{
        .start_byte = @intCast(start),
        .end_byte = @intCast(end),
        .capture_id = span.capture_id,
        .pattern_index = span.pattern_index,
        .layer = span.layer,
    };
}

fn spansAreSorted(spans: []const Span) bool {
    if (spans.len < 2) return true;
    var i: usize = 1;
    while (i < spans.len) : (i += 1) {
        if (spanLessThan({}, spans[i], spans[i - 1])) return false;
    }
    return true;
}

/// Comparator for highlight spans.
/// Order: start_byte ASC, layer DESC, pattern_index DESC, end_byte ASC.
/// This ensures injection spans (higher layer) win over outer spans at the
/// same byte position, and within a layer the most specific pattern wins.
fn spanLessThan(_: void, a: Span, b: Span) bool {
    if (a.start_byte != b.start_byte) return a.start_byte < b.start_byte;
    if (a.layer != b.layer) return a.layer > b.layer;
    if (a.pattern_index != b.pattern_index) return a.pattern_index > b.pattern_index;
    return a.end_byte < b.end_byte;
}

// ── Compiled-in grammar registry ──────────────────────────────────────────

// Extern declarations for all compiled-in grammars.
extern fn tree_sitter_elixir() ?*const c.TSLanguage;
extern fn tree_sitter_heex() ?*const c.TSLanguage;
extern fn tree_sitter_json() ?*const c.TSLanguage;
extern fn tree_sitter_yaml() ?*const c.TSLanguage;
extern fn tree_sitter_toml() ?*const c.TSLanguage;
extern fn tree_sitter_markdown() ?*const c.TSLanguage;
extern fn tree_sitter_markdown_inline() ?*const c.TSLanguage;
extern fn tree_sitter_ruby() ?*const c.TSLanguage;
extern fn tree_sitter_javascript() ?*const c.TSLanguage;
extern fn tree_sitter_typescript() ?*const c.TSLanguage;
extern fn tree_sitter_tsx() ?*const c.TSLanguage;
extern fn tree_sitter_go() ?*const c.TSLanguage;
extern fn tree_sitter_rust() ?*const c.TSLanguage;
extern fn tree_sitter_zig() ?*const c.TSLanguage;
extern fn tree_sitter_erlang() ?*const c.TSLanguage;
extern fn tree_sitter_bash() ?*const c.TSLanguage;
extern fn tree_sitter_c() ?*const c.TSLanguage;
extern fn tree_sitter_cpp() ?*const c.TSLanguage;
extern fn tree_sitter_html() ?*const c.TSLanguage;
extern fn tree_sitter_css() ?*const c.TSLanguage;
extern fn tree_sitter_lua() ?*const c.TSLanguage;
extern fn tree_sitter_python() ?*const c.TSLanguage;
extern fn tree_sitter_kotlin() ?*const c.TSLanguage;
extern fn tree_sitter_gleam() ?*const c.TSLanguage;
extern fn tree_sitter_java() ?*const c.TSLanguage;
extern fn tree_sitter_c_sharp() ?*const c.TSLanguage;
extern fn tree_sitter_php_only() ?*const c.TSLanguage;
extern fn tree_sitter_dockerfile() ?*const c.TSLanguage;
extern fn tree_sitter_hcl() ?*const c.TSLanguage;
extern fn tree_sitter_scss() ?*const c.TSLanguage;
extern fn tree_sitter_graphql() ?*const c.TSLanguage;
extern fn tree_sitter_nix() ?*const c.TSLanguage;
extern fn tree_sitter_ocaml() ?*const c.TSLanguage;
extern fn tree_sitter_haskell() ?*const c.TSLanguage;
extern fn tree_sitter_scala() ?*const c.TSLanguage;
extern fn tree_sitter_r() ?*const c.TSLanguage;
extern fn tree_sitter_dart() ?*const c.TSLanguage;
extern fn tree_sitter_make() ?*const c.TSLanguage;
extern fn tree_sitter_diff() ?*const c.TSLanguage;
extern fn tree_sitter_elisp() ?*const c.TSLanguage;
extern fn tree_sitter_clojure() ?*const c.TSLanguage;
extern fn tree_sitter_objc() ?*const c.TSLanguage;
extern fn tree_sitter_sql() ?*const c.TSLanguage;
extern fn tree_sitter_xml() ?*const c.TSLanguage;
extern fn tree_sitter_ini() ?*const c.TSLanguage;
extern fn tree_sitter_swift() ?*const c.TSLanguage;
extern fn tree_sitter_vim() ?*const c.TSLanguage;
extern fn tree_sitter_proto() ?*const c.TSLanguage;
extern fn tree_sitter_fish() ?*const c.TSLanguage;
extern fn tree_sitter_perl() ?*const c.TSLanguage;

/// Helper to resolve a highlight query via the query_loader, which handles
/// `; inherits:` directives at comptime. All parent queries are prepended
/// automatically before the query reaches ts_query_new.
fn ql(comptime name: []const u8) ?[]const u8 {
    return comptime query_loader.resolve(name, .highlights);
}

/// Helper to resolve an injection query via the query_loader.
fn qlInj(comptime name: []const u8) ?[]const u8 {
    return comptime query_loader.resolve(name, .injections);
}

/// Helper to resolve a fold query via the query_loader.
fn qlFold(comptime name: []const u8) ?[]const u8 {
    return comptime query_loader.resolve(name, .folds);
}

/// Helper to resolve an indent query via the query_loader.
fn qlIndent(comptime name: []const u8) ?[]const u8 {
    return comptime query_loader.resolve(name, .indents);
}

/// Helper to resolve a textobjects query via the query_loader.
fn qlTextobj(comptime name: []const u8) ?[]const u8 {
    return comptime query_loader.resolve(name, .textobjects);
}

const builtin_grammars = [_]BuiltinGrammar{
    .{ .name = "elixir", .func = tree_sitter_elixir, .query = ql("elixir"), .injection_query = qlInj("elixir"), .fold_query = qlFold("elixir"), .indent_query = qlIndent("elixir"), .textobject_query = qlTextobj("elixir") },
    .{ .name = "heex", .func = tree_sitter_heex },
    .{ .name = "json", .func = tree_sitter_json, .query = ql("json"), .fold_query = qlFold("json"), .indent_query = qlIndent("json") },
    .{ .name = "yaml", .func = tree_sitter_yaml, .query = ql("yaml"), .fold_query = qlFold("yaml"), .indent_query = qlIndent("yaml") },
    .{ .name = "toml", .func = tree_sitter_toml, .query = ql("toml"), .fold_query = qlFold("toml") },
    .{ .name = "markdown", .func = tree_sitter_markdown, .query = ql("markdown"), .injection_query = qlInj("markdown"), .fold_query = qlFold("markdown") },
    .{ .name = "markdown_inline", .func = tree_sitter_markdown_inline, .query = ql("markdown_inline"), .injection_query = qlInj("markdown_inline") },
    .{ .name = "ruby", .func = tree_sitter_ruby, .query = ql("ruby"), .fold_query = qlFold("ruby"), .indent_query = qlIndent("ruby"), .textobject_query = qlTextobj("ruby") },
    .{ .name = "javascript", .func = tree_sitter_javascript, .query = ql("javascript"), .injection_query = qlInj("javascript"), .fold_query = qlFold("javascript"), .indent_query = qlIndent("javascript"), .textobject_query = qlTextobj("javascript") },
    .{ .name = "typescript", .func = tree_sitter_typescript, .query = ql("typescript"), .fold_query = qlFold("typescript"), .indent_query = qlIndent("typescript"), .textobject_query = qlTextobj("typescript") },
    .{ .name = "tsx", .func = tree_sitter_tsx, .query = ql("tsx"), .fold_query = qlFold("tsx"), .textobject_query = qlTextobj("tsx") },
    .{ .name = "go", .func = tree_sitter_go, .query = ql("go"), .fold_query = qlFold("go"), .indent_query = qlIndent("go"), .textobject_query = qlTextobj("go") },
    .{ .name = "rust", .func = tree_sitter_rust, .query = ql("rust"), .injection_query = qlInj("rust"), .fold_query = qlFold("rust"), .indent_query = qlIndent("rust"), .textobject_query = qlTextobj("rust") },
    .{ .name = "zig", .func = tree_sitter_zig, .query = ql("zig"), .injection_query = qlInj("zig"), .fold_query = qlFold("zig"), .indent_query = qlIndent("zig"), .textobject_query = qlTextobj("zig") },
    .{ .name = "erlang", .func = tree_sitter_erlang, .query = ql("erlang"), .fold_query = qlFold("erlang") },
    .{ .name = "bash", .func = tree_sitter_bash, .query = ql("bash"), .fold_query = qlFold("bash"), .indent_query = qlIndent("bash"), .textobject_query = qlTextobj("bash") },
    .{ .name = "c", .func = tree_sitter_c, .query = ql("c"), .fold_query = qlFold("c"), .indent_query = qlIndent("c"), .textobject_query = qlTextobj("c") },
    .{ .name = "cpp", .func = tree_sitter_cpp, .query = ql("cpp"), .injection_query = qlInj("cpp"), .fold_query = qlFold("cpp"), .indent_query = qlIndent("cpp"), .textobject_query = qlTextobj("cpp") },
    .{ .name = "html", .func = tree_sitter_html, .query = ql("html"), .injection_query = qlInj("html"), .fold_query = qlFold("html") },
    .{ .name = "css", .func = tree_sitter_css, .query = ql("css"), .fold_query = qlFold("css"), .indent_query = qlIndent("css") },
    .{ .name = "lua", .func = tree_sitter_lua, .query = ql("lua"), .injection_query = qlInj("lua"), .fold_query = qlFold("lua"), .indent_query = qlIndent("lua"), .textobject_query = qlTextobj("lua") },
    .{ .name = "python", .func = tree_sitter_python, .query = ql("python"), .fold_query = qlFold("python"), .indent_query = qlIndent("python"), .textobject_query = qlTextobj("python") },
    .{ .name = "kotlin", .func = tree_sitter_kotlin, .query = ql("kotlin"), .fold_query = qlFold("kotlin"), .indent_query = qlIndent("kotlin"), .textobject_query = qlTextobj("kotlin") },
    .{ .name = "gleam", .func = tree_sitter_gleam, .query = ql("gleam"), .injection_query = qlInj("gleam"), .fold_query = qlFold("gleam") },
    .{ .name = "java", .func = tree_sitter_java, .query = ql("java"), .fold_query = qlFold("java"), .indent_query = qlIndent("java"), .textobject_query = qlTextobj("java") },
    .{ .name = "c_sharp", .func = tree_sitter_c_sharp, .query = ql("c_sharp") },
    .{ .name = "php", .func = tree_sitter_php_only, .query = ql("php"), .fold_query = qlFold("php") },
    .{ .name = "dockerfile", .func = tree_sitter_dockerfile, .query = ql("dockerfile") },
    .{ .name = "hcl", .func = tree_sitter_hcl, .query = ql("hcl") },
    .{ .name = "scss", .func = tree_sitter_scss, .query = ql("scss"), .fold_query = qlFold("scss") },
    .{ .name = "graphql", .func = tree_sitter_graphql, .query = ql("graphql") },
    .{ .name = "nix", .func = tree_sitter_nix, .query = ql("nix"), .fold_query = qlFold("nix"), .indent_query = qlIndent("nix"), .textobject_query = qlTextobj("nix") },
    .{ .name = "ocaml", .func = tree_sitter_ocaml, .query = ql("ocaml"), .fold_query = qlFold("ocaml"), .indent_query = qlIndent("ocaml") },
    .{ .name = "haskell", .func = tree_sitter_haskell, .query = ql("haskell"), .fold_query = qlFold("haskell"), .textobject_query = qlTextobj("haskell") },
    .{ .name = "scala", .func = tree_sitter_scala, .query = ql("scala"), .fold_query = qlFold("scala"), .indent_query = qlIndent("scala"), .textobject_query = qlTextobj("scala") },
    .{ .name = "r", .func = tree_sitter_r, .query = ql("r") },
    .{ .name = "dart", .func = tree_sitter_dart, .query = ql("dart"), .fold_query = qlFold("dart"), .indent_query = qlIndent("dart"), .textobject_query = qlTextobj("dart") },
    .{ .name = "make", .func = tree_sitter_make, .query = ql("make"), .fold_query = qlFold("make") },
    .{ .name = "diff", .func = tree_sitter_diff, .query = ql("diff"), .fold_query = qlFold("diff") },
    .{ .name = "elisp", .func = tree_sitter_elisp, .query = ql("elisp") },
    .{ .name = "clojure", .func = tree_sitter_clojure, .query = ql("clojure") },
    .{ .name = "objc", .func = tree_sitter_objc, .query = ql("objc") },
    .{ .name = "sql", .func = tree_sitter_sql, .query = ql("sql"), .fold_query = qlFold("sql"), .indent_query = qlIndent("sql"), .textobject_query = qlTextobj("sql") },
    .{ .name = "xml", .func = tree_sitter_xml, .query = ql("xml"), .injection_query = qlInj("xml"), .fold_query = qlFold("xml"), .indent_query = qlIndent("xml"), .textobject_query = qlTextobj("xml") },
    .{ .name = "ini", .func = tree_sitter_ini, .query = ql("ini"), .fold_query = qlFold("ini"), .indent_query = qlIndent("ini"), .textobject_query = qlTextobj("ini") },
    .{ .name = "swift", .func = tree_sitter_swift, .query = ql("swift"), .injection_query = qlInj("swift"), .fold_query = qlFold("swift"), .indent_query = qlIndent("swift"), .textobject_query = qlTextobj("swift") },
    .{ .name = "vim", .func = tree_sitter_vim, .query = ql("vim"), .injection_query = qlInj("vim"), .fold_query = qlFold("vim"), .indent_query = qlIndent("vim"), .textobject_query = qlTextobj("vim") },
    .{ .name = "protobuf", .func = tree_sitter_proto, .query = ql("protobuf"), .injection_query = qlInj("protobuf"), .fold_query = qlFold("protobuf"), .indent_query = qlIndent("protobuf"), .textobject_query = qlTextobj("protobuf") },
    .{ .name = "fish", .func = tree_sitter_fish, .query = ql("fish"), .injection_query = qlInj("fish"), .indent_query = qlIndent("fish"), .textobject_query = qlTextobj("fish") },
    .{ .name = "perl", .func = tree_sitter_perl, .query = ql("perl"), .injection_query = qlInj("perl"), .fold_query = qlFold("perl"), .indent_query = qlIndent("perl"), .textobject_query = qlTextobj("perl") },
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "highlighter: init registers all grammars" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.languages.count() == builtin_grammars.len);
    try std.testing.expect(hl.languages.get("elixir") != null);
    try std.testing.expect(hl.languages.get("zig") != null);
    try std.testing.expect(hl.languages.get("nonexistent") == null);
}

test "highlighter: setLanguage" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("elixir"));
    try std.testing.expect(hl.current_language != null);
    try std.testing.expect(!hl.setLanguage("nonexistent"));
}

test "highlighter: parse Elixir source" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("elixir"));
    try hl.parse("defmodule Foo do\n  def bar, do: :ok\nend\n");

    try std.testing.expect(hl.tree != null);
}

test "highlighter: parse and highlight Elixir" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("elixir"));

    const source = "defmodule Foo do\n  def bar, do: :ok\nend\n";
    try hl.parse(source);

    // Minimal Elixir highlight query for testing
    const query_source =
        \\(call target: (identifier) @keyword
        \\  (#match? @keyword "^(defmodule|def|defp|do|end)$"))
        \\(atom) @string.special.symbol
    ;
    try hl.setHighlightQuery(query_source);

    var result = try hl.highlight();
    defer result.deinit();

    // Should have some spans and capture names
    try std.testing.expect(result.spans.len > 0);
    try std.testing.expect(result.capture_names.len > 0);

    // Verify at least one span covers "defmodule" (bytes 0-9)
    var found_defmodule = false;
    for (result.spans) |span| {
        if (span.start_byte == 0 and span.end_byte == 9) {
            found_defmodule = true;
            break;
        }
    }
    try std.testing.expect(found_defmodule);
}

test "highlighter: parse JSON" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("json"));
    try hl.parse("{\"key\": 42}");
    try std.testing.expect(hl.tree != null);
}

test "highlighter: missing grammar languages parse and highlight" {
    const Sample = struct {
        name: []const u8,
        source: []const u8,
        require_structural_queries: bool = false,
    };
    const samples = [_]Sample{
        .{ .name = "sql", .source = "SELECT id, name FROM users WHERE active = true;\n", .require_structural_queries = true },
        .{ .name = "xml", .source = "<root><item name=\"one\">value</item></root>\n", .require_structural_queries = true },
        .{ .name = "ini", .source = "[core]\neditor = minga\n", .require_structural_queries = true },
        .{ .name = "swift", .source = "func greet(name: String) { print(name) }\n", .require_structural_queries = true },
        .{ .name = "vim", .source = "function! Test()\n  echo \"hi\"\nendfunction\n", .require_structural_queries = true },
        .{ .name = "protobuf", .source = "syntax = \"proto3\";\nmessage User { string name = 1; }\n" },
        .{ .name = "fish", .source = "function greet\n  echo hi\nend\n" },
        .{ .name = "perl", .source = "sub greet { print \"hi\"; }\n" },
    };

    for (samples) |sample| {
        var hl = try Highlighter.init(std.testing.allocator);
        defer hl.deinit();

        try std.testing.expect(hl.setLanguage(sample.name));
        try std.testing.expect(hl.query != null);
        if (sample.require_structural_queries) {
            try std.testing.expect(hl.fold_query != null);
            try std.testing.expect(hl.indent_query != null);
            try std.testing.expect(hl.textobject_query != null);
        }

        try hl.parse(sample.source);
        var result = try hl.highlightWithInjections();
        defer result.deinit();
        try std.testing.expect(result.spans.len > 0);
    }
}

test "highlighter: new indent queries use supported captures" {
    var sql = try Highlighter.init(std.testing.allocator);
    defer sql.deinit();

    try std.testing.expect(sql.setLanguage("sql"));
    try sql.parse("SELECT\n  id\nFROM users;\n");
    try std.testing.expect(sql.computeIndent(1) > 0);

    var swift = try Highlighter.init(std.testing.allocator);
    defer swift.deinit();

    try std.testing.expect(swift.setLanguage("swift"));
    try swift.parse("class Greeter {\n  let name = \"Minga\"\n}\n");
    try std.testing.expect(swift.computeIndent(1) > 0);

    try std.testing.expect(swift.setLanguage("swift"));
    try swift.parse("struct Box<\n  T\n> {\n}\n");
    try std.testing.expect(swift.computeIndent(1) > 0);
    try std.testing.expectEqual(@as(i32, 0), swift.computeIndent(2));
}

test "highlighter: SQL numeric predicates classify integer and float literals" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("sql"));

    const source = "SELECT 42, 3.14, 'x';\n";
    try hl.parse(source);

    var result = try hl.highlightWithInjections();
    defer result.deinit();

    var number_id: ?u16 = null;
    var float_id: ?u16 = null;
    for (result.capture_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, "number")) number_id = @intCast(i);
        if (std.mem.eql(u8, name, "float")) float_id = @intCast(i);
    }

    try std.testing.expect(number_id != null);
    try std.testing.expect(float_id != null);

    const integer_start = std.mem.indexOf(u8, source, "42") orelse unreachable;
    const float_start = std.mem.indexOf(u8, source, "3.14") orelse unreachable;

    var found_integer = false;
    var found_float = false;
    for (result.spans) |span| {
        if (span.start_byte == integer_start and span.end_byte == integer_start + 2 and span.capture_id == number_id.?) {
            found_integer = true;
        }
        if (span.start_byte == float_start and span.end_byte == float_start + 4 and span.capture_id == float_id.?) {
            found_float = true;
        }
    }

    try std.testing.expect(found_integer);
    try std.testing.expect(found_float);
}

test "highlighter: Perl shebang predicate does not tag ordinary first comments as preproc" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("perl"));

    const comment_source = "# ordinary comment\nsub greet { print \"hi\"; }\n";
    try hl.parse(comment_source);

    var comment_result = try hl.highlightWithInjections();
    defer comment_result.deinit();

    var preproc_id: ?u16 = null;
    for (comment_result.capture_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, "preproc")) preproc_id = @intCast(i);
    }
    try std.testing.expect(preproc_id != null);

    for (comment_result.spans) |span| {
        if (span.start_byte == 0 and span.capture_id == preproc_id.?) {
            return error.OrdinaryCommentTaggedAsPreproc;
        }
    }

    try std.testing.expect(hl.setLanguage("perl"));

    const shebang_source = "#!/usr/bin/env perl\nsub greet { print \"hi\"; }\n";
    try hl.parse(shebang_source);

    var shebang_result = try hl.highlightWithInjections();
    defer shebang_result.deinit();

    preproc_id = null;
    for (shebang_result.capture_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, "preproc")) preproc_id = @intCast(i);
    }
    try std.testing.expect(preproc_id != null);

    const shebang_end = std.mem.indexOf(u8, shebang_source, "\n") orelse unreachable;
    var found_shebang = false;
    for (shebang_result.spans) |span| {
        if (span.start_byte == 0 and span.end_byte == shebang_end and span.capture_id == preproc_id.?) {
            found_shebang = true;
        }
    }
    try std.testing.expect(found_shebang);
}

test "highlighter: match item finds structural brackets" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("javascript"));
    try hl.parse("const x = (1 + 2);");

    const result = hl.findMatchingItem(0, 10) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 0), result.row);
    try std.testing.expectEqual(@as(u32, 16), result.col);
}

test "highlighter: match item ignores unrelated separators" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("javascript"));
    try hl.parse("foo(a, b, c);");

    try std.testing.expect(hl.findMatchingItem(0, 5) == null);
}

test "highlighter: match item ignores brackets inside strings and comments" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("javascript"));
    try hl.parse("const s = \"(\"; // )\nconst x = (1);\n");

    try std.testing.expect(hl.findMatchingItem(0, 11) == null);
    try std.testing.expect(hl.findMatchingItem(0, 18) == null);

    const result = hl.findMatchingItem(1, 10) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 1), result.row);
    try std.testing.expectEqual(@as(u32, 12), result.col);
}

test "highlighter: match item matches Elixir block keywords" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("elixir"));
    try hl.parse("def foo do\n  :ok\nend\n");

    const from_def = hl.findMatchingItem(0, 0) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 2), from_def.row);
    try std.testing.expectEqual(@as(u32, 0), from_def.col);

    const from_do = hl.findMatchingItem(0, 8) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 2), from_do.row);
    try std.testing.expectEqual(@as(u32, 0), from_do.col);

    const from_end = hl.findMatchingItem(2, 0) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 0), from_end.row);
    try std.testing.expectEqual(@as(u32, 0), from_end.col);
}

test "highlighter: match item matches string delimiters" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("javascript"));
    try hl.parse("const s = \"hello\";");

    const from_open = hl.findMatchingItem(0, 10) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 0), from_open.row);
    try std.testing.expectEqual(@as(u32, 16), from_open.col);

    const from_close = hl.findMatchingItem(0, 16) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 0), from_close.row);
    try std.testing.expectEqual(@as(u32, 10), from_close.col);
}

test "highlighter: match item ignores string content" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("javascript"));
    try hl.parse("const s = \"hello\";");

    try std.testing.expect(hl.findMatchingItem(0, 11) == null);
    try std.testing.expect(hl.findMatchingItem(0, 15) == null);
}

test "highlighter: match item ignores identifiers that look like shell keywords" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("javascript"));
    try hl.parse("do { done(); } while (ok);");

    try std.testing.expect(hl.findMatchingItem(0, 0) == null);
    try std.testing.expect(hl.findMatchingItem(0, 5) == null);
}

test "highlighter: match item keeps HTML attributes out of tag matching" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("html"));
    try hl.parse("<div title=\"x\"></div>");

    try std.testing.expect(hl.findMatchingItem(0, 11) == null);
    try std.testing.expect(hl.findMatchingItem(0, 12) == null);
}

test "highlighter: match item matches HTML tags and ignores self-closing tags" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("html"));
    try hl.parse("<div><br/></div>");

    const from_open = hl.findMatchingItem(0, 1) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 0), from_open.row);
    try std.testing.expectEqual(@as(u32, 12), from_open.col);

    const from_close = hl.findMatchingItem(0, 12) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 0), from_close.row);
    try std.testing.expectEqual(@as(u32, 1), from_close.col);

    try std.testing.expect(hl.findMatchingItem(0, 6) == null);
}

test "highlighter: match item matches Ruby if end" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("ruby"));
    try hl.parse("if ok\n  puts :ok\nend\n");

    const result = hl.findMatchingItem(0, 0) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 2), result.row);
    try std.testing.expectEqual(@as(u32, 0), result.col);

    const reverse = hl.findMatchingItem(2, 0) orelse return error.NoMatch;
    try std.testing.expectEqual(@as(u32, 0), reverse.row);
    try std.testing.expectEqual(@as(u32, 0), reverse.col);
}

test "highlighter: setLanguage invalidates tree, restores cached query" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("elixir"));
    try hl.parse("defmodule Foo do end");
    try std.testing.expect(hl.tree != null);
    // Elixir has a pre-compiled query from init
    try std.testing.expect(hl.query != null);

    // Switching language should clear tree but restore cached query
    try std.testing.expect(hl.setLanguage("json"));
    try std.testing.expect(hl.tree == null);
    // JSON also has a pre-compiled query
    try std.testing.expect(hl.query != null);
}

test "highlighter: markdown query compiles and highlights" {
    // Requires tree-sitter >= 0.25.0 (ABI 15 support)
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("markdown"));

    const query_source =
        \\[
        \\  (atx_h1_marker)
        \\  (atx_h2_marker)
        \\  (atx_h3_marker)
        \\] @punctuation.special
        \\(fenced_code_block) @text.literal
        \\(link_destination) @text.uri
    ;
    try hl.setHighlightQuery(query_source);

    const source = "# Hello\n\n```\ncode\n```\n";
    try hl.parse(source);

    var result = try hl.highlight();
    defer result.deinit();

    try std.testing.expect(result.spans.len > 0);
}

test "highlighter: query cache restores on language switch" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    // Elixir has a pre-compiled query from init
    try std.testing.expect(hl.setLanguage("elixir"));
    try std.testing.expect(hl.query != null);
    const elixir_query = hl.query;

    // HEEx has no pre-compiled query
    try std.testing.expect(hl.setLanguage("heex"));
    try std.testing.expect(hl.query == null);

    // Switch back to elixir — query should be restored from cache
    try std.testing.expect(hl.setLanguage("elixir"));
    try std.testing.expect(hl.query != null);
    try std.testing.expect(hl.query == elixir_query);
}

test "highlighter: injection query loaded for markdown" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("markdown"));
    try std.testing.expect(hl.injection_query != null);

    // JSON has no injection query
    try std.testing.expect(hl.setLanguage("json"));
    try std.testing.expect(hl.injection_query == null);

    // Switch back: injection query restored from cache
    try std.testing.expect(hl.setLanguage("markdown"));
    try std.testing.expect(hl.injection_query != null);
}

test "highlighter: highlightWithInjections falls back for non-injection language" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    // JSON has no injection query — should fall back to plain highlight
    try std.testing.expect(hl.setLanguage("json"));
    const source = "{\"key\": 42}";
    try hl.parse(source);

    var result = try hl.highlightWithInjections();
    defer result.deinit();

    // Should produce the same spans as regular highlight
    try std.testing.expect(result.spans.len > 0);
    // All spans should be layer 0
    for (result.spans) |span| {
        try std.testing.expectEqual(@as(u16, 0), span.layer);
    }
}

test "highlighter: markdown injection produces spans for fenced code block" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("markdown"));

    // Markdown with a fenced JSON code block
    const source =
        \\# Title
        \\
        \\```json
        \\{"key": 42}
        \\```
        \\
    ;
    try hl.parse(source);

    var result = try hl.highlightWithInjections();
    defer result.deinit();

    try std.testing.expect(result.spans.len > 0);

    // Should have at least one injection span (layer 1)
    var has_injection = false;
    for (result.spans) |span| {
        if (span.layer == 1) {
            has_injection = true;
            break;
        }
    }
    try std.testing.expect(has_injection);
}

test "highlighter: injection spans sort before outer spans at same position" {
    // Verify the sort puts layer 1 before layer 0 at same start_byte
    const spans = [_]Span{
        .{ .start_byte = 10, .end_byte = 20, .capture_id = 0, .pattern_index = 5, .layer = 0 },
        .{ .start_byte = 10, .end_byte = 15, .capture_id = 1, .pattern_index = 2, .layer = 1 },
    };

    var sorted: [2]Span = spans;
    std.mem.sortUnstable(Span, &sorted, {}, spanLessThan);

    // Layer 1 should come first (higher layer wins)
    try std.testing.expectEqual(@as(u16, 1), sorted[0].layer);
    try std.testing.expectEqual(@as(u16, 0), sorted[1].layer);
}

test "highlighter: capture names are unified across injection boundaries" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("markdown"));

    // Markdown with a fenced JSON block
    const source =
        \\# Hello
        \\
        \\```json
        \\{"key": 42}
        \\```
        \\
    ;
    try hl.parse(source);

    var result = try hl.highlightWithInjections();
    defer result.deinit();

    // All capture IDs in spans should be valid indices into capture_names
    for (result.spans) |span| {
        try std.testing.expect(span.capture_id < result.capture_names.len);
    }

    // The capture names list should contain names from both markdown and JSON queries
    // (at minimum the outer markdown names)
    try std.testing.expect(result.capture_names.len > 0);
}

test "highlighter: getInjectionLanguagePredicate reads #set! predicates" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("markdown"));

    // The markdown injection query has patterns with #set! injection.language
    // (e.g. for html_block, yaml metadata). Verify we can read at least one.
    const inj_q = hl.injection_query orelse return error.NoInjectionQuery;

    const pattern_count = c.ts_query_pattern_count(inj_q);
    var found_set_predicate = false;
    for (0..pattern_count) |i| {
        if (getInjectionLanguagePredicate(inj_q, @intCast(i))) |lang| {
            // Should be a known language like "html", "yaml", "toml", or "markdown_inline"
            try std.testing.expect(lang.len > 0);
            found_set_predicate = true;
        }
    }
    try std.testing.expect(found_set_predicate);
}

test "highlighter: predicates filter #any-of? correctly in Elixir" {
    // Acid test: `defmodule` and `def` should be @keyword.function,
    // but `IO` and `puts` should NOT be @keyword.function.
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.setLanguage("elixir"));

    const source = "defmodule Foo do\n  def bar do\n    IO.puts(\"hello\")\n  end\nend\n";
    try hl.parse(source);

    var result = try hl.highlightWithInjections();
    defer result.deinit();

    // Find the capture index for "keyword.function" and "function.call"
    var keyword_fn_id: ?u16 = null;
    var function_call_id: ?u16 = null;
    for (result.capture_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, "keyword.function")) keyword_fn_id = @intCast(i);
        if (std.mem.eql(u8, name, "function.call")) function_call_id = @intCast(i);
    }

    // keyword.function should exist (from defmodule/def patterns)
    try std.testing.expect(keyword_fn_id != null);

    // Check that "puts" (byte offset in source) is NOT tagged as keyword.function
    const puts_start = std.mem.indexOf(u8, source, "puts") orelse unreachable;
    const puts_end = puts_start + 4;

    for (result.spans) |span| {
        if (span.start_byte == puts_start and span.end_byte == puts_end) {
            // "puts" should NOT be keyword.function
            try std.testing.expect(span.capture_id != keyword_fn_id.?);
        }
    }

    // Check that "defmodule" IS tagged as keyword.function
    const defmod_start: u32 = 0;
    const defmod_end: u32 = 9; // "defmodule"
    var found_defmodule_keyword = false;
    for (result.spans) |span| {
        if (span.start_byte == defmod_start and span.end_byte == defmod_end) {
            if (keyword_fn_id) |kid| {
                if (span.capture_id == kid) found_defmodule_keyword = true;
            }
        }
    }
    try std.testing.expect(found_defmodule_keyword);
}
