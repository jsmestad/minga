defmodule MingaEditor.Window do
  @moduledoc """
  A window is a viewport into a buffer.

  Each window holds a reference to a buffer process and its own independent
  viewport (scroll position and dimensions). Multiple windows can reference
  the same buffer; edits in one are visible in all.

  `render_cache` contains only bounded input-domain observations. Durable
  render state is owned by `MingaEditor.Renderer.State`.
  """

  alias Minga.Buffer
  alias MingaEditor.FoldMap
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias Minga.Language.Symbol
  alias MingaEditor.Viewport
  alias MingaEditor.Window.Content
  alias MingaEditor.Window.RenderCache
  alias MingaEditor.Window.ScrollVelocity
  alias MingaEditor.UI.Popup.Active, as: PopupActive

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
    render_cache: %RenderCache{
      viewport_top: 0,
      viewport_left: 0,
      cursor_line: 0,
      cursor_col: 0,
      buffer_version: 0
    },
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
      pinned: true
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
      viewport: Viewport.new(rows, cols)
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
  end

  @doc "Switches the window from the launchpad back to a buffer."
  @spec show_buffer(t(), pid()) :: t()
  def show_buffer(%__MODULE__{} = window, buffer) when is_pid(buffer) do
    %{window | content: Content.buffer(buffer)}
    |> set_document_symbols([])
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

  @doc "Remembers the buffer cursor last observed while this window was active."
  @spec remember_cursor(t(), Buffer.position()) :: t()
  def remember_cursor(%__MODULE__{} = window, {line, col} = cursor)
      when is_integer(line) and line >= 0 and is_integer(col) and col >= 0,
      do: %{window | cursor: cursor}

  @doc "Updates the viewport dimensions for this window, marking all lines dirty."
  @spec resize(t(), non_neg_integer(), non_neg_integer()) :: t()
  def resize(%__MODULE__{} = window, rows, cols)
      when is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    set_viewport(window, Viewport.new(rows, cols))
  end

  # When a window is squeezed to zero dimensions (e.g., terminal resized
  # too small with splits active), clamp to 1x1 to avoid downstream crashes.
  def resize(%__MODULE__{} = window, rows, cols)
      when is_integer(rows) and is_integer(cols) do
    resize(window, max(rows, 1), max(cols, 1))
  end

  # ── Scroll helpers ──────────────────────────────────────────────────────────

  @doc "Sets the window cursor."
  @spec set_cursor(t(), Buffer.position()) :: t()
  def set_cursor(%__MODULE__{} = window, {line, col} = cursor)
      when is_integer(line) and line >= 0 and is_integer(col) and col >= 0,
      do: %{window | cursor: cursor}

  @doc "Stores the computed viewport for this window."
  @spec set_viewport(t(), Viewport.t()) :: t()
  def set_viewport(%__MODULE__{} = window, %Viewport{} = viewport) do
    %{window | viewport: viewport}
  end

  @doc "Commits bounded viewport/cursor input metadata from a synchronous render."
  @spec observe_render(t(), Viewport.t(), non_neg_integer()) :: t()
  def observe_render(%__MODULE__{} = window, %Viewport{} = viewport, buffer_version) do
    {cursor_line, cursor_col} = window.cursor

    %{
      window
      | viewport: viewport,
        render_cache:
          RenderCache.new(
            viewport.top,
            viewport.left,
            cursor_line,
            cursor_col,
            buffer_version
          )
    }
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

    max_top = max(total_lines - visible, 0)

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

  @spec scroll_follow_cursor?(t(), Buffer.position(), integer()) :: {t(), boolean()}
  def scroll_follow_cursor?(%__MODULE__{} = window, cursor_pos, now_ms) do
    cond do
      scroll_velocity_tier(window, now_ms) != :idle ->
        {window, false}

      window.scroll_detach_cursor != nil and cursor_pos == window.scroll_detach_cursor ->
        {window, false}

      window.scroll_detach_cursor != nil ->
        {%{window | scroll_detach_cursor: nil}, true}

      true ->
        {window, true}
    end
  end

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

  @doc "Updates textobject positions available for this window."
  @spec set_textobject_positions(t(), map()) :: t()
  def set_textobject_positions(%__MODULE__{} = window, positions) when is_map(positions) do
    %{window | textobject_positions: positions}
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
    end
  end

  @doc "Unfolds the range containing the given buffer line."
  @spec unfold_at(t(), non_neg_integer()) :: t()
  def unfold_at(%__MODULE__{fold_map: fm} = window, line) do
    new_fm = FoldMap.unfold_at(fm, line)

    if new_fm == fm do
      window
    else
      %{window | fold_map: new_fm}
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
    end
  end

  @doc "Unfolds every active fold inside the outermost range containing the given buffer line."
  @spec unfold_recursive_at(t(), non_neg_integer()) :: t()
  def unfold_recursive_at(%__MODULE__{fold_map: fm, fold_ranges: ranges} = window, line) do
    new_fm = FoldMap.unfold_recursive(fm, line, ranges)

    if new_fm == fm do
      window
    else
      %{window | fold_map: new_fm}
    end
  end

  @doc "Folds all available ranges."
  @spec fold_all(t()) :: t()
  def fold_all(%__MODULE__{fold_ranges: ranges} = window) do
    %{window | fold_map: FoldMap.fold_all(FoldMap.new(), ranges)}
    |> clamp_cursor_to_visible()
  end

  @doc "Unfolds all folds."
  @spec unfold_all(t()) :: t()
  def unfold_all(%__MODULE__{} = window) do
    %{window | fold_map: FoldMap.unfold_all(window.fold_map)}
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
      window
    end
  end

  @doc "Unfolds any folds that contain the given lines (used by search auto-unfold)."
  @spec unfold_containing(t(), [non_neg_integer()]) :: t()
  def unfold_containing(%__MODULE__{fold_map: fm} = window, lines) do
    new_fm = FoldMap.unfold_containing(fm, lines)

    if new_fm == fm do
      window
    else
      %{window | fold_map: new_fm}
    end
  end
end
