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
  alias Minga.RenderModel.Window.RowSlotExhaustedError
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias Minga.Telemetry

  alias MingaEditor.Renderer.Context
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.RenderModel.Window.Builder, as: WindowModelBuilder
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.WindowContent
  alias MingaEditor.Viewport
  alias MingaEditor.Renderer.RenderWindow, as: Window

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

  @spec build_agent_chat_content(state(), Layout.t(), map()) ::
          {[WindowContent.t()], Cursor.t() | nil, state()}
  def build_agent_chat_content(state, layout, _prefetched_agent_chats) do
    layout.window_layouts
    |> Enum.reduce({[], nil, state}, fn {win_id, win_layout}, {frames, cursor, st} ->
      window = Map.get(st.workspace.windows.map, win_id)
      maybe_render_agent_window(window, win_id, win_layout, frames, cursor, st)
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

  @spec build_window_model_with_slot_reset(state(), WindowScroll.t(), Window.t(), Context.t()) ::
          {Minga.RenderModel.Window.t(), WindowModelBuilder.build_stats(), Window.t()}
  defp build_window_model_with_slot_reset(state, scroll, window, render_ctx) do
    result =
      Telemetry.span([:minga, :render, :window_model_build], %{window_id: scroll.win_id}, fn ->
        WindowModelBuilder.build_with_stats(state, %{scroll | window: window}, render_ctx,
          content_kind: :buffer,
          retained_rows: Window.retained_rows(window),
          retained_wrap_lines: Window.retained_wrap_lines(window),
          resident_build: Window.resident_build(window),
          hydration_reason: Window.hydration_reason(window),
          edit_deltas: Window.pending_edit_deltas(window),
          row_slot_allocator: Window.row_slot_allocator(window)
        )
      end)

    {window_model, build_stats} = result
    {window_model, build_stats, window}
  rescue
    RowSlotExhaustedError ->
      reset_window = Window.reset_content_identity(window, scroll.snapshot)

      reset_scroll = %{
        scroll
        | window: reset_window,
          line_identity: Window.line_identity(reset_window),
          content_epoch: Window.content_epoch(reset_window),
          full_refresh: true
      }

      build_window_model_with_slot_reset(state, reset_scroll, reset_window, render_ctx)
  end

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
    {window_model, build_stats, window} =
      build_window_model_with_slot_reset(state, scroll, window, render_ctx)

    window =
      window
      |> Window.put_retained_rows(build_stats.retained_rows)
      |> Window.put_retained_wrap_lines(build_stats.retained_wrap_lines)
      |> Window.put_resident_build(build_stats.resident_build)
      |> Window.put_row_slot_allocator(build_stats.row_slot_allocator)

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

    if line_idx >= 0 and line_idx < Enum.count(lines) do
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
    |> Enum.at(-1, {%{byte_offset: 0}, 0})
    |> elem(1)
  end

  defp maybe_render_agent_window(
         %Window{content: {:agent_chat, _}} = window,
         win_id,
         win_layout,
         frames,
         cursor,
         st
       ) do
    {content, ci, st} = render_agent_chat_window(st, window, win_id, win_layout)
    new_cursor = if ci != nil, do: ci, else: cursor
    {[content | frames], new_cursor, st}
  catch
    # Prompt or session process died between state sync and this render.
    # Skip this window; the next lifecycle event will clean up state.
    :exit, _ ->
      Minga.Log.debug(
        :render,
        "[content] skipped agent window #{win_id}: agent process unavailable"
      )

      {frames, cursor, st}
  end

  defp maybe_render_agent_window(_window, _win_id, _win_layout, frames, cursor, st) do
    {frames, cursor, st}
  end

  # Renders an agent chat window through semantic transcript and prompt models.
  @spec render_agent_chat_window(
          state(),
          Window.t(),
          Window.id(),
          Layout.window_layout()
        ) :: {WindowContent.t(), Cursor.t() | nil, state()}
  defp render_agent_chat_window(state, window, win_id, win_layout) do
    # Build ViewContext once for the prompt geometry and the semantic prompt model.
    ctx = ViewContext.from_editor_state(state)

    # Split the content rect to carve out a sidebar when wide enough. The
    # carved rect still drives layout (chat width, cursor math); the sidebar
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
    full_rect = {row_off, col_off, chat_width, height}
    state = update_agent_window_viewport(state, window, win_id, chat_height, chat_width)

    # When help is visible the chat buffer is suppressed. The help overlay
    # and prompt both reach the live (semantic) frontends through the
    # AgentChat semantic model, so this branch emits no window models.
    help_visible = state.workspace.agent_ui.view.help_visible

    if help_visible do
      {WindowContent.new(nil, [], nil), nil, state}
    else
      render_semantic_agent_chat_window(
        state,
        ctx,
        chat_width,
        chat_height,
        prompt_rect,
        full_rect
      )
    end
  end

  @spec render_semantic_agent_chat_window(
          state(),
          ViewContext.t(),
          pos_integer(),
          pos_integer(),
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()},
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}
        ) :: {WindowContent.t(), Cursor.t() | nil, state()}
  defp render_semantic_agent_chat_window(
         state,
         ctx,
         chat_width,
         chat_height,
         prompt_rect,
         full_rect
       ) do
    inner_width = PromptRenderer.input_inner_width(PromptRenderer.input_box_width(chat_width))

    prompt_models =
      case PromptRenderWindow.build(ctx, inner_width, prompt_rect,
             content_epoch: 0,
             full_refresh: true
           ) do
        nil -> []
        prompt_window_model -> [prompt_window_model]
      end

    cursor = prompt_cursor(ctx, full_rect)
    total_lines = Enum.count(state.workspace.agent_ui.panel.cached_line_index)
    state = update_agent_scroll_metrics(state, total_lines, chat_height)

    {WindowContent.new(nil, prompt_models, cursor), cursor, state}
  end

  @spec update_agent_window_viewport(
          state(),
          Window.t(),
          Window.id(),
          pos_integer(),
          pos_integer()
        ) ::
          state()
  defp update_agent_window_viewport(
         state,
         %Window{viewport: viewport} = window,
         win_id,
         rows,
         cols
       ) do
    ws = state.workspace
    updated_viewport = %{viewport | rows: rows, cols: cols, reserved: 0}
    updated_window = Window.set_viewport(window, updated_viewport)
    windows = %{ws.windows | map: Map.put(ws.windows.map, win_id, updated_window)}
    %{state | workspace: %{ws | windows: windows}}
  end

  @spec update_agent_scroll_metrics(state(), non_neg_integer(), pos_integer()) :: state()
  defp update_agent_scroll_metrics(state, total_lines, visible_height) do
    ws = state.workspace

    agent_ui =
      MingaEditor.Agent.UIState.record_scroll_metrics(ws.agent_ui, total_lines, visible_height)

    %{state | workspace: %{ws | agent_ui: agent_ui}}
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

  defp cursor_text_from_snapshot(lines, cursor_line, first_line) do
    idx = cursor_line - first_line

    if idx >= 0 and idx < Enum.count(lines) do
      Enum.at(lines, idx, "")
    else
      ""
    end
  end
end
