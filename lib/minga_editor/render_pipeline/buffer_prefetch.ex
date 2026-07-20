defmodule MingaEditor.RenderPipeline.BufferPrefetch do
  @moduledoc """
  Pre-stage buffer snapshot prefetch.

  Per-window viewport adjustment and buffer data fetch. For each window
  in the layout, reads the cursor position, computes the viewport scroll,
  fetches buffer lines, and determines gutter dimensions. Also runs
  per-window invalidation detection by comparing current scroll position,
  gutter width, line count, and buffer version against the window's
  tracking fields from the previous frame.
  """

  alias Minga.Buffer
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.RenderSnapshot
  alias Minga.Config
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias Minga.Core.WidthOracle
  alias Minga.Core.WrapMap
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.FoldMap.VisibleLines
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout
  alias MingaEditor.BufferDecorations
  alias MingaEditor.RenderModel.Window.ResidentBuild
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Renderer.SearchHighlight
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Renderer.RenderWindow, as: Window

  @typedoc "Render pipeline input."
  @type state :: Input.t()

  # Fixed overscan for the surviving non-wrapped windowed fetch (the brief
  # pre-promotion arming frame, and residence-disabled configs). Matches the
  # former idle-tier value so the first-paint arming frame is byte-for-byte
  # unchanged; wrapped/folded windows ignore it entirely (see resolve_fetch_range).
  # Replaces the deleted velocity-scaled tiers (50/100/300) and prefetch boost (#2680).
  @windowed_overscan_rows 50

  @doc """
  Prefetches per-window buffer snapshots before the pure render stages run.

  Returns `{scrolls, updated_state}` where `updated_state` has the
  windows map updated with invalidation results.
  """
  @spec prefetch_scrolls(state(), Layout.t()) :: {%{Window.id() => WindowScroll.t()}, state()}
  def prefetch_scrolls(input, layout) do
    layout.window_layouts
    |> Enum.reduce({%{}, input}, fn {win_id, win_layout}, {acc, st} ->
      window = Map.get(st.workspace.windows.map, win_id)

      if window == nil or not match?({:buffer, _}, window.content) do
        # Skip nil and semantic windows; they have no buffer snapshot to prefetch.
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
          scroll.window
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

        # #2661: settle this frame's scroll-authority sequence and record the
        # residence flag. Both live in the render cache (renderer-owned, written
        # back via `State.merge_renderer_window/2`), so `scroll_seq` stays
        # monotonic on the wire across the async render round trip and the input
        # layer sees residence on the live window. `settle_scroll_seq/1` reads its
        # own baselines, the sticky `scroll_echo_top`, and the editor-set
        # `authoritative_scroll_seq` marker from the window, bumping `scroll_seq`
        # for a genuine BEAM-initiated anchor move (top change) OR an explicitly
        # marked authoritative jump that landed on the same top (#2652).
        updated_window =
          updated_window
          |> Window.settle_scroll_seq()
          |> Window.set_resident(scroll.full_residence)

        {updated_window, content_epoch, full_refresh?} =
          Window.prepare_render_epoch(updated_window, render_reset_fingerprint(scroll))

        scroll = %{
          scroll
          | window: updated_window,
            content_epoch: content_epoch,
            full_refresh: full_refresh?,
            scroll_seq: Window.scroll_seq(updated_window),
            line_identity: Window.line_identity(updated_window)
        }

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
    wrap_on = wrap_enabled?(buffer_pid(window))
    width_oracle = Capabilities.width_oracle(state.capabilities)
    scroll_margin = scroll_margin(buffer_pid(window))
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

    # Viewport stays where the user scrolled it until the cursor moves.
    now = System.monotonic_time(:millisecond)

    {window, follow_cursor} =
      if is_active,
        do: Window.scroll_follow_cursor?(window, {cursor_line, cursor_byte_col}, now),
        else: {window, true}

    {expected_version, changed_snapshot, base_snapshot} = render_observation!(window)

    window = Window.sync_line_identity(window, base_snapshot)
    line_count = base_snapshot.line_count
    total_visible_lines = FoldMap.visible_line_count(fold_map, line_count)

    viewport =
      if follow_cursor do
        maybe_scroll_active_window_to_cursor(
          viewport,
          visible_cursor_line,
          scroll_margin,
          is_active,
          wrap_on,
          total_visible_lines
        )
      else
        viewport
      end

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
    line_number_style = Buffer.get_option(buffer_pid(window), :line_numbers)

    {has_sign_column, gutter_w} =
      gutter_dimensions(state, buffer_pid(window), line_number_style, line_count)

    content_w = max(viewport.cols - gutter_w, 1)

    # Compute which buffer lines are visible at each screen row.
    # The DisplayMap merges per-window folds, decoration folds, and virtual
    # lines into a unified mapping. Falls back to VisibleLines when there
    # are no decoration folds or virtual lines (pure window-fold case).
    decorations = fetch_decorations(state, buffer_pid(window))

    # Two-pass scroll: compute DisplayMap, then verify cursor is visible.
    # If decorations push the cursor off-screen, adjust first_line and recompute.
    {first_line, visible_line_map} =
      if DisplayMap.required?(fold_map, decorations) do
        compute_display_map_with_cursor_check(
          fold_map,
          decorations,
          first_line,
          visible_rows,
          line_count,
          content_w,
          cursor_line
        )
      else
        {first_line, nil}
      end

    # Full-document residence (#2653): for under-threshold, non-wrapped, non-fold
    # buffers, fetch and emit the entire laid-out document so a fast scroll can
    # never outrun the resident row store. Wrapped or folded buffers (and the brief
    # pre-promotion arming frame below) keep the viewport-plus-fixed-overscan
    # windowing. The velocity-aware overscan and prefetch hints were deleted with
    # residence on by default and huge files refused (#2680, epic #2652): the
    # windowed remnant either ignores overscan (wrapped/folded) or renders a single
    # idle first-paint frame (arming), so adaptive sizing bought nothing.
    #
    # First-paint-then-promote (#2679): the O(document) first build is ~0.5s at the
    # 65k-row ceiling (measured), so an eligible window renders viewport-windowed on
    # its first frame (fast file-open paint) and promotes to full residence on the
    # next frame, when `residence_armed?` is true. The expensive build then lands
    # one frame later on the renderer process, after content is already on screen,
    # instead of blocking first paint. `residence_armed` resets on layout_generation
    # rebuilds (RenderCache.reset/1) so resize/font/wrap changes re-defer.
    residence_eligible? =
      is_nil(visible_line_map) and full_residence?(buffer_pid(window), wrap_on, line_count)

    full_residence? = residence_eligible? and Window.residence_armed?(window)

    {fetch_first, fetch_count, visible_row_start_index} =
      resolve_fetch_range(%{
        window: window,
        visible_line_map: visible_line_map,
        full_residence?: full_residence?,
        keyframe?: state.force_keyframe?,
        first_line: first_line,
        visible_rows: visible_rows,
        line_count: line_count,
        wrap_on: wrap_on
      })

    snapshot =
      fetch_snapshot!(
        buffer_pid(window),
        expected_version,
        fetch_first,
        fetch_count,
        changed_snapshot
      )

    lines = snapshot.lines

    Minga.Telemetry.execute(
      [:minga, :render, :line_fetch],
      %{lines_fetched: length(lines)},
      %{window_id: win_id, buffer: buffer_pid(window), full_residence?: full_residence?}
    )

    # Cursor byte → display col
    {viewport, first_line, snapshot, lines, _cursor_line_text, cursor_col} =
      maybe_adjust_wrapped_viewport(%{
        wrap_on: wrap_on,
        is_active: is_active,
        follow_cursor: follow_cursor,
        viewport: viewport,
        first_line: fetch_first,
        lines: lines,
        snapshot: snapshot,
        buf: buffer_pid(window),
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

    {total_visual_rows, window} =
      total_visual_rows_for_frontend(
        state,
        window,
        wrap_on,
        visible_line_map,
        content_w,
        width_oracle,
        snapshot
      )

    # Arm promotion for the next frame whenever this window is residence-eligible,
    # so an eligible window that rendered windowed this frame goes resident next
    # frame (#2679). Disarms when eligibility is lost (wrap/fold/over-threshold).
    window = Window.set_residence_armed(window, residence_eligible?)

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
      git_signs: ContentHelpers.signs_for_window(state, window),
      visible_line_map: visible_line_map,
      total_visual_rows: total_visual_rows,
      visible_row_start_index: visible_row_start_index,
      full_residence: full_residence?
    }
  end

  @spec render_observation!(Window.t()) ::
          {non_neg_integer(), RenderSnapshot.t() | nil, RenderSnapshot.t()}
  defp render_observation!(window) do
    expected_version =
      Window.expected_buffer_version(window) || Buffer.version(buffer_pid(window))

    changed_snapshot = Window.changed_snapshot(window)

    base_snapshot =
      changed_snapshot || fetch_at_version!(buffer_pid(window), expected_version, 0, 0)

    {expected_version, changed_snapshot, base_snapshot}
  end

  @spec fetch_snapshot!(
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          RenderSnapshot.t() | nil
        ) :: RenderSnapshot.t()
  defp fetch_snapshot!(
         buffer,
         expected_version,
         first_line,
         count,
         %RenderSnapshot{
           version: expected_version,
           first_line: first_line,
           lines: lines
         } = snapshot
       ) do
    if length(lines) == count,
      do: snapshot,
      else: fetch_at_version!(buffer, expected_version, first_line, count)
  end

  defp fetch_snapshot!(buffer, expected_version, first_line, count, _changed_snapshot),
    do: fetch_at_version!(buffer, expected_version, first_line, count)

  @spec fetch_at_version!(pid(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          RenderSnapshot.t()
  defp fetch_at_version!(buffer, expected_version, first_line, count) do
    case Buffer.render_lines(buffer, expected_version, first_line, count) do
      {:ok, snapshot} ->
        snapshot

      :stale ->
        raise MingaEditor.Renderer.StaleBufferError,
          buffer: buffer,
          expected_version: expected_version
    end
  end

  # Resolves the buffer line range to fetch and the visible viewport's offset
  # within it. Three cases: full-document residence (whole doc from line 0),
  # folded/decorated windows (the visible_line_map's exact buffer span), and the
  # default viewport-plus-fixed-overscan window (wrapped/folded/arming remnant).
  @spec resolve_fetch_range(map()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp resolve_fetch_range(
         %{
           visible_line_map: nil,
           full_residence?: true,
           keyframe?: true,
           window: window
         } = params
       ) do
    # A complete renderer-owned store can materialize a frontend keyframe
    # without fetching the document again. Keep only the visible source range
    # needed by the remaining viewport presentation calculations. Pending edits
    # still win: their exact rows must be fetched and spliced before materializing.
    resident_build = Window.resident_build(window)

    case {resident_delta_fetch_range(window, params.line_count), resident_build} do
      {nil, %ResidentBuild{}} ->
        count = min(params.visible_rows, max(params.line_count - params.first_line, 1))
        {params.first_line, count, 0}

      {nil, nil} ->
        {0, params.line_count, params.first_line}

      {{fetch_first, fetch_count}, _resident_build} ->
        {fetch_first, fetch_count, params.first_line}
    end
  end

  defp resolve_fetch_range(%{visible_line_map: nil, full_residence?: true} = params) do
    # A hydrated resident store needs only changed rows. A no-edit warm frame
    # reuses the store and fetches only bounded visible presentation data.
    case {resident_delta_fetch_range(params.window, params.line_count),
          Window.resident_build(params.window)} do
      {{fetch_first, fetch_count}, _resident_build} ->
        {fetch_first, fetch_count, params.first_line}

      {nil, %ResidentBuild{}} ->
        count = min(params.visible_rows, max(params.line_count - params.first_line, 1))
        {params.first_line, count, 0}

      {nil, nil} ->
        {0, params.line_count, params.first_line}
    end
  end

  defp resolve_fetch_range(%{
         visible_line_map: nil,
         first_line: first_line,
         visible_rows: visible_rows,
         line_count: line_count,
         wrap_on: wrap_on
       }) do
    # Fixed, evenly-split overscan. Wrapped/folded windows ignore these counts
    # (the wrap_on clauses of scroll_overscan_before/after fetch a fixed span);
    # the non-wrapped arming frame renders once at idle before promoting, so
    # velocity scaling bought nothing (#2680).
    overscan_behind = div(@windowed_overscan_rows, 2)
    overscan_ahead = @windowed_overscan_rows - overscan_behind

    {overscan_before, fetch_first} =
      scroll_overscan_before(first_line, wrap_on, overscan_behind)

    overscan_after =
      scroll_overscan_after(first_line, visible_rows, line_count, wrap_on, overscan_ahead)

    fetch_rows = scroll_fetch_rows(visible_rows, overscan_before, overscan_after, wrap_on)
    {fetch_first, fetch_rows, overscan_before}
  end

  defp resolve_fetch_range(%{visible_line_map: entries, full_residence?: false})
       when entries != nil do
    {buf_first, buf_last} = buffer_range_from_entries(entries)
    {buf_first, buf_last - buf_first + 1, 0}
  end

  @spec resident_delta_fetch_range(Window.t(), non_neg_integer()) ::
          {non_neg_integer(), pos_integer()} | nil
  defp resident_delta_fetch_range(window, line_count) do
    deltas = Window.pending_edit_deltas(window)

    if Window.resident_build(window) != nil and deltas != [] do
      {first, last} = EditDelta.affected_line_range(deltas)
      bounded_first = min(first, max(line_count - 1, 0))
      {bounded_first, max(min(last, line_count - 1) - bounded_first + 1, 1)}
    else
      nil
    end
  end

  # Wire-format ceiling: gui_window_content and its row/viewport deltas encode the
  # row count as a u16, so a resident store may not exceed 65_535 rows regardless
  # of the configured line threshold. Above this, fall back to windowed emit.
  @wire_max_rows 65_536
  @default_resident_store_max_bytes 10_485_760

  # A buffer qualifies for full-document residence when it is not wrapped, not
  # folded/decorated (caller passes the nil-visible_line_map case only), and both
  # its line count and byte size sit under the configured thresholds and the wire
  # row ceiling. The byte check runs last so an over-line file skips the extra call.
  # Residence is on by default (:resident_store_max_lines defaults to the u16 wire
  # ceiling); a line threshold of 0 (or nil) disables it and forces the windowed path.
  @spec full_residence?(pid(), boolean(), non_neg_integer()) :: boolean()
  defp full_residence?(_buf, true = _wrap_on, _line_count), do: false

  defp full_residence?(buf, false = _wrap_on, line_count) do
    case resident_store_max_lines() do
      max_lines when is_integer(max_lines) and max_lines > 0 ->
        line_count <= @wire_max_rows and
          line_count <= max_lines and
          buffer_bytes_within_limit?(buf)

      _disabled ->
        false
    end
  end

  @spec buffer_bytes_within_limit?(pid()) :: boolean()
  defp buffer_bytes_within_limit?(buf) do
    Buffer.content_byte_size(buf) <= resident_store_max_bytes()
  catch
    :exit, _ -> false
  end

  @spec resident_store_max_lines() :: non_neg_integer()
  defp resident_store_max_lines do
    Config.get(:resident_store_max_lines)
  catch
    :exit, _ -> 0
  end

  @spec resident_store_max_bytes() :: pos_integer()
  defp resident_store_max_bytes do
    Config.get(:resident_store_max_bytes)
  catch
    :exit, _ -> @default_resident_store_max_bytes
  end

  @spec scroll_overscan_before(non_neg_integer(), boolean(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp scroll_overscan_before(first_line, true, _overscan), do: {0, first_line}

  defp scroll_overscan_before(first_line, false, overscan) do
    count = min(overscan, first_line)
    {count, first_line - count}
  end

  @spec scroll_overscan_after(
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          boolean(),
          pos_integer()
        ) :: non_neg_integer()
  defp scroll_overscan_after(_first_line, _visible_rows, _line_count, true, _overscan), do: 0

  defp scroll_overscan_after(first_line, visible_rows, line_count, false, overscan) do
    rows_after = line_count - first_line - visible_rows
    min(overscan, max(0, rows_after))
  end

  @spec scroll_fetch_rows(pos_integer(), non_neg_integer(), non_neg_integer(), boolean()) ::
          pos_integer()
  defp scroll_fetch_rows(visible_rows, _before, _after, true),
    do: visible_rows * 3

  defp scroll_fetch_rows(visible_rows, before_count, after_count, false),
    do: visible_rows + before_count + after_count

  @spec total_visual_rows_for_frontend(
          state(),
          Window.t(),
          boolean(),
          [VisibleLines.line_entry()] | [DisplayMap.entry()] | nil,
          pos_integer(),
          Minga.Core.WidthOracle.t(),
          Minga.Buffer.RenderSnapshot.t()
        ) :: {non_neg_integer() | nil, Window.t()}
  defp total_visual_rows_for_frontend(state, window, true, nil, content_w, oracle, snapshot) do
    if Capabilities.semantic_ui?(state.capabilities) do
      key = total_visual_rows_cache_key(snapshot, content_w, oracle)

      case Window.cached_total_visual_rows(window, key) do
        nil ->
          total = visual_rows_to_eof(buffer_pid(window), snapshot.version, 0, content_w, oracle)
          {total, Window.put_total_visual_rows(window, key, total)}

        total ->
          {total, window}
      end
    else
      {nil, window}
    end
  end

  defp total_visual_rows_for_frontend(
         _state,
         window,
         _wrap_on,
         _visible_line_map,
         _content_w,
         _oracle,
         _snapshot
       ),
       do: {nil, window}

  @spec total_visual_rows_cache_key(
          Minga.Buffer.RenderSnapshot.t(),
          pos_integer(),
          Minga.Core.WidthOracle.t()
        ) :: term()
  defp total_visual_rows_cache_key(snapshot, content_w, oracle) do
    options = snapshot.options

    {
      snapshot.version,
      content_w,
      Map.get(options, :breakindent, true),
      Map.get(options, :linebreak, true),
      Map.get(options, :tab_width, 2),
      WidthOracle.fingerprint(oracle)
    }
  end

  @spec render_reset_fingerprint(WindowScroll.t()) :: term()
  defp render_reset_fingerprint(%WindowScroll{} = scroll) do
    options = scroll.snapshot.options

    {
      scroll.win_id,
      buffer_pid(scroll.window),
      scroll.win_layout.total,
      scroll.win_layout.content,
      scroll.content_w,
      scroll.gutter_w,
      scroll.wrap_on,
      scroll.line_number_style,
      scroll.viewport.rows,
      scroll.viewport.cols,
      scroll.window.fold_map,
      # A residence toggle mid-session swaps the row set between viewport-sized
      # and full-document; force a full re-emit so no :patch frame diffs across
      # differently-sized stores.
      scroll.full_residence,
      Map.get(options, :breakindent, true),
      Map.get(options, :linebreak, true),
      Map.get(options, :tab_width, 2),
      WidthOracle.fingerprint(scroll.width_oracle)
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
           follow_cursor: false
         } = params
       ) do
    # Free-scroll (#2661/#2668): the wheel/trackpad moved `viewport.top` directly
    # and `scroll_follow_cursor?/3` suppressed cursor-follow, so honor the
    # free-scrolled top/offset instead of re-anchoring to the cursor. This mirrors
    # the non-wrapped path, where the same `follow_cursor` gate on
    # `maybe_scroll_active_window_to_cursor/6` already keeps the viewport put.
    # Preserving the reported top keeps the #2668 echo contract: the emitted top
    # equals the top `Window.mark_scroll_echo/2` recorded, so `settle_scroll_seq/1`
    # does not bump `scroll_seq` on the user's own scroll.
    present_free_scroll_wrapped_viewport(params)
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
    if cursor_line < first_line or cursor_line >= first_line + Enum.count(lines) do
      refetch_wrapped_viewport(Map.merge(params, %{top: cursor_line, offset: 0}))
    else
      adjust_wrapped_viewport_from_map(params)
    end
  end

  # Presents a wrapped active window at its already-committed free-scroll top
  # without moving toward the cursor. Reuses the lines already fetched at
  # `first_line` (== the free-scrolled `viewport.top` for wrapped windows, whose
  # overscan-before is zero), computes the top line's wrap count for the visual
  # offset, and applies the same near-EOF offset clamp as
  # `adjust_wrapped_viewport_from_map/1`.
  @spec present_free_scroll_wrapped_viewport(map()) ::
          {Viewport.t(), non_neg_integer(), map(), [String.t()], String.t(), non_neg_integer()}
  defp present_free_scroll_wrapped_viewport(%{
         viewport: viewport,
         first_line: first_line,
         lines: lines,
         snapshot: snapshot,
         buf: buf,
         cursor_line: cursor_line,
         cursor_byte_col: cursor_byte_col,
         content_w: content_w,
         visible_rows: visible_rows,
         oracle: oracle
       }) do
    wrap_map = compute_wrap_map(buf, lines, content_w, oracle)

    top_count =
      wrap_map
      |> List.first([%{byte_offset: 0, text: "", source_text: "", indent_width: 0}])
      |> Enum.count()
      |> max(1)

    total_lines = Buffer.line_count(buf)
    near_eof = first_line + visible_rows >= total_lines - 1

    total_visual_rows_to_eof =
      if near_eof do
        visual_rows_to_eof(buf, snapshot.version, first_line, content_w, oracle)
      else
        top_count
      end

    new_offset =
      if near_eof do
        min(
          viewport.visual_row_offset,
          Viewport.max_visual_row_offset(total_visual_rows_to_eof, visible_rows)
        )
      else
        viewport.visual_row_offset
      end

    top_count = max(top_count, total_visual_rows_to_eof)
    new_viewport = Viewport.put_top_visual(viewport, first_line, new_offset, top_count)
    text = cursor_line_text(lines, cursor_line, first_line)
    {new_viewport, first_line, snapshot, lines, text, Unicode.display_col(text, cursor_byte_col)}
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
        visual_rows_to_eof(buf, snapshot.version, new_top, content_w, oracle)
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
         snapshot: prior_snapshot,
         top: top,
         offset: offset,
         buf: buf,
         cursor_line: cursor_line,
         cursor_byte_col: cursor_byte_col,
         content_w: content_w,
         fetch_count: fetch_count,
         oracle: oracle
       }) do
    snapshot = fetch_at_version!(buf, prior_snapshot.version, top, fetch_count)
    lines = snapshot.lines
    wrap_map = compute_wrap_map(buf, lines, content_w, oracle)

    top_count =
      wrap_map
      |> List.first([%{byte_offset: 0, text: "", source_text: "", indent_width: 0}])
      |> Enum.count()
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
    count = max(Enum.count(entry), 1)

    if desired_start < count do
      {line, desired_start, count}
    else
      do_visual_start_to_top(rest, line + 1, desired_start - count)
    end
  end

  @spec visual_rows_to_eof(
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          Minga.Core.WidthOracle.t()
        ) ::
          pos_integer()
  defp visual_rows_to_eof(buf, expected_version, start_line, content_w, oracle) do
    total_lines = Buffer.line_count(buf)
    fetch_count = max(total_lines - start_line, 1)
    snapshot = fetch_at_version!(buf, expected_version, start_line, fetch_count)

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
    |> Enum.at(-1, {%{byte_offset: 0}, 0})
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
          boolean(),
          non_neg_integer()
        ) :: Viewport.t()
  defp maybe_scroll_active_window_to_cursor(
         viewport,
         _visible_cursor_line,
         _scroll_margin,
         false,
         _wrap_on,
         _total_visible_lines
       ),
       do: viewport

  defp maybe_scroll_active_window_to_cursor(
         viewport,
         _visible_cursor_line,
         _scroll_margin,
         true,
         true,
         _total_visible_lines
       ) do
    viewport
  end

  defp maybe_scroll_active_window_to_cursor(
         viewport,
         visible_cursor_line,
         scroll_margin,
         true,
         false,
         total_visible_lines
       ) do
    saved_left = viewport.left

    # Clamp top to EOF after scrolling so the last line pins to the bottom
    # instead of scrolling past it (scroll_to_cursor applies scroll_margin
    # without knowing the buffer length). The wrap path clamps separately.
    viewport
    |> Viewport.scroll_to_cursor({visible_cursor_line, 0}, scroll_margin)
    |> Viewport.clamp_top_to_eof(total_visible_lines)
    |> Map.put(:left, saved_left)
  end

  @spec fetch_decorations(term(), pid()) :: Decorations.t()
  defp fetch_decorations(state, buf) do
    decorations = BufferDecorations.compose(state, buf)

    Minga.Telemetry.execute(
      [:minga, :render, :decorations],
      %{decorations_visited: decoration_count(decorations)},
      %{buffer: buf}
    )

    decorations
  catch
    :exit, _ ->
      Minga.Telemetry.execute(
        [:minga, :render, :decorations],
        %{decorations_visited: 0},
        %{buffer: buf}
      )

      Decorations.new()
  end

  @spec decoration_count(Decorations.t()) :: non_neg_integer()
  defp decoration_count(%Decorations{} = decorations) do
    Decorations.highlight_count(decorations) + length(decorations.virtual_texts) +
      length(decorations.annotations) + length(decorations.fold_regions) +
      length(decorations.block_decorations) + length(decorations.conceal_ranges)
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

  @spec buffer_pid(Window.t()) :: pid()
  defp buffer_pid(%Window{content: {:buffer, buffer}}), do: buffer

  @spec window_cursor(Window.t(), boolean()) :: {non_neg_integer(), non_neg_integer()}
  defp window_cursor(window, true), do: Buffer.cursor(buffer_pid(window))
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
