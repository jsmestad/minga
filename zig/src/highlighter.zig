const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

/// A highlight span: byte range + capture index.
pub const Span = struct {
    start_byte: u32,
    end_byte: u32,
    capture_id: u16,
};

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

/// Built-in grammar entry with optional embedded highlight query.
const BuiltinGrammar = struct {
    name: []const u8,
    func: LanguageFn,
    query: ?[]const u8 = null,
};

/// Tree-sitter highlighter. Owns a parser, optional tree, and query.
/// Grammar languages are registered at init time (compiled-in) or
/// loaded dynamically via `loadGrammar`.
pub const Highlighter = struct {
    parser: *c.TSParser,
    tree: ?*c.TSTree = null,
    query: ?*c.TSQuery = null,
    current_language: ?*const c.TSLanguage = null,
    current_language_name: ?[]const u8 = null,
    languages: std.StringHashMapUnmanaged(*const c.TSLanguage),
    query_cache: std.StringHashMapUnmanaged(*c.TSQuery),
    cache_mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

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
                self.prewarmOne(entry.name, query_source);
            }
        }
        self.prewarm_done.store(true, .release);
    }

    fn prewarmOne(self: *Highlighter, name: []const u8, query_source: []const u8) void {
        // Check if already compiled (e.g. by a setLanguage call on the main thread)
        {
            self.cache_mutex.lock();
            defer self.cache_mutex.unlock();
            if (self.query_cache.get(name) != null) return;
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
            if (self.query_cache.get(name) != null) {
                c.ts_query_delete(compiled);
            } else {
                self.query_cache.put(self.allocator, name, compiled) catch {
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

        if (self.tree) |t| c.ts_tree_delete(t);
        c.ts_parser_delete(self.parser);
        self.languages.deinit(self.allocator);
    }

    /// Set the active language by name. Returns false if not found.
    /// Restores the cached query for this language if available.
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
        // Restore cached query (may have been pre-compiled on background thread),
        // or lazily compile from embedded source.
        {
            self.cache_mutex.lock();
            defer self.cache_mutex.unlock();

            if (self.query_cache.get(name)) |cached| {
                self.query = cached;
            } else {
                self.query = null;
                // Try to compile from embedded query source
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

    /// Parse source text. Full re-parse (no incremental).
    pub fn parse(self: *Highlighter, source: []const u8) !void {
        if (self.tree) |t| c.ts_tree_delete(t);

        self.tree = c.ts_parser_parse_string(
            self.parser,
            null,
            source.ptr,
            @intCast(source.len),
        ) orelse return error.ParseFailed;
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
                });
            }
        }

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

const query_dir = "queries/";

const builtin_grammars = [_]BuiltinGrammar{
    .{ .name = "elixir", .func = tree_sitter_elixir, .query = @embedFile(query_dir ++ "elixir/highlights.scm") },
    .{ .name = "heex", .func = tree_sitter_heex },
    .{ .name = "json", .func = tree_sitter_json, .query = @embedFile(query_dir ++ "json/highlights.scm") },
    .{ .name = "yaml", .func = tree_sitter_yaml, .query = @embedFile(query_dir ++ "yaml/highlights.scm") },
    .{ .name = "toml", .func = tree_sitter_toml, .query = @embedFile(query_dir ++ "toml/highlights.scm") },
    .{ .name = "markdown", .func = tree_sitter_markdown, .query = @embedFile(query_dir ++ "markdown/highlights.scm") },
    .{ .name = "markdown_inline", .func = tree_sitter_markdown_inline, .query = @embedFile(query_dir ++ "markdown_inline/highlights.scm") },
    .{ .name = "ruby", .func = tree_sitter_ruby, .query = @embedFile(query_dir ++ "ruby/highlights.scm") },
    .{ .name = "javascript", .func = tree_sitter_javascript, .query = @embedFile(query_dir ++ "javascript/highlights.scm") },
    .{ .name = "typescript", .func = tree_sitter_typescript, .query = @embedFile(query_dir ++ "typescript/highlights.scm") },
    .{ .name = "tsx", .func = tree_sitter_tsx, .query = @embedFile(query_dir ++ "tsx/highlights.scm") },
    .{ .name = "go", .func = tree_sitter_go, .query = @embedFile(query_dir ++ "go/highlights.scm") },
    .{ .name = "rust", .func = tree_sitter_rust, .query = @embedFile(query_dir ++ "rust/highlights.scm") },
    .{ .name = "zig", .func = tree_sitter_zig, .query = @embedFile(query_dir ++ "zig/highlights.scm") },
    .{ .name = "erlang", .func = tree_sitter_erlang, .query = @embedFile(query_dir ++ "erlang/highlights.scm") },
    .{ .name = "bash", .func = tree_sitter_bash, .query = @embedFile(query_dir ++ "bash/highlights.scm") },
    .{ .name = "c", .func = tree_sitter_c, .query = @embedFile(query_dir ++ "c/highlights.scm") },
    .{ .name = "cpp", .func = tree_sitter_cpp, .query = @embedFile(query_dir ++ "cpp/highlights.scm") },
    .{ .name = "html", .func = tree_sitter_html, .query = @embedFile(query_dir ++ "html/highlights.scm") },
    .{ .name = "css", .func = tree_sitter_css, .query = @embedFile(query_dir ++ "css/highlights.scm") },
    .{ .name = "lua", .func = tree_sitter_lua, .query = @embedFile(query_dir ++ "lua/highlights.scm") },
    .{ .name = "python", .func = tree_sitter_python, .query = @embedFile(query_dir ++ "python/highlights.scm") },
    .{ .name = "kotlin", .func = tree_sitter_kotlin, .query = @embedFile(query_dir ++ "kotlin/highlights.scm") },
    .{ .name = "gleam", .func = tree_sitter_gleam, .query = @embedFile(query_dir ++ "gleam/highlights.scm") },
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "highlighter: init registers all grammars" {
    var hl = try Highlighter.init(std.testing.allocator);
    defer hl.deinit();

    try std.testing.expect(hl.languages.count() == 24);
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
