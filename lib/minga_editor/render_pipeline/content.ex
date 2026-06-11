defmodule MingaEditor.RenderPipeline.Content do
  @moduledoc """
  Stage 4: Content.

  Builds the semantic `RenderModel.Window` models for each editor window
  (buffer windows and agent chat windows) and resolves each active window's
  buffer cursor. Produces `WindowContent` carriers that the Compose stage
  flattens into the frame's window list.
  """

  alias MingaEditor.Agent.View.PromptRenderer
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias MingaEditor.Agent.ViewContext
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias Minga.Core.WrapMap
  alias Minga.RenderModel.Cursor
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias Minga.Telemetry

  alias Minga.RenderModel.Window, as: RenderWindow
  alias MingaEditor.RenderPipeline.AgentChatPrefetch
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.RenderModel.Window.Builder, as: WindowModelBuilder
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.WindowContent
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  @typedoc "Render pipeline input."
  @type state :: Input.t()

  @doc """
  Builds the semantic window models for each buffer window.

  Produces `WindowContent` carriers (the window's `RenderModel.Window`
  models) and the absolute cursor position for the active window.
  """
  @spec build_content(state(), %{Window.id() => WindowScroll.t()}) ::
          {[WindowContent.t()], Cursor.t() | nil, state()}
  def build_content(state, scrolls) do
    {contents, cursor_info, state} =
      Enum.reduce(scrolls, {[], nil, state}, fn {_win_id, scroll}, {contents, cursor_info, st} ->
        {wc, ci, st} = build_window_content(st, scroll)
        new_cursor = if scroll.is_active and ci != nil, do: ci, else: cursor_info
        {[wc | contents], new_cursor, st}
      end)

    {Enum.reverse(contents), cursor_info, state}
  end

  @doc """
  Builds the semantic window models for agent chat windows.

  Finds windows with `{:agent_chat, _}` content in the layout, renders
  the agent chat content into their rects, and returns `WindowContent`
  carriers. Buffer windows are skipped (handled by `build_content/2`).

  Returns an empty list if no agent chat windows exist.
  """
  @spec build_agent_chat_content(state(), Layout.t()) ::
          {[WindowContent.t()], Cursor.t() | nil, state()}
  def build_agent_chat_content(state, layout) do
    build_agent_chat_content(state, layout, %{})
  end

  @spec build_agent_chat_content(state(), Layout.t(), %{Window.id() => AgentChatPrefetch.t()}) ::
          {[WindowContent.t()], Cursor.t() | nil, state()}
  def build_agent_chat_content(state, layout, prefetched_agent_chats) do
    layout.window_layouts
    |> Enum.reduce({[], nil, state}, fn {win_id, win_layout}, {frames, cursor, st} ->
      window = Map.get(st.workspace.windows.map, win_id)
      prefetch = Map.get(prefetched_agent_chats, win_id)
      maybe_render_agent_window(window, prefetch, win_id, win_layout, frames, cursor, st)
    end)
  end

  @doc "Resets the per-frame rasterized-row counter at the start of the Content stage (#2287)."
  @spec reset_rows_rasterized(state()) :: state()
  def reset_rows_rasterized(state) do
    %{state | caches: %{state.caches | frame_rows_rasterized: 0}}
  end

  @doc "Returns the number of buffer rows rasterized so far this frame (#2287)."
  @spec rows_rasterized(state()) :: non_neg_integer()
  def rows_rasterized(state), do: state.caches.frame_rows_rasterized

  # ── Private ──────────────────────────────────────────────────────────────

  @spec add_rows_rasterized(state(), non_neg_integer()) :: state()
  defp add_rows_rasterized(state, count) do
    current = state.caches.frame_rows_rasterized
    %{state | caches: %{state.caches | frame_rows_rasterized: current + count}}
  end

  @spec build_window_content(state(), WindowScroll.t()) ::
          {WindowContent.t(), Cursor.t() | nil, state()}
  defp build_window_content(state, scroll) do
    %WindowScroll{
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
      width_oracle: width_oracle,
      window: window
    } = scroll

    {row_off, col_off, _content_width, _content_height} = win_layout.content

    cursor = {cursor_line, cursor_byte_col}

    # Build per-frame render context (also updates caches on state)
    {render_ctx, state} =
      ContentHelpers.build_render_ctx(state, window, %{
        viewport: viewport,
        cursor: cursor,
        cursor_col: cursor_col,
        lines: lines,
        first_line: first_line,
        preview_matches: preview_matches,
        gutter_w: gutter_w,
        content_w: content_w,
        has_sign_column: has_sign_column,
        file_path: snapshot.file_path,
        options: snapshot.options,
        decorations: snapshot.decorations,
        git_signs: scroll.git_signs,
        is_active: is_active,
        wrap_on: wrap_on,
        line_number_style: line_number_style,
        width_oracle: width_oracle
      })

    # Compute context fingerprint and check for context changes.
    # If any context input (visual selection, search, highlights, signs,
    # horizontal scroll, active status) changed, all lines are dirty.
    ctx_fp = ContentHelpers.context_fingerprint(render_ctx, is_active)
    window = Window.detect_context_change(window, ctx_fp)

    # Resolve the active window's buffer cursor.
    buf_cursor =
      if is_active do
        # When folds are active, viewport.top is in visible-line coordinates.
        # Convert cursor_line from buffer to visible for correct screen position.
        visible_cursor =
          if FoldMap.empty?(window.fold_map) do
            cursor_line
          else
            FoldMap.buffer_to_visible(window.fold_map, cursor_line)
          end

        {screen_row_delta, visual_row_byte_offset, visual_row_indent_width} =
          cursor_visual_position(%{
            wrap_on: wrap_on,
            lines: lines,
            first_line: first_line,
            cursor_line: cursor_line,
            cursor_byte_col: cursor_byte_col,
            content_w: content_w,
            viewport: viewport,
            options: snapshot.options,
            oracle: render_ctx.width_oracle,
            visible_line_map: scroll.visible_line_map
          })

        cr = max(visible_cursor - viewport.top + screen_row_delta + row_off, 0)

        # Adjust cursor column for inline virtual text that shifts content right
        adjusted_cursor_col =
          Decorations.buf_col_to_display_col(render_ctx.decorations, cursor_line, cursor_col)

        cursor_line_text = cursor_text_from_snapshot(lines, cursor_line, first_line)
        visual_row_col = Unicode.display_col(cursor_line_text, visual_row_byte_offset)

        cc =
          gutter_w + visual_row_indent_width + adjusted_cursor_col - visual_row_col -
            viewport.left + col_off

        Cursor.new(cr, cc, Minga.Editing.cursor_shape(state))
      else
        nil
      end

    # Build the canonical window model; TUI adapts it to cells at the frontend boundary.
    # Carry the previous frame's retained rows so unchanged rows are reused
    # without recomposing, and capture how many rows were freshly rasterized (#2287).
    {window_model, build_stats} =
      Telemetry.span([:minga, :render, :window_model_build], %{window_id: scroll.win_id}, fn ->
        WindowModelBuilder.build_with_stats(state, %{scroll | window: window}, render_ctx,
          content_kind: :buffer,
          retained_rows: Window.retained_rows(window),
          retained_wrap_lines: Window.retained_wrap_lines(window)
        )
      end)

    window =
      window
      |> Window.put_retained_rows(build_stats.retained_rows)
      |> Window.put_retained_wrap_lines(build_stats.retained_wrap_lines)

    state = add_rows_rasterized(state, build_stats.rasterized)

    window_content = WindowContent.new(window_model, [], buf_cursor)

    cursor_info = buf_cursor

    # Snapshot tracking fields after the render pass.
    updated_window =
      Window.snapshot_after_render(
        window,
        viewport.top,
        Viewport.cache_key(viewport),
        gutter_w,
        snapshot.line_count,
        cursor_line,
        scroll.buf_version,
        ctx_fp
      )

    new_map = Map.put(state.workspace.windows.map, scroll.win_id, updated_window)
    ws = state.workspace
    state = %{state | workspace: %{ws | windows: %{ws.windows | map: new_map}}}

    {window_content, cursor_info, state}
  end

  @spec cursor_visual_position(map()) :: {integer(), non_neg_integer(), non_neg_integer()}
  defp cursor_visual_position(%{wrap_on: false}), do: {0, 0, 0}

  defp cursor_visual_position(%{wrap_on: true, visible_line_map: visible_line_map})
       when is_list(visible_line_map), do: {0, 0, 0}

  defp cursor_visual_position(%{
         wrap_on: true,
         lines: lines,
         first_line: first_line,
         cursor_line: cursor_line,
         cursor_byte_col: cursor_byte_col,
         content_w: content_w,
         viewport: viewport,
         options: options,
         oracle: oracle
       }) do
    line_idx = cursor_line - first_line

    if line_idx >= 0 and line_idx < length(lines) do
      wrap_map = wrap_map_for_cursor(lines, line_idx, content_w, options, oracle)

      cursor_entry =
        Enum.at(wrap_map, line_idx, [
          %{byte_offset: 0, text: "", source_text: "", indent_width: 0}
        ])

      visual_row_idx = visual_row_index(cursor_entry, cursor_byte_col)
      rows_before = wrap_map |> Enum.take(line_idx) |> WrapMap.visual_row_count()
      logical_delta = cursor_line - viewport.top
      screen_delta = rows_before + visual_row_idx - viewport.visual_row_offset - logical_delta

      cursor_row =
        Enum.at(cursor_entry, visual_row_idx, %{
          byte_offset: 0,
          text: "",
          source_text: "",
          indent_width: 0
        })

      {screen_delta, cursor_row.byte_offset, Map.get(cursor_row, :indent_width, 0)}
    else
      {0, 0, 0}
    end
  end

  @spec wrap_map_for_cursor(
          [String.t()],
          non_neg_integer(),
          pos_integer(),
          %{atom() => term()},
          Minga.Core.WidthOracle.t()
        ) :: WrapMap.t()
  defp wrap_map_for_cursor(lines, line_idx, content_w, options, oracle) do
    relevant_lines = Enum.take(lines, line_idx + 1)

    WrapMap.compute(relevant_lines, content_w,
      breakindent: Map.get(options, :breakindent, true),
      linebreak: Map.get(options, :linebreak, true),
      oracle: oracle,
      tab_width: Map.get(options, :tab_width, 2)
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

  defp maybe_render_agent_window(
         %Window{content: {:agent_chat, _}} = window,
         prefetch,
         win_id,
         win_layout,
         frames,
         cursor,
         st
       ) do
    if prefetch == nil and not st.workspace.agent_ui.view.help_visible do
      Minga.Log.debug(:render, "[content] skipped agent window #{win_id}: missing prefetch")
      {frames, cursor, st}
    else
      {content, ci, st} = render_agent_chat_window(st, window, prefetch, win_id, win_layout)
      new_cursor = if ci != nil, do: ci, else: cursor
      {[content | frames], new_cursor, st}
    end
  catch
    # Buffer process died between the :DOWN message and this render.
    # Skip this window; the :DOWN handler will clean up state next cycle.
    :exit, _ ->
      Minga.Log.debug(:render, "[content] skipped agent window #{win_id}: buffer process dead")
      {frames, cursor, st}
  end

  defp maybe_render_agent_window(_window, _prefetch, _win_id, _win_layout, frames, cursor, st) do
    {frames, cursor, st}
  end

  # Renders an agent chat window: buffer content through the standard
  # pipeline (for decorations, visual mode, search) plus the prompt
  # input from PromptRenderer.
  @spec render_agent_chat_window(
          state(),
          Window.t(),
          AgentChatPrefetch.t() | nil,
          Window.id(),
          Layout.window_layout()
        ) :: {WindowContent.t(), Cursor.t() | nil, state()}
  defp render_agent_chat_window(state, window, prefetch, _win_id, win_layout) do
    # Build ViewContext once for the prompt geometry and the semantic prompt model.
    ctx = ViewContext.from_editor_state(state)

    # Split the content rect to carve out a sidebar when wide enough. The
    # carved rect still drives layout (chat width, cursor math); the dashboard
    # itself is a semantic surface (AgentChatBuilder), not a cell-era sidebar.
    win_layout = Layout.add_sidebar(win_layout)
    {row_off, col_off, chat_width, height} = win_layout.content

    # Compute prompt height and subdivide the content rect for chat content vs
    # prompt input. PromptRenderer here is pure layout math (no cell drawing).
    prompt_height = PromptRenderer.prompt_height(ctx, chat_width)
    input_v_gap = 1
    chat_height = max(height - prompt_height - input_v_gap, 1)
    prompt_row = row_off + chat_height + input_v_gap
    prompt_rect = {prompt_row, col_off, chat_width, prompt_height}

    # When help is visible the chat buffer is suppressed. The help overlay,
    # prompt, and dashboard all reach the live (semantic) frontends through the
    # AgentChat semantic model, so this branch emits no window models.
    help_visible = state.workspace.agent_ui.view.help_visible

    if help_visible do
      {WindowContent.new(nil, [], nil), nil, state}
    else
      render_agent_chat_buffer(
        state,
        ctx,
        window,
        prefetch,
        win_layout,
        row_off: row_off,
        col_off: col_off,
        chat_width: chat_width,
        chat_height: chat_height,
        height: height,
        prompt_rect: prompt_rect
      )
    end
  end

  @spec render_agent_chat_buffer(
          state(),
          ViewContext.t(),
          Window.t(),
          AgentChatPrefetch.t(),
          Layout.window_layout(),
          keyword()
        ) :: {WindowContent.t(), Cursor.t() | nil, state()}
  defp render_agent_chat_buffer(
         state,
         ctx,
         _window,
         %AgentChatPrefetch{} = prefetch,
         win_layout,
         opts
       ) do
    row_off = Keyword.fetch!(opts, :row_off)
    col_off = Keyword.fetch!(opts, :col_off)
    chat_width = Keyword.fetch!(opts, :chat_width)
    chat_height = Keyword.fetch!(opts, :chat_height)
    height = Keyword.fetch!(opts, :height)
    prompt_rect = Keyword.fetch!(opts, :prompt_rect)

    %AgentChatPrefetch{
      win_id: win_id,
      window: window,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_byte_col: cursor_byte_col,
      cursor_col: cursor_col,
      first_line: first_line,
      snapshot: snapshot,
      line_number_style: line_number_style,
      gutter_w: gutter_w,
      content_w: content_w,
      buf_version: buf_version
    } = prefetch

    is_active =
      window.buffer == state.workspace.buffers.active or state.workspace.windows.active == win_id

    visible_rows = Viewport.content_rows(viewport)
    line_count = snapshot.line_count

    # Build render context (includes decorations from the buffer; also updates caches on state)
    {render_ctx, state} =
      ContentHelpers.build_render_ctx(state, window, %{
        viewport: viewport,
        cursor: {cursor_line, cursor_byte_col},
        cursor_col: cursor_col,
        lines: snapshot.lines,
        first_line: first_line,
        preview_matches: [],
        gutter_w: gutter_w,
        content_w: content_w,
        has_sign_column: true,
        is_active: is_active,
        wrap_on: true,
        line_number_style: line_number_style,
        options: snapshot.options,
        decorations: snapshot.decorations,
        git_signs: %{},
        width_oracle: MingaEditor.Frontend.Capabilities.width_oracle(state.capabilities)
      })

    # Compute the display map (block decorations, fold regions, virtual lines).
    # Without this, the sequential fast path skips all decoration rendering.
    decorations = render_ctx.decorations
    fold_map = window.fold_map

    visible_line_map =
      build_visible_line_map(
        fold_map,
        decorations,
        first_line,
        visible_rows,
        line_count,
        content_w
      )

    # Detect scroll/structural invalidation (viewport_top, gutter, line count,
    # buffer version). The normal buffer path does this in the Scroll stage;
    # agent chat skips that stage, so we must do it here.
    window =
      Window.detect_invalidation(
        window,
        viewport.top,
        Viewport.cache_key(viewport),
        gutter_w,
        line_count,
        buf_version,
        cursor_line
      )

    # Detect context changes to invalidate dirty-line cache
    ctx_fp = ContentHelpers.context_fingerprint(render_ctx, is_active)
    window = Window.detect_context_change(window, ctx_fp)

    {window, content_epoch, full_refresh?} =
      Window.prepare_render_epoch(
        window,
        agent_render_reset_fingerprint(%{
          win_id: win_id,
          window: window,
          win_layout: win_layout,
          chat_width: chat_width,
          chat_height: chat_height,
          content_w: content_w,
          gutter_w: gutter_w,
          viewport: viewport,
          line_number_style: line_number_style,
          options: snapshot.options,
          width_oracle: MingaEditor.Frontend.Capabilities.width_oracle(state.capabilities)
        })
      )

    # Snapshot render state so future frames can detect changes.
    # Without this, dirty_lines stays empty and content is never re-rendered.
    # buf_version was already fetched above for detect_invalidation.
    window =
      Window.snapshot_after_render(
        window,
        viewport.top,
        Viewport.cache_key(viewport),
        gutter_w,
        line_count,
        cursor_line,
        buf_version,
        ctx_fp
      )

    # Persist the updated window back to input
    ws = state.workspace
    new_map = Map.put(ws.windows.map, window.id, window)
    state = %{state | workspace: %{ws | windows: %{ws.windows | map: new_map}}}

    buf_cursor =
      build_agent_buffer_cursor(is_active, %{
        decorations: render_ctx.decorations,
        cursor_line: cursor_line,
        cursor_col: cursor_col,
        viewport: viewport,
        row_off: row_off,
        col_off: col_off,
        gutter_w: gutter_w,
        state: state
      })

    # Prompt cursor (overrides buffer cursor when input is focused).
    # cursor_position_in_rect needs the full content rect to compute
    # the prompt position correctly (it subdivides internally).
    full_rect = {row_off, col_off, chat_width, height}
    final_cursor = prefer_prompt_cursor(prompt_cursor(ctx, full_rect), buf_cursor)

    chat_win_layout = %{win_layout | content: {row_off, col_off, chat_width, chat_height}}

    model_scroll = %WindowScroll{
      win_id: win_id,
      window: window,
      win_layout: chat_win_layout,
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_byte_col: cursor_byte_col,
      cursor_col: cursor_col,
      first_line: first_line,
      lines: snapshot.lines,
      snapshot: snapshot,
      gutter_w: gutter_w,
      content_w: content_w,
      has_sign_column: true,
      preview_matches: [],
      line_number_style: line_number_style,
      wrap_on: true,
      buf_version: buf_version,
      width_oracle: MingaEditor.Frontend.Capabilities.width_oracle(state.capabilities),
      git_signs: %{},
      visible_line_map: visible_line_map,
      content_epoch: content_epoch,
      full_refresh: full_refresh?
    }

    {window_model, additional_window_models} =
      agent_window_models(state, model_scroll, render_ctx, ctx, chat_width, prompt_rect)

    window_content = WindowContent.new(window_model, additional_window_models, final_cursor)

    state = update_agent_scroll_metrics(state, line_count, chat_height)

    {window_content, final_cursor, state}
  end

  @spec agent_render_reset_fingerprint(map()) :: term()
  defp agent_render_reset_fingerprint(params) do
    options = params.options

    {
      params.win_id,
      :agent_chat,
      params.window.buffer,
      params.win_layout.total,
      params.win_layout.content,
      params.chat_width,
      params.chat_height,
      params.content_w,
      params.gutter_w,
      true,
      params.line_number_style,
      params.viewport.rows,
      params.viewport.cols,
      params.window.fold_map,
      Map.get(options, :breakindent, true),
      Map.get(options, :linebreak, true),
      Map.get(options, :tab_width, 2),
      Minga.Core.WidthOracle.fingerprint(params.width_oracle)
    }
  end

  @spec update_agent_scroll_metrics(state(), non_neg_integer(), pos_integer()) :: state()
  defp update_agent_scroll_metrics(state, total_lines, visible_height) do
    ws = state.workspace
    panel = ws.agent_ui.panel

    updated_scroll =
      Minga.Editing.Scroll.update_metrics(panel.scroll, total_lines, visible_height)

    updated_panel = %{panel | scroll: updated_scroll}
    updated_ui = %{ws.agent_ui | panel: updated_panel}
    %{state | workspace: %{ws | agent_ui: updated_ui}}
  end

  @spec build_visible_line_map(
          FoldMap.t(),
          Decorations.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [{non_neg_integer(), term()}] | nil
  defp build_visible_line_map(
         fold_map,
         decorations,
         first_line,
         visible_rows,
         line_count,
         content_w
       ) do
    case DisplayMap.compute(
           fold_map,
           decorations,
           first_line,
           visible_rows,
           line_count,
           content_w
         ) do
      nil -> nil
      %DisplayMap{} = dm -> DisplayMap.to_visible_line_map(dm)
    end
  end

  @spec build_agent_buffer_cursor(boolean(), map()) :: Cursor.t() | nil
  defp build_agent_buffer_cursor(false, _params), do: nil

  defp build_agent_buffer_cursor(true, params) do
    adjusted_cc =
      Decorations.buf_col_to_display_col(
        params.decorations,
        params.cursor_line,
        params.cursor_col
      )

    cr = params.cursor_line - params.viewport.top + params.row_off
    cc = params.gutter_w + adjusted_cc - params.viewport.left + params.col_off
    # Clamp: a cursor transiently outside its own viewport must not trip
    # RenderModel.Cursor's non-negative guard (the old DisplayList.Cursor was
    # lax here; a losing cursor candidate was simply discarded downstream).
    Cursor.new(max(cr, 0), max(cc, 0), Minga.Editing.cursor_shape(params.state))
  end

  @spec prompt_cursor(
          ViewContext.t(),
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}
        ) :: Cursor.t() | nil
  defp prompt_cursor(ctx, full_rect) do
    case PromptRenderer.cursor_position_in_rect(ctx, full_rect) do
      {row, col} -> Cursor.new(row, col, :beam)
      nil -> nil
    end
  end

  @spec prefer_prompt_cursor(Cursor.t() | nil, Cursor.t() | nil) :: Cursor.t() | nil
  defp prefer_prompt_cursor(nil, buf_cursor), do: buf_cursor
  defp prefer_prompt_cursor(%Cursor{} = prompt_cursor, _buf_cursor), do: prompt_cursor

  @spec agent_window_models(
          state(),
          WindowScroll.t(),
          MingaEditor.Renderer.Context.t(),
          ViewContext.t(),
          pos_integer(),
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}
        ) :: {RenderWindow.t() | nil, [RenderWindow.t()]}
  defp agent_window_models(state, model_scroll, render_ctx, ctx, chat_width, prompt_rect) do
    window_model =
      Telemetry.span(
        [:minga, :render, :window_model_build],
        %{window_id: model_scroll.win_id},
        fn ->
          WindowModelBuilder.build(state, model_scroll, render_ctx, content_kind: :agent_chat)
        end
      )

    inner_width = PromptRenderer.input_inner_width(PromptRenderer.input_box_width(chat_width))

    additional_window_models =
      case PromptRenderWindow.build(ctx, inner_width, prompt_rect,
             content_epoch: model_scroll.content_epoch,
             full_refresh: model_scroll.full_refresh
           ) do
        nil -> []
        prompt_window_model -> [prompt_window_model]
      end

    {window_model, additional_window_models}
  end

  defp cursor_text_from_snapshot(lines, cursor_line, first_line) do
    idx = cursor_line - first_line

    if idx >= 0 and idx < length(lines) do
      Enum.at(lines, idx, "")
    else
      ""
    end
  end
end
