defmodule MingaEditor.RenderPipeline.Scroll do
  @moduledoc """
  Stage 3: Scroll.

  Per-window viewport adjustment and buffer data fetch. For each window
  in the layout, reads the cursor position, computes the viewport scroll,
  fetches buffer lines, and determines gutter dimensions. Also runs
  per-window invalidation detection by comparing current scroll position,
  gutter width, line count, and buffer version against the window's
  tracking fields from the previous frame.
  """

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias Minga.Core.WrapMap
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.FoldMap.VisibleLines
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout
  alias MingaEditor.InlineAsk.Render, as: InlineAskRender
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Renderer.SearchHighlight
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  defmodule WindowScroll do
    @moduledoc """
    Per-window data produced by the scroll stage.

    Bundles the viewport, buffer snapshot, cursor positions, and gutter
    dimensions for one window. The content stage consumes this to produce
    draws without making any GenServer calls.
    """

    alias MingaEditor.FoldMap.VisibleLines
    alias MingaEditor.Layout
    alias MingaEditor.Viewport
    alias MingaEditor.Window

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
      :buf_version,
      :width_oracle
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
      :width_oracle,
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
            width_oracle: Minga.Core.WidthOracle.t(),
            visible_line_map: [VisibleLines.line_entry()] | [MingaEditor.DisplayMap.entry()] | nil
          }
  end

  @typedoc "Render pipeline input."
  @type state :: Input.t()

  @doc """
  Per-window viewport adjustment and buffer data fetch.

  Returns `{scrolls, updated_state}` where `updated_state` has the
  windows map updated with invalidation results.
  """
  @spec scroll_windows(state(), Layout.t()) :: {%{Window.id() => WindowScroll.t()}, state()}
  def scroll_windows(input, layout) do
    layout.window_layouts
    |> Enum.reduce({%{}, input}, fn {win_id, win_layout}, {acc, st} ->
      window = Map.get(st.workspace.windows.map, win_id)

      if window == nil or window.buffer == nil or match?({:agent_chat, _}, window.content) do
        # Skip nil windows and agent chat windows (rendered by build_agent_chat_content)
        {acc, st}
      else
        scroll_and_invalidate(input, st, acc, win_id, window, win_layout)
      end
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  # Scrolls a single window and detects invalidation. Guards against buffer
  # death in the race window between the process dying and the :DOWN message
  # being processed. Only scroll_window makes GenServer calls to the buffer;
  # the invalidation detection is pure computation.
  @spec scroll_and_invalidate(
          state(),
          state(),
          %{Window.id() => WindowScroll.t()},
          Window.id(),
          Window.t(),
          Layout.window_layout()
        ) :: {%{Window.id() => WindowScroll.t()}, state()}
  defp scroll_and_invalidate(state, st, acc, win_id, window, win_layout) do
    is_active = win_id == state.workspace.windows.active

    case safe_scroll_window(st, win_id, window, win_layout, is_active) do
      :skip ->
        {acc, st}

      {:ok, scroll} ->
        updated_window =
          window
          |> Window.set_viewport(scroll.viewport)
          |> Window.detect_invalidation(
            scroll.viewport.top,
            Viewport.cache_key(scroll.viewport),
            scroll.gutter_w,
            scroll.snapshot.line_count,
            scroll.buf_version,
            scroll.cursor_line
          )

        updated_window =
          detect_gutter_invalidation(
            updated_window,
            scroll.cursor_line,
            scroll.line_number_style
          )

        scroll = %{scroll | window: updated_window}
        new_map = Map.put(st.workspace.windows.map, win_id, updated_window)

        windows = Windows.set_map(st.workspace.windows, new_map)
        st = %{st | workspace: put_windows(st.workspace, windows)}

        {Map.put(acc, win_id, scroll), st}
    end
  end

  @spec put_windows(map(), Windows.t()) :: map()
  defp put_windows(workspace, windows) when is_map(workspace),
    do: Map.put(workspace, :windows, windows)

  # Wraps scroll_window with a catch for dead buffer processes. Returns
  # {:ok, scroll} on success, :skip if the buffer died mid-call.
  @spec safe_scroll_window(state(), Window.id(), Window.t(), Layout.window_layout(), boolean()) ::
          {:ok, WindowScroll.t()} | :skip
  defp safe_scroll_window(state, win_id, window, win_layout, is_active) do
    {:ok, scroll_window(state, win_id, window, win_layout, is_active)}
  catch
    :exit, _ ->
      Minga.Log.debug(:render, "[scroll] skipped window #{win_id}: buffer process dead")
      :skip
  end

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
    width_oracle = Capabilities.width_oracle(state.capabilities)
    scroll_margin = scroll_margin(window.buffer)
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

    # Vertical-only scroll for the active window. Inactive windows preserve their
    # own viewport so hover-wheel scrolling a split does not snap back to the
    # inactive window's stored cursor during the render that follows the mouse event.
    viewport =
      maybe_scroll_active_window_to_cursor(
        viewport,
        visible_cursor_line,
        scroll_margin,
        is_active,
        wrap_on
      )

    visible_rows = Viewport.content_rows(viewport)

    # Map viewport visible range back to buffer lines
    {vis_first, _vis_last} = Viewport.visible_range(viewport)

    first_line =
      if FoldMap.empty?(fold_map) do
        vis_first
      else
        FoldMap.visible_to_buffer(fold_map, vis_first)
      end

    # Compute final gutter dimensions before building the DisplayMap.
    # Dynamic block decorations must see the same text width in scroll, content, and GUI gutter paths.
    line_count_approx = Buffer.line_count(window.buffer)
    line_number_style = Buffer.get_option(window.buffer, :line_numbers)

    {has_sign_column, gutter_w} =
      gutter_dimensions(state, window.buffer, line_number_style, line_count_approx)

    content_w = max(viewport.cols - gutter_w, 1)

    # Compute which buffer lines are visible at each screen row.
    # The DisplayMap merges per-window folds, decoration folds, and virtual
    # lines into a unified mapping. Falls back to VisibleLines when there
    # are no decoration folds or virtual lines (pure window-fold case).
    decorations = fetch_decorations(state, window.buffer)

    # Two-pass scroll: compute DisplayMap, then verify cursor is visible.
    # If decorations push the cursor off-screen, adjust first_line and recompute.
    {first_line, visible_line_map} =
      if DisplayMap.required?(fold_map, decorations) do
        compute_display_map_with_cursor_check(
          fold_map,
          decorations,
          first_line,
          visible_rows,
          line_count_approx,
          content_w,
          cursor_line
        )
      else
        {first_line, nil}
      end

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

    snapshot = Buffer.render_snapshot(window.buffer, fetch_first, fetch_count)
    lines = snapshot.lines
    # Cursor byte → display col
    {viewport, first_line, snapshot, lines, _cursor_line_text, cursor_col} =
      maybe_adjust_wrapped_viewport(%{
        wrap_on: wrap_on,
        is_active: is_active,
        viewport: viewport,
        first_line: first_line,
        lines: lines,
        snapshot: snapshot,
        buf: window.buffer,
        cursor_line: cursor_line,
        cursor_byte_col: cursor_byte_col,
        content_w: content_w,
        visible_rows: visible_rows,
        scroll_margin: scroll_margin,
        fetch_count: fetch_count,
        oracle: width_oracle,
        visible_line_map: visible_line_map
      })

    wrap_on = wrap_on and is_nil(visible_line_map)

    # Horizontal scroll (disabled when wrapping).
    # Use content_w (text area excluding gutter) as the effective width,
    # so the cursor triggers scroll when it reaches the content edge,
    # not the full viewport edge.
    viewport =
      if is_active do
        scroll_horizontal(viewport, cursor_line, cursor_col, wrap_on, content_w, scroll_margin)
      else
        viewport
      end

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
      width_oracle: width_oracle,
      visible_line_map: visible_line_map
    }
  end

  @spec maybe_adjust_wrapped_viewport(map()) ::
          {Viewport.t(), non_neg_integer(), map(), [String.t()], String.t(), non_neg_integer()}
  defp maybe_adjust_wrapped_viewport(%{
         wrap_on: false,
         viewport: viewport,
         first_line: first_line,
         lines: lines,
         snapshot: snapshot,
         cursor_line: cursor_line,
         cursor_byte_col: cursor_byte_col
       }) do
    text = cursor_line_text(lines, cursor_line, first_line)
    {viewport, first_line, snapshot, lines, text, Unicode.display_col(text, cursor_byte_col)}
  end

  defp maybe_adjust_wrapped_viewport(%{
         wrap_on: true,
         is_active: false,
         viewport: viewport,
         first_line: first_line,
         lines: lines,
         snapshot: snapshot,
         cursor_line: cursor_line,
         cursor_byte_col: cursor_byte_col
       }) do
    text = cursor_line_text(lines, cursor_line, first_line)
    {viewport, first_line, snapshot, lines, text, Unicode.display_col(text, cursor_byte_col)}
  end

  defp maybe_adjust_wrapped_viewport(
         %{
           wrap_on: true,
           is_active: true,
           visible_line_map: visible_line_map
         } = params
       )
       when is_list(visible_line_map) do
    text = cursor_line_text(params.lines, params.cursor_line, params.first_line)

    {params.viewport, params.first_line, params.snapshot, params.lines, text,
     Unicode.display_col(text, params.cursor_byte_col)}
  end

  defp maybe_adjust_wrapped_viewport(
         %{
           wrap_on: true,
           is_active: true,
           first_line: first_line,
           lines: lines,
           cursor_line: cursor_line
         } = params
       ) do
    if cursor_line < first_line or cursor_line >= first_line + length(lines) do
      refetch_wrapped_viewport(Map.merge(params, %{top: cursor_line, offset: 0}))
    else
      adjust_wrapped_viewport_from_map(params)
    end
  end

  @spec adjust_wrapped_viewport_from_map(map()) ::
          {Viewport.t(), non_neg_integer(), map(), [String.t()], String.t(), non_neg_integer()}
  defp adjust_wrapped_viewport_from_map(
         %{
           viewport: viewport,
           first_line: first_line,
           lines: lines,
           snapshot: snapshot,
           buf: buf,
           cursor_line: cursor_line,
           cursor_byte_col: cursor_byte_col,
           content_w: content_w,
           visible_rows: visible_rows,
           scroll_margin: scroll_margin,
           oracle: oracle,
           fetch_count: fetch_count
         } = params
       ) do
    wrap_map = compute_wrap_map(buf, lines, content_w, oracle)
    cursor_idx = cursor_line - first_line

    cursor_entry =
      Enum.at(wrap_map, cursor_idx, [
        %{byte_offset: 0, text: "", source_text: "", indent_width: 0}
      ])

    cursor_visual_row = visual_row_index(cursor_entry, cursor_byte_col)
    rows_before_cursor = wrap_map |> Enum.take(cursor_idx) |> WrapMap.visual_row_count()
    cursor_abs = rows_before_cursor + cursor_visual_row
    effective_margin = min(scroll_margin, div(visible_rows - 1, 2))

    desired_start =
      desired_visual_start(viewport.visual_row_offset, cursor_abs, visible_rows, effective_margin)

    {new_top, new_offset, top_count} = visual_start_to_top(wrap_map, first_line, desired_start)

    total_lines = Buffer.line_count(buf)
    near_eof = new_top + visible_rows >= total_lines - 1

    total_visual_rows_to_eof =
      if near_eof do
        visual_rows_to_eof(buf, new_top, content_w, oracle)
      else
        top_count
      end

    new_offset =
      if near_eof do
        min(new_offset, Viewport.max_visual_row_offset(total_visual_rows_to_eof, visible_rows))
      else
        new_offset
      end

    top_count = max(top_count, total_visual_rows_to_eof)
    new_viewport = Viewport.put_top_visual(viewport, new_top, new_offset, top_count)

    if new_top == first_line and not near_eof do
      text = cursor_line_text(lines, cursor_line, first_line)

      {new_viewport, first_line, snapshot, lines, text,
       Unicode.display_col(text, cursor_byte_col)}
    else
      refetch_wrapped_viewport(
        Map.merge(params, %{
          viewport: new_viewport,
          top: new_top,
          offset: new_offset,
          fetch_count:
            if(near_eof, do: max(fetch_count, max(total_lines - new_top, 1)), else: fetch_count)
        })
      )
    end
  end

  @spec refetch_wrapped_viewport(map()) ::
          {Viewport.t(), non_neg_integer(), map(), [String.t()], String.t(), non_neg_integer()}
  defp refetch_wrapped_viewport(%{
         viewport: viewport,
         top: top,
         offset: offset,
         buf: buf,
         cursor_line: cursor_line,
         cursor_byte_col: cursor_byte_col,
         content_w: content_w,
         fetch_count: fetch_count,
         oracle: oracle
       }) do
    snapshot = Buffer.render_snapshot(buf, top, fetch_count)
    lines = snapshot.lines
    wrap_map = compute_wrap_map(buf, lines, content_w, oracle)

    top_count =
      wrap_map
      |> List.first([%{byte_offset: 0, text: "", source_text: "", indent_width: 0}])
      |> length()
      |> max(1)

    viewport = Viewport.put_top_visual(viewport, top, offset, top_count)
    text = cursor_line_text(lines, cursor_line, top)
    {viewport, top, snapshot, lines, text, Unicode.display_col(text, cursor_byte_col)}
  end

  @spec desired_visual_start(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  defp desired_visual_start(current_start, cursor_abs, _visible_rows, margin)
       when cursor_abs < current_start + margin do
    if current_start > 0 and cursor_abs >= current_start do
      current_start
    else
      max(cursor_abs - margin, 0)
    end
  end

  defp desired_visual_start(current_start, cursor_abs, visible_rows, margin)
       when cursor_abs >= current_start + visible_rows - margin do
    max(cursor_abs - visible_rows + 1 + margin, 0)
  end

  defp desired_visual_start(current_start, _cursor_abs, _visible_rows, _margin), do: current_start

  @spec visual_start_to_top(WrapMap.t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer(), pos_integer()}
  defp visual_start_to_top(wrap_map, first_line, desired_start) do
    do_visual_start_to_top(wrap_map, first_line, desired_start)
  end

  @spec do_visual_start_to_top(WrapMap.t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer(), pos_integer()}
  defp do_visual_start_to_top([], first_line, _desired_start), do: {first_line, 0, 1}

  defp do_visual_start_to_top([entry | rest], line, desired_start) do
    count = max(length(entry), 1)

    if desired_start < count do
      {line, desired_start, count}
    else
      do_visual_start_to_top(rest, line + 1, desired_start - count)
    end
  end

  @spec visual_rows_to_eof(pid(), non_neg_integer(), pos_integer(), Minga.Core.WidthOracle.t()) ::
          pos_integer()
  defp visual_rows_to_eof(buf, start_line, content_w, oracle) do
    total_lines = Buffer.line_count(buf)
    fetch_count = max(total_lines - start_line, 1)
    snapshot = Buffer.render_snapshot(buf, start_line, fetch_count)

    WrapMap.compute(snapshot.lines, content_w,
      breakindent: wrap_option(buf, :breakindent),
      linebreak: wrap_option(buf, :linebreak),
      oracle: oracle,
      tab_width: tab_width(buf)
    )
    |> WrapMap.visual_row_count()
    |> max(1)
  catch
    :exit, _ -> 1
  end

  @spec compute_wrap_map(pid(), [String.t()], pos_integer(), Minga.Core.WidthOracle.t()) ::
          WrapMap.t()
  defp compute_wrap_map(buf, lines, content_w, oracle) do
    WrapMap.compute(lines, content_w,
      breakindent: wrap_option(buf, :breakindent),
      linebreak: wrap_option(buf, :linebreak),
      oracle: oracle,
      tab_width: tab_width(buf)
    )
  end

  @spec visual_row_index(WrapMap.wrap_entry(), non_neg_integer()) :: non_neg_integer()
  defp visual_row_index(wrap_entry, cursor_byte_col) do
    wrap_entry
    |> Enum.with_index()
    |> Enum.filter(fn {row, _idx} -> row.byte_offset <= cursor_byte_col end)
    |> List.last({%{byte_offset: 0}, 0})
    |> elem(1)
  end

  @spec wrap_option(pid(), atom()) :: boolean()
  defp wrap_option(buf, name) do
    Buffer.get_option(buf, name)
  catch
    :exit, _ -> true
  end

  @spec tab_width(pid()) :: pos_integer()
  defp tab_width(buf) do
    Buffer.get_option(buf, :tab_width)
  catch
    :exit, _ -> 2
  end

  @spec maybe_scroll_active_window_to_cursor(
          Viewport.t(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          boolean()
        ) :: Viewport.t()
  defp maybe_scroll_active_window_to_cursor(
         viewport,
         _visible_cursor_line,
         _scroll_margin,
         false,
         _wrap_on
       ),
       do: viewport

  defp maybe_scroll_active_window_to_cursor(
         viewport,
         _visible_cursor_line,
         _scroll_margin,
         true,
         true
       ) do
    viewport
  end

  defp maybe_scroll_active_window_to_cursor(
         viewport,
         visible_cursor_line,
         scroll_margin,
         true,
         false
       ) do
    saved_left = viewport.left

    viewport
    |> Viewport.scroll_to_cursor({visible_cursor_line, 0}, scroll_margin)
    |> Map.put(:left, saved_left)
  end

  @spec fetch_decorations(term(), pid()) :: Decorations.t()
  defp fetch_decorations(state, buf) do
    buf
    |> Buffer.decorations()
    |> InlineAskRender.merge_decorations(state, buf)
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
    old_cursor = window.render_cache.last_cursor_line

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
  defp window_cursor(window, true), do: Buffer.cursor(window.buffer)
  defp window_cursor(window, false), do: window.cursor

  @spec scroll_horizontal(
          Viewport.t(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          pos_integer(),
          non_neg_integer()
        ) :: Viewport.t()
  defp scroll_horizontal(
         vp,
         _cursor_line,
         _cursor_col,
         true = _wrap_on,
         _content_w,
         _scroll_margin
       ) do
    # Wrapping: no horizontal scroll needed. Just reset left to 0.
    # Vertical scroll is handled separately above (save/restore pattern).
    %{vp | left: 0}
  end

  defp scroll_horizontal(vp, cursor_line, cursor_col, false = _wrap_on, content_w, scroll_margin) do
    if cursor_col >= vp.left and cursor_col < vp.left + content_w do
      vp
    else
      # Cursor fits within the first viewport-width of content; reset scroll rather than re-computing
      if cursor_col < content_w do
        %{vp | left: 0}
      else
        content_vp = %{vp | cols: content_w}
        adjusted = Viewport.scroll_to_cursor(content_vp, {cursor_line, cursor_col}, scroll_margin)
        %{vp | left: adjusted.left}
      end
    end
  end

  @spec scroll_margin(pid()) :: non_neg_integer()
  defp scroll_margin(buf) do
    Buffer.get_option(buf, :scroll_margin)
  catch
    :exit, _ -> 5
  end

  @spec wrap_enabled?(pid()) :: boolean()
  defp wrap_enabled?(buf) do
    Buffer.get_option(buf, :wrap)
  catch
    :exit, _ -> false
  end

  @spec gutter_dimensions(state(), pid(), atom(), non_neg_integer()) ::
          {boolean(), non_neg_integer()}
  defp gutter_dimensions(_state, _buf, line_number_style, line_count) do
    # Sign column is always reserved for consistent gutter layout.
    # This prevents line numbers from shifting when diagnostics or git
    # markers appear.
    number_w =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    {true, Gutter.total_width(number_w)}
  end

  @spec cursor_line_text([String.t()], non_neg_integer(), non_neg_integer()) :: String.t()
  defp cursor_line_text(lines, cursor_line, first_line) do
    index = cursor_line - first_line

    if index >= 0 do
      case Enum.fetch(lines, index) do
        {:ok, line} -> line
        :error -> ""
      end
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
