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
  alias Minga.Diagnostics
  alias Minga.LSP.SyncServer
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.FoldMap.VisibleLines
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout
  alias MingaEditor.BufferDecorations
  alias MingaEditor.RenderModel.Window.ResidentBuild
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.WindowDiagnostics
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Renderer.MixedLayout
  alias MingaEditor.Renderer.SearchHighlight
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Renderer.WrapLayout
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.Viewport
  alias MingaEditor.Renderer.RenderWindow, as: Window

  @typedoc "Render pipeline input."
  @type state :: Input.t()
  @typep wrap_geometry :: {pos_integer(), WidthOracle.t(), non_neg_integer()}

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
    {scrolls, input} =
      layout.window_layouts
      |> Enum.reduce({%{}, input}, fn {win_id, win_layout}, {acc, st} ->
        window = Map.get(st.windows.map, win_id)

        if window == nil or not match?({:buffer, _}, window.content) do
          # Skip nil and semantic windows; they have no buffer snapshot to prefetch.
          {acc, st}
        else
          scroll_and_invalidate(input, st, acc, win_id, window, win_layout)
        end
      end)

    {scrolls, prefetch_diagnostics(input, scrolls)}
  end

  # Looks up each displayed file's diagnostics once per frame, shared by every
  # split showing it. An unchanged revision keeps the retained view without
  # copying its list; files no longer displayed are dropped.
  @spec prefetch_diagnostics(state(), %{Window.id() => WindowScroll.t()}) :: state()
  defp prefetch_diagnostics(input, scrolls) do
    retained =
      scrolls
      |> Map.values()
      |> Enum.flat_map(fn
        %WindowScroll{snapshot: %{file_path: path}} when is_binary(path) -> [path]
        _scroll -> []
      end)
      |> Enum.uniq()
      |> Map.new(fn path ->
        current = Caches.diagnostics_for(input.caches, path)
        change = Diagnostics.changed_since(SyncServer.path_to_uri(path), current.revision)
        {path, WindowDiagnostics.apply_change(current, change)}
      end)

    Input.retain_diagnostics(input, retained)
  end

  @doc "Fetches the version-qualified source range needed by the resident build plan."
  @spec ensure_resident_source(state(), WindowScroll.t(), ResidentBuild.plan() | :windowed) ::
          WindowScroll.t()
  def ensure_resident_source(state, %WindowScroll{} = scroll, {:hydrate, _reason}) do
    replace_resident_source(state, scroll, 0, scroll.snapshot.line_count)
  end

  def ensure_resident_source(
        state,
        %WindowScroll{wrap_on: true} = scroll,
        {:splices, [_ | _] = source_splices}
      ) do
    [{first, last} | rest] = EditDelta.inserted_line_ranges(source_splices)

    state
    |> replace_resident_source(scroll, first, last - first + 1)
    |> with_extra_sources(state, rest)
  end

  def ensure_resident_source(_state, scroll, _plan), do: scroll

  @spec replace_resident_source(state(), WindowScroll.t(), non_neg_integer(), pos_integer()) ::
          WindowScroll.t()
  defp replace_resident_source(state, scroll, first, count) do
    snapshot =
      fetch_snapshot!(
        buffer_pid(scroll.window),
        scroll.snapshot.version,
        first,
        count,
        scroll.snapshot
      )

    {lines, preview_matches} =
      if scroll.is_active,
        do: SearchHighlight.maybe_substitute_preview(state, snapshot.lines, first),
        else: {snapshot.lines, []}

    %{
      scroll
      | snapshot: snapshot,
        lines: lines,
        extra_sources: [],
        preview_matches: preview_matches,
        first_line: first,
        visible_row_start_index: scroll.viewport.top
    }
  end

  # Attaches the source text for every further range the frame's edits changed. A range the snapshot already
  # holds (it was read in the same buffer call as the edits) is used as it is; any other is fetched at the
  # snapshot's version.
  @spec with_extra_sources(WindowScroll.t(), state(), [EditDelta.line_range()]) ::
          WindowScroll.t()
  defp with_extra_sources(%WindowScroll{} = scroll, _state, []), do: %{scroll | extra_sources: []}

  defp with_extra_sources(%WindowScroll{snapshot: snapshot} = scroll, state, ranges) do
    primary_last = scroll.first_line + length(scroll.lines) - 1

    {sources, preview_matches} =
      ranges
      |> Enum.reject(fn {first, last} -> first >= scroll.first_line and last <= primary_last end)
      |> Enum.map_reduce(scroll.preview_matches, fn {first, last}, matches ->
        {source_first, offset, lines} = extra_range(scroll, snapshot, first, last)

        {lines, more} =
          if scroll.is_active,
            do: SearchHighlight.maybe_substitute_preview(state, lines, source_first),
            else: {lines, []}

        {{source_first, offset, lines}, matches ++ more}
      end)

    extra_lines =
      Enum.reduce(sources, 0, fn {_first, _offset, lines}, sum -> sum + length(lines) end)

    report_line_fetch(scroll.window.id, buffer_pid(scroll.window), extra_lines, true)
    %{scroll | extra_sources: sources, preview_matches: preview_matches}
  end

  @spec extra_range(WindowScroll.t(), RenderSnapshot.t(), non_neg_integer(), non_neg_integer()) ::
          RenderSnapshot.extra_range()
  defp extra_range(scroll, snapshot, first, last) do
    held =
      Enum.find(snapshot.extra_ranges, fn {held_first, _offset, lines} ->
        first >= held_first and last < held_first + length(lines)
      end)

    case held do
      nil ->
        fetched =
          fetch_at_version!(buffer_pid(scroll.window), snapshot.version, first, last - first + 1)

        {first, fetched.first_line_byte_offset, fetched.lines}

      range ->
        range
    end
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
    is_active = win_id == state.windows.active

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
            scroll.snapshot.version,
            scroll.cursor_line
          )

        updated_window =
          detect_gutter_invalidation(
            updated_window,
            scroll.cursor_line,
            scroll.line_number_style
          )

        # The wrapped builder settles authority after clamping against the
        # resulting resident store, not the source slice used for prefetch.
        updated_window = Window.set_resident(updated_window, scroll.full_residence)

        updated_window =
          if scroll.wrap_on and scroll.full_residence,
            do: updated_window,
            else: Window.settle_scroll_seq(updated_window)

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

        st = Input.record_render_window(st, win_id, updated_window)

        {Map.put(acc, win_id, scroll), st}
    end
  end

  # Wraps scroll_window with a catch for dead buffer processes. Returns
  # {:ok, scroll} on success, :skip if the buffer died mid-call.
  @spec safe_scroll_window(state(), Window.id(), Window.t(), Layout.window_layout(), boolean()) ::
          {:ok, WindowScroll.t()} | :skip
  defp safe_scroll_window(state, win_id, window, win_layout, is_active) do
    {:ok, scroll_window(state, window, win_layout, is_active)}
  catch
    :exit, _ ->
      Minga.Log.debug(:render, "[scroll] skipped window #{win_id}: buffer process dead")
      :skip
  end

  @spec scroll_window(
          state(),
          Window.t(),
          Layout.window_layout(),
          boolean()
        ) :: WindowScroll.t()
  defp scroll_window(state, window, win_layout, is_active) do
    {_row_off, _col_off, content_width, content_height} = win_layout.content

    # Cursor: active window reads live from buffer; inactive uses stored
    {cursor_line, cursor_byte_col} = window_cursor(window, is_active)

    # Use the window's persistent viewport, updating dimensions from Layout.
    # This preserves the scroll position (viewport.top) across frames so that
    # Ctrl-e/y, zz/zt/zb, and mouse wheel scroll actually persist.
    # scroll_to_cursor only adjusts top when the cursor moves off-screen.
    wrap_on = wrap_enabled?(buffer_pid(window))
    width_oracle = Capabilities.width_oracle(state.intent.frame.capabilities)
    scroll_margin = scroll_margin(buffer_pid(window))
    fold_map = window.fold_map
    %Viewport{} = win_vp = window.viewport
    viewport = Viewport.fit_content(win_vp, content_width, content_height)

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

    buffer = buffer_pid(window)
    decorations = fetch_decorations(state, buffer)

    scroll = %WindowScroll{
      window: window,
      win_layout: win_layout,
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_byte_col: cursor_byte_col,
      cursor_col: 0,
      first_line: first_line,
      lines: [],
      snapshot: base_snapshot,
      gutter_w: gutter_w,
      content_w: content_w,
      has_sign_column: has_sign_column,
      preview_matches: [],
      line_number_style: line_number_style,
      wrap_on: wrap_on,
      width_oracle: width_oracle,
      git_signs: ContentHelpers.signs_for_window(state, window)
    }

    if wrap_on and DisplayMap.required?(fold_map, decorations) do
      layout_snapshot =
        if changed_snapshot,
          do: fetch_at_version!(buffer, expected_version, 0, 0),
          else: base_snapshot

      mixed_source(
        state,
        %{scroll | snapshot: layout_snapshot},
        decorations,
        follow_cursor,
        scroll_margin
      )
    else
      direct_source(
        state,
        scroll,
        decorations,
        {expected_version, changed_snapshot},
        follow_cursor,
        scroll_margin
      )
    end
  end

  defp mixed_source(state, scroll, decorations, follow_cursor, scroll_margin) do
    cursor = {scroll.cursor_line, scroll.cursor_byte_col}
    motion = if scroll.is_active and follow_cursor, do: {:follow, scroll_margin}, else: 0
    buffer = buffer_pid(scroll.window)

    case MixedLayout.page(
           buffer,
           scroll.snapshot,
           {scroll.window.fold_map, decorations},
           scroll.viewport,
           {scroll.content_w, scroll.width_oracle, cursor},
           motion,
           preview_owner(state, scroll.is_active),
           Window.text_presentation(scroll.window)
         ) do
      {:ok, %DisplayMap{entries: [{first, _} | _]} = page, viewport, _, matches} ->
        report_line_fetch(scroll.window.id, buffer, page.source_fetch_count, false)
        text = DisplayMap.source_text(page, scroll.cursor_line)

        %{
          scroll
          | window: Window.set_residence_armed(scroll.window, false),
            viewport:
              scroll_horizontal(viewport, scroll.cursor_line, 0, true, scroll.content_w, 0),
            cursor_col: Unicode.display_col(text, scroll.cursor_byte_col),
            first_line: first,
            visible_line_map: page,
            preview_matches: matches
        }

      :stale ->
        raise MingaEditor.Renderer.StaleBufferError,
          buffer: buffer,
          expected_version: scroll.snapshot.version
    end
  end

  defp report_line_fetch(win_id, buffer, count, full_residence?) do
    Minga.Telemetry.execute(
      [:minga, :render, :line_fetch],
      %{lines_fetched: count},
      %{window_id: win_id, buffer: buffer, full_residence?: full_residence?}
    )
  end

  defp direct_source(
         state,
         %WindowScroll{} = scroll,
         decorations,
         {expected_version, changed_snapshot},
         follow_cursor,
         scroll_margin
       ) do
    %WindowScroll{
      window: window,
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_byte_col: cursor_byte_col,
      first_line: first_line,
      snapshot: base_snapshot,
      content_w: content_w,
      wrap_on: wrap_on,
      width_oracle: width_oracle
    } = scroll

    fold_map = window.fold_map
    line_count = base_snapshot.line_count
    visible_rows = Viewport.content_rows(viewport)

    # Two-pass scroll: compute DisplayMap, then verify cursor is visible.
    # If decorations push the cursor off-screen, adjust first_line and recompute.
    {first_line, visible_line_map} =
      if not wrap_on and DisplayMap.required?(fold_map, decorations) do
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

    # Mixed wrapped panes took the separate, windowed path above.
    {viewport, first_line} =
      layout_anchor(viewport, first_line, visible_line_map, wrap_on, line_count)

    {total_visual_rows, window, full_residence?} =
      admit_residence(
        state,
        window,
        base_snapshot,
        {content_w, width_oracle, cursor_line},
        wrap_on,
        is_nil(visible_line_map),
        is_active
      )

    {fetch_first, fetch_count, visible_row_start_index} =
      resolve_fetch_range(%{
        window: window,
        visible_line_map: visible_line_map,
        full_residence?: full_residence? and not wrap_on,
        keyframe?: state.intent.frame.force_keyframe?,
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
    report_line_fetch(window.id, buffer_pid(window), length(lines), full_residence?)

    # Cursor byte → display col
    {viewport, first_line, snapshot, lines, _cursor_line_text, cursor_col} =
      maybe_adjust_wrapped_viewport(%{
        window: window,
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
        preview: preview_owner(state, is_active and wrap_on),
        preserve_anchor?: preserve_resident_anchor?(full_residence?, is_active, window, viewport)
      })

    # Horizontal scroll (disabled when wrapping).
    # Use content_w (text area excluding gutter) as the effective width,
    # so the cursor triggers scroll when it reaches the content edge,
    # not the full viewport edge.
    viewport =
      if wrap_on or (is_active and follow_cursor) do
        scroll_horizontal(viewport, cursor_line, cursor_col, wrap_on, content_w, scroll_margin)
      else
        viewport
      end

    {lines, preview_matches} = preview_lines(state, is_active, lines, first_line)

    %{
      scroll
      | window: window,
        viewport: viewport,
        cursor_col: cursor_col,
        first_line: first_line,
        lines: lines,
        snapshot: snapshot,
        preview_matches: preview_matches,
        visible_line_map: visible_line_map,
        total_visual_rows: total_visual_rows,
        visible_row_start_index: visible_row_start_index,
        full_residence: full_residence?
    }
    |> with_extra_sources(
      state,
      extra_delta_ranges(window, full_residence? and not wrap_on, line_count)
    )
  end

  # The changed ranges after the first one, for a resident window that reads its edits from the frame's own
  # fetch. A wrapped window fetches from its build plan instead (`ensure_resident_source/3`).
  @spec extra_delta_ranges(Window.t(), boolean(), non_neg_integer()) :: [EditDelta.line_range()]
  defp extra_delta_ranges(_window, false, _line_count), do: []

  defp extra_delta_ranges(window, true, line_count) do
    case resident_delta_ranges(window, line_count) do
      [_first | rest] -> rest
      [] -> []
    end
  end

  defp admit_residence(state, window, snapshot, basis, wrap_on, direct_layout?, active?) do
    limit =
      if direct_layout? and
           not (wrap_on and active? and SearchHighlight.substitute_preview?(state)),
         do: resident_source_limit(window, snapshot.line_count)

    {extent, window} = wrapped_resident_extent(window, snapshot, basis, wrap_on, limit)
    eligible? = not is_nil(limit)

    resident? =
      eligible? and Window.residence_armed?(window) and
        (not wrap_on or (is_integer(extent) and extent <= limit))

    {if(resident?, do: extent), Window.set_residence_armed(window, eligible?), resident?}
  end

  defp preserve_resident_anchor?(true, false, _window, _viewport), do: true

  defp preserve_resident_anchor?(
         true,
         true,
         %{scroll_echo_anchor: {line, offset, _left}},
         viewport
       ),
       do: {line, offset} == Viewport.vertical_anchor(viewport)

  defp preserve_resident_anchor?(true, true, _window, _viewport), do: false

  defp preserve_resident_anchor?(false, _active?, _window, _viewport), do: false

  defp preview_owner(state, true), do: if(SearchHighlight.substitute_preview?(state), do: state)
  defp preview_owner(_state, false), do: nil

  defp preview_lines(state, true, lines, first),
    do: SearchHighlight.maybe_substitute_preview(state, lines, first)

  defp preview_lines(_state, false, lines, _first), do: {lines, []}

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
        {params.first_line, count, params.first_line}

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
        {params.first_line, count, params.first_line}

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

  # The first range the frame's edits changed. The frame fetches it as its own source; the ranges after it
  # ride along as extra sources, so lines between two edits are never read.
  @spec resident_delta_fetch_range(Window.t(), non_neg_integer()) ::
          {non_neg_integer(), pos_integer()} | nil
  defp resident_delta_fetch_range(window, line_count) do
    case resident_delta_ranges(window, line_count) do
      [{first, last} | _rest] -> {first, last - first + 1}
      [] -> nil
    end
  end

  @spec resident_delta_ranges(Window.t(), non_neg_integer()) :: [EditDelta.line_range()]
  defp resident_delta_ranges(window, line_count) do
    deltas = Window.pending_edit_deltas(window)

    if Window.resident_build(window) != nil and deltas != [] do
      deltas
      |> EditDelta.line_splices()
      |> EditDelta.inserted_line_ranges()
      |> EditDelta.clamp_line_ranges(line_count)
    else
      []
    end
  end

  # Reviewed residence ceiling: cap full-document residence at 65_536 rows for
  # resident-store memory and first-build performance. GUI window-content row counts
  # and row-delta count/index fields are u32 on the wire; this policy does not widen residence.
  @resident_store_max_lines 65_536
  @default_resident_store_max_bytes 10_485_760

  # Source limits bound the admission scan. Wrapped panes must also fit the
  # visual row limit after layout.
  @spec resident_source_limit(Window.t(), non_neg_integer()) :: pos_integer() | nil
  defp resident_source_limit(window, line_count) do
    case resident_store_max_lines() do
      max_lines when is_integer(max_lines) and max_lines > 0 ->
        limit = min(max_lines, @resident_store_max_lines)
        if line_count <= limit and buffer_bytes_within_limit?(buffer_pid(window)), do: limit

      _disabled ->
        nil
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

  @spec wrapped_resident_extent(
          Window.t(),
          RenderSnapshot.t(),
          wrap_geometry(),
          boolean(),
          pos_integer() | nil
        ) :: {non_neg_integer() | nil, Window.t()}
  defp wrapped_resident_extent(
         window,
         snapshot,
         {width, oracle, cursor_line} = geometry,
         true,
         limit
       )
       when is_integer(limit) do
    basis = WrapLayout.basis(snapshot, width, oracle, cursor_line)
    key = {snapshot.version, basis, limit}

    case Window.cached_total_visual_rows(window, key) do
      nil ->
        if Window.residence_armed?(window) do
          total = measure_resident_extent(window, snapshot, geometry, basis, limit)
          {total, Window.put_total_visual_rows(window, key, total)}
        else
          {nil, window}
        end

      total ->
        {total, window}
    end
  end

  defp wrapped_resident_extent(window, _snapshot, _geometry, _wrapped, _limit),
    do: {nil, window}

  @spec measure_resident_extent(
          Window.t(),
          RenderSnapshot.t(),
          wrap_geometry(),
          tuple(),
          pos_integer()
        ) :: pos_integer()
  defp measure_resident_extent(
         window,
         snapshot,
         {width, oracle, cursor_line} = geometry,
         basis,
         limit
       ) do
    previous_key = {window.render_cache.last_buf_version, basis, limit}

    case {Window.resident_build(window), Window.cached_total_visual_rows(window, previous_key),
          Window.pending_edit_deltas(window)} do
      {%ResidentBuild{store: store, line_count: old_count}, prior, [_ | _] = deltas}
      when is_integer(prior) and prior <= limit ->
        source_splices = EditDelta.line_splices(deltas)

        net =
          Enum.reduce(source_splices, 0, fn {_start, delete_count, insert_count}, net ->
            net + insert_count - delete_count
          end)

        removed = removed_visual_rows(store, source_splices)

        if is_integer(removed) and old_count + net == snapshot.line_count do
          added =
            source_splices
            |> EditDelta.inserted_line_ranges()
            |> Enum.reduce(0, fn {first, last}, sum ->
              range =
                fetch_at_version!(buffer_pid(window), snapshot.version, first, last - first + 1)

              sum + Enum.sum(WrapLayout.row_counts(range, width, oracle, cursor_line))
            end)

          prior - removed + added
        else
          measure_wrap_chunks(buffer_pid(window), snapshot, geometry, limit, 0, 0)
        end

      _other ->
        measure_wrap_chunks(buffer_pid(window), snapshot, geometry, limit, 0, 0)
    end
  end

  # The visual rows the splices delete from the store, or nil when a splice does not land on a known line.
  @spec removed_visual_rows(ResidentStore.t(), [EditDelta.line_splice()]) ::
          non_neg_integer() | nil
  defp removed_visual_rows(store, source_splices) do
    Enum.reduce_while(source_splices, 0, fn {start, delete_count, _insert_count}, sum ->
      case {ResidentStore.visual_rank(store, start),
            ResidentStore.visual_rank(store, start + delete_count)} do
        {old_start, old_stop}
        when is_integer(old_start) and is_integer(old_stop) and old_stop >= old_start ->
          {:cont, sum + old_stop - old_start}

        _unmatched ->
          {:halt, nil}
      end
    end)
  end

  @spec measure_wrap_chunks(
          pid(),
          RenderSnapshot.t(),
          wrap_geometry(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: pos_integer()
  defp measure_wrap_chunks(
         buffer,
         snapshot,
         {width, oracle, cursor_line} = geometry,
         limit,
         first,
         total
       ) do
    count = min(128, snapshot.line_count - first)
    range = fetch_at_version!(buffer, snapshot.version, first, count)
    total = total + Enum.sum(WrapLayout.row_counts(range, width, oracle, cursor_line))
    next = first + count

    if total > limit or next == snapshot.line_count do
      min(total, limit + 1)
    else
      measure_wrap_chunks(buffer, snapshot, geometry, limit, next, total)
    end
  end

  @spec render_reset_fingerprint(WindowScroll.t()) :: term()
  defp render_reset_fingerprint(%WindowScroll{} = scroll) do
    options = scroll.snapshot.options

    {
      scroll.window.id,
      buffer_pid(scroll.window),
      scroll.win_layout.total,
      scroll.win_layout.content,
      scroll.content_w,
      scroll.gutter_w,
      scroll.wrap_on,
      match?(%DisplayMap{}, scroll.visible_line_map),
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

  defp maybe_adjust_wrapped_viewport(%{wrap_on: true, is_active: false} = params),
    do: detached_wrapped_viewport(params)

  defp maybe_adjust_wrapped_viewport(%{wrap_on: true, follow_cursor: false} = params),
    do: detached_wrapped_viewport(params)

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

  @spec detached_wrapped_viewport(map()) ::
          {Viewport.t(), non_neg_integer(), RenderSnapshot.t(), [String.t()], String.t(),
           non_neg_integer()}
  defp detached_wrapped_viewport(%{preserve_anchor?: true} = params) do
    text = cursor_line_text(params.lines, params.cursor_line, params.first_line)

    {params.viewport, params.first_line, params.snapshot, params.lines, text,
     Unicode.display_col(text, params.cursor_byte_col)}
  end

  defp detached_wrapped_viewport(params), do: present_free_scroll_wrapped_viewport(params)

  @spec layout_anchor(
          Viewport.t(),
          non_neg_integer(),
          [DisplayMap.entry()] | nil,
          boolean(),
          pos_integer()
        ) :: {Viewport.t(), non_neg_integer()}
  defp layout_anchor(viewport, first, nil, true, line_count) when first >= line_count do
    top = line_count - 1
    {Viewport.put_top(viewport, top), top}
  end

  defp layout_anchor(viewport, first, _display_map, true, _line_count),
    do: {Viewport.source_rows(viewport), first}

  defp layout_anchor(viewport, _first, nil, false, line_count) do
    viewport = viewport |> Viewport.put_top(viewport.top) |> Viewport.clamp_top_to_eof(line_count)
    {viewport, viewport.top}
  end

  defp layout_anchor(viewport, first, _display_map, false, _line_count),
    do: {Viewport.put_top(viewport, viewport.top), first}

  # Validate a detached anchor against the current composition, not the old wheel
  # echo. A reflow can move the last full page behind the fetched logical line.
  @spec present_free_scroll_wrapped_viewport(map()) ::
          {Viewport.t(), non_neg_integer(), RenderSnapshot.t(), [String.t()], String.t(),
           non_neg_integer()}
  defp present_free_scroll_wrapped_viewport(%{
         window: window,
         viewport: viewport,
         first_line: first_line,
         lines: lines,
         snapshot: snapshot,
         buf: buf,
         cursor_line: cursor_line,
         cursor_byte_col: cursor_byte_col,
         content_w: width,
         visible_rows: visible_rows,
         oracle: oracle,
         preview: preview
       }) do
    retained = retained_wrap_counts(window, snapshot, width, oracle, cursor_line, preview)
    counts = wrapped_visible_counts(snapshot, width, oracle, cursor_line, preview, retained)

    {measured_first, counts} =
      if first_line > 0 and first_line + length(lines) >= snapshot.line_count and
           Enum.sum(counts) < visible_rows do
        earlier = max(first_line - visible_rows + 1, 0)
        prefix = fetch_at_version!(buf, snapshot.version, earlier, first_line - earlier)
        preceding = wrapped_visible_counts(prefix, width, oracle, cursor_line, preview, retained)
        {earlier, preceding ++ counts}
      else
        {first_line, counts}
      end

    counts = List.to_tuple(counts)

    {viewport, _at_bottom?} =
      Viewport.scroll_visual_rows(viewport, 0, snapshot.line_count, fn line ->
        elem(counts, line - measured_first)
      end)

    top = viewport.top

    snapshot =
      if top == first_line,
        do: snapshot,
        else: fetch_at_version!(buf, snapshot.version, top, snapshot.line_count - top)

    text = cursor_line_text(snapshot.lines, cursor_line, top)
    {viewport, top, snapshot, snapshot.lines, text, Unicode.display_col(text, cursor_byte_col)}
  end

  defp retained_wrap_counts(window, snapshot, width, oracle, cursor_line, nil) do
    TextPresentation.matching_wrap_counts(
      Window.text_presentation(window),
      buffer_pid(window),
      snapshot.version,
      WrapLayout.basis(snapshot, width, oracle, cursor_line)
    )
  end

  defp retained_wrap_counts(_window, _snapshot, _width, _oracle, _cursor_line, _preview), do: %{}

  @spec wrapped_visible_counts(
          RenderSnapshot.t(),
          pos_integer(),
          WidthOracle.t(),
          non_neg_integer(),
          state() | nil,
          WrapLayout.counts()
        ) :: [pos_integer()]
  defp wrapped_visible_counts(snapshot, width, oracle, cursor_line, preview, retained) do
    {lines, _matches} =
      SearchHighlight.maybe_substitute_preview(preview, snapshot.lines, snapshot.first_line)

    WrapLayout.row_counts(snapshot, width, oracle, cursor_line, lines, retained)
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

    cursor_visual_row =
      case Enum.at(wrap_map, cursor_idx) do
        nil -> 0
        entry -> entry |> WrapMap.row_at_byte(cursor_byte_col) |> elem(0)
      end

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

    opts = [
      breakindent: wrap_option(buf, :breakindent),
      linebreak: wrap_option(buf, :linebreak),
      oracle: oracle,
      tab_width: tab_width(buf)
    ]

    snapshot.lines
    |> WrapMap.count_rows(content_w, opts)
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

  @spec fetch_decorations(state(), pid()) :: Decorations.t()
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

  # Relative and hybrid numbers depend on the cursor line. Mark full
  # invalidation for classification, but keep the retained content.
  @spec detect_gutter_invalidation(Window.t(), non_neg_integer(), atom()) :: Window.t()
  defp detect_gutter_invalidation(window, cursor_line, line_number_style) do
    old_cursor = window.render_cache.last_cursor_line

    if old_cursor >= 0 and old_cursor != cursor_line and line_number_style in [:relative, :hybrid],
      do: Window.mark_fully_dirty(window),
      else: window
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
    {true, Gutter.total_width(line_number_style, line_count)}
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
