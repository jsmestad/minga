const std = @import("std");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

/// Tree-sitter highlighter. Owns a parser, optional tree, and query.
/// Grammar languages are registered at init time (compiled-in) or
/// loaded dynamically via `loadGrammar`.
pub const Highlighter = struct {
    parser: *c.TSParser,

    pub fn init() !Highlighter {
        const parser = c.ts_parser_new() orelse return error.ParserCreateFailed;
        return .{ .parser = parser };
    }

    pub fn deinit(self: *Highlighter) void {
        c.ts_parser_delete(self.parser);
    }
};

test "tree-sitter smoke test: parser creates and destroys" {
    var hl = try Highlighter.init();
    defer hl.deinit();
}
