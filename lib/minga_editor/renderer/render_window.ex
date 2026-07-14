defmodule MingaEditor.Renderer.RenderWindow do
  @moduledoc """
  A window is a viewport into a buffer.

  Each window holds a reference to a buffer process and its own independent
  viewport (scroll position and dimensions). Multiple windows can reference
  the same buffer; edits in one are visible in all.

  ## Render cache and dirty-line tracking

  Windows carry per-frame render state that enables incremental rendering.
  The semantic `RenderModel.Window.Builder` reuses retained composed rows for
  lines whose inputs are unchanged and only recomposes lines marked as dirty.

  The dirty set uses two representations:
  - `:all` means every line needs re-rendering (used for scroll, resize,
    theme change, highlight update, and other wholesale invalidation)
  - A map of specific buffer line numbers (`%{line => true}`) that need re-rendering
    (used for edits that touch a few lines)

  Tracking fields (`last_viewport_top`, `last_viewport_cache_key`,
  `last_gutter_w`, `last_line_count`, `last_cursor_line`, `last_buf_version`)
  store the values from the previous frame. The Scroll stage compares current
  values against these to detect full-invalidation triggers automatically.
  """

  alias Minga.Buffer
  alias MingaEditor.FoldMap
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias Minga.Language.Symbol
  alias MingaEditor.Viewport
  alias MingaEditor.Window.Content
  alias MingaEditor.Renderer.WindowCache, as: RenderCache
  alias MingaEditor.Window.ScrollVelocity
  alias MingaEditor.UI.Popup.Active, as: PopupActive

  @compile {:inline, dirty?: 2}

  @typedoc "Unique identifier for a window."
  @type id :: pos_integer()

  @type t :: %__MODULE__{
          id: id(),
          content: Content.t(),
          viewport: Viewport.t(),
          cursor: Buffer.position(),
          pinned: boolean(),
          fold_map: FoldMap.t(),
          fold_ranges: [FoldRange.t()],
          textobject_positions: %{atom() => [{non_neg_integer(), non_neg_integer()}]},
          document_symbols: [Symbol.t()],
          popup_meta: PopupActive.t() | nil,
          render_cache: RenderCache.t(),
          scroll_velocity: ScrollVelocity.t(),
          scroll_detach_cursor: Buffer.position() | nil,
          scroll_echo_top: integer() | nil,
          authoritative_scroll_seq: non_neg_integer()
        }

  @enforce_keys [:id, :content, :viewport]
  defstruct [
    :id,
    :content,
    :viewport,
    cursor: {0, 0},
    pinned: false,
    fold_map: %FoldMap{folds: []},
    fold_ranges: [],
    textobject_positions: %{},
    document_symbols: [],
    popup_meta: nil,
    render_cache: %RenderCache{},
    scroll_velocity: %ScrollVelocity{},
    scroll_detach_cursor: nil,
    scroll_echo_top: nil,
    authoritative_scroll_seq: 0
  ]

  @doc "Creates a new window with the given id, buffer, and viewport dimensions."
  @spec new(id(), pid(), pos_integer(), pos_integer()) :: t()
  def new(id, buffer, rows, cols)
      when is_integer(id) and id > 0 and is_pid(buffer) and
             is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    %__MODULE__{
      id: id,
      content: Content.buffer(buffer),
      viewport: Viewport.new(rows, cols)
    }
  end

  @doc """
  Creates a new semantic agent chat window.
  """
  @spec new_agent_chat(id(), pos_integer(), pos_integer()) :: t()
  def new_agent_chat(id, rows, cols)
      when is_integer(id) and id > 0 and is_integer(rows) and rows > 0 and is_integer(cols) and
             cols > 0 do
    %__MODULE__{
      id: id,
      content: Content.agent_chat(),
      viewport: Viewport.new(rows, cols),
      pinned: true,
      render_cache: RenderCache.reset()
    }
  end

  @doc "Creates a new window showing the zero-buffers launchpad surface (#2689)."
  @spec new_empty_state(id(), pos_integer(), pos_integer()) :: t()
  def new_empty_state(id, rows, cols)
      when is_integer(id) and id > 0 and is_integer(rows) and rows > 0 and is_integer(cols) and
             cols > 0 do
    %__MODULE__{
      id: id,
      content: Content.empty(),
      viewport: Viewport.new(rows, cols),
      render_cache: RenderCache.reset()
    }
  end

  @doc """
  Switches the window to the zero-buffers launchpad surface (#2689).

  The window stays open (the window tree never drops its last leaf); only
  its content changes, mirroring how agent chat panes host non-buffer
  content. Any cached buffer rendering is invalidated.
  """
  @spec show_empty_state(t()) :: t()
  def show_empty_state(%__MODULE__{} = window) do
    %{window | content: Content.empty()}
    |> set_document_symbols([])
    |> invalidate()
  end

  @doc "Switches the window from the launchpad back to a buffer."
  @spec show_buffer(t(), pid()) :: t()
  def show_buffer(%__MODULE__{} = window, buffer) when is_pid(buffer) do
    %{window | content: Content.buffer(buffer)}
    |> set_document_symbols([])
    |> invalidate()
  end

  @doc "Creates a new window with the given id, buffer, viewport dimensions, and cursor position."
  @spec new(id(), pid(), pos_integer(), pos_integer(), Buffer.position()) :: t()
  def new(id, buffer, rows, cols, cursor)
      when is_integer(id) and id > 0 and is_pid(buffer) and
             is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 and
             is_tuple(cursor) do
    %__MODULE__{
      id: id,
      content: Content.buffer(buffer),
      viewport: Viewport.new(rows, cols),
      cursor: cursor
    }
  end

  @doc "Updates the viewport dimensions for this window, marking all lines dirty."
  @spec resize(t(), non_neg_integer(), non_neg_integer()) :: t()
  def resize(%__MODULE__{} = window, rows, cols)
      when is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    window
    |> invalidate()
    |> set_viewport(Viewport.new(rows, cols))
  end

  # When a window is squeezed to zero dimensions (e.g., terminal resized
  # too small with splits active), clamp to 1x1 to avoid downstream crashes.
  def resize(%__MODULE__{} = window, rows, cols)
      when is_integer(rows) and is_integer(cols) do
    resize(window, max(rows, 1), max(cols, 1))
  end

  # ── Scroll helpers ──────────────────────────────────────────────────────────

  @doc "Stores the computed viewport for this window."
  @spec set_viewport(t(), Viewport.t()) :: t()
  def set_viewport(%__MODULE__{} = window, %Viewport{} = viewport) do
    %{window | viewport: viewport}
  end

  @doc """
  Scrolls the window's viewport by `delta` lines and updates pinned state.

  Scrolling up always unpins. Scrolling down re-pins only when the viewport
  reaches the bottom. `total_lines` is the buffer's line count.

  Returns the updated window.
  """
  @spec scroll_viewport(t(), integer(), non_neg_integer()) :: t()
  def scroll_viewport(%__MODULE__{} = window, 0, _total_lines), do: window

  def scroll_viewport(%__MODULE__{viewport: vp} = window, delta, total_lines) do
    visible = Viewport.content_rows(vp)

    max_top =
      if resident?(window),
        do: max(total_lines - 1, 0),
        else: max(total_lines - visible, 0)

    new_top = (vp.top + delta) |> max(0) |> min(max_top)
    pinned = delta > 0 and new_top >= max_top

    %{window | viewport: Viewport.put_top(vp, new_top), pinned: pinned}
  end

  @doc "Scrolls the window horizontally by display columns."
  @spec scroll_horizontal(t(), integer()) :: t()
  def scroll_horizontal(%__MODULE__{viewport: viewport} = window, delta) do
    new_left = max(viewport.left + delta, 0)
    %{window | viewport: %{viewport | left: new_left}}
  end

  @doc "Sets whether the window should stay pinned to the bottom while content streams."
  @spec set_pinned(t(), boolean()) :: t()
  def set_pinned(%__MODULE__{} = window, pinned?) when is_boolean(pinned?) do
    %{window | pinned: pinned?}
  end

  @doc """
  Records a wheel/trackpad scroll event so the render pipeline can tell a scroll
  gesture is in progress.

  Advances the scroll-rate estimator (`scroll_follow_cursor?/3` reads its tier to
  suppress cursor re-anchoring mid-gesture) and marks `scroll_detach_cursor` at
  the cursor position at gesture start, so the viewport stays put until the cursor
  actually moves.
  """
  @spec record_scroll_event(t(), integer(), Buffer.position()) :: t()
  def record_scroll_event(%__MODULE__{} = window, now_ms, cursor_pos) do
    %{
      window
      | scroll_velocity: ScrollVelocity.record(window.scroll_velocity, now_ms),
        scroll_detach_cursor: cursor_pos
    }
  end

  @doc """
  Records whether this window is a full-document resident window (#2653/#2658).

  Stored in the render cache because residence is a renderer-computed value and
  the render cache is the only per-window struct copied back from the async
  render pipeline (see `MingaEditor.State.merge_renderer_window/2`). The input
  layer (mouse wheel/trackpad handling) reads it via `resident?/1` so it can
  branch on residence without recomputing it. Stale by at most one frame, which
  is harmless: residence is a document-size property that doesn't flip mid-gesture.
  """
  @spec set_resident(t(), boolean()) :: t()
  def set_resident(%__MODULE__{render_cache: cache} = window, resident?)
      when is_boolean(resident?) do
    %{window | render_cache: RenderCache.set_resident(cache, resident?)}
  end

  @doc "Returns whether this window was a full-document resident window as of the last rendered frame."
  @spec resident?(t()) :: boolean()
  def resident?(%__MODULE__{render_cache: cache}), do: RenderCache.resident?(cache)

  @doc "Arms or disarms residence promotion for the next frame (#2679 first-paint-then-promote)."
  @spec set_residence_armed(t(), boolean()) :: t()
  def set_residence_armed(%__MODULE__{render_cache: cache} = window, armed?)
      when is_boolean(armed?) do
    %{window | render_cache: RenderCache.set_residence_armed(cache, armed?)}
  end

  @doc "Returns whether residence was armed by the previous eligible frame (#2679)."
  @spec residence_armed?(t()) :: boolean()
  def residence_armed?(%__MODULE__{render_cache: cache}), do: RenderCache.residence_armed?(cache)

  @doc """
  Records the committed viewport top of a frontend-reported free-scroll (#2661).

  Set by the mouse-wheel/trackpad input path to the top it just committed. It is
  an editor-owned, top-level `Window` field (never in the render cache) so the
  async render writeback cannot clobber a newer value: only the input path ever
  writes it, on the live window. It is deliberately sticky — never cleared. A
  later wheel overwrites it; `settle_scroll_seq/1` treats a viewport top equal to
  this value as an echo of the frontend's own report, so it does not advance
  `scroll_seq` (the "echo-loop guard": no re-anchor storm during a wheel/trackpad scroll gesture).
  """
  @spec mark_scroll_echo(t(), integer()) :: t()
  def mark_scroll_echo(%__MODULE__{} = window, echo_top) when is_integer(echo_top) do
    %{window | scroll_echo_top: echo_top}
  end

  @doc """
  Records that an authoritative BEAM-initiated viewport jump must discard any
  frontend-held local scroll offset, even if the committed top is unchanged (#2652).

  Command handlers call this on the live window (editor process): at dispatch
  for the always-authoritative viewport commands, and from the success branches
  of failable jumps (search hits, mark jumps, bracket match, LSP goto). The
  `MingaEditor.Commands` `@authoritative_scroll_commands` comment documents the
  policy and is the source of truth for the command set.
  It is an editor-owned, top-level `Window` field (never in the render cache), a
  monotonic request counter incremented once per authoritative jump. Like
  `scroll_echo_top`, only the editor writes it, on the live window, so the async
  render writeback (which copies back only the render cache) cannot clobber it.

  `settle_scroll_seq/1` consumes it: the render cache remembers the last request
  count it settled against and advances `scroll_seq` whenever this counter moved
  past that baseline. Because the baseline (in the render cache) is overwritten to
  the observed counter every settle rather than the counter being cleared here, a
  single increment produces exactly one bump per rendered lineage and cannot latch
  (see `MingaEditor.Window.RenderCache.settle_scroll_seq/4`). This closes the
  same-top gap that the settle-time top comparison alone cannot see (a `zz` while
  already centered, a search hit already on screen).
  """
  @spec mark_authoritative_scroll(t()) :: t()
  def mark_authoritative_scroll(%__MODULE__{authoritative_scroll_seq: seq} = window) do
    %{window | authoritative_scroll_seq: seq + 1}
  end

  @doc "Returns the editor-owned authoritative-scroll request counter (#2652)."
  @spec authoritative_scroll_seq(t()) :: non_neg_integer()
  def authoritative_scroll_seq(%__MODULE__{authoritative_scroll_seq: seq}), do: seq

  @doc "Returns the renderer-owned monotonic scroll-authority sequence."
  @spec scroll_seq(t()) :: non_neg_integer()
  def scroll_seq(%__MODULE__{render_cache: cache}), do: RenderCache.scroll_seq(cache)

  @doc """
  Settles the per-frame `scroll_seq` decision against the render cache baseline.

  Delegates to `MingaEditor.Window.RenderCache.settle_scroll_seq/4` with this
  frame's committed viewport top, the sticky `scroll_echo_top` recorded by the
  input path, and the `authoritative_scroll_seq` request counter set by command
  handlers. `scroll_seq` advances when EITHER an authoritative jump was marked
  since the last settle OR the top moved to a value that is neither the previous
  committed top nor a frontend-reported free-scroll top (a genuine BEAM-initiated
  anchor move). Wheel/trackpad free-scroll frames share the reported top, so they are
  echoes and do not advance the sequence. A jump that also moves the top bumps
  once, not twice (a single OR decision per settle). The counter, its baseline,
  and the authoritative-request baseline all live in the render cache, so the
  sequence is monotonic across the serially threaded, written-back render cache.
  """
  @spec settle_scroll_seq(t()) :: t()
  def settle_scroll_seq(
        %__MODULE__{
          render_cache: cache,
          viewport: %Viewport{top: top},
          scroll_echo_top: echo_top,
          authoritative_scroll_seq: auth_seq
        } = window
      ) do
    %{window | render_cache: RenderCache.settle_scroll_seq(cache, top, echo_top, auth_seq)}
  end

  @spec scroll_follow_cursor?(t(), Buffer.position(), integer()) :: {t(), boolean()}
  def scroll_follow_cursor?(%__MODULE__{} = window, cursor_pos, now_ms) do
    resolve_scroll_follow(
      window,
      cursor_pos,
      window.scroll_detach_cursor,
      scroll_velocity_tier(window, now_ms)
    )
  end

  defp resolve_scroll_follow(window, _cursor_pos, _detached_at, tier) when tier != :idle,
    do: {window, false}

  defp resolve_scroll_follow(window, cursor_pos, cursor_pos, :idle) when cursor_pos != nil,
    do: {window, false}

  defp resolve_scroll_follow(window, _cursor_pos, detached_at, :idle) when detached_at != nil,
    do: {%{window | scroll_detach_cursor: nil}, true}

  defp resolve_scroll_follow(window, _cursor_pos, nil, :idle), do: {window, true}

  @spec scroll_velocity_tier(t(), integer()) :: ScrollVelocity.tier()
  def scroll_velocity_tier(%__MODULE__{} = window, now_ms) do
    ScrollVelocity.tier(window.scroll_velocity, now_ms)
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

  @doc "Updates the document symbols available for this window."
  @spec set_document_symbols(t(), [Symbol.t()]) :: t()
  def set_document_symbols(%__MODULE__{} = window, symbols) when is_list(symbols) do
    %{window | document_symbols: symbols}
  end

  @doc "Finds the next textobject position of the given type after (row, col)."
  @spec next_textobject(t(), atom(), {non_neg_integer(), non_neg_integer()}) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def next_textobject(%__MODULE__{textobject_positions: positions}, type, {row, col}) do
    positions
    |> Map.get(type, [])
    |> Enum.find(fn {r, c} -> r > row or (r == row and c > col) end)
  end

  @doc "Finds the previous textobject position of the given type before (row, col)."
  @spec prev_textobject(t(), atom(), {non_neg_integer(), non_neg_integer()}) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def prev_textobject(%__MODULE__{textobject_positions: positions}, type, {row, col}) do
    positions
    |> Map.get(type, [])
    |> Enum.reverse()
    |> Enum.find(fn {r, c} -> r < row or (r == row and c < col) end)
  end

  @doc "Toggles the fold at the given buffer line using the window's available fold ranges."
  @spec toggle_fold(t(), non_neg_integer()) :: t()
  def toggle_fold(%__MODULE__{fold_map: fm, fold_ranges: ranges} = window, line) do
    new_fm = FoldMap.toggle(fm, line, ranges)

    %{window | fold_map: new_fm}
    |> clamp_cursor_to_visible()
    |> invalidate()
  end

  @doc "Folds the range containing the given buffer line."
  @spec fold_at(t(), non_neg_integer()) :: t()
  def fold_at(%__MODULE__{fold_map: fm, fold_ranges: ranges} = window, line) do
    case FoldMap.innermost_range(ranges, line) do
      nil ->
        window

      range ->
        %{window | fold_map: FoldMap.fold(fm, range)}
        |> clamp_cursor_to_visible()
        |> invalidate()
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

  @doc "Folds the outermost range containing the given buffer line and every nested range."
  @spec fold_recursive_at(t(), non_neg_integer()) :: t()
  def fold_recursive_at(%__MODULE__{fold_map: fm, fold_ranges: ranges} = window, line) do
    new_fm = FoldMap.fold_recursive(fm, line, ranges)

    if new_fm == fm do
      window
    else
      %{window | fold_map: new_fm}
      |> clamp_cursor_to_visible()
      |> invalidate()
    end
  end

  @doc "Unfolds every active fold inside the outermost range containing the given buffer line."
  @spec unfold_recursive_at(t(), non_neg_integer()) :: t()
  def unfold_recursive_at(%__MODULE__{fold_map: fm, fold_ranges: ranges} = window, line) do
    new_fm = FoldMap.unfold_recursive(fm, line, ranges)

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
    |> clamp_cursor_to_visible()
    |> invalidate()
  end

  @doc "Unfolds all folds."
  @spec unfold_all(t()) :: t()
  def unfold_all(%__MODULE__{} = window) do
    %{window | fold_map: FoldMap.unfold_all(window.fold_map)}
    |> invalidate()
  end

  # If the cursor is inside a folded (hidden) region, move it to the
  # start of the fold that contains it. Also clamps the viewport top
  # so the scroll stage doesn't start from a stale position.
  @spec clamp_cursor_to_visible(t()) :: t()
  defp clamp_cursor_to_visible(%__MODULE__{fold_map: fm, cursor: {line, col}} = window) do
    window =
      if FoldMap.folded?(fm, line) do
        case FoldMap.fold_at(fm, line) do
          {:ok, %FoldRange{start_line: start}} -> %{window | cursor: {start, col}}
          :none -> window
        end
      else
        window
      end

    # Clamp viewport top: after folding, the visible line count may shrink
    # below the current viewport top, causing negative cursor screen rows.
    # Map the cursor to visible-line space and ensure the viewport top
    # doesn't exceed it.
    {cursor_line, _} = window.cursor
    visible_cursor = FoldMap.buffer_to_visible(fm, cursor_line)
    vp = window.viewport

    if vp.top > visible_cursor do
      %{window | viewport: Viewport.put_top(vp, max(visible_cursor - 5, 0))}
    else
      window
    end
  end

  @doc "Updates the available fold ranges (from a provider). Preserves existing folds that still exist in the new ranges."
  @spec set_fold_ranges(t(), [FoldRange.t()]) :: t()
  def set_fold_ranges(%__MODULE__{fold_map: fm, fold_ranges: old_ranges} = window, new_ranges) do
    # Keep existing folds that still match a range in the new set
    surviving_folds =
      Enum.filter(FoldMap.folds(fm), fn old_fold ->
        Enum.any?(new_ranges, fn new_range ->
          new_range.start_line == old_fold.start_line and
            new_range.end_line == old_fold.end_line
        end)
      end)

    new_fm = FoldMap.from_ranges(surviving_folds)

    window =
      %{window | fold_ranges: new_ranges, fold_map: new_fm}
      |> clamp_cursor_to_visible()

    if old_ranges == new_ranges do
      window
    else
      invalidate(window)
    end
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
  def mark_dirty(%__MODULE__{render_cache: cache} = window, lines) do
    %{window | render_cache: RenderCache.mark_dirty(cache, lines)}
  end

  @doc """
  Marks all lines dirty (full redraw needed).

  Clears all caches and resets tracking fields to sentinels so the next
  render pass starts from scratch. Use this when the window's buffer
  changes, on resize, or any other event that makes all cached draws
  invalid.
  """
  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{render_cache: cache} = window) do
    %{window | render_cache: RenderCache.reset(cache)}
  end

  @doc """
  Returns true if the given buffer line needs re-rendering.

  Always true when `dirty_lines` is `:all`.
  """
  @spec dirty?(t(), non_neg_integer()) :: boolean()
  def dirty?(%__MODULE__{render_cache: cache}, line), do: RenderCache.dirty?(cache, line)

  @doc "Returns the retained composed rows from the previous semantic content build (#2287)."
  @spec retained_rows(t()) :: %{optional(non_neg_integer()) => RenderCache.retained_row()}
  def retained_rows(%__MODULE__{render_cache: cache}), do: RenderCache.retained_rows(cache)

  @doc "Stores the current frame's retained composed rows for upstream reuse next frame (#2287)."
  @spec put_retained_rows(t(), %{optional(non_neg_integer()) => RenderCache.retained_row()}) ::
          t()
  def put_retained_rows(%__MODULE__{render_cache: cache} = window, rows) do
    %{window | render_cache: RenderCache.put_retained_rows(cache, rows)}
  end

  @doc "Returns the retained wrapped logical lines from the previous semantic content build (#2287)."
  @spec retained_wrap_lines(t()) ::
          %{optional(non_neg_integer()) => RenderCache.retained_wrap_line()}
  def retained_wrap_lines(%__MODULE__{render_cache: cache}),
    do: RenderCache.retained_wrap_lines(cache)

  @doc "Stores the current frame's retained wrapped logical lines for upstream reuse next frame (#2287)."
  @spec put_retained_wrap_lines(
          t(),
          %{optional(non_neg_integer()) => RenderCache.retained_wrap_line()}
        ) :: t()
  def put_retained_wrap_lines(%__MODULE__{render_cache: cache} = window, lines) do
    %{window | render_cache: RenderCache.put_retained_wrap_lines(cache, lines)}
  end

  @doc "Reconciles durable logical-line identities from an atomic buffer snapshot."
  @spec sync_line_identity(t(), Minga.Buffer.RenderSnapshot.t()) :: t()
  def sync_line_identity(
        %__MODULE__{render_cache: cache, content: {:buffer, buffer}} = window,
        snapshot
      ) do
    %{window | render_cache: RenderCache.sync_line_identity(cache, buffer, snapshot)}
  end

  @doc "Overlays renderer-owned committed lineage onto a window snapshot."
  @spec put_lineage(
          t(),
          Minga.RenderModel.Window.LineIdentity.t(),
          non_neg_integer()
        ) :: t()
  def put_lineage(
        %__MODULE__{render_cache: cache, content: {:buffer, buffer}} = window,
        identity,
        sequence
      ) do
    %{window | render_cache: RenderCache.put_lineage(cache, buffer, identity, sequence)}
  end

  @doc "Returns the renderer-consumed version pinned for bounded line fetches."
  @spec expected_buffer_version(t()) :: non_neg_integer() | nil
  def expected_buffer_version(%__MODULE__{render_cache: cache}),
    do: RenderCache.fetch_version(cache)

  @doc "Returns the producer-owned stable row-slot allocator."
  @spec row_slot_allocator(t()) :: Minga.RenderModel.Window.RowSlotAllocator.t()
  def row_slot_allocator(%__MODULE__{render_cache: cache}) do
    RenderCache.row_slot_allocator(cache)
  end

  @doc "Stores the producer-owned stable row-slot allocator."
  @spec put_row_slot_allocator(t(), Minga.RenderModel.Window.RowSlotAllocator.t()) :: t()
  def put_row_slot_allocator(%__MODULE__{render_cache: cache} = window, allocator) do
    %{window | render_cache: RenderCache.put_row_slot_allocator(cache, allocator)}
  end

  @doc "Returns the applied buffer change sequence for durable line identity."
  @spec applied_change_sequence(t()) :: non_neg_integer()
  def applied_change_sequence(%__MODULE__{render_cache: cache}) do
    RenderCache.applied_change_sequence(cache)
  end

  @doc "Explicitly rebuilds durable content identity in a fresh epoch."
  @spec reset_content_identity(t(), Minga.Buffer.RenderSnapshot.t()) :: t()
  def reset_content_identity(
        %__MODULE__{render_cache: cache, content: {:buffer, buffer}} = window,
        snapshot
      ) do
    %{window | render_cache: RenderCache.reset_content_identity(cache, buffer, snapshot)}
  end

  @doc "Returns the window's durable content epoch."
  @spec content_epoch(t()) :: non_neg_integer()
  def content_epoch(%__MODULE__{render_cache: cache}), do: RenderCache.content_epoch(cache)

  @doc "Returns the window's durable logical-line identity sequence."
  @spec line_identity(t()) :: Minga.RenderModel.Window.LineIdentity.t() | nil
  def line_identity(%__MODULE__{render_cache: cache}), do: RenderCache.line_identity(cache)

  @doc "Returns the explicit reason for the next resident hydration."
  @spec hydration_reason(t()) :: atom() | nil
  def hydration_reason(%__MODULE__{render_cache: cache}), do: RenderCache.hydration_reason(cache)

  @doc "Returns renderer-consumed edit deltas pending resident composition."
  @spec pending_edit_deltas(t()) :: [Minga.Buffer.EditDelta.t()]
  def pending_edit_deltas(%__MODULE__{render_cache: cache}),
    do: RenderCache.pending_edit_deltas(cache)

  @doc "Returns the atomic bounded snapshot for pending resident deltas."
  @spec changed_snapshot(t()) :: Minga.Buffer.RenderSnapshot.t() | nil
  def changed_snapshot(%__MODULE__{render_cache: cache}),
    do: RenderCache.changed_snapshot(cache)

  @doc "Returns the persistent full-document residence build state (#2658)."
  @spec resident_build(t()) :: MingaEditor.RenderModel.Window.ResidentBuild.t() | nil
  def resident_build(%__MODULE__{render_cache: cache}), do: RenderCache.resident_build(cache)

  @doc "Stores the current frame's residence build state for incremental reuse next frame (#2658)."
  @spec put_resident_build(t(), MingaEditor.RenderModel.Window.ResidentBuild.t() | nil) :: t()
  def put_resident_build(%__MODULE__{render_cache: cache} = window, state) do
    %{window | render_cache: RenderCache.put_resident_build(cache, state)}
  end

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
  def detect_invalidation(
        %__MODULE__{render_cache: cache} = window,
        viewport_top,
        gutter_w,
        line_count,
        buf_version
      ) do
    %{
      window
      | render_cache:
          RenderCache.detect_invalidation(cache, viewport_top, gutter_w, line_count, buf_version)
    }
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
        %__MODULE__{render_cache: cache} = window,
        viewport_top,
        gutter_w,
        line_count,
        buf_version,
        cursor_line
      ) do
    %{
      window
      | render_cache:
          RenderCache.detect_invalidation(
            cache,
            viewport_top,
            viewport_top,
            gutter_w,
            line_count,
            buf_version,
            cursor_line
          )
    }
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
        %__MODULE__{render_cache: cache} = window,
        viewport_top,
        viewport_cache_key,
        gutter_w,
        line_count,
        buf_version,
        cursor_line
      ) do
    %{
      window
      | render_cache:
          RenderCache.detect_invalidation(
            cache,
            viewport_top,
            viewport_cache_key,
            gutter_w,
            line_count,
            buf_version,
            cursor_line
          )
    }
  end

  @doc """
  Compares the current render context fingerprint against the last frame's.

  If the fingerprint changed, marks all lines dirty. This catches changes
  to visual selection, search matches, syntax highlights, diagnostic signs,
  git signs, horizontal scroll, active/inactive status, and theme colors,
  all of which affect every visible line's draw output.
  """
  @spec detect_context_change(t(), RenderCache.context_fingerprint()) :: t()
  def detect_context_change(%__MODULE__{render_cache: cache} = window, fingerprint) do
    %{window | render_cache: RenderCache.detect_context_change(cache, fingerprint)}
  end

  @doc "Marks the next retained GUI frame as a frontend-state reset without discarding TUI draw caches."
  @spec mark_frontend_reset_pending(t()) :: t()
  def mark_frontend_reset_pending(%__MODULE__{render_cache: cache} = window) do
    %{window | render_cache: RenderCache.mark_reset_pending(cache)}
  end

  @doc "Prepares the retained GUI content epoch for the current frame."
  @spec prepare_render_epoch(t(), term()) :: {t(), non_neg_integer(), boolean()}
  def prepare_render_epoch(%__MODULE__{render_cache: cache} = window, reset_fingerprint) do
    {cache, epoch, full_refresh?} = RenderCache.prepare_epoch(cache, reset_fingerprint)
    {%{window | render_cache: cache}, epoch, full_refresh?}
  end

  @doc "Returns a cached wrapped visual row total when the key matches."
  @spec cached_total_visual_rows(t(), term()) :: non_neg_integer() | nil
  def cached_total_visual_rows(%__MODULE__{render_cache: cache}, key) do
    RenderCache.cached_total_visual_rows(cache, key)
  end

  @doc "Stores the wrapped visual row total for the current cache key."
  @spec put_total_visual_rows(t(), term(), non_neg_integer()) :: t()
  def put_total_visual_rows(%__MODULE__{render_cache: cache} = window, key, total) do
    %{window | render_cache: RenderCache.put_total_visual_rows(cache, key, total)}
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
          RenderCache.context_fingerprint()
        ) :: t()
  def snapshot_after_render(
        %__MODULE__{render_cache: cache} = window,
        viewport_top,
        gutter_w,
        line_count,
        cursor_line,
        buf_version,
        ctx_fingerprint
      ) do
    %{
      window
      | render_cache:
          RenderCache.snapshot(
            cache,
            viewport_top,
            viewport_top,
            gutter_w,
            line_count,
            cursor_line,
            buf_version,
            ctx_fingerprint
          )
    }
  end

  @spec snapshot_after_render(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          RenderCache.context_fingerprint()
        ) :: t()
  def snapshot_after_render(
        %__MODULE__{render_cache: cache} = window,
        viewport_top,
        viewport_cache_key,
        gutter_w,
        line_count,
        cursor_line,
        buf_version,
        ctx_fingerprint
      ) do
    %{
      window
      | render_cache:
          RenderCache.snapshot(
            cache,
            viewport_top,
            viewport_cache_key,
            gutter_w,
            line_count,
            cursor_line,
            buf_version,
            ctx_fingerprint
          )
    }
  end
end
