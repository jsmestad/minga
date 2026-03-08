# Rendering Architecture Gaps

What established editors (Emacs, Neovim, Helix, Zed) have as architectural primitives that Minga is missing, and how to close the gaps. This is the reference document for the rendering refactor work.

## Context

Minga's two-process architecture (BEAM for logic, Zig for terminal output) is sound. The BEAM side's concurrency model, process isolation, and supervision are genuine advantages. The gap isn't in the macro architecture; it's in the rendering pipeline within the BEAM process. Specifically, Minga lacks the intermediate abstractions that make rendering composable, incremental, and debuggable.

## Gap 1: No Damage Tracking

**Impact: High. This is the single biggest gap.**

Every mature editor tracks *what changed*, not *what to draw*. Minga redraws everything, every frame.

**What the others do:**
- **Emacs** marks individual lines and windows as "dirty." Its `redisplay` engine walks the window tree and only touches invalidated regions.
- **Neovim** uses a per-window grid model. Buffer edits produce line-level deltas (`nvim_buf_lines_event`). The UI layer only updates affected grid rows.
- **Helix** maintains a virtual terminal buffer and diffs frame N against frame N-1.
- **Zed** has a GPU scene graph; only dirty subtrees trigger re-rendering.

**What Minga does:** `Renderer.render/1` starts with `Protocol.encode_clear()`, fetches all visible lines, rebuilds every gutter entry, every modeline, every line of content, and sends all of it to Zig. The Zig side (libvaxis) does cell-level diffing before writing to the terminal, which saves at the output layer. But the BEAM side still does O(visible_lines) work and serializes it across the Port boundary on every keystroke.

**The fix:** A dirty-line set per window. When a buffer edit happens, mark affected lines dirty. When rendering, only rebuild draw commands for dirty lines. Keep the previous frame's command list and splice in replacements. This alone would cut per-frame work by 90%+ for single-character edits.

## Gap 2: Window Is Not a Self-Contained Render Unit

**Impact: High. This causes code duplication and makes windows fragile.**

In Emacs, Neovim, and Helix, a window is the fundamental unit of rendering. Each window owns its own viewport, display state, and rendering lifecycle. You can render one window without touching any other.

**What Minga does:** There are two completely separate render paths: `render_single/1` (~200 lines) and `render_split/1` (different code path). The single-window path does inline viewport math, fetches data, builds highlights, and emits commands all in one function. The split path calls `render_window_content/5` per window, which is a partial duplicate with slightly different viewport logic (`scroll_to_cursor_modeline_only` vs the normal version).

This duplication is the symptom. The disease is that a `Window` struct is just `{id, buffer, viewport, cursor}`. It doesn't carry its own render state.

**What a Window should own:**
```elixir
%Window{
  id: pos_integer(),
  buffer: pid(),
  viewport: Viewport.t(),
  cursor: position(),
  # These are currently recomputed from scratch every frame:
  gutter_width: non_neg_integer(),
  wrap_map: WrapMap.t() | nil,
  dirty_lines: MapSet.t(),       # which lines need redraw
  cached_commands: [binary()],   # previous frame's draw commands
  highlight_snapshot: map(),     # cached highlight data for this window
}
```

With this, `render/1` becomes one path that iterates over all windows (including the single-window case) and calls the same render function on each.

## Gap 3: No Render Pipeline Stages

**Impact: Medium. Hurts debuggability and makes optimization hard to target.**

Mature editors have explicit, named stages in their render pipeline. Minga's is a monolithic function.

**How the others structure it:**
- **Emacs:** Buffer content → Glyph matrix → Terminal update
- **Neovim:** State change → Grid update → TUI diff → Terminal write
- **Helix:** Document change → View update → Virtual terminal → Flush
- **Zed:** Layout tree → Scene graph → GPU batch → Present

**Minga's current pipeline (all in `Renderer.render/1`):**
1. Fetch data from buffer GenServer
2. Compute layout
3. Compute viewport scroll
4. Compute gutter dimensions
5. Compute visual selection bounds
6. Compute search highlights
7. Build gutter commands
8. Build line commands
9. Build modeline commands
10. Build minibuffer commands
11. Build overlay commands (whichkey, completion, picker)
12. Build tree commands
13. Build agent panel commands
14. Resolve cursor position
15. Concatenate all commands
16. Send to Port

That's ~15 responsibilities in one pass. When something goes wrong visually, you can't easily isolate which stage produced the bad output.

**What a pipeline should look like:**
```
1. Invalidation  — mark dirty windows/lines from the event
2. Layout        — recompute rects only if layout-affecting state changed (already cached)
3. Scroll        — adjust viewport per dirty window
4. Content       — rebuild draw commands only for dirty lines per window
5. Chrome        — modeline, minibuffer, overlays (only if their inputs changed)
6. Compose       — merge window commands + chrome into final command list
7. Emit          — send to Port
```

Each stage has clear inputs, clear outputs, and can be cached or skipped independently.

## Gap 4: No Intermediate Representation (Display List)

**Impact: High. Blocks damage tracking, BEAM-side diffing, and multi-frontend rendering.**

The others all have an intermediate representation between "editor state" and "terminal bytes."

- **Emacs** has the *glyph matrix*: a 2D grid of styled characters per window.
- **Neovim** has *screen grids*: per-window cell arrays that the TUI layer diffs.
- **Helix** uses `tui::buffer::Buffer`, a virtual terminal you write into and then diff.
- **Zed** has a scene graph of render primitives.

**Minga skips this layer entirely.** The renderer produces binary protocol commands (`draw_text` opcodes) directly from editor state. There's no in-memory representation of "what's currently on screen from the BEAM's perspective." This means:

- You can't diff frame N-1 against frame N on the BEAM side.
- You can't ask "what's at row 5, col 10?" without re-rendering.
- You can't do partial updates because you don't know what the previous state was.

**The fix: A display list of styled text runs, not a cell grid.**

A cell grid (row × col → character + style) is terminal-shaped. It works for a TUI, but Minga is planning macOS and Linux GUI frontends where rendering uses proportional font engines, subpixel positioning, and variable line heights. A cell grid forces GUI frontends to fake a terminal, which is the wrong abstraction.

Instead, the BEAM-side IR should be **styled text runs organized by line, within positioned rectangular regions (windows)**. This is the same approach Neovim's UI protocol uses internally: its `grid_line` events send styled text chunks, not individual cells. The TUI frontend converts those runs into terminal cells. Remote GUIs (Neovide, etc.) convert the same runs into GPU draw calls. Same editing model, different output formats.

The key insight: Minga is a monospaced editor. Even in a GUI, the editing area uses a monospaced font, so "column 5" always means a deterministic position. The IR stays line-and-column based. It just doesn't pre-split text into individual cells on the BEAM side.

```elixir
# A styled run of text: "draw these characters in this style"
@type style :: %{fg: color(), bg: color(), bold: boolean(), italic: boolean(), ...}
@type text_run :: {col :: non_neg_integer(), text :: String.t(), style :: style()}

# A line's visual content: a list of runs that together cover the line
@type display_line :: [text_run()]

# A window's frame: its rectangle + the visible lines
@type window_frame :: %{
  rect: rect(),
  lines: %{row :: non_neg_integer() => display_line()},
  cursor: {row :: non_neg_integer(), col :: non_neg_integer()},
  gutter: %{row :: non_neg_integer() => display_line()}
}

# A full frame: all windows + chrome
@type frame :: %{
  windows: [window_frame()],
  modelines: [window_frame()],
  minibuffer: display_line(),
  overlays: [overlay()]
}
```

Each frontend then does the last-mile translation:

- **Terminal (Zig/libvaxis):** Converts text runs into cell writes. `{5, "hello", green}` becomes five green cells at columns 5-9. libvaxis diffs against its internal cell grid and emits only changed terminal sequences. This is essentially what happens today, just with a cleaner input.
- **macOS GUI:** Converts text runs into Core Text attributed string draws at pixel position `(col * cell_width, row * cell_height)`.
- **Linux GUI:** Same idea with whatever rendering toolkit is chosen.

Diffing happens at the display list level: compare frame N-1's `[text_run()]` for a given line against frame N's. If they match, skip that line entirely. If they differ, send the new runs. This gives the BEAM full knowledge of "what's on screen" without committing to a terminal-specific cell model.

The `Port.Frontend` behaviour is the natural place for each backend to translate from this shared IR to its native primitives.

## Gap 5: Layout Has No Constraint System

**Impact: Low now, Medium later as UI complexity grows.**

Minga's `Layout.compute/1` is a waterfall: minibuffer takes 1 row, file tree takes its width, agent panel takes 35% of height, windows get the rest.

**What the others have:**
- **Emacs**: `window-min-height`, `window-min-width`, `fit-window-to-buffer`, window configuration save/restore
- **Neovim**: `winwidth`, `winheight`, `winminwidth`, `winminheight`, `winfixwidth`, `winfixheight`, `equalalways`
- **Zed**: A full flexbox-like layout engine (GPUI)
- **Helix**: Fixed layout but with proportional splits that handle edge cases

**What Minga is missing:** Min/max constraints on any region. What happens when the terminal is 10 columns wide and the file tree wants 30? The `max()` calls in `file_tree_layout` handle the crash case, but they don't produce a *good* layout. There's no "this element has priority, that one shrinks first" system.

## Gap 6: Coupling Between Editor State and Render Decisions

**Impact: Medium. Makes the renderer hard to test and reason about.**

The renderer reads deeply into `EditorState` to make decisions: `state.mode`, `state.mode_state`, `state.highlight`, `state.completion`, `state.agent`, `state.picker_ui`, etc. This coupling means every render touches the full state struct, making it hard to know what actually affects the visual output.

**What the others do:**
- **Neovim** has a clean UI protocol. The core produces structured events (`grid_line`, `grid_cursor_goto`, `msg_show`). The UI consumer only sees these events.
- **Helix** uses a `Compositor` with a stack of `Component` trait objects. Each component renders independently given a limited context.
- **Zed** uses GPUI elements that receive only their relevant props.

Minga's renderer takes the entire EditorState. Each UI element (gutter, content area, modeline, minibuffer, agent panel, picker, whichkey) should be a component that receives only the data it needs and produces draw commands independently.

## The Root Issue

All six gaps point to the same underlying problem: **Minga treats rendering as a side effect of state, not as a composable system with its own lifecycle.**

The render function is called imperatively (`Renderer.render(state)`) at the end of every event handler. It produces draw commands directly from the full editor state. There's no intermediate step where you describe what the screen *should* look like and then let a reconciliation system figure out the minimal changes.

The editors that feel "reliable and clean" all share one trait: they separate *describing the UI* from *updating the terminal*. Emacs builds glyph matrices. Neovim sends UI events. Helix writes to a virtual buffer. Zed builds a scene graph. The rendering system then owns the "how do we get from here to there" problem.

## Recommended Priority Order

Ordered by dependency (each item enables the ones below it) and impact:

| Priority | Gap | Effort | Why this order |
|----------|-----|--------|----------------|
| 1 | Unify render paths (Gap 2, partial) | Low | Eliminates duplication, makes everything else simpler |
| 2 | Per-window render state (Gap 2, full) | Medium | Enables damage tracking and caching |
| 3 | Dirty-line tracking (Gap 1) | Medium | Biggest per-frame performance win |
| 4 | BEAM-side cell grid (Gap 4) | Medium | Biggest protocol bandwidth win |
| 5 | Render pipeline stages (Gap 3) | Medium | Best for debuggability and maintainability |
| 6 | Component model (Gap 6) | Medium | Best for testability and isolation |
| 7 | Layout constraints (Gap 5) | Low | Best for edge-case robustness |

Items 1 and 2 can be done together as a single refactor that sets the foundation for everything else.
