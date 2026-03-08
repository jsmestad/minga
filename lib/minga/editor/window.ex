defmodule Minga.Editor.Window do
  @moduledoc """
  A window is a viewport into a buffer.

  Each window holds a reference to a buffer process and its own independent
  viewport (scroll position and dimensions). Multiple windows can reference
  the same buffer; edits in one are visible in all.

  ## Render cache and dirty-line tracking

  Windows carry per-frame render state that enables incremental rendering.
  Instead of rebuilding draw commands for every visible line on every frame,
  the pipeline caches draws keyed by buffer line number and only re-renders
  lines marked as dirty.

  The dirty set uses two representations:
  - `:all` means every line needs re-rendering (used for scroll, resize,
    theme change, highlight update, and other wholesale invalidation)
  - A map of specific buffer line numbers (`%{line => true}`) that need re-rendering
    (used for edits that touch a few lines)

  Gutter and content caches are separate because cursor movement with
  relative line numbering dirties every gutter entry without changing
  content. This avoids re-rendering line text when only line numbers change.

  Tracking fields (`last_viewport_top`, `last_gutter_w`, `last_line_count`,
  `last_cursor_line`, `last_buf_version`) store the values from the previous
  frame. The Scroll stage compares current values against these to detect
  full-invalidation triggers automatically.
  """

  alias Minga.Buffer.Document
  alias Minga.Editor.DisplayList
  alias Minga.Editor.Viewport

  @typedoc "Unique identifier for a window."
  @type id :: pos_integer()

  @type t :: %__MODULE__{
          id: id(),
          buffer: pid(),
          viewport: Viewport.t(),
          cursor: Document.position(),
          dirty_lines: :all | %{optional(non_neg_integer()) => true},
          cached_gutter: %{optional(non_neg_integer()) => [DisplayList.draw()]},
          cached_content: %{optional(non_neg_integer()) => [DisplayList.draw()]},
          last_viewport_top: integer(),
          last_gutter_w: integer(),
          last_line_count: integer(),
          last_cursor_line: integer(),
          last_buf_version: integer()
        }

  @enforce_keys [:id, :buffer, :viewport]
  defstruct [
    :id,
    :buffer,
    :viewport,
    cursor: {0, 0},
    dirty_lines: %{},
    cached_gutter: %{},
    cached_content: %{},
    last_viewport_top: -1,
    last_gutter_w: -1,
    last_line_count: -1,
    last_cursor_line: -1,
    last_buf_version: -1
  ]

  @doc "Creates a new window with the given id, buffer, and viewport dimensions."
  @spec new(id(), pid(), pos_integer(), pos_integer()) :: t()
  def new(id, buffer, rows, cols)
      when is_integer(id) and id > 0 and is_pid(buffer) and
             is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    %__MODULE__{
      id: id,
      buffer: buffer,
      viewport: Viewport.new(rows, cols)
    }
  end

  @doc "Creates a new window with the given id, buffer, viewport dimensions, and cursor position."
  @spec new(id(), pid(), pos_integer(), pos_integer(), Document.position()) :: t()
  def new(id, buffer, rows, cols, cursor)
      when is_integer(id) and id > 0 and is_pid(buffer) and
             is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 and
             is_tuple(cursor) do
    %__MODULE__{
      id: id,
      buffer: buffer,
      viewport: Viewport.new(rows, cols),
      cursor: cursor
    }
  end

  @doc "Updates the viewport dimensions for this window, marking all lines dirty."
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(%__MODULE__{} = window, rows, cols)
      when is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    %{window | viewport: Viewport.new(rows, cols), dirty_lines: :all}
  end

  # ── Dirty-line tracking ───────────────────────────────────────────────────

  @doc """
  Marks specific buffer lines as needing re-render.

  Pass `:all` to force a complete redraw (scroll, resize, theme change, etc.).
  Pass a list of buffer line numbers for targeted invalidation (edits).
  If the window is already fully dirty, adding specific lines is a no-op.
  """
  @spec mark_dirty(t(), [non_neg_integer()] | :all) :: t()
  def mark_dirty(%__MODULE__{} = window, :all) do
    %{window | dirty_lines: :all}
  end

  def mark_dirty(%__MODULE__{dirty_lines: :all} = window, _lines), do: window

  def mark_dirty(%__MODULE__{dirty_lines: existing} = window, lines) when is_list(lines) do
    new_dirty = Enum.reduce(lines, existing, fn line, acc -> Map.put(acc, line, true) end)
    %{window | dirty_lines: new_dirty}
  end

  @doc "Marks all lines dirty (full redraw needed)."
  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{} = window) do
    %{window | dirty_lines: :all}
  end

  @doc """
  Returns true if the given buffer line needs re-rendering.

  Always true when `dirty_lines` is `:all`.
  """
  @spec dirty?(t(), non_neg_integer()) :: boolean()
  def dirty?(%__MODULE__{dirty_lines: :all}, _line), do: true
  def dirty?(%__MODULE__{dirty_lines: dirty}, line), do: Map.has_key?(dirty, line)

  @doc """
  Checks current frame parameters against last-frame tracking fields
  and returns the window with `dirty_lines: :all` if anything that
  requires a full redraw has changed.

  Checked triggers: viewport scroll position, gutter width, total line
  count, and whether the cache is empty (first frame).
  """
  @spec detect_invalidation(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def detect_invalidation(%__MODULE__{} = window, viewport_top, gutter_w, line_count, buf_version) do
    # Sentinel value -1 means no prior render has completed. Force full
    # redraw on the very first frame regardless of parameter values.
    first_frame = window.last_buf_version < 0

    needs_full =
      first_frame or
        window.last_viewport_top != viewport_top or
        window.last_gutter_w != gutter_w or
        window.last_line_count != line_count

    window = if needs_full, do: %{window | dirty_lines: :all}, else: window

    # Buffer version change means content was edited. We don't know exactly
    # which lines changed here (that info lives in EditDelta, which is
    # consumed by HighlightSync). Conservative: mark all dirty when
    # version changes, since the edit could be multi-line (paste, undo).
    #
    # Future optimization: add a non-destructive `peek_edits` API to
    # BufferServer that returns delta line ranges without consuming them.
    if window.last_buf_version != buf_version and window.last_buf_version >= 0 do
      %{window | dirty_lines: :all}
    else
      window
    end
  end

  @doc """
  Stores rendered gutter and content draws for a buffer line.

  Does NOT remove the line from the dirty set; that happens in
  `snapshot_after_render/5` when the full frame is complete.
  """
  @spec cache_line(
          t(),
          non_neg_integer(),
          [DisplayList.draw()],
          [DisplayList.draw()]
        ) :: t()
  def cache_line(%__MODULE__{} = window, buf_line, gutter_draws, content_draws) do
    %{
      window
      | cached_gutter: Map.put(window.cached_gutter, buf_line, gutter_draws),
        cached_content: Map.put(window.cached_content, buf_line, content_draws)
    }
  end

  @doc """
  Snapshots tracking fields after a successful render pass.

  Clears the dirty set and records the current frame's parameters so the
  next frame can detect what changed.
  """
  @spec snapshot_after_render(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def snapshot_after_render(
        %__MODULE__{} = window,
        viewport_top,
        gutter_w,
        line_count,
        cursor_line,
        buf_version
      ) do
    %{
      window
      | dirty_lines: %{},
        last_viewport_top: viewport_top,
        last_gutter_w: gutter_w,
        last_line_count: line_count,
        last_cursor_line: cursor_line,
        last_buf_version: buf_version
    }
  end

  @doc """
  Prunes cache entries for buffer lines no longer in the visible range.

  Keeps the cache bounded to avoid memory growth as the user scrolls
  through a large file.
  """
  @spec prune_cache(t(), non_neg_integer(), non_neg_integer()) :: t()
  def prune_cache(%__MODULE__{} = window, first_visible, last_visible) do
    filter = fn {line, _draws} -> line >= first_visible and line <= last_visible end

    %{
      window
      | cached_gutter: Map.filter(window.cached_gutter, filter),
        cached_content: Map.filter(window.cached_content, filter)
    }
  end
end
