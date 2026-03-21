defmodule Minga.Editor.RenderPipeline.Scroll do
  @moduledoc """
  Stage 3: Scroll.

  Per-window viewport adjustment and buffer data fetch. For each window
  in the layout, reads the cursor position, computes the viewport scroll,
  fetches buffer lines, and determines gutter dimensions. Also runs
  per-window invalidation detection by comparing current scroll position,
  gutter width, line count, and buffer version against the window's
  tracking fields from the previous frame.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Editor.DisplayMap
  alias Minga.Editor.FoldMap
  alias Minga.Editor.FoldMap.VisibleLines
  alias Minga.Editor.Layout
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window

  alias Minga.Git.Tracker, as: GitTracker

  defmodule WindowScroll do
    @moduledoc """
    Per-window data produced by the scroll stage.

    Bundles the viewport, buffer snapshot, cursor positions, and gutter
    dimensions for one window. The content stage consumes this to produce
    draws without making any GenServer calls.
    """

    alias Minga.Editor.FoldMap.VisibleLines
    alias Minga.Editor.Layout
    alias Minga.Editor.Viewport
    alias Minga.Editor.Window

    @enforce_keys [
      :win_id,
      :window,
      :win_layout,
      :is_active,
      :viewport,
      :cursor_line,
      :cursor_byte_col,
      :cursor_col,
      :first_line,
      :lines,
      :snapshot,
      :gutter_w,
      :content_w,
      :has_sign_column,
      :preview_matches,
      :line_number_style,
      :wrap_on,
      :buf_version
    ]

    defstruct [
      :win_id,
      :window,
      :win_layout,
      :is_active,
      :viewport,
      :cursor_line,
      :cursor_byte_col,
      :cursor_col,
      :first_line,
      :lines,
      :snapshot,
      :gutter_w,
      :content_w,
      :has_sign_column,
      :preview_matches,
      :line_number_style,
      :wrap_on,
      :buf_version,
      visible_line_map: nil
    ]

    @type t :: %__MODULE__{
            win_id: Window.id(),
            window: Window.t(),
            win_layout: Layout.window_layout(),
            is_active: boolean(),
            viewport: Viewport.t(),
            cursor_line: non_neg_integer(),
            cursor_byte_col: non_neg_integer(),
            cursor_col: non_neg_integer(),
            first_line: non_neg_integer(),
            lines: [String.t()],
            snapshot: map(),
            gutter_w: non_neg_integer(),
            content_w: pos_integer(),
            has_sign_column: boolean(),
            preview_matches: list(),
            line_number_style: atom(),
            wrap_on: boolean(),
            buf_version: non_neg_integer(),
            visible_line_map:
              [VisibleLines.line_entry()] | [Minga.Editor.DisplayMap.entry()] | nil
          }
  end

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Per-window viewport adjustment and buffer data fetch.

  Returns `{scrolls, updated_state}` where `updated_state` has the
  windows map updated with invalidation results.
  """
  @spec scroll_windows(state(), Layout.t()) :: {%{Window.id() => WindowScroll.t()}, state()}
  def scroll_windows(state, layout) do
    layout.window_layouts
    |> Enum.reduce({%{}, state}, fn {win_id, win_layout}, {acc, st} ->
      window = Map.get(st.windows.map, win_id)

      if window == nil or window.buffer == nil or match?({:agent_chat, _}, window.content) do
        # Skip nil windows and agent chat windows (rendered by build_agent_chat_content)
        {acc, st}
      else
        is_active = win_id == state.windows.active
        scroll = scroll_window(st, win_id, window, win_layout, is_active)

        # Detect per-window invalidation by comparing against last frame
        updated_window =
          Window.detect_invalidation(
            window,
            scroll.viewport.top,
            scroll.gutter_w,
            scroll.snapshot.line_count,
            scroll.buf_version
          )

        # Also invalidate gutter when cursor line changed with relative numbering
        updated_window =
          detect_gutter_invalidation(
            updated_window,
            scroll.cursor_line,
            scroll.line_number_style
          )

        # Store the invalidated window and update the scroll to reference it
        scroll = %{scroll | window: updated_window}

        new_map = Map.put(st.windows.map, win_id, updated_window)
        st = %{st | windows: %{st.windows | map: new_map}}

        {Map.put(acc, win_id, scroll), st}
      end
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec scroll_window(
          state(),
          Window.id(),
          Window.t(),
          Layout.window_layout(),
          boolean()
        ) :: WindowScroll.t()
  defp scroll_window(state, win_id, window, win_layout, is_active) do
    {_row_off, _col_off, content_width, content_height} = win_layout.content

    # Cursor: active window reads live from buffer; inactive uses stored
    {cursor_line, cursor_byte_col} = window_cursor(window, is_active)

    # Use the window's persistent viewport, updating dimensions from Layout.
    # This preserves the scroll position (viewport.top) across frames so that
    # Ctrl-e/y, zz/zt/zb, and mouse wheel scroll actually persist.
    # scroll_to_cursor only adjusts top when the cursor moves off-screen.
    wrap_on = wrap_enabled?(window.buffer)
    fold_map = window.fold_map
    %Viewport{} = win_vp = window.viewport
    viewport = %{win_vp | rows: content_height, cols: content_width, reserved: 0}

    # When folds are active, scroll in visible-line coordinates.
    # The cursor's buffer line must be mapped to visible-line space
    # so the viewport doesn't try to scroll to a hidden line.
    visible_cursor_line =
      if FoldMap.empty?(fold_map) do
        cursor_line
      else
        FoldMap.buffer_to_visible(fold_map, cursor_line)
      end

    # Vertical-only scroll: preserve horizontal scroll position (viewport.left)
    # so that horizontal scroll from cursor tracking or mouse wheel persists.
    # Passing cursor_col=0 would reset left to 0 via adjust_left.
    # TODO: replace save/restore with Viewport.scroll_to_cursor_vertical/3
    # that only modifies `top`. The same trap exists in mouse.ex:934 and
    # content.ex:470 where {cursor_line, 0} silently resets left.
    saved_left = viewport.left
    viewport = Viewport.scroll_to_cursor(viewport, {visible_cursor_line, 0}, window.buffer)
    viewport = %{viewport | left: saved_left}
    visible_rows = Viewport.content_rows(viewport)

    # Map viewport visible range back to buffer lines
    {vis_first, _vis_last} = Viewport.visible_range(viewport)

    first_line =
      if FoldMap.empty?(fold_map) do
        vis_first
      else
        FoldMap.visible_to_buffer(fold_map, vis_first)
      end

    # Compute which buffer lines are visible at each screen row.
    # The DisplayMap merges per-window folds, decoration folds, and virtual
    # lines into a unified mapping. Falls back to VisibleLines when there
    # are no decoration folds or virtual lines (pure window-fold case).
    line_count_approx = BufferServer.line_count(window.buffer)
    decorations = fetch_decorations(window.buffer)

    # Two-pass scroll: compute DisplayMap, then verify cursor is visible.
    # If decorations push the cursor off-screen, adjust first_line and recompute.
    {first_line, visible_line_map} =
      compute_display_map_with_cursor_check(
        fold_map,
        decorations,
        first_line,
        visible_rows,
        line_count_approx,
        content_width,
        cursor_line
      )

    # Fetch buffer data: need to cover all visible buffer lines
    {fetch_first, fetch_count} =
      case visible_line_map do
        nil ->
          fetch_rows = if wrap_on, do: visible_rows + div(visible_rows, 2), else: visible_rows
          {first_line, fetch_rows}

        entries ->
          {buf_first, buf_last} = buffer_range_from_entries(entries)
          {buf_first, buf_last - buf_first + 1}
      end

    snapshot = BufferServer.render_snapshot(window.buffer, fetch_first, fetch_count)
    lines = snapshot.lines
    line_count = snapshot.line_count

    # Cursor byte → display col
    cursor_line_text = cursor_line_text(lines, cursor_line, first_line)
    cursor_col = Unicode.display_col(cursor_line_text, cursor_byte_col)

    # Gutter dimensions
    line_number_style = BufferServer.get_option(window.buffer, :line_numbers)

    {has_sign_column, gutter_w} =
      gutter_dimensions(state, window.buffer, line_number_style, line_count)

    content_w = max(viewport.cols - gutter_w, 1)

    # Horizontal scroll (disabled when wrapping).
    # Use content_w (text area excluding gutter) as the effective width,
    # so the cursor triggers scroll when it reaches the content edge,
    # not the full viewport edge.
    viewport =
      scroll_horizontal(viewport, cursor_line, cursor_col, wrap_on, content_w, window.buffer)

    # Substitution preview (active window only)
    {lines, preview_matches} =
      if is_active do
        SearchHighlight.maybe_substitute_preview(state, lines, first_line)
      else
        {lines, []}
      end

    %WindowScroll{
      win_id: win_id,
      window: window,
      win_layout: win_layout,
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_byte_col: cursor_byte_col,
      cursor_col: cursor_col,
      first_line: first_line,
      lines: lines,
      snapshot: snapshot,
      gutter_w: gutter_w,
      content_w: content_w,
      has_sign_column: has_sign_column,
      preview_matches: preview_matches,
      line_number_style: line_number_style,
      wrap_on: wrap_on,
      buf_version: snapshot.version,
      visible_line_map: visible_line_map
    }
  end

  @spec fetch_decorations(pid()) :: Decorations.t()
  defp fetch_decorations(buf) do
    BufferServer.decorations(buf)
  catch
    :exit, _ -> Decorations.new()
  end

  # Compute buffer range from a visible_line_map (works for both
  # VisibleLines entries and DisplayMap entries).
  @spec buffer_range_from_entries([{non_neg_integer(), term()}]) ::
          {non_neg_integer(), non_neg_integer()}
  defp buffer_range_from_entries([]), do: {0, 0}

  defp buffer_range_from_entries(entries) do
    lines = Enum.map(entries, fn {line, _} -> line end)
    {Enum.min(lines), Enum.max(lines)}
  end

  # When cursor line changes with relative or hybrid numbering, every
  # gutter entry shows a different number. Mark all lines dirty for
  # re-render. With absolute numbering, cursor movement doesn't affect
  # gutter content so we only mark the old and new cursor lines.
  @spec detect_gutter_invalidation(Window.t(), non_neg_integer(), atom()) :: Window.t()
  defp detect_gutter_invalidation(window, cursor_line, line_number_style) do
    old_cursor = window.last_cursor_line

    if old_cursor == cursor_line or old_cursor < 0 do
      # Cursor didn't move or first frame (already :all dirty)
      window
    else
      case line_number_style do
        style when style in [:relative, :hybrid] ->
          # Every visible line number changes. Use mark_dirty (not
          # invalidate) because the content draws are still valid;
          # only gutter numbers change.
          Window.mark_dirty(window, :all)

        _ ->
          # Only the old and new cursor lines need gutter + cursor highlight update
          Window.mark_dirty(window, [old_cursor, cursor_line])
      end
    end
  end

  @spec window_cursor(Window.t(), boolean()) :: {non_neg_integer(), non_neg_integer()}
  defp window_cursor(window, true), do: BufferServer.cursor(window.buffer)
  defp window_cursor(window, false), do: window.cursor

  @spec scroll_horizontal(
          Viewport.t(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          pos_integer(),
          pid()
        ) :: Viewport.t()
  defp scroll_horizontal(vp, _cursor_line, _cursor_col, true = _wrap_on, _content_w, _buf) do
    # Wrapping: no horizontal scroll needed. Just reset left to 0.
    # Vertical scroll is handled separately above (save/restore pattern).
    %{vp | left: 0}
  end

  defp scroll_horizontal(vp, cursor_line, cursor_col, false = _wrap_on, content_w, buf) do
    # Temporarily set cols to content_w (excluding gutter) so adjust_left
    # triggers scroll at the content edge, not the full viewport edge.
    content_vp = %{vp | cols: content_w}
    adjusted = Viewport.scroll_to_cursor(content_vp, {cursor_line, cursor_col}, buf)
    %{vp | left: adjusted.left}
  end

  @spec wrap_enabled?(pid()) :: boolean()
  defp wrap_enabled?(buf) do
    BufferServer.get_option(buf, :wrap)
  catch
    :exit, _ -> false
  end

  @spec gutter_dimensions(state(), pid(), atom(), non_neg_integer()) ::
          {boolean(), non_neg_integer()}
  defp gutter_dimensions(_state, buf, line_number_style, line_count) do
    has_sign_column =
      GitTracker.tracked?(buf) or BufferServer.file_path(buf) != nil

    sign_w = if has_sign_column, do: Gutter.sign_column_width(), else: 0

    number_w =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    {has_sign_column, number_w + sign_w}
  end

  @spec cursor_line_text([String.t()], non_neg_integer(), non_neg_integer()) :: String.t()
  defp cursor_line_text(lines, cursor_line, first_line) do
    index = cursor_line - first_line

    if index >= 0 and index < length(lines) do
      Enum.at(lines, index)
    else
      ""
    end
  end

  # Two-pass display map computation with cursor visibility check.
  #
  # Pass 1: compute the DisplayMap from the coarse first_line.
  # Pass 2: if the cursor isn't visible in the DisplayMap (decorations
  # pushed it off-screen), adjust first_line and recompute. Caps at 2
  # adjustment iterations to avoid infinite loops.
  @spec compute_display_map_with_cursor_check(
          FoldMap.t(),
          Decorations.t(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: {non_neg_integer(), [term()] | nil}
  defp compute_display_map_with_cursor_check(
         fold_map,
         decorations,
         first_line,
         visible_rows,
         total_lines,
         content_width,
         cursor_line
       ) do
    dm =
      DisplayMap.compute(
        fold_map,
        decorations,
        first_line,
        visible_rows,
        total_lines,
        content_width
      )

    resolve_display_map(
      dm,
      fold_map,
      decorations,
      first_line,
      visible_rows,
      total_lines,
      content_width,
      cursor_line
    )
  end

  # No decorations: fast path.
  defp resolve_display_map(
         nil,
         fold_map,
         _decs,
         first_line,
         visible_rows,
         total_lines,
         _cw,
         _cursor
       ) do
    vlm = VisibleLines.compute(fold_map, first_line, visible_rows, total_lines)
    {first_line, vlm}
  end

  # DisplayMap exists: check cursor visibility and adjust if needed.
  defp resolve_display_map(
         %DisplayMap{} = dm,
         fold_map,
         decorations,
         first_line,
         visible_rows,
         total_lines,
         content_width,
         cursor_line
       ) do
    case DisplayMap.display_row_for_buf_line(dm, cursor_line) do
      row when is_integer(row) and row >= 0 and row < visible_rows ->
        {first_line, DisplayMap.to_visible_line_map(dm)}

      _ ->
        adjusted = adjust_first_line_for_cursor(first_line, cursor_line, visible_rows)

        resolve_adjusted_display_map(
          fold_map,
          decorations,
          adjusted,
          visible_rows,
          total_lines,
          content_width
        )
    end
  end

  defp resolve_adjusted_display_map(
         fold_map,
         decorations,
         adjusted,
         visible_rows,
         total_lines,
         content_width
       ) do
    case DisplayMap.compute(
           fold_map,
           decorations,
           adjusted,
           visible_rows,
           total_lines,
           content_width
         ) do
      nil ->
        vlm = VisibleLines.compute(fold_map, adjusted, visible_rows, total_lines)
        {adjusted, vlm}

      %DisplayMap{} = dm2 ->
        {adjusted, DisplayMap.to_visible_line_map(dm2)}
    end
  end

  # When the cursor is below the visible area, increase first_line.
  # When above, decrease it. The adjustment is bounded to avoid overshooting.
  @spec adjust_first_line_for_cursor(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: non_neg_integer()
  defp adjust_first_line_for_cursor(first_line, cursor_line, visible_rows) do
    if cursor_line >= first_line + visible_rows do
      # Cursor is below: move first_line down so cursor is near bottom
      max(cursor_line - visible_rows + 1, 0)
    else
      # Cursor is above: move first_line up so cursor is near top
      max(cursor_line, 0)
    end
  end
end
