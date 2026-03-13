const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});
const query_loader = @import("query_loader.zig");

/// A highlight span: byte range + capture index.
/// `pattern_index` is used for priority sorting (higher = more specific)
/// but is NOT serialized in the port protocol.
const protocol = @import("protocol.zig");
pub const Span = protocol.Span;

/// Result of a highlight operation.
pub const HighlightResult = struct {
    spans: []Span,
    capture_names: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HighlightResult) void {
        self.allocator.free(self.spans);
        self.allocator.free(self.capture_names);
    }
};

/// Compiled-in grammar language function type.
const LanguageFn = *const fn () callconv(.c) ?*const c.TSLanguage;

/// Built-in grammar entry with optional embedded highlight and injection queries.
const BuiltinGrammar = struct {
    name: []const u8,
    func: LanguageFn,
    query: ?[]const u8 = null,
    injection_query: ?[]const u8 = null,
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
    current_language: ?*const c.TSLanguage = null,
    current_language_name: ?[]const u8 = null,
    current_source: ?[]const u8 = null,
    languages: std.StringHashMapUnmanaged(*const c.TSLanguage),
    query_cache: std.StringHashMapUnmanaged(*c.TSQuery),
    injection_query_cache: std.StringHashMapUnmanaged(*c.TSQuery),
    cache_mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    /// After `highlightWithInjections`, holds the injection language regions.
    /// Callers can read this to determine which language is at a given byte offset.
    /// Owned by the Highlighter; freed on the next call to `highlightWithInjections`.
    injection_ranges: []InjectionRange = &.{},

    /// Tracks background pre-compilation state.
    prewarm_thread: ?std.Thread = null,
    prewarm_done: std.atomic.Value(bool) = .init(false),

    /// Initialize with compiled-in grammars registered.
    /// Spawns a background thread to pre-compile all embedded queries.
    pub fn init(allocator: std.mem.Allocator) !Highlighter {
        const parser = c.ts_parser_new() orelse return error.ParserCreateFailed;

        var hl = Highlighter{
            .parser = parser,
            .languages = .empty,
            .query_cache = .empty,
            .injection_query_cache = .empty,
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
            }
            if (entry.injection_query) |inj_source| {
                self.prewarmOne(entry.name, inj_source, &self.injection_query_cache);
            }
        }
        self.prewarm_done.store(true, .release);
    }

    fn prewarmOne(
        self: *Highlighter,
        name: []const u8,
        query_source: []const u8,
        cache: *std.StringHashMapUnmanaged(*c.TSQuery),
    ) void {
        // Check if already compiled (e.g. by a setLanguage call on the main thread)
        {
            self.cache_mutex.lock();
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
            self.cache_mutex.lock();
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

        // Free all cached injection queries
        var iqit = self.injection_query_cache.iterator();
        while (iqit.next()) |entry| {
            c.ts_query_delete(entry.value_ptr.*);
        }
        self.injection_query_cache.deinit(self.allocator);

        if (self.injection_ranges.len > 0) {
            self.allocator.free(self.injection_ranges);
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
        // Restore cached queries (may have been pre-compiled on background thread),
        // or lazily compile from embedded source.
        {
            self.cache_mutex.lock();
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
                            }
                        }
                    }
                }
            }

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
        }
        return true;
    }

    /// Compile a highlight query (.scm source) for the current language.
    /// Caches the compiled query so subsequent `setLanguage` calls restore it.
    pub fn setHighlightQuery(self: *Highlighter, source: []const u8) !void {
        const lang = self.current_language orelse return error.NoLanguageSet;
        const name = self.current_language_name orelse return error.NoLanguageSet;

        self.cache_mutex.lock();
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

        self.cache_mutex.lock();
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

    /// Parse source text. Full re-parse (no incremental).
    /// Stores a reference to the source for injection highlighting.
    pub fn parse(self: *Highlighter, source: []const u8) !void {
        if (self.tree) |t| c.ts_tree_delete(t);

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
    }

    /// Run highlight query on the current tree, returning spans.
    pub fn highlight(self: *Highlighter) !HighlightResult {
        const tree = self.tree orelse return error.NoTree;
        const query = self.query orelse return error.NoQuery;
        const alloc = self.allocator;

        const root = c.ts_tree_root_node(tree);
        const cursor = c.ts_query_cursor_new() orelse return error.CursorCreateFailed;
        defer c.ts_query_cursor_delete(cursor);

        c.ts_query_cursor_exec(cursor, query, root);

        // Collect spans
        var spans: std.ArrayListUnmanaged(Span) = .empty;
        errdefer spans.deinit(alloc);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            const captures = match.captures[0..match.capture_count];
            for (captures) |cap| {
                const node = cap.node;
                const start = c.ts_node_start_byte(node);
                const end = c.ts_node_end_byte(node);
                try spans.append(alloc, .{
                    .start_byte = start,
                    .end_byte = end,
                    .capture_id = @intCast(cap.index),
                    .pattern_index = @intCast(match.pattern_index),
                });
            }
        }

        // Sort by (start_byte ASC, layer DESC, pattern_index DESC, end_byte ASC).
        // Layer ensures injection spans always win over outer spans at the
        // same byte position. Within a layer, higher pattern_index = more
        // specific rule. The BEAM side's first-wins walk picks the correct span.
        std.mem.sortUnstable(Span, spans.items, {}, spanLessThan);

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

        // ── Phase 1: Outer highlight ──────────────────────────────────────
        const cursor = c.ts_query_cursor_new() orelse return error.CursorCreateFailed;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, query, root);

        var spans: std.ArrayListUnmanaged(Span) = .empty;
        errdefer spans.deinit(alloc);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            const captures = match.captures[0..match.capture_count];
            for (captures) |cap| {
                try spans.append(alloc, .{
                    .start_byte = c.ts_node_start_byte(cap.node),
                    .end_byte = c.ts_node_end_byte(cap.node),
                    .capture_id = @intCast(cap.index),
                    .pattern_index = @intCast(match.pattern_index),
                    .layer = 0,
                });
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
            std.mem.sortUnstable(Span, spans.items, {}, spanLessThan);
            const names = try alloc.alloc([]const u8, name_list.items.len);
            @memcpy(names, name_list.items);
            return .{
                .spans = try spans.toOwnedSlice(alloc),
                .capture_names = names,
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

            const caps = inj_match.captures[0..inj_match.capture_count];
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
                self.cache_mutex.lock();
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

            // Collect injection spans with remapped capture IDs
            var hl_match: c.TSQueryMatch = undefined;
            while (c.ts_query_cursor_next_match(hl_cursor, &hl_match)) {
                const caps = hl_match.captures[0..hl_match.capture_count];
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

        // ── Phase 4: Punch holes in outer spans ──────────────────────────
        // The BEAM's renderer sorts spans by start_byte and uses first-wins.
        // Outer spans that cover injection regions would "eat" the injection
        // spans because they start at a lower byte offset. Fix: trim or
        // remove outer spans that overlap with any injection region.
        if (regions.items.len > 0) {
            // Build sorted injection range list
            var inj_ranges = try alloc.alloc(TrimRange, regions.items.len);
            defer alloc.free(inj_ranges);
            for (regions.items, 0..) |reg, i| {
                inj_ranges[i] = .{ .start_byte = reg.start_byte, .end_byte = reg.end_byte };
            }
            std.mem.sortUnstable(TrimRange, inj_ranges, {}, struct {
                fn cmp(_: void, a: TrimRange, b: TrimRange) bool {
                    return a.start_byte < b.start_byte;
                }
            }.cmp);

            var trimmed: std.ArrayListUnmanaged(Span) = .empty;
            errdefer trimmed.deinit(alloc);
            try trimmed.ensureTotalCapacity(alloc, spans.items.len);

            for (spans.items) |span| {
                if (span.layer != 0) {
                    // Injection span — keep as-is
                    try trimmed.append(alloc, span);
                    continue;
                }
                // Outer span — trim around injection regions
                try trimOuterSpan(alloc, span, inj_ranges, &trimmed);
            }

            spans.deinit(alloc);
            spans = trimmed;
        }

        // ── Phase 5: Sort and return ─────────────────────────────────────
        std.mem.sortUnstable(Span, spans.items, {}, spanLessThan);

        const names = try alloc.alloc([]const u8, name_list.items.len);
        @memcpy(names, name_list.items);

        return .{
            .spans = try spans.toOwnedSlice(alloc),
            .capture_names = names,
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
const TrimRange = struct {
    start_byte: u32,
    end_byte: u32,
};

/// Trims an outer span around injection ranges. If the span doesn't
/// overlap any range, it's kept as-is. If it partially overlaps, the
/// non-overlapping fragments are emitted. If fully covered, it's dropped.
fn trimOuterSpan(
    alloc: std.mem.Allocator,
    span: Span,
    ranges: []const TrimRange,
    out: *std.ArrayListUnmanaged(Span),
) !void {
    // Check if this span overlaps any injection range
    var overlaps_any = false;
    for (ranges) |r| {
        if (span.start_byte < r.end_byte and span.end_byte > r.start_byte) {
            overlaps_any = true;
            break;
        }
    }
    if (!overlaps_any) {
        try out.append(alloc, span);
        return;
    }

    // Walk through injection ranges and emit fragments of the outer span
    // that don't overlap with any range.
    var pos = span.start_byte;
    for (ranges) |r| {
        if (r.start_byte >= span.end_byte) break;
        if (r.end_byte <= pos) continue;

        // Emit fragment before this range
        const range_start = @max(r.start_byte, span.start_byte);
        if (range_start > pos) {
            try out.append(alloc, .{
                .start_byte = pos,
                .end_byte = range_start,
                .capture_id = span.capture_id,
                .pattern_index = span.pattern_index,
                .layer = 0,
            });
        }
        pos = @max(pos, @min(r.end_byte, span.end_byte));
    }

    // Emit trailing fragment after the last overlapping range
    if (pos < span.end_byte) {
        try out.append(alloc, .{
            .start_byte = pos,
            .end_byte = span.end_byte,
            .capture_id = span.capture_id,
            .pattern_index = span.pattern_index,
            .layer = 0,
        });
    }
}

// ── Span ordering ─────────────────────────────────────────────────────────

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

const builtin_grammars = [_]BuiltinGrammar{
    .{ .name = "elixir", .func = tree_sitter_elixir, .query = ql("elixir"), .injection_query = qlInj("elixir") },
    .{ .name = "heex", .func = tree_sitter_heex },
    .{ .name = "json", .func = tree_sitter_json, .query = ql("json") },
    .{ .name = "yaml", .func = tree_sitter_yaml, .query = ql("yaml") },
    .{ .name = "toml", .func = tree_sitter_toml, .query = ql("toml") },
    .{ .name = "markdown", .func = tree_sitter_markdown, .query = ql("markdown"), .injection_query = qlInj("markdown") },
    .{ .name = "markdown_inline", .func = tree_sitter_markdown_inline, .query = ql("markdown_inline"), .injection_query = qlInj("markdown_inline") },
    .{ .name = "ruby", .func = tree_sitter_ruby, .query = ql("ruby") },
    .{ .name = "javascript", .func = tree_sitter_javascript, .query = ql("javascript"), .injection_query = qlInj("javascript") },
    .{ .name = "typescript", .func = tree_sitter_typescript, .query = ql("typescript") },
    .{ .name = "tsx", .func = tree_sitter_tsx, .query = ql("tsx") },
    .{ .name = "go", .func = tree_sitter_go, .query = ql("go") },
    .{ .name = "rust", .func = tree_sitter_rust, .query = ql("rust"), .injection_query = qlInj("rust") },
    .{ .name = "zig", .func = tree_sitter_zig, .query = ql("zig"), .injection_query = qlInj("zig") },
    .{ .name = "erlang", .func = tree_sitter_erlang, .query = ql("erlang") },
    .{ .name = "bash", .func = tree_sitter_bash, .query = ql("bash") },
    .{ .name = "c", .func = tree_sitter_c, .query = ql("c") },
    .{ .name = "cpp", .func = tree_sitter_cpp, .query = ql("cpp"), .injection_query = qlInj("cpp") },
    .{ .name = "html", .func = tree_sitter_html, .query = ql("html"), .injection_query = qlInj("html") },
    .{ .name = "css", .func = tree_sitter_css, .query = ql("css") },
    .{ .name = "lua", .func = tree_sitter_lua, .query = ql("lua"), .injection_query = qlInj("lua") },
    .{ .name = "python", .func = tree_sitter_python, .query = ql("python") },
    .{ .name = "kotlin", .func = tree_sitter_kotlin, .query = ql("kotlin") },
    .{ .name = "gleam", .func = tree_sitter_gleam, .query = ql("gleam"), .injection_query = qlInj("gleam") },
    .{ .name = "java", .func = tree_sitter_java, .query = ql("java") },
    .{ .name = "c_sharp", .func = tree_sitter_c_sharp, .query = ql("c_sharp") },
    .{ .name = "php", .func = tree_sitter_php_only, .query = ql("php") },
    .{ .name = "dockerfile", .func = tree_sitter_dockerfile, .query = ql("dockerfile") },
    .{ .name = "hcl", .func = tree_sitter_hcl, .query = ql("hcl") },
    .{ .name = "scss", .func = tree_sitter_scss, .query = ql("scss") },
    .{ .name = "graphql", .func = tree_sitter_graphql, .query = ql("graphql") },
    .{ .name = "nix", .func = tree_sitter_nix, .query = ql("nix") },
    .{ .name = "ocaml", .func = tree_sitter_ocaml, .query = ql("ocaml") },
    .{ .name = "haskell", .func = tree_sitter_haskell, .query = ql("haskell") },
    .{ .name = "scala", .func = tree_sitter_scala, .query = ql("scala") },
    .{ .name = "r", .func = tree_sitter_r, .query = ql("r") },
    .{ .name = "dart", .func = tree_sitter_dart, .query = ql("dart") },
    .{ .name = "make", .func = tree_sitter_make, .query = ql("make") },
    .{ .name = "diff", .func = tree_sitter_diff, .query = ql("diff") },
    .{ .name = "elisp", .func = tree_sitter_elisp, .query = ql("elisp") },
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
