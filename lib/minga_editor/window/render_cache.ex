defmodule MingaEditor.Window.RenderCache do
  @moduledoc """
  Per-window render state for incremental rendering.

  Tracks which buffer lines need re-rendering, caches draw commands from
  previous frames, and stores last-frame comparison values so the render
  pipeline can detect when a full redraw is needed.

  ## Dirty-line tracking

  The dirty set uses two representations:

  - `:all` means every line needs re-rendering (scroll, resize, theme
    change, highlight update, fold toggle, or any other wholesale
    invalidation)
  - A map of specific buffer line numbers (`%{line => true}`) for targeted
    invalidation (edits that touch a few lines)

  Gutter and content caches are separate because cursor movement with
  relative line numbering dirties every gutter entry without changing
  content. This avoids re-rendering line text when only line numbers change.

  ## Tracking fields

  `last_viewport_top`, `last_viewport_cache_key`, `last_gutter_w`,
  `last_line_count`, `last_cursor_line`, and `last_buf_version` store values
  from the previous frame. The Scroll stage compares current values against
  these to detect full-invalidation triggers. `last_context_fingerprint`
  captures all per-frame render context inputs (visual selection, search
  matches, syntax highlights, signs, etc.) so context changes trigger full
  redraws.
  """

  alias MingaEditor.DisplayList

  @compile {:inline, dirty?: 2}

  @typedoc """
  A retained composed row plus the cheap input fingerprint that produced it.

  The Content stage (semantic Builder) keys these by `row_id`. On the next
  frame it recomputes only the input fingerprint per row; when the fingerprint
  matches, it reuses the cached `Row.t()` verbatim instead of recomposing the
  text and spans. See `MingaEditor.RenderModel.Window.Builder` (#2287).
  """
  @type retained_row :: {input_hash :: non_neg_integer(), Minga.RenderModel.Window.Row.t()}

  @typedoc """
  A retained wrapped logical line: the cheap input fingerprint that produced its
  visual rows plus the full visual-row entry list (Rows and their wrap metadata).

  The Content stage (semantic Builder) keys these by `buf_line`. On the next
  frame, when the logical line's fingerprint (line text, highlight segments,
  compose context, and content width) is unchanged, the Builder reuses the
  entire visual-row set verbatim instead of recomposing the line and recomputing
  its wrap points. See `MingaEditor.RenderModel.Window.Builder` (#2287).
  """
  @type retained_wrap_line :: {input_hash :: non_neg_integer(), entries :: [map()]}

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
          dirty_lines: :all | %{optional(non_neg_integer()) => true},
          cached_gutter: %{optional(non_neg_integer()) => [DisplayList.draw()]},
          cached_content: %{optional(non_neg_integer()) => [DisplayList.draw()]},
          last_viewport_top: integer(),
          last_viewport_cache_key: integer(),
          last_gutter_w: integer(),
          last_line_count: integer(),
          last_cursor_line: integer(),
          last_buf_version: integer(),
          last_context_fingerprint: context_fingerprint(),
          content_epoch: non_neg_integer(),
          reset_pending: boolean(),
          last_reset_fingerprint: term(),
          total_visual_rows_cache: {term(), non_neg_integer()} | nil,
          retained_rows: %{optional(non_neg_integer()) => retained_row()},
          retained_wrap_lines: %{optional(non_neg_integer()) => retained_wrap_line()}
        }

  defstruct dirty_lines: %{},
            cached_gutter: %{},
            cached_content: %{},
            last_viewport_top: -1,
            last_viewport_cache_key: -1,
            last_gutter_w: -1,
            last_line_count: -1,
            last_cursor_line: -1,
            last_buf_version: -1,
            last_context_fingerprint: nil,
            content_epoch: 0,
            reset_pending: true,
            last_reset_fingerprint: nil,
            total_visual_rows_cache: nil,
            retained_rows: %{},
            retained_wrap_lines: %{}

  @doc """
  Returns a fresh cache with all lines dirty and no cached draws.

  Use after any event that invalidates all cached draws: buffer switch,
  resize, theme change, etc.
  """
  @spec reset() :: t()
  def reset do
    %__MODULE__{
      dirty_lines: :all,
      reset_pending: true,
      retained_rows: %{},
      retained_wrap_lines: %{}
    }
  end

  @doc "Returns a fresh cache invalidation while preserving retained-render epoch state."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = cache) do
    %{
      cache
      | dirty_lines: :all,
        cached_gutter: %{},
        cached_content: %{},
        last_viewport_top: -1,
        last_viewport_cache_key: -1,
        last_gutter_w: -1,
        last_line_count: -1,
        last_cursor_line: -1,
        last_buf_version: -1,
        last_context_fingerprint: nil,
        reset_pending: true,
        total_visual_rows_cache: nil,
        retained_rows: %{},
        retained_wrap_lines: %{}
    }
  end

  @doc """
  Marks specific buffer lines as needing re-render.

  Pass `:all` to force a complete redraw. Pass a list of buffer line
  numbers for targeted invalidation. If already fully dirty, adding
  specific lines is a no-op.
  """
  @spec mark_dirty(t(), [non_neg_integer()] | :all) :: t()
  def mark_dirty(%__MODULE__{} = cache, :all) do
    %{cache | dirty_lines: :all}
  end

  def mark_dirty(%__MODULE__{dirty_lines: :all} = cache, _lines), do: cache

  def mark_dirty(%__MODULE__{dirty_lines: existing} = cache, lines) when is_list(lines) do
    new_dirty = Enum.reduce(lines, existing, fn line, acc -> Map.put(acc, line, true) end)
    %{cache | dirty_lines: new_dirty}
  end

  @doc "Returns true if the given buffer line needs re-rendering."
  @spec dirty?(t(), non_neg_integer()) :: boolean()
  def dirty?(%__MODULE__{dirty_lines: :all}, _line), do: true
  def dirty?(%__MODULE__{dirty_lines: dirty}, line), do: Map.has_key?(dirty, line)

  @doc """
  Checks current frame parameters against last-frame tracking fields
  and marks all lines dirty if anything requiring a full redraw has changed.

  Structural redraw triggers: viewport scroll, gutter width, line count, buffer
  version, first frame (sentinel values). Only first frame and gutter-width
  geometry changes request a retained-GUI epoch reset; ordinary text edits and
  line-count changes use row hashes without bumping the content epoch.
  """
  @spec detect_invalidation(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def detect_invalidation(%__MODULE__{} = cache, viewport_top, gutter_w, line_count, buf_version) do
    detect_invalidation(
      cache,
      viewport_top,
      viewport_top,
      gutter_w,
      line_count,
      buf_version,
      cache.last_cursor_line
    )
  end

  @spec detect_invalidation(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def detect_invalidation(
        %__MODULE__{} = cache,
        viewport_top,
        gutter_w,
        line_count,
        buf_version,
        cursor_line
      ) do
    detect_invalidation(
      cache,
      viewport_top,
      viewport_top,
      gutter_w,
      line_count,
      buf_version,
      cursor_line
    )
  end

  @spec detect_invalidation(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def detect_invalidation(
        %__MODULE__{} = cache,
        viewport_top,
        viewport_cache_key,
        gutter_w,
        line_count,
        buf_version,
        _cursor_line
      ) do
    first_frame = cache.last_buf_version < 0

    geometry_reset = first_frame or cache.last_gutter_w != gutter_w

    needs_full =
      geometry_reset or
        cache.last_viewport_top != viewport_top or
        cache.last_viewport_cache_key != viewport_cache_key or
        cache.last_line_count != line_count

    cache = if needs_full, do: %{cache | dirty_lines: :all}, else: cache
    cache = if geometry_reset, do: %{cache | reset_pending: true}, else: cache

    if cache.last_buf_version != buf_version and cache.last_buf_version >= 0 do
      %{cache | dirty_lines: :all}
    else
      cache
    end
  end

  @doc """
  Compares the current render context fingerprint against the last frame's.

  If the fingerprint changed, marks all lines dirty. Catches changes to
  visual selection, search matches, syntax highlights, diagnostic signs,
  git signs, horizontal scroll, active/inactive status, and theme colors.
  """
  @spec detect_context_change(t(), context_fingerprint()) :: t()
  def detect_context_change(%__MODULE__{} = cache, fingerprint) do
    if cache.last_context_fingerprint != nil and
         cache.last_context_fingerprint != fingerprint do
      %{cache | dirty_lines: :all}
    else
      cache
    end
  end

  @doc "Marks the next retained GUI frame as a frontend-state reset."
  @spec mark_reset_pending(t()) :: t()
  def mark_reset_pending(%__MODULE__{} = cache) do
    %{cache | reset_pending: true}
  end

  @doc "Prepares the retained GUI content epoch for the current frame."
  @spec prepare_epoch(t(), term()) :: {t(), non_neg_integer(), boolean()}
  def prepare_epoch(%__MODULE__{} = cache, reset_fingerprint) do
    reset? = cache.reset_pending or cache.last_reset_fingerprint != reset_fingerprint
    epoch = if reset?, do: cache.content_epoch + 1, else: cache.content_epoch

    {%{
       cache
       | content_epoch: epoch,
         reset_pending: false,
         last_reset_fingerprint: reset_fingerprint
     }, epoch, reset?}
  end

  @doc "Returns a cached wrapped visual row total when the key matches."
  @spec cached_total_visual_rows(t(), term()) :: non_neg_integer() | nil
  def cached_total_visual_rows(%__MODULE__{total_visual_rows_cache: {key, total}}, key), do: total
  def cached_total_visual_rows(%__MODULE__{}, _key), do: nil

  @doc "Stores the wrapped visual row total for the current cache key."
  @spec put_total_visual_rows(t(), term(), non_neg_integer()) :: t()
  def put_total_visual_rows(%__MODULE__{} = cache, key, total) when is_integer(total) do
    %{cache | total_visual_rows_cache: {key, total}}
  end

  @doc """
  Stores rendered gutter and content draws for a buffer line.

  Does NOT remove the line from the dirty set; that happens in
  `snapshot/7` when the full frame is complete.
  """
  @spec cache_line(t(), non_neg_integer(), [DisplayList.draw()], [DisplayList.draw()]) :: t()
  def cache_line(%__MODULE__{} = cache, buf_line, gutter_draws, content_draws) do
    %{
      cache
      | cached_gutter: Map.put(cache.cached_gutter, buf_line, gutter_draws),
        cached_content: Map.put(cache.cached_content, buf_line, content_draws)
    }
  end

  @doc """
  Snapshots tracking fields after a successful render pass.

  Clears the dirty set and records the current frame's parameters so the
  next frame can detect what changed.
  """
  @spec snapshot(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          context_fingerprint()
        ) :: t()
  def snapshot(
        %__MODULE__{} = cache,
        viewport_top,
        gutter_w,
        line_count,
        cursor_line,
        buf_version,
        ctx_fingerprint
      ) do
    snapshot(
      cache,
      viewport_top,
      viewport_top,
      gutter_w,
      line_count,
      cursor_line,
      buf_version,
      ctx_fingerprint
    )
  end

  @spec snapshot(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          context_fingerprint()
        ) :: t()
  def snapshot(
        %__MODULE__{} = cache,
        viewport_top,
        viewport_cache_key,
        gutter_w,
        line_count,
        cursor_line,
        buf_version,
        ctx_fingerprint
      ) do
    %{
      cache
      | dirty_lines: %{},
        last_viewport_top: viewport_top,
        last_viewport_cache_key: viewport_cache_key,
        last_gutter_w: gutter_w,
        last_line_count: line_count,
        last_cursor_line: cursor_line,
        last_buf_version: buf_version,
        last_context_fingerprint: ctx_fingerprint
    }
  end

  @doc """
  Prunes cache entries for buffer lines no longer in the visible range.

  Keeps the cache bounded to avoid memory growth as the user scrolls
  through a large file.
  """
  @spec prune(t(), non_neg_integer(), non_neg_integer()) :: t()
  def prune(%__MODULE__{} = cache, first_visible, last_visible) do
    filter = fn {line, _draws} -> line >= first_visible and line <= last_visible end

    %{
      cache
      | cached_gutter: Map.filter(cache.cached_gutter, filter),
        cached_content: Map.filter(cache.cached_content, filter)
    }
  end

  # ── Retained composed rows (#2287) ─────────────────────────────────────────

  @doc """
  Returns the `{row_id => {input_hash, Row.t()}}` map captured by the last
  semantic content build. The Builder consults it to skip recomposing rows
  whose cheap input fingerprint is unchanged.
  """
  @spec retained_rows(t()) :: %{optional(non_neg_integer()) => retained_row()}
  def retained_rows(%__MODULE__{retained_rows: rows}), do: rows

  @doc """
  Replaces the retained-row map with the current frame's composed rows.

  Stored wholesale (not merged) so the map stays bounded to the visible row
  set and never accumulates rows that scrolled out of view.
  """
  @spec put_retained_rows(t(), %{optional(non_neg_integer()) => retained_row()}) :: t()
  def put_retained_rows(%__MODULE__{} = cache, rows) when is_map(rows) do
    %{cache | retained_rows: rows}
  end

  @doc """
  Returns the `{buf_line => {input_hash, entries}}` map captured by the last
  semantic content build for wrapped windows. The Builder consults it to skip
  recomposing and re-wrapping logical lines whose input fingerprint is unchanged.
  """
  @spec retained_wrap_lines(t()) :: %{optional(non_neg_integer()) => retained_wrap_line()}
  def retained_wrap_lines(%__MODULE__{retained_wrap_lines: lines}), do: lines

  @doc """
  Replaces the retained wrapped-line map with the current frame's logical lines.

  Stored wholesale (not merged) so the map stays bounded to the visible logical
  lines and never accumulates lines that scrolled out of view.
  """
  @spec put_retained_wrap_lines(t(), %{optional(non_neg_integer()) => retained_wrap_line()}) ::
          t()
  def put_retained_wrap_lines(%__MODULE__{} = cache, lines) when is_map(lines) do
    %{cache | retained_wrap_lines: lines}
  end
end
