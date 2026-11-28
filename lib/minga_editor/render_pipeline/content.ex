defmodule MingaEditor.RenderPipeline.Content do
  @moduledoc """
  Stage 4: Content.

  Builds the semantic `RenderModel.Window` models for buffer, agent chat, and read-only review windows and resolves each active window's buffer cursor.
  Produces `WindowContent` carriers that the Compose stage flattens into the frame's window list.
  """

  alias MingaEditor.Agent.View.PromptRenderer
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias MingaEditor.Agent.ViewContext
  alias MingaEditor.Agent.View.PromptFrame
  alias MingaEditor.Agent.View.PromptProjection
  alias MingaEditor.Agent.PromptInput
  alias Minga.Core.Decorations
  alias Minga.Core.WidthOracle.Monospace
  alias Minga.Config
  alias Minga.RenderModel.Cursor
  alias Minga.RenderModel.Window.RowSlotExhaustedError
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias Minga.Telemetry

  alias MingaEditor.Renderer.Context
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.RenderPipeline.BufferPrefetch
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.RenderModel.Window.Builder, as: WindowModelBuilder
  alias MingaEditor.RenderModel.Window.BuildResult
  alias MingaEditor.RenderModel.Window.ResidentBuild
  alias MingaEditor.Agent.ReviewHighlights
  alias MingaEditor.RenderModel.Window.ReviewBuilder
  alias MingaEditor.RenderModel.Window.ReviewLayout
  alias MingaEditor.Shell.Runtime
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
  Builds semantic window models for agent chat and read-only review windows.

  Buffer windows are handled by `build_content/2`.
  Returns an empty list when no agent workspace windows exist.
  """
  @spec build_agent_chat_content(state(), Layout.t()) ::
          {[WindowContent.t()], Cursor.t() | nil, state()}
  def build_agent_chat_content(state, layout) do
    layout.window_layouts
    |> Enum.reduce({[], nil, state}, fn {win_id, win_layout}, {frames, cursor, st} ->
      window = Map.get(st.windows.map, win_id)
      maybe_render_agent_window(window, win_id, win_layout, frames, cursor, st)
    end)
  end

  @doc "Resets the per-frame rasterized-row counter at the start of the Content stage (#2287)."
  @spec reset_rows_rasterized(state()) :: state()
  def reset_rows_rasterized(state) do
    Input.reset_frame_rows_rasterized(state)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec build_window_model_with_slot_reset(
          state(),
          WindowScroll.t(),
          Window.t(),
          Context.t(),
          MingaEditor.RenderModel.Window.ResidentBuild.plan() | :windowed
        ) ::
          {Minga.RenderModel.Window.t(), BuildResult.t(), Window.t(),
           MingaEditor.UI.FontRegistry.t()}
  defp build_window_model_with_slot_reset(state, scroll, window, render_ctx, plan) do
    result =
      Telemetry.span([:minga, :render, :window_model_build], %{window_id: scroll.window.id}, fn ->
        WindowModelBuilder.build_with_stats(
          state,
          %{scroll | window: window},
          render_ctx,
          state.font_registry,
          content_kind: :buffer,
          retained_rows: Window.retained_rows(window),
          retained_wrap_lines: Window.retained_wrap_lines(window),
          resident_build: Window.resident_build(window),
          resident_semantic_state: Window.resident_semantic_state(window),
          resident_plan: plan,
          hydration_reason: Window.hydration_reason(window),
          edit_deltas: Window.pending_edit_deltas(window),
          row_slot_allocator: Window.row_slot_allocator(window)
        )
      end)

    {window_model, build_result, font_registry} = result
    {window_model, build_result, window, font_registry}
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

      {reset_scroll, render_ctx, state, plan} = prepare_window_source(state, reset_scroll)
      build_window_model_with_slot_reset(state, reset_scroll, reset_window, render_ctx, plan)
  end

  @spec prepare_window_source(state(), WindowScroll.t()) ::
          {WindowScroll.t(), Context.t(), state(),
           MingaEditor.RenderModel.Window.ResidentBuild.plan() | :windowed}
  defp prepare_window_source(state, scroll) do
    {ctx, state} = build_render_context(state, scroll)
    plan = WindowModelBuilder.plan_resident_build(scroll, ctx)
    prepare_planned_source(state, scroll, ctx, plan)
  end

  @spec prepare_planned_source(
          state(),
          WindowScroll.t(),
          Context.t(),
          MingaEditor.RenderModel.Window.ResidentBuild.plan() | :windowed
        ) ::
          {WindowScroll.t(), Context.t(), state(),
           MingaEditor.RenderModel.Window.ResidentBuild.plan() | :windowed}
  defp prepare_planned_source(state, scroll, _ctx, {:hydrate, _reason} = plan) do
    prepare_resident_range(state, scroll, plan)
  end

  defp prepare_planned_source(
         state,
         %WindowScroll{wrap_on: true} = scroll,
         _ctx,
         {:splices, _} = plan
       ) do
    prepare_resident_range(state, scroll, plan)
  end

  defp prepare_planned_source(state, scroll, ctx, plan), do: {scroll, ctx, state, plan}

  @spec prepare_resident_range(state(), WindowScroll.t(), ResidentBuild.plan()) ::
          {WindowScroll.t(), Context.t(), state(), ResidentBuild.plan()}
  defp prepare_resident_range(state, scroll, plan) do
    scroll = BufferPrefetch.ensure_resident_source(state, scroll, plan)
    {ctx, state} = build_render_context(state, scroll)
    {scroll, ctx, state, plan}
  end

  @spec build_render_context(state(), WindowScroll.t()) :: {Context.t(), state()}
  defp build_render_context(state, scroll) do
    ContentHelpers.build_render_ctx(state, scroll.window, %{
      viewport: scroll.viewport,
      cursor: {scroll.cursor_line, scroll.cursor_byte_col},
      cursor_col: scroll.cursor_col,
      lines: scroll.lines,
      first_line: scroll.first_line,
      extra_sources: for({first, _offset, lines} <- scroll.extra_sources, do: {first, lines}),
      preview_matches: scroll.preview_matches,
      gutter_w: scroll.gutter_w,
      content_w: scroll.content_w,
      has_sign_column: scroll.has_sign_column,
      file_path: scroll.snapshot.file_path,
      options: scroll.snapshot.options,
      visible_line_map: scroll.visible_line_map,
      decorations: scroll.snapshot.decorations,
      git_signs: scroll.git_signs,
      is_active: scroll.is_active,
      wrap_on: scroll.wrap_on,
      line_number_style: scroll.line_number_style,
      width_oracle: scroll.width_oracle
    })
  end

  @spec add_rows_rasterized(state(), non_neg_integer()) :: state()
  defp add_rows_rasterized(state, count) do
    Input.add_frame_rows_rasterized(state, count)
  end

  @spec build_window_content(state(), WindowScroll.t()) ::
          {WindowContent.t(), Cursor.t() | nil, state()}
  defp build_window_content(state, scroll) do
    {scroll, render_ctx, state, plan} = prepare_window_source(state, scroll)

    %WindowScroll{
      win_layout: win_layout,
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_col: cursor_col,
      snapshot: snapshot,
      gutter_w: gutter_w,
      window: window
    } = scroll

    {row_off, col_off, _content_width, _content_height} = win_layout.content

    # Context invalidation is detected after frame classification.
    ctx_fp = ContentHelpers.context_fingerprint(render_ctx, is_active)
    window = Window.detect_context_change(window, ctx_fp)

    # Wrapped cursors are projected from the composed rows in the window model.
    buf_cursor =
      if is_active and not scroll.wrap_on do
        visible_cursor =
          if FoldMap.empty?(window.fold_map) do
            cursor_line
          else
            FoldMap.buffer_to_visible(window.fold_map, cursor_line)
          end

        adjusted_col =
          Decorations.buf_col_to_display_col(render_ctx.decorations, cursor_line, cursor_col)

        if Viewport.includes_column?(viewport, adjusted_col, scroll.content_w) do
          row = max(visible_cursor - viewport.top + row_off, 0)
          col = gutter_w + adjusted_col - viewport.left + col_off
          Cursor.new(row, col, Minga.Editing.cursor_shape(state))
        end
      end

    # Build the canonical window model; TUI adapts it to cells at the frontend boundary.
    # Carry the previous frame's retained rows so unchanged rows are reused
    # without recomposing, and capture how many rows were freshly rasterized (#2287).
    {window_model, build_result, window, font_registry} =
      build_window_model_with_slot_reset(state, scroll, window, render_ctx, plan)

    {window_model, window, viewport, buf_cursor} =
      finalize_buffer_presentation(window_model, window, scroll, buf_cursor)

    presentation =
      TextPresentation.settle_scroll(build_result.text_presentation, window_model.scroll_seq)

    window =
      window
      |> Window.put_retained_rows(build_result.retained_rows)
      |> Window.put_retained_wrap_lines(build_result.retained_wrap_lines)
      |> Window.complete_resident_build(
        build_result.resident_build,
        build_result.resident_semantic_state
      )
      |> Window.put_text_presentation(presentation)
      |> Window.put_gutter_authorship(window_model.gutter)
      |> Window.put_row_slot_allocator(build_result.row_slot_allocator)

    state =
      state
      |> Input.with_font_registry(font_registry)
      |> add_rows_rasterized(build_result.rasterized)

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
        scroll.snapshot.version,
        ctx_fp
      )

    state = Input.record_render_window(state, scroll.window.id, updated_window)

    {window_content, cursor_info, state}
  end

  @spec finalize_buffer_presentation(
          Minga.RenderModel.Window.t(),
          Window.t(),
          WindowScroll.t(),
          Cursor.t() | nil
        ) :: {Minga.RenderModel.Window.t(), Window.t(), Viewport.t(), Cursor.t() | nil}
  defp finalize_buffer_presentation(
         model,
         window,
         %WindowScroll{wrap_on: true, full_residence: true} = scroll,
         _cursor
       ) do
    geometry = model.geometry.viewport

    viewport =
      Viewport.put_top_visual(
        scroll.viewport,
        geometry.top,
        geometry.visual_row_offset,
        geometry.visual_row_offset + 1
      )

    window = window |> Window.set_viewport(viewport) |> Window.settle_scroll_seq()
    model = %{model | scroll_seq: Window.scroll_seq(window)}
    {model, window, viewport, wrapped_model_cursor(model, scroll)}
  end

  defp finalize_buffer_presentation(
         model,
         window,
         %WindowScroll{wrap_on: true} = scroll,
         _cursor
       ),
       do: {model, window, scroll.viewport, wrapped_model_cursor(model, scroll)}

  defp finalize_buffer_presentation(model, window, scroll, cursor) do
    viewport = Viewport.put_horizontal_pan_limit(scroll.viewport, model.horizontal_pan_limit)
    {model, Window.set_viewport(window, viewport), viewport, cursor}
  end

  defp wrapped_model_cursor(model, scroll) do
    if scroll.is_active and model.cursor_visible do
      {row, col, _width, _height} = scroll.win_layout.content

      Cursor.new(
        row + model.cursor_row,
        col + scroll.gutter_w + model.cursor_col,
        model.cursor_shape
      )
    end
  end

  defp maybe_render_agent_window(
         %Window{content: {:agent_chat, _}} = window,
         win_id,
         _win_layout,
         frames,
         cursor,
         %{workspace: %{agent_ui: %{panel: %{prompt_buffer: nil}}}} = st
       ) do
    {frames, cursor, warn_unavailable_prompt(st, window, win_id, :missing)}
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
    # Retire the old composer frame so AgentChatBuilder can publish the failure.
    :exit, _ ->
      {frames, cursor, warn_unavailable_prompt(st, window, win_id, :unavailable)}
  end

  defp maybe_render_agent_window(
         %Window{content: {:agent_review, :semantic}},
         _win_id,
         %{content: {_row, _col, width, height}},
         frames,
         cursor,
         st
       )
       when width == 0 or height == 0 do
    {frames, cursor, st}
  end

  defp maybe_render_agent_window(
         %Window{content: {:agent_review, :semantic}} = window,
         win_id,
         win_layout,
         frames,
         cursor,
         st
       ) do
    {_row, _col, width, _height} = win_layout.content
    frame = st.intent.frame
    view = st.workspace.agent_ui.view
    syntax = ReviewHighlights.sides(view.review_highlights)
    layout = ReviewLayout.new(width, %Monospace{}, frame.theme, Config.get(:tab_width), syntax)
    scope = Runtime.review_scope(frame.shell, frame.shell_state)

    result =
      Telemetry.span([:minga, :render, :window_model_build], %{window_id: win_id}, fn ->
        ReviewBuilder.build(window, view.preview, win_layout, layout, scope, review_keys(frame))
      end)

    case result do
      {:ok, model, window} ->
        content = WindowContent.new(model, [], nil)
        {[content | frames], cursor, Input.record_render_window(st, win_id, window)}

      :not_visible ->
        {frames, cursor, st}

      {:error, reason} ->
        raise "Could not render read-only agent review: #{inspect(reason)}"
    end
  end

  defp maybe_render_agent_window(_window, _win_id, _win_layout, frames, cursor, st) do
    {frames, cursor, st}
  end

  # The review names the keys of the active editing model, spelled for this frontend.
  @spec review_keys(MingaEditor.RenderPipeline.FrameIntent.t()) ::
          Minga.Keymap.Scope.Agent.diff_review_key_set()
  defp review_keys(frame) do
    Minga.Keymap.Scope.Agent.diff_review_key_set(
      frame.editing_model,
      MingaEditor.Frontend.Capabilities.gui?(frame.capabilities)
    )
  end

  @spec warn_unavailable_prompt(state(), Window.t(), Window.id(), :missing | :unavailable) ::
          state()
  defp warn_unavailable_prompt(state, window, id, reason) do
    fault = {id, window.accessibility_generation, reason}

    if state.caches.prompt_unavailable == fault do
      state
    else
      # Publishing to Messages requests another render. Warn once per fault.
      Minga.Log.warning(
        :render,
        "[content] Agent composer unavailable for window #{id}: #{reason}"
      )

      Input.record_prompt_unavailable(state, fault)
    end
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

    inner_width = PromptRenderer.input_inner_width(PromptRenderer.input_box_width(chat_width))

    projection =
      PromptProjection.build(ctx.ui_state.panel, inner_width,
        oracle: MingaEditor.Frontend.Capabilities.width_oracle(ctx.capabilities)
      )

    prompt_height = projection.visible_rows + 2
    input_v_gap = 1
    chat_height = max(height - prompt_height - input_v_gap, 1)
    prompt_row = row_off + chat_height + input_v_gap
    prompt_rect = {prompt_row + 1, col_off + 4, projection.columns, projection.visible_rows}
    state = update_agent_window_viewport(state, window, win_id, chat_height, chat_width)

    render_semantic_agent_chat_window(
      state,
      ctx,
      chat_width,
      chat_height,
      prompt_rect,
      projection
    )
  end

  @spec render_semantic_agent_chat_window(
          state(),
          ViewContext.t(),
          pos_integer(),
          pos_integer(),
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()},
          PromptProjection.t()
        ) :: {WindowContent.t(), Cursor.t() | nil, state()}
  defp render_semantic_agent_chat_window(
         state,
         ctx,
         _chat_width,
         chat_height,
         prompt_rect,
         projection
       ) do
    presentation_id =
      if is_integer(state.frame_seq),
        do: state.frame_seq + 1,
        else: System.unique_integer([:positive, :monotonic])

    frame = state.intent.frame

    owner =
      PromptInput.submission_owner(
        Runtime.review_scope(frame.shell, frame.shell_state),
        ctx.ui_state
      )

    {prompt_window, lease} =
      PromptRenderWindow.build_presented(ctx, projection.columns, prompt_rect,
        projection: projection,
        submission_owner: owner,
        presentation_id: presentation_id,
        previous_presentation: state.caches.prompt_presentation,
        cursor_eligible:
          state.intent.frame.focus_owner.responder == :editor_view and
            state.intent.frame.focus_owner.surface == :agent,
        full_refresh: false
      )

    prompt = %PromptFrame{window: prompt_window, presentation: lease, projection: projection}
    state = Input.record_prompt(state, prompt)
    {row, col, _width, _height} = prompt_rect

    cursor =
      if prompt_window.cursor_visible,
        do:
          Cursor.new(
            row + prompt_window.cursor_row,
            col + prompt_window.cursor_col,
            prompt_window.cursor_shape
          )

    state =
      update_agent_scroll_metrics(state, state.workspace.agent_transcript_lines, chat_height)

    {WindowContent.new(nil, [prompt_window], cursor), cursor, state}
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
    updated_viewport = %{viewport | rows: rows, cols: cols, reserved: 0}
    updated_window = Window.set_viewport(window, updated_viewport)
    Input.record_render_window(state, win_id, updated_window)
  end

  @spec update_agent_scroll_metrics(state(), non_neg_integer(), pos_integer()) :: state()
  defp update_agent_scroll_metrics(state, total_lines, visible_height) do
    Input.record_agent_scroll_metrics(state, total_lines, visible_height)
  end
end
