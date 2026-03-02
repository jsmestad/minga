# Plan: Tree-sitter Syntax Highlighting (#34)

## Goal

Add real-time syntax highlighting powered by tree-sitter. Ship with 20+
compiled-in grammars, runtime `dlopen` for user grammars, highlight queries
loaded from disk, and a Doom One theme. As a prerequisite, refactor the gap
buffer from grapheme-indexed to byte-indexed positions — this eliminates O(n)
grapheme scanning on every operation (100-24,000x faster), aligns with
tree-sitter's byte-offset model, and makes the highlight integration zero-cost.

## Context

### The grapheme problem

The gap buffer currently stores `cursor_col` as a grapheme index. This means:

| Operation | Current (grapheme) | After refactor (byte) | Speedup |
|-----------|-------------------|-----------------------|---------|
| `byte_size` vs `String.length` | O(n) | O(1) | **212x** |
| `binary_part` vs `split_at_grapheme` | O(n) | O(1) | **24,000x** |
| `move_to` offset calculation | O(n) grapheme scan | O(n) byte_size sum | **5x** |

Every cursor move, insert, delete, motion, and rendered line hits these paths.
88 call sites across 37 files use grapheme-indexed operations. Tree-sitter
returns byte offsets — if the buffer uses byte offsets natively, the highlight
integration requires zero conversion.

**Key invariant**: For ASCII content (>95% of code), byte offset == grapheme
index. Behavior only diverges for multi-byte UTF-8 (é = 2 bytes/1 grapheme,
emoji = 4+ bytes/1 grapheme). The refactor changes internal representation
only — external behavior (cursor appears at the right character) is preserved
by converting byte→grapheme at the rendering boundary.

### Existing architecture

- **Port protocol**: BEAM ↔ Zig, `{:packet, 4}` length-prefixed binary.
  Opcodes 0x01–0x04 Zig→BEAM; 0x10–0x15 BEAM→Zig.
- **Rendering**: `Editor.Renderer` → `Renderer.Line` → `Protocol.encode_draw/4`
  already supports per-draw `fg`/`bg`/attrs.
- **Filetype detection**: `Minga.Filetype` detects language, stored in buffer
  state, available in `render_snapshot`.
- **Event loop**: Both TUI and GUI: read stdin → `decodeCommand()` →
  `rend.handleCommand()`. Events sent via `writeMessage(stdout)`.
- **Zig build**: `build.zig` + `build.zig.zon`. Zig 0.15.2, compiles C natively.

### Grammar inventory (24 grammars, all compiled-in)

| # | Language | Repo | Scanner? |
|---|----------|------|----------|
| 1 | Elixir | elixir-lang/tree-sitter-elixir | .c |
| 2 | HEEx | the-mikedavis/tree-sitter-heex | — |
| 3 | JSON | tree-sitter/tree-sitter-json | — |
| 4 | YAML | tree-sitter-grammars/tree-sitter-yaml | .c |
| 5 | TOML | tree-sitter/tree-sitter-toml | .c |
| 6 | Markdown | tree-sitter-grammars/tree-sitter-markdown | .c (×2) |
| 7 | Ruby | tree-sitter/tree-sitter-ruby | .c |
| 8 | JavaScript | tree-sitter/tree-sitter-javascript | .c |
| 9 | TypeScript | tree-sitter/tree-sitter-typescript | .c (ts+tsx) |
| 10 | Go | tree-sitter/tree-sitter-go | — |
| 11 | Rust | tree-sitter/tree-sitter-rust | .c |
| 12 | Zig | tree-sitter-grammars/tree-sitter-zig | — |
| 13 | Erlang | WhatsApp/tree-sitter-erlang | .c |
| 14 | Bash | tree-sitter/tree-sitter-bash | .c |
| 15 | C | tree-sitter/tree-sitter-c | — |
| 16 | C++ | tree-sitter/tree-sitter-cpp | .c |
| 17 | HTML | tree-sitter/tree-sitter-html | .c |
| 18 | CSS | tree-sitter/tree-sitter-css | .c |
| 19 | Lua | tree-sitter-grammars/tree-sitter-lua | .c |
| 20 | Python | tree-sitter/tree-sitter-python | .c |
| 21 | SQL | DerekStride/tree-sitter-sql | .c |
| 22 | GraphQL | bkegley/tree-sitter-graphql | — |
| 23 | Kotlin | fwcd/tree-sitter-kotlin | .c |
| 24 | Gleam | gleam-lang/tree-sitter-gleam | .c |

## Approach

### Data flow

```
1. BEAM detects filetype → :elixir
2. BEAM reads priv/queries/elixir/highlights.scm (or user override)
3. BEAM sends set_language("elixir") + query text to Zig
4. BEAM sends parse_buffer(version, content) to Zig
5. Zig parses with tree-sitter, runs highlight query
6. Zig sends highlight_names (once) + highlight_spans back
7. BEAM stores spans, maps capture names → theme colors via byte offsets
8. BEAM slices lines at span boundaries using binary_part (O(1))
9. BEAM emits draw_text commands with per-span fg/bg/attrs
```

### Key decisions

- **Byte-indexed positions throughout** — gap buffer, motions, operators,
  text objects all work in `{line, byte_col}`. Grapheme/display-width
  conversion happens only at the rendering boundary.
- **BEAM controls themes and queries** — Zig is a stateless parsing engine.
- **Grammar registry** — `highlighter.zig` uses `StringHashMap` for lookups,
  populated at init (compiled-in) and extendable at runtime (`dlopen`).
- **Version counter** — stale parse results discarded.
- **Full re-parse** — incremental parsing deferred to follow-up.
- **Queries on disk** — BEAM reads `.scm` files, sends to Zig. User can
  override by placing files in `~/.config/minga/queries/{lang}/`.

## Steps

### 0. Refactor gap buffer to byte-indexed positions

This is a mechanical refactor: `cursor_col` changes from grapheme index to
byte offset within the current line. Every downstream consumer adapts.

#### 0a. Core: `GapBuffer` internals
- **Files**: `lib/minga/buffer/gap_buffer.ex`, `test/minga/buffer/gap_buffer_test.exs`
- **Changes**:
  - `cursor_col` becomes byte offset within the current line
  - `@type position :: {line :: non_neg_integer(), byte_col :: non_neg_integer()}`
  - `move_to/2`: clamp col to `byte_size(line_text)`, use `byte_offset_for`
    (sum of `byte_size(line) + 1` for preceding lines) instead of
    `grapheme_offset_for`, use `binary_part` instead of `split_at_grapheme`
  - `insert_char/2`: update col with `byte_size(char)` instead of
    `String.length(char)`
  - `delete_before/1`: compute col change from `byte_size(removed)` instead of
    grapheme count; `pop_last_grapheme` already returns the removed bytes, just
    use `byte_size` of the result
  - `delete_at/1`: unchanged (operates on `after`, col doesn't change)
  - `move_left/1`: col change = `byte_size(char)` not 1
  - `move_right/1`: col change = `byte_size(grapheme)` not 1
  - `content_range/3`: use `byte_offset_for` + `binary_part`
  - `delete_range/3`: use `byte_offset_for` + `binary_part`
  - `get_range/3`: use `byte_offset_for` + `binary_part`
  - Remove `split_at_grapheme/2`, `do_split_at_grapheme/3`,
    `grapheme_offset_for/3` (dead code after refactor)
  - Rename `col_in_last_line/1` to use `byte_size` of last segment after
    last `\n`
  - `compute_cursor_after_insert/4`: use `byte_size` instead of
    `String.length`
  - Add `grapheme_col/2` — converts `{line, byte_col}` to grapheme column
    for display purposes (used only by the renderer)
  - Add `byte_col_for_grapheme/2` — converts a grapheme column to byte col
    (used by motions that need to reason about visible character positions)
  - Update all tests: position assertions change for non-ASCII content
    (ASCII tests unchanged since byte == grapheme for ASCII)

#### 0b. Motions
- **Files**: `lib/minga/motion/line.ex`, `lib/minga/motion/word.ex`,
  `lib/minga/motion/char.ex`, `lib/minga/motion/document.ex`,
  `lib/minga/motion/helpers.ex` + their test files
- **Changes**:
  - `line_end/2`: `byte_size(text)` instead of `String.length(text) - 1`.
    Note: byte offset of last grapheme, not past-end. Need
    `byte_size(text) - byte_size_of_last_grapheme(text)`. OR: keep the
    semantic "col of last character" but in byte units. Define helper
    `last_grapheme_byte_offset/1`.
  - `first_non_blank/2`: walk with `String.next_grapheme`, accumulate byte
    offset instead of incrementing col by 1
  - `find_char_forward/3`, `find_char_backward/3`: scan text tracking byte
    offset instead of grapheme index
  - `word_forward/2`, `word_backward/2`, `word_end/2` etc: convert to work
    with byte offsets. `Helpers.offset_for` returns byte offset.
    `GapBuffer.offset_to_position` converts byte offset → `{line, byte_col}`
  - `match_bracket/2`: scan tracking byte positions
  - **Key**: motions compare characters (graphemes), but track positions in
    bytes. The scanning loop changes from `col + 1` to
    `col + byte_size(grapheme)`.

#### 0c. Operators and text objects
- **Files**: `lib/minga/operator.ex`, `lib/minga/text_object.ex` + tests
- **Changes**:
  - `Operator`: position arithmetic (`line_len`, range endpoints) switches
    to byte units
  - `TextObject`: grapheme scanning loops (`String.graphemes |> List.to_tuple`)
    replaced with byte-tracking iteration. `scan_left/3`, `scan_right/3`
    accumulate byte offsets. Quote/bracket matching uses byte positions.

#### 0d. Editor commands
- **Files**: `lib/minga/editor/commands/*.ex` + tests
- **Changes**:
  - Commands that construct positions (e.g., `{line, 0}`, `{line, col + 1}`)
    need to use byte arithmetic. Most are already fine since they call
    motions or gap buffer methods.
  - `editing.ex`: open-line, join-line position construction
  - `movement.ex`: mostly delegates to motions — minimal changes
  - `visual.ex`: position comparison/sorting — unchanged (byte offsets sort
    the same way as grapheme offsets for same-line comparisons)
  - `marks.ex`: stores positions — automatically correct once positions are
    byte-indexed

#### 0e. Renderer (display-width conversion)
- **Files**: `lib/minga/editor/renderer.ex`, `lib/minga/editor/renderer/line.ex`,
  `lib/minga/editor/renderer/gutter.ex`
- **Changes**:
  - `Renderer`: cursor placement converts `byte_col` → display column.
    Add `grapheme_display_col(line_text, byte_col)` helper that iterates
    graphemes up to `byte_col`, summing display widths.
  - `Renderer.Line`: `String.graphemes(line_text)` still used for iterating
    visible characters for drawing — this doesn't change (rendering always
    needs to walk graphemes for display width).
  - Viewport horizontal scroll (`left`) becomes byte-based internally but
    the visual scroll amount is still in display columns.
  - **This is the only place grapheme iteration is needed** — and it only
    runs for visible lines (~40 per frame), which is negligible.

#### 0f. Mode, search, picker, auto-pair
- **Files**: `lib/minga/mode/*.ex`, `lib/minga/search.ex`, `lib/minga/picker.ex`,
  `lib/minga/auto_pair.ex`
- **Changes**:
  - Search: match positions already come from `:binary.match` or regex
    which return byte offsets — this actually becomes simpler
  - Picker: string display operations stay grapheme-based (user-facing)
  - Auto-pair: position checks use byte offsets
  - Command/search modes: input string manipulation stays grapheme-based
    (input is user-facing text, not buffer positions)

#### 0g. Buffer.Server and render_snapshot
- **Files**: `lib/minga/buffer/server.ex`
- **Changes**:
  - `render_snapshot`: cursor position is now `{line, byte_col}`. No other
    changes needed — lines are still strings.
  - Add `content/0` wrapper if not already public (needed for parse_buffer)

### 1. Vendor tree-sitter core C library

- **Files**: `zig/build.zig`, `zig/vendor/tree-sitter/`
- **Changes**:
  - Download tree-sitter v0.24.x `lib/src/` and `lib/include/` into
    `zig/vendor/tree-sitter/`
  - Add static library step in `build.zig` that compiles `lib.c`
  - Link into exe and test targets
  - Verify `zig build` and `zig build test` pass

### 2. Vendor all grammar C sources

- **Files**: `zig/vendor/grammars/{language}/`, `zig/build.zig`
- **Changes**:
  - For each grammar: download `src/parser.c`, `src/scanner.c` (if present),
    `src/tree_sitter/parser.h`
  - Helper function in `build.zig`: `addGrammar(b, exe, name, has_scanner)`
  - TypeScript: vendor `typescript/` and `tsx/` sub-parsers separately
  - Markdown: vendor `tree-sitter-markdown/` and `tree-sitter-markdown-inline/`

### 3. Vendor highlight queries into priv/

- **Files**: `priv/queries/{language}/highlights.scm`
- **Changes**:
  - Download each grammar's `queries/highlights.scm`
  - TS inherits from JS query; C++ inherits from C
  - Git-tracked (small files, <50KB total)

### 4. Create `zig/src/highlighter.zig`

- **Files**: `zig/src/highlighter.zig`
- **Changes**:
  - `@cImport` tree-sitter `api.h`
  - Fields: `parser: *TSParser`, `tree: ?*TSTree`, `query: ?*TSQuery`,
    `languages: StringHashMapUnmanaged(*const TSLanguage)`, `allocator`
  - `init(alloc)` — create parser, populate registry with compiled-in grammars
  - `deinit()` — free parser, tree, query
  - `setLanguage(name) bool` — registry lookup, set parser language
  - `setHighlightQuery(source) !void` — compile query for current language
  - `parse(source) !void` — full parse, store tree
  - `highlight(source) !HighlightResult` — TSQueryCursor iteration,
    collect `{start_byte, end_byte, capture_id}` spans
  - `loadDynamic(name, lib_path) !void` — `std.DynLib` open + symbol lookup
  - Types: `Span { start_byte: u32, end_byte: u32, capture_id: u8 }`,
    `HighlightResult { spans: []Span, capture_names: [][]const u8 }`
  - Tests: parse Elixir source, verify keyword/string/comment spans

### 5. Protocol opcodes — Zig side

- **Files**: `zig/src/protocol.zig`
- **Changes**:
  - BEAM→Zig: `0x20 set_language`, `0x21 parse_buffer`,
    `0x22 set_highlight_query`, `0x23 load_grammar`
  - Zig→BEAM: `0x30 highlight_spans`, `0x31 highlight_names`,
    `0x32 grammar_loaded`
  - Decode 0x20–0x23 in `decodeCommand()`, new `RenderCommand` variants
  - Encode 0x30–0x32 functions
  - `commandSize()` updates
  - Round-trip tests

### 6. Integrate highlighter into Zig event loops

- **Files**: `zig/src/apprt/tui.zig`, `zig/src/apprt/gui.zig`
- **Changes**:
  - Both runtimes get a `Highlighter` instance
  - Intercept 0x20–0x23 in command dispatch (before renderer):
    - `set_language` → `highlighter.setLanguage(name)`
    - `set_highlight_query` → `highlighter.setHighlightQuery(query)`
    - `parse_buffer` → parse + highlight → encode + send `highlight_names`
      (first time) + `highlight_spans` via stdout
    - `load_grammar` → `highlighter.loadDynamic()` → send `grammar_loaded`
  - Renderer never sees these opcodes

### 7. Protocol opcodes — Elixir side

- **Files**: `lib/minga/port/protocol.ex`, `test/minga/port/protocol_test.exs`
- **Changes**:
  - Opcodes: `@op_set_language 0x20`, `@op_parse_buffer 0x21`,
    `@op_set_highlight_query 0x22`, `@op_load_grammar 0x23`,
    `@op_highlight_spans 0x30`, `@op_highlight_names 0x31`,
    `@op_grammar_loaded 0x32`
  - Encoding: `encode_set_language/1`, `encode_parse_buffer/2`,
    `encode_set_highlight_query/1`, `encode_load_grammar/2`
  - Decoding: `decode_event/1` for 0x30, 0x31, 0x32
  - Tests

### 8. `Minga.Theme` module

- **Files**: `lib/minga/theme.ex`, `test/minga/theme_test.exs`
- **Changes**:
  - `doom_one/0` — Doom One color map (~25 entries)
  - `style_for_capture(theme, name)` — exact match → strip suffix fallback →
    default `[]`
  - Capture names: `keyword`, `string`, `comment`, `function`, `type`,
    `number`, `operator`, `punctuation`, `variable`, `constant`, `module`,
    `attribute`, `tag`, `property`, `label`, `boolean`, `escape` + dotted
    variants (`keyword.function`, `punctuation.bracket`, etc.)
  - Tests: exact, prefix fallback, deep fallback, unknown → default

### 9. `Minga.Highlight` module

- **Files**: `lib/minga/highlight.ex`, `test/minga/highlight_test.exs`
- **Changes**:
  - Struct: `version`, `spans` (sorted by start_byte), `capture_names`,
    `theme`
  - `new/0` — empty state, default theme
  - `put_names(hl, names)` — store capture name list
  - `put_spans(hl, version, spans)` — store if version ≥ current
  - `styles_for_line(hl, line_text, line_start_byte)` — intersect spans with
    line byte range, split at boundaries using `binary_part` (O(1)),
    map to styles via theme. Returns `[{text_segment, style}]`
  - `byte_offset_for_line(lines, line_index)` — cumulative `byte_size + 1`
  - Tests: version gating, line splitting, Unicode byte alignment, empty spans

### 10. `Minga.Grammar` module

- **Files**: `lib/minga/grammar.ex`, `test/minga/grammar_test.exs`
- **Changes**:
  - `@filetype_to_language` map (24 entries)
  - `language_for_filetype(ft)` → `{:ok, name}` | `:unsupported`
  - `query_path(lang)` — user dir → priv dir search
  - `read_query(lang)` — reads `.scm` file content
  - `dynamic_grammar_path(name)` — `~/.config/minga/grammars/` path
  - Tests

### 11. Wire into Editor

- **Files**: `lib/minga/editor/state.ex`, `lib/minga/editor.ex`,
  `lib/minga/port/manager.ex`
- **Changes**:
  - `EditorState`: add `highlight: Highlight.t()`
  - `Port.Manager`: decode 0x30–0x32, forward as `{:minga_input, ...}`
  - `Editor` on buffer open/switch:
    1. `Grammar.language_for_filetype(filetype)` → language name
    2. `Grammar.read_query(language)` → query text
    3. Send `set_language` + `set_highlight_query` + `parse_buffer` to port
  - `Editor` on content change: send `parse_buffer(version++, content)`
  - `Editor` on highlight events: update `state.highlight`, re-render

### 12. Integrate into line rendering

- **Files**: `lib/minga/editor/renderer.ex`, `lib/minga/editor/renderer/line.ex`,
  `lib/minga/editor/renderer/context.ex`
- **Changes**:
  - `Context`: add `highlight: Highlight.t()`,
    `first_line_byte_offset: non_neg_integer()`
  - `Renderer`: compute first-line byte offset, pass to context
  - `Renderer.Line`: when highlights exist and no visual selection:
    1. Compute `line_start_byte` from context offset + preceding visible
       lines' `byte_size + 1`
    2. `Highlight.styles_for_line(hl, line_text, line_start_byte)` →
       `[{segment, style}]`
    3. Emit `encode_draw(row, col, segment, style)` per segment, advance
       col by grapheme display width of segment
    4. Search highlights overlay on top
  - Visual selection takes priority; syntax colors in non-selected regions
  - Empty highlights → current plain rendering (zero regression)

### 13. Tests

- Zig: `zig build test` — highlighter, protocol
- Elixir: Theme, Highlight, Grammar, Protocol, Renderer.Line
- Pre-commit: `mix lint`, `mix dialyzer`, `mix test --warnings-as-errors`
- Manual: open `.ex` file → keywords purple, strings green, comments gray
- Edge cases: empty file, syntax errors, unsupported filetype, Unicode,
  rapid typing, very long lines

## Current Status (2026-03-02)

### Completed (Steps 0–12 + performance work)
- ✅ Steps 0a–0f: Gap buffer byte-indexed refactor (all 88 call sites)
- ✅ Step 0 consolidation: `Minga.Buffer.Unicode` module (49 tests)
- ✅ Steps 1–3: Vendored tree-sitter v0.25.3 + 24 grammars + 23 query sets
- ✅ Steps 4–6: Zig highlighter, protocol opcodes, TUI integration
- ✅ Steps 7–10: Elixir protocol, Theme (Doom One), Highlight, Grammar modules
- ✅ Steps 11–12: Editor wiring, line rendering with syntax colors
- ✅ Bug fixes: overlapping spans, async setup timing, buffer switch stale
  highlights, UTF-8 safety with mismatched spans
- ✅ Per-buffer highlight cache (instant buffer switching)
- ✅ Centralized buffer-change detection (works for :e, SPC b n/p, SPC f f, picker)
- ✅ Tree-sitter upgraded to v0.25.3 (ABI 15 — all 24 grammars work)
- ✅ YAML scanner alignment fix (-fno-sanitize=undefined)
- ✅ ReleaseFast for vendored C code (query compile: 3,800ms → ~16ms)
- ✅ @embedFile queries in Zig binary (no port round-trip for query text)
- ✅ Background thread pre-compiles all 23 queries after startup
- ✅ Lazy compilation fallback in setLanguage (cache miss = ~16ms)
- ✅ Suppressed vaxis debug log bleeding into rendered output
- ✅ 12 integration tests for highlight lifecycle

### Test counts
- 1393 Elixir tests (41 doctests, 4 properties, 1348 unit) — all passing
- 105 Zig tests — all passing

### What to do next

#### 1. Normal-mode operator reparse (high impact, user-visible bug)
`dd`, `p`, `x`, `>>`, `<<`, and other normal-mode operators that mutate buffer
content don't trigger a highlight reparse. The user has to enter insert mode
for highlights to update. Fix: detect content mutations after command dispatch
(e.g., compare buffer content hash or version before/after) and call
`HighlightBridge.request_reparse/1` when content changed.

**Files**: `lib/minga/editor.ex` (key handler), `lib/minga/editor/highlight_bridge.ex`

#### 2. Step 0g: Render boundary byte→grapheme cleanup
The byte→grapheme display-width conversion at the render boundary needs a
cleanup pass. Some paths may still have redundant conversions or edge cases
with wide characters (CJK, emoji). Audit `Renderer.Line` and `Context` for
correctness with multi-byte/multi-width characters.

**Files**: `lib/minga/editor/renderer/line.ex`, `lib/minga/editor/renderer/context.ex`

#### 3. Step 13: Full test suite
- Integration tests for end-to-end highlighting through the headless harness
- Test: open file → verify colored output segments
- Test: edit in insert mode → verify reparse updates highlights
- Test: operator in normal mode → verify reparse (after fix #1)
- Test: unsupported filetype → no crash, plain rendering
- Test: empty file → no crash
- Test: syntax errors in file → partial highlighting still works
- Test: very long lines → horizontal scroll with highlights
- Property-based: random edits preserve highlight/buffer consistency

#### 4. User-customizable queries (polish)
Query override from `~/.config/minga/queries/{lang}/highlights.scm` works
on the Elixir side (`Grammar.read_query/1` checks user dir first), but the
Zig side now uses `@embedFile` for built-in queries. If a user provides a
custom query, the Elixir side needs to send it via `set_highlight_query`
which will override the pre-compiled one. Currently untested path — needs
integration test and possibly a `:reload_highlights` command.

#### 5. HEEx highlight queries
HEEx grammar is compiled in but has no highlight query. Write
`priv/queries/heex/highlights.scm` using the HEEx grammar's node types.
Low effort, useful for Phoenix developers.

#### 6. Incremental parsing (future optimization)
Full re-parse is <5ms for 10K-line files, so not urgent. When editing very
large files (50K+ lines), incremental parsing via `ts_parser_parse` with
edit info would reduce parse time to sub-millisecond. Requires tracking
byte-level edit deltas from gap buffer operations.

## Risks & Open Questions

1. ~~**Step 0 scope**~~ — Done. All 88 call sites migrated successfully.

2. ~~**`line_end` semantic**~~ — Solved via `Minga.Buffer.Unicode` helpers.

3. **Horizontal scroll**: Viewport `left` is display-column-based. Conversion
   to byte offset happens at render time. Needs audit with wide characters.

4. **Binary size**: 24 grammars + embedded queries ≈ 5MB. Acceptable.

5. ~~**Async highlights**~~ — Solved. With ReleaseFast C + background
   pre-compilation, first file highlights appear in ~16ms (effectively instant).

6. **Incremental parsing**: Deferred. Not needed until 50K+ line files.

7. **Thread safety**: Background prewarm thread accesses `query_cache` with a
   mutex. The `languages` hashmap is read-only after init (no mutex needed).
   `setLanguage` on the main thread does a lazy compile + cache insert under
   the same mutex. Double-check pattern prevents duplicate compilation.

## GitHub Ticket

Existing ticket: **#34** — "Editor displays syntax-highlighted code via
tree-sitter parsing". Steps 0–12 complete. Remaining: operator reparse,
test suite, render cleanup, user query overrides, HEEx queries.
