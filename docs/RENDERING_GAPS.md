# Rendering Architecture: Current State

How Minga's rendering pipeline compares to established editors (Emacs, Neovim, Helix, Zed), and what was done to close the gaps.

This document was originally written to identify missing architectural primitives. All six gaps have been addressed. The sections below describe what was built, with references to the implementing code.

## Architecture Overview

Minga's two-process architecture (BEAM for logic, Zig for terminal output) remains the foundation. The BEAM side owns all rendering decisions: layout, content composition, dirty tracking, caching. The Zig side is a thin terminal adapter that receives draw commands and puts cells on screen via libvaxis.

The rendering pipeline lives in `Minga.Editor.RenderPipeline` and runs seven named stages per frame:

1. **Invalidation** — detects what changed since the last frame
2. **Layout** — computes screen rectangles via `Layout.put/1`
3. **Scroll** — per-window viewport adjustment + buffer data fetch
4. **Content** — builds display list draws for dirty lines only
5. **Chrome** — modeline, minibuffer, overlays, separators, file tree, agent panel
6. **Compose** — merges content + chrome into a `Frame` struct
7. **Emit** — converts frame to protocol commands and sends to the Zig port

Each stage is a public function with typed inputs/outputs and per-stage timing via `Logger.debug`.

## Gap 1: Damage Tracking ✅

**Ticket:** [#164](https://github.com/jsmestad/minga/issues/164) (closed)

**Implementation:** `Minga.Editor.Window` carries a `dirty_lines` field with two representations:
- `:all` for full redraw (scroll, resize, theme change, highlight update)
- A map of specific buffer line numbers for targeted invalidation (single edits)

Two detection mechanisms run automatically each frame:
- **Structural invalidation** (`Window.detect_invalidation/5`): compares viewport scroll position, gutter width, line count, and buffer version against last-frame tracking fields.
- **Context invalidation** (`Window.detect_context_change/2`): compares a fingerprint of render context (visual selection, search matches, highlight version, diagnostic signs, git signs, horizontal scroll, active status) against the previous frame.

Clean lines reuse cached draws. Dirty lines re-render and update the cache. For a single-character edit, only one line is re-rendered instead of every visible line.

**Code:** `lib/minga/editor/window.ex` (dirty tracking, cache management), `lib/minga/editor/render_pipeline.ex` (dirty-aware content loop in `render_lines_nowrap/2`)

## Gap 2: Window as Self-Contained Render Unit ✅

**Tickets:** [#162](https://github.com/jsmestad/minga/issues/162), [#163](https://github.com/jsmestad/minga/issues/163) (both closed)

**Implementation:** The `Window` struct now carries its own render state:

```elixir
%Window{
  id: id(),
  buffer: pid(),
  viewport: Viewport.t(),
  cursor: Document.position(),
  dirty_lines: :all | %{line => true},
  cached_gutter: %{line => [draw()]},
  cached_content: %{line => [draw()]},
  last_viewport_top: integer(),
  last_gutter_w: integer(),
  last_line_count: integer(),
  last_cursor_line: integer(),
  last_buf_version: integer(),
  last_context_fingerprint: term()
}
```

There is one render path that iterates over all windows (single or split) and calls the same `build_window_content/2` function on each. The old `render_single/1` vs `render_split/1` duplication is gone.

Cache pruning (`Window.prune_cache/3`) keeps cached draws bounded to the visible line range, preventing memory growth as the user scrolls.

**Code:** `lib/minga/editor/window.ex`, `lib/minga/editor/render_pipeline.ex` (unified `build_content/2`)

## Gap 3: Named Pipeline Stages ✅

**Ticket:** [#166](https://github.com/jsmestad/minga/issues/166) (closed)

**Implementation:** `Minga.Editor.RenderPipeline` decomposes rendering into seven stages (listed above). Each stage is a public function with a typed spec. The `timed/2` wrapper logs elapsed microseconds per stage at debug level.

Stage result types are defined as module structs: `Invalidation`, `WindowScroll`, `Chrome`. The `Frame` and `WindowFrame` structs live in `Minga.Editor.DisplayList`.

**Code:** `lib/minga/editor/render_pipeline.ex`

## Gap 4: Display List IR ✅

**Ticket:** [#165](https://github.com/jsmestad/minga/issues/165) (closed)

**Implementation:** `Minga.Editor.DisplayList` defines a styled text run IR between editor state and protocol encoding:

- `draw()` — `{row, col, text, style}` tuples produced by all renderer modules
- `text_run()` — column + text + style (no row)
- `display_line()` — list of text runs for one screen row
- `render_layer()` — rows mapped to display lines
- `WindowFrame` — per-window display data (gutter, lines, tildes, modeline, cursor)
- `Frame` — complete frame (windows + chrome + overlays + regions + cursor)

`DisplayList.to_commands/1` converts a `Frame` to protocol command binaries for the TUI. Other frontends (GUI, headless) can consume the `Frame` directly without going through the binary protocol.

**Code:** `lib/minga/editor/display_list.ex`

## Gap 5: Layout Constraints ✅

**Ticket:** [#168](https://github.com/jsmestad/minga/issues/168) (closed)

**Implementation:** `Minga.Editor.Layout` computes all rectangles from a single `Layout.put/1` call. The layout is the single source of truth for all screen positions. Mouse hit-testing, rendering, and region definitions all reference `Layout.get(state)` rects.

**Code:** `lib/minga/editor/layout.ex`

## Gap 6: Component Model ✅

**Ticket:** [#167](https://github.com/jsmestad/minga/issues/167) (closed)

**Implementation:** UI elements are separate renderer modules that receive only the data they need:

- `Renderer.BufferLine` — per-line content rendering
- `Renderer.Gutter` — line numbers and sign column
- `Renderer.Minibuffer` — command/search input
- `Renderer.SearchHighlight` — search match highlighting
- `Renderer.Regions` — region definitions from layout
- `Editor.Modeline` — mode, file, cursor info
- `Editor.TreeRenderer` — file tree sidebar
- `Editor.PickerUI` — fuzzy finder overlay
- `Editor.CompletionUI` — completion menu
- `Agent.ChatRenderer` — agent panel sidebar
- `Agent.View.Renderer` — full-screen agent view

Each module produces `[DisplayList.draw()]` lists. The pipeline's Chrome stage collects them; the Compose stage merges them into the final `Frame`.

**Code:** `lib/minga/editor/renderer/` (BufferLine, Gutter, Minibuffer, SearchHighlight, Regions, Caps, Context)

## Performance Characteristics

With all gaps closed, the rendering pipeline has these properties:

- **Single-character edits** re-render one line (the dirty line), not every visible line. Cached draws for clean lines are reused.
- **Cursor movement** with absolute line numbering dirties only the old and new cursor lines (2 lines). With relative numbering, all gutter entries are dirty but content draws are reused.
- **Scroll** triggers a full redraw (`:all` dirty) because every visible line changes. libvaxis handles cell-level diffing on the Zig side.
- **Context changes** (entering/leaving visual mode, search highlight updates, new syntax highlights) trigger full redraws via the context fingerprint mechanism.
- **Per-stage timing** is available at debug log level for profiling.

## Relationship to the Zig Renderer

The Zig side (`zig/src/renderer.zig`) is intentionally thin: ~430 lines that translate protocol commands into libvaxis cell writes. It handles:

- `draw_text` — grapheme iteration, display width calculation, cell writes with region clipping
- `set_cursor` / `set_cursor_shape` — cursor positioning
- `define_region` / `set_active_region` / `clear_region` — region management
- `batch_end` — triggers libvaxis frame diff and terminal flush

libvaxis provides cell-level diffing (only changed cells are written to the terminal), grapheme cluster handling, and terminal capability detection. The BEAM side's dirty-line tracking reduces how much data crosses the Port boundary; libvaxis's cell diffing reduces how much data hits the terminal. Both layers contribute to rendering efficiency.

The `Surface` interface (`zig/src/surface.zig`) abstracts the terminal backend, enabling future backends (e.g., a Metal-based GUI surface) to implement the same 7-method interface without changing the renderer or protocol.
