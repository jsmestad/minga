# Variable-width fonts in GUI frontends

**Status:** Design proposal — tracking only. Do not implement until a feature requires variable-width rendering.

**Tracking issue:** #1438

## Problem

Minga's display-list IR speaks character columns: each draw command names a `{col, text, style}` triple, and column units assume monospace. Every consumer downstream — chrome layout, cursor placement, mouse hit-tests, search highlights, the gutter — multiplies columns by an implicit cell width to land in screen space.

For features that want proportional fonts (Inter for chrome, JetBrains Mono Variable for code, ligature support, italic glyph metrics) that assumption fails. The naive workaround is "let the BEAM ask the frontend for character widths." That route is a latency disaster:

- Cursor placement after every keystroke would round-trip across the port to measure preceding characters on the cursor line.
- Mouse hit-tests in `Mouse.translate_click/2` would round-trip to resolve a pixel `(x, y)` to a `(line, col)` cursor position.
- The Layout stage would round-trip to know how wide a chrome label renders before computing the editor area.
- A horizontal scroll command would round-trip to know how many pixels a column shift costs.

At terminal cadence (every keystroke, every mouse move) those round-trips are intolerable. The port boundary is the constraint that monospace papers over.

## What we won't do

**We won't extend the existing IR by carrying pixel widths alongside columns.** That keeps the BEAM authoritative on layout, requires the frontend to return measurements eagerly for every glyph, and recreates the round-trip tax in different clothing. Atom (the editor) tried this and abandoned it.

**We won't ship monospace-only forever.** GUI users want proper chrome typography even when they keep monospace code; the architecture has to admit a path.

## Recommended direction: the frontend owns line layout

When the team is ready, push more layout responsibility into the frontend. The BEAM sends *semantic* draw intent ("at line 12, render this run of styled text spans, with a cursor at logical column 7"); the frontend owns measurement, line layout, and pixel placement. Cursor and hit-test coordinates are exchanged only at boundaries, asynchronously where possible.

This mirrors how Zed works in-process and how modern GUI editors handle the same problem when they can't share an address space with their layout engine.

### Protocol shape (sketch)

A new IR variant, sent from the BEAM to the GUI frontend per dirty window per frame:

```
window_paint {
  window_id: u32,
  rect:      {x, y, w, h},          // pixel rect from the latest layout
  lines:     [LineSpec, ...],
  cursor:    LogicalCursor | null,  // {line, col, shape}
  selection: [LogicalRange, ...],   // {start_line, start_col, end_line, end_col}
  decorations: [Decoration, ...],   // diagnostics, search hits, semantic tokens
}

LineSpec {
  buf_line:  u32,           // logical line in the buffer
  spans:     [Span, ...],   // runs of styled text
  gutter:    GutterSpec,
}

Span {
  text:  String,
  style: u32,               // index into a style table sent once per theme
}
```

Logical (line, column) units stay column-based on the wire — the BEAM continues to think in characters, which keeps every text-editing primitive (motions, text objects, marks, undo) unchanged. The frontend converts logical → pixel locally using its native typography engine (Core Text on macOS, FreeType on Linux, DirectWrite on Windows).

### Cursor and hit-test exchange

Cursor pixel position is the one place the frontend has to talk back to the BEAM, but only on demand. Two query callbacks:

- **`cursor_pixel_at(window_id, line, col) -> {x, y}`**: requested by the BEAM only when it needs an exact pixel coordinate (e.g., for an absolute-positioned float anchored on the cursor — hover tooltips, signature help). Most frames don't need this; the cursor is part of `window_paint` and the frontend places it itself.
- **`hit_test(window_id, x, y) -> {line, col}`**: requested by the GUI itself in response to a click, before forwarding the click event to the BEAM. The BEAM never originates `hit_test`; it only consumes the resolved `(line, col)` from the click event.

Both are synchronous within the GUI process, never round-trip the port. The port carries only the resolved logical coordinate.

### What stays monospaced internally

The BEAM keeps treating buffers as `{line, col}` grids:

- All motions and text objects (`w`, `b`, `iw`, `at`) work on character columns. Variable-width fonts don't change "the next word."
- Visual block mode stays a logical column rectangle. The frontend rasterises it as a non-rectangular pixel shape if the font is proportional; the model is unaffected.
- Marks, jumps, change tracking — all column-based. No change.
- Search highlights ship as `LogicalRange`s; the frontend draws boxes around the rendered runs.
- Folds remain a logical line range.

The only places the BEAM talks pixels: window rectangles (already pixel-based on the GUI side via `LayoutGUIBridge`) and the two query callbacks above.

## Features that change

| Feature | Today (monospace) | After |
|---|---|---|
| Cursor placement | `col * cell_width` | Frontend reads cursor from `window_paint`, places using its layout |
| Visual selection | Pixel-perfect rectangle | Frontend draws shape around span ranges |
| Visual block | Pixel-perfect rectangle | Frontend renders one rect per row of the logical block |
| Search match highlight | Background fill at `{col, len}` | Frontend draws box around span range; box may be non-rectangular |
| Diagnostic underline | `col_start..col_end` underline | Frontend renders squiggle under span range |
| Inlay hints | Insert run at column | Run is part of a `LineSpec.spans`; frontend lays out around it |
| Gutter | `gutter_width` columns reserved | Gutter is its own pixel region in `LineSpec.gutter`; frontend chooses width |
| Horizontal scroll (`zh`/`zl`) | Shift `viewport.left` by `n` columns | Same; frontend shows whatever fits |
| Tab stops | Already configurable (`'tabstop'`) | No change |
| Wrap at column | Optional today | Wrap point becomes pixel-based when proportional; ship as a frontend setting |
| Mouse click → cursor | BEAM divides x by cell_width | Frontend's `hit_test` resolves; BEAM gets `(line, col)` |
| Drag-select | Same | Same; each drag tick goes through `hit_test` |
| Modeline | Column-spaced segments | Modeline becomes a flex layout in chrome; specs ship as `[ChromeSegment]` |
| Tab bar | Column-spaced labels | Same — chrome layout in the frontend |
| Whichkey popup | Column grid | Frontend lays out; BEAM ships `[(key, label, group)]` |
| Picker | Column grid | Frontend handles; spec is a list of items + match ranges |

The features that *don't* change (motions, marks, text objects, undo, the buffer model itself) are the majority — that's the win of keeping logical units on the wire.

## Migration path

When a feature wants variable width:

1. **Phase 1:** ship `window_paint` as a new opcode alongside the existing `draw_text` series. GUI frontends can opt in per window via a capability bit (`incremental_layout`); TUI frontends never opt in. BEAM emits whichever opcode set the frontend negotiated at startup.
2. **Phase 2:** convert chrome (modeline, tab bar, popups) to the new spec shape. Chrome is the easiest win because its content is small and the BEAM doesn't currently reason about chrome character widths anyway.
3. **Phase 3:** convert buffer rendering. This is the hard part — `Renderer.Line`, `Renderer.SearchHighlight`, `Renderer.Gutter`, and friends become spec emitters. The Stage 1 invalidation work (#1431) helps because dirty information already scopes what to re-emit.
4. **Phase 4:** add the `hit_test` callback for click handling and `cursor_pixel_at` for floats. These are the only synchronous BEAM↔frontend round-trips and should be rare per frame.

Each phase is shippable on its own. The TUI frontend always uses the existing IR.

## Open questions

- **Style table churn.** Today every `draw_text` carries a style index that maps to a `Theme` slot. With many proportional spans per frame, that table grows. Consider per-frame interning vs. per-theme prebuilt table.
- **Wrap mode.** Soft wrap on column is ill-defined when characters have varying widths. Ship as a frontend setting; the BEAM only knows "wrap is on, here's the available pixel width per line."
- **Horizontal scroll semantics.** `zh`/`zl` shift by columns today. With proportional fonts, "one column" may not equal "one logical column of text." Either (a) keep column semantics and let the frontend interpret, or (b) shift by character offset and let the frontend pick how far that scrolls in pixels. Option (a) is simpler.
- **Ligatures.** A run of three characters that renders as one glyph (e.g., `!=`) breaks the assumption that `n` characters take `n` cells. Ligatures are a frontend concern under this design — the BEAM ships the underlying characters, the frontend draws whatever its font says.
- **Fallback fonts.** Mixed scripts (English text with CJK insertions) require font fallback. Same answer: frontend handles it.

## Reference points

- **Zed:** single-process renderer with shared-memory access to the layout engine. No port boundary, so the architecture above is unnecessary.
- **VS Code:** electron + DOM. The frontend (Chromium) owns line layout via CSS; the editor model is column-based. Same shape as this proposal — proves the architecture works at scale.
- **Neovim:** monospace by structural assumption. UI plugins draw chrome with their own conventions but the buffer rendering is grid-based.
- **Helix:** monospace.
- **Atom (historical):** attempted variable-width for code. The cursor stability and selection-shape problems were severe; eventually abandoned for monospace code with optional proportional chrome. Lessons: keep code monospace by default, ship proportional chrome first.

## Decision

**Don't implement until a feature forces it.** When that happens, the right starting point is `window_paint` for chrome (cheap, contained, learns the protocol shape) before touching buffer rendering. The recommendation here is the architecture, not a backlog plan.
