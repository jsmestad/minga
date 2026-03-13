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
  alias Minga.Editor.FoldMap
  alias Minga.Editor.FoldRange
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window.Content
  alias Minga.Popup.Active, as: PopupActive

  @typedoc "Unique identifier for a window."
  @type id :: pos_integer()

  @typedoc """
  Context fingerprint: a term derived from the render context that
  captures all per-frame inputs affecting every visible line. When
  the fingerprint changes between frames, all lines are re-rendered.

  Built from: visual selection, search matches, highlight version,
  diagnostic signs, git signs, viewport left scroll, active status,
  and theme color structs.
  """
  @type context_fingerprint :: term()

  @type t :: %__MODULE__{
          id: id(),
          content: Content.t(),
          buffer: pid(),
          viewport: Viewport.t(),
          cursor: Document.position(),
          fold_map: FoldMap.t(),
          fold_ranges: [FoldRange.t()],
          popup_meta: PopupActive.t() | nil,
          dirty_lines: :all | %{optional(non_neg_integer()) => true},
          cached_gutter: %{optional(non_neg_integer()) => [DisplayList.draw()]},
          cached_content: %{optional(non_neg_integer()) => [DisplayList.draw()]},
          last_viewport_top: integer(),
          last_gutter_w: integer(),
          last_line_count: integer(),
          last_cursor_line: integer(),
          last_buf_version: integer(),
          last_context_fingerprint: context_fingerprint()
        }

  @enforce_keys [:id, :content, :buffer, :viewport]
  defstruct [
    :id,
    :content,
    :buffer,
    :viewport,
    cursor: {0, 0},
    fold_map: %FoldMap{folds: []},
    fold_ranges: [],
    popup_meta: nil,
    dirty_lines: %{},
    cached_gutter: %{},
    cached_content: %{},
    last_viewport_top: -1,
    last_gutter_w: -1,
    last_line_count: -1,
    last_cursor_line: -1,
    last_buf_version: -1,
    last_context_fingerprint: nil
  ]

  @doc """
  Creates a new window with the given id, buffer, and viewport dimensions.

  Sets both `content` (the polymorphic content reference) and `buffer`
  (backward-compatible pid field). During the migration, callers access
  `window.buffer` directly. Once all callers are updated to use
  `Content.buffer_pid(window.content)`, the `buffer` field will be removed.
  """
  @spec new(id(), pid(), pos_integer(), pos_integer()) :: t()
  def new(id, buffer, rows, cols)
      when is_integer(id) and id > 0 and is_pid(buffer) and
             is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    %__MODULE__{
      id: id,
      content: Content.buffer(buffer),
      buffer: buffer,
      viewport: Viewport.new(rows, cols)
    }
  end

  @doc """
  Creates a new agent chat window.

  The `buffer` field is set to the agent's `*Agent*` Buffer.Server pid
  for backward compatibility with code that reads `window.buffer`. The
  `content` field uses the `:agent_chat` tag so the render pipeline can
  dispatch to the agent chat renderer.
  """
  @spec new_agent_chat(id(), pid(), pos_integer(), pos_integer()) :: t()
  def new_agent_chat(id, agent_buffer, rows, cols)
      when is_integer(id) and id > 0 and is_pid(agent_buffer) and
             is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    %__MODULE__{
      id: id,
      content: Content.agent_chat(agent_buffer),
      buffer: agent_buffer,
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
      content: Content.buffer(buffer),
      buffer: buffer,
      viewport: Viewport.new(rows, cols),
      cursor: cursor
    }
  end

  @doc "Updates the viewport dimensions for this window, marking all lines dirty."
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(%__MODULE__{} = window, rows, cols)
      when is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    window
    |> invalidate()
    |> Map.put(:viewport, Viewport.new(rows, cols))
  end

  # ── Popup queries ──────────────────────────────────────────────────────────

  @doc "Returns true if this window is a popup (has popup metadata attached)."
  @spec popup?(t()) :: boolean()
  def popup?(%__MODULE__{popup_meta: nil}), do: false
  def popup?(%__MODULE__{popup_meta: %PopupActive{}}), do: true

  # ── Fold operations ────────────────────────────────────────────────────────

  @doc "Returns true if this window has any active folds."
  @spec has_folds?(t()) :: boolean()
  def has_folds?(%__MODULE__{fold_map: fm}), do: not FoldMap.empty?(fm)

  @doc "Toggles the fold at the given buffer line using the window's available fold ranges."
  @spec toggle_fold(t(), non_neg_integer()) :: t()
  def toggle_fold(%__MODULE__{fold_map: fm, fold_ranges: ranges} = window, line) do
    %{window | fold_map: FoldMap.toggle(fm, line, ranges)}
    |> invalidate()
  end

  @doc "Folds the range containing the given buffer line."
  @spec fold_at(t(), non_neg_integer()) :: t()
  def fold_at(%__MODULE__{fold_map: fm, fold_ranges: ranges} = window, line) do
    case Enum.find(ranges, &FoldRange.contains?(&1, line)) do
      nil -> window
      range -> %{window | fold_map: FoldMap.fold(fm, range)} |> invalidate()
    end
  end

  @doc "Unfolds the range containing the given buffer line."
  @spec unfold_at(t(), non_neg_integer()) :: t()
  def unfold_at(%__MODULE__{fold_map: fm} = window, line) do
    new_fm = FoldMap.unfold_at(fm, line)

    if new_fm == fm do
      window
    else
      %{window | fold_map: new_fm} |> invalidate()
    end
  end

  @doc "Folds all available ranges."
  @spec fold_all(t()) :: t()
  def fold_all(%__MODULE__{fold_ranges: ranges} = window) do
    %{window | fold_map: FoldMap.fold_all(FoldMap.new(), ranges)}
    |> invalidate()
  end

  @doc "Unfolds all folds."
  @spec unfold_all(t()) :: t()
  def unfold_all(%__MODULE__{} = window) do
    %{window | fold_map: FoldMap.unfold_all(window.fold_map)}
    |> invalidate()
  end

  @doc "Updates the available fold ranges (from a provider). Preserves existing folds that still exist in the new ranges."
  @spec set_fold_ranges(t(), [FoldRange.t()]) :: t()
  def set_fold_ranges(%__MODULE__{fold_map: fm} = window, new_ranges) do
    # Keep existing folds that still match a range in the new set
    surviving_folds =
      Enum.filter(FoldMap.folds(fm), fn old_fold ->
        Enum.any?(new_ranges, fn new_range ->
          new_range.start_line == old_fold.start_line and
            new_range.end_line == old_fold.end_line
        end)
      end)

    new_fm = FoldMap.from_ranges(surviving_folds)
    %{window | fold_ranges: new_ranges, fold_map: new_fm}
  end

  @doc "Unfolds any folds that contain the given lines (used by search auto-unfold)."
  @spec unfold_containing(t(), [non_neg_integer()]) :: t()
  def unfold_containing(%__MODULE__{fold_map: fm} = window, lines) do
    new_fm = FoldMap.unfold_containing(fm, lines)

    if new_fm == fm do
      window
    else
      %{window | fold_map: new_fm} |> invalidate()
    end
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

  @doc """
  Marks all lines dirty (full redraw needed).

  Clears all caches and resets tracking fields to sentinels so the next
  render pass starts from scratch. Use this when the window's buffer
  changes, on resize, or any other event that makes all cached draws
  invalid.
  """
  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{} = window) do
    %{
      window
      | dirty_lines: :all,
        cached_gutter: %{},
        cached_content: %{},
        last_viewport_top: -1,
        last_gutter_w: -1,
        last_line_count: -1,
        last_cursor_line: -1,
        last_buf_version: -1,
        last_context_fingerprint: nil
    }
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

  Structural triggers (checked here): viewport scroll, gutter width,
  line count, buffer version, first frame (sentinel values).

  Context triggers (checked separately via `detect_context_change/2`):
  visual selection, search matches, syntax highlights, diagnostic signs,
  git signs, viewport horizontal scroll, active status, theme colors.
  """
  @spec detect_invalidation(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def detect_invalidation(%__MODULE__{} = window, viewport_top, gutter_w, line_count, buf_version) do
    first_frame = window.last_buf_version < 0

    needs_full =
      first_frame or
        window.last_viewport_top != viewport_top or
        window.last_gutter_w != gutter_w or
        window.last_line_count != line_count

    window = if needs_full, do: %{window | dirty_lines: :all}, else: window

    if window.last_buf_version != buf_version and window.last_buf_version >= 0 do
      %{window | dirty_lines: :all}
    else
      window
    end
  end

  @doc """
  Compares the current render context fingerprint against the last frame's.

  If the fingerprint changed, marks all lines dirty. This catches changes
  to visual selection, search matches, syntax highlights, diagnostic signs,
  git signs, horizontal scroll, active/inactive status, and theme colors,
  all of which affect every visible line's draw output.
  """
  @spec detect_context_change(t(), context_fingerprint()) :: t()
  def detect_context_change(%__MODULE__{} = window, fingerprint) do
    if window.last_context_fingerprint != nil and
         window.last_context_fingerprint != fingerprint do
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
  next frame can detect what changed. The context fingerprint captures
  all per-frame render context inputs (visual selection, search matches,
  syntax highlights, signs, etc.) so context changes trigger full redraws.
  """
  @spec snapshot_after_render(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          context_fingerprint()
        ) :: t()
  def snapshot_after_render(
        %__MODULE__{} = window,
        viewport_top,
        gutter_w,
        line_count,
        cursor_line,
        buf_version,
        context_fingerprint
      ) do
    %{
      window
      | dirty_lines: %{},
        last_viewport_top: viewport_top,
        last_gutter_w: gutter_w,
        last_line_count: line_count,
        last_cursor_line: cursor_line,
        last_buf_version: buf_version,
        last_context_fingerprint: context_fingerprint
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
