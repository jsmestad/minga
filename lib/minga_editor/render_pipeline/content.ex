defmodule MingaEditor.RenderPipeline.Content do
  @moduledoc """
  Stage 4: Content.

  Builds display list draws for each window's buffer content and agent
  chat windows. Produces `WindowFrame` structs with gutter, lines, and
  tildes (but without modeline, which is added in the Chrome stage).
  """

  alias MingaEditor.Agent.View.DashboardRenderer
  alias MingaEditor.Agent.View.PromptRenderer
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias MingaEditor.Agent.ViewContext
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias Minga.Core.WrapMap
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Cursor, WindowFrame}
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias Minga.Telemetry

  alias Minga.Core.Face
  alias Minga.RenderModel.Window, as: RenderWindow
  alias MingaEditor.RenderPipeline.AgentChatPrefetch
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.RenderModel.Window.Builder, as: WindowModelBuilder
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  @typedoc "Render pipeline input."
  @type state :: Input.t()

  @doc """
  Builds display list draws for each window's buffer content.

  Produces `WindowFrame` structs (with gutter, lines, tildes, but
  without modeline; modeline is in the Chrome stage) and the absolute
  cursor position for the active window.
  """
  @spec build_content(state(), %{Window.id() => WindowScroll.t()}) ::
          {[WindowFrame.t()], Cursor.t() | nil, state()}
  def build_content(state, scrolls) do
    {frames, cursor_info, state} =
      Enum.reduce(scrolls, {[], nil, state}, fn {_win_id, scroll}, {frames, cursor_info, st} ->
        {wf, ci, st} = build_window_content(st, scroll)
        new_cursor = if scroll.is_active and ci != nil, do: ci, else: cursor_info
        {[wf | frames], new_cursor, st}
      end)

    {Enum.reverse(frames), cursor_info, state}
  end

  @doc """
  Builds display list draws for agent chat windows.

  Finds windows with `{:agent_chat, _}` content in the layout, renders
  the agent chat content into their rects, and returns `WindowFrame`
  structs. Buffer windows are skipped (handled by `build_content/2`).

  Returns an empty list if no agent chat windows exist.
  """
  @spec build_agent_chat_content(state(), Layout.t()) ::
          {[WindowFrame.t()], Cursor.t() | nil, state()}
  def build_agent_chat_content(state, layout) do
    build_agent_chat_content(state, layout, %{})
  end

  @spec build_agent_chat_content(state(), Layout.t(), %{Window.id() => AgentChatPrefetch.t()}) ::
          {[WindowFrame.t()], Cursor.t() | nil, state()}
  def build_agent_chat_content(state, layout, prefetched_agent_chats) do
    layout.window_layouts
    |> Enum.reduce({[], nil, state}, fn {win_id, win_layout}, {frames, cursor, st} ->
      window = Map.get(st.workspace.windows.map, win_id)
      prefetch = Map.get(prefetched_agent_chats, win_id)
      maybe_render_agent_window(window, prefetch, win_id, win_layout, frames, cursor, st)
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec build_window_content(state(), WindowScroll.t()) ::
          {WindowFrame.t(), Cursor.t() | nil, state()}
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

    {row_off, col_off, content_width, content_height} = win_layout.content
    visible_rows = Viewport.content_rows(viewport)

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
        is_gui: MingaEditor.Frontend.gui?(state.capabilities),
        wrap_on: wrap_on,
        line_number_style: line_number_style,
        width_oracle: width_oracle
      })

    # Compute context fingerprint and check for context changes.
    # If any context input (visual selection, search, highlights, signs,
    # horizontal scroll, active status) changed, all lines are dirty.
    ctx_fp = ContentHelpers.context_fingerprint(render_ctx, is_active)
    window = Window.detect_context_change(window, ctx_fp)

    gui? = MingaEditor.Frontend.gui?(state.capabilities)

    # Render lines with dirty-aware loop. GUI buffer windows build the canonical window model below
    # instead of building throwaway DisplayList draw layers.
    line_opts = %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: render_ctx,
      ln_style: line_number_style,
      gutter_w: gutter_w,
      first_byte_off: snapshot.first_line_byte_offset,
      row_off: row_off,
      col_off: col_off,
      window: window,
      buffer: window.buffer,
      visible_line_map: scroll.visible_line_map,
      fold_map: window.fold_map,
      wrap_on: wrap_on,
      options: snapshot.options
    }

    {gutter_layer, line_layer, rows_used, window} =
      if gui? do
        {%{}, %{}, visible_rows, window}
      else
        render_display_layers(lines, visible_rows, line_opts, scroll, wrap_on, window)
      end

    # Tilde lines for empty space below content
    tilde_draws =
      if rows_used < visible_rows do
        for row <- rows_used..(visible_rows - 1) do
          DisplayList.draw(
            row + row_off,
            col_off + gutter_w,
            "~",
            Face.new(fg: state.theme.editor.tilde_fg)
          )
        end
      else
        []
      end

    # Build WindowFrame
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

    # Build the canonical window model for GUI frontends. GUI buffer windows use this model
    # instead of DisplayList draw layers for gutter, content, cursorline, and indent guides.
    window_model =
      if gui? do
        Telemetry.span([:minga, :render, :window_model_build], %{window_id: scroll.win_id}, fn ->
          WindowModelBuilder.build(state, %{scroll | window: window}, render_ctx,
            content_kind: :buffer
          )
        end)
      else
        nil
      end

    win_frame = %WindowFrame{
      rect: {0, 0, content_width, content_height},
      gutter: if(gui?, do: %{}, else: gutter_layer),
      lines: if(gui?, do: %{}, else: line_layer),
      tilde_lines: if(gui?, do: %{}, else: DisplayList.draws_to_layer_sorted(tilde_draws)),
      modeline: %{},
      cursor: buf_cursor,
      window_model: window_model
    }

    cursor_info = buf_cursor

    # Snapshot tracking fields and prune cache to visible range
    last_visible = first_line + length(lines) - 1

    updated_window =
      window
      |> Window.snapshot_after_render(
        viewport.top,
        Viewport.cache_key(viewport),
        gutter_w,
        snapshot.line_count,
        cursor_line,
        scroll.buf_version,
        ctx_fp
      )
      |> Window.prune_cache(first_line, last_visible)

    new_map = Map.put(state.workspace.windows.map, scroll.win_id, updated_window)
    ws = state.workspace
    state = %{state | workspace: %{ws | windows: %{ws.windows | map: new_map}}}

    {win_frame, cursor_info, state}
  end

  @spec render_display_layers(
          [String.t()],
          pos_integer(),
          map(),
          WindowScroll.t(),
          boolean(),
          Window.t()
        ) ::
          {DisplayList.render_layer(), DisplayList.render_layer(), non_neg_integer(), Window.t()}
  defp render_display_layers(
         lines,
         visible_rows,
         line_opts,
         %{visible_line_map: nil},
         true,
         window
       ) do
    # Wrapping currently runs only on the plain sequential path. When a visible_line_map is present,
    # folding/virtual-line bookkeeping takes priority so we do not count hidden display-map entries as rows.
    wrap_opts = Map.drop(line_opts, [:visible_line_map, :fold_map])

    {gutter_draws, line_draws, rows_used} =
      ContentHelpers.render_lines_wrapped(lines, visible_rows, wrap_opts)

    {DisplayList.draws_to_layer_sorted(gutter_draws),
     DisplayList.draws_to_layer_sorted(line_draws), rows_used, window}
  end

  defp render_display_layers(
         lines,
         _visible_rows,
         line_opts,
         %{visible_line_map: nil},
         _wrap_on,
         _window
       ) do
    ContentHelpers.render_lines_nowrap_layers(lines, line_opts)
  end

  defp render_display_layers(lines, _visible_rows, line_opts, _scroll, _wrap_on, _window) do
    {gutter_draws, line_draws, rows_used, window} =
      ContentHelpers.render_lines_nowrap(lines, line_opts)

    {DisplayList.draws_to_layer_sorted(gutter_draws),
     DisplayList.draws_to_layer_sorted(line_draws), rows_used, window}
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
      {frame, ci, st} = render_agent_chat_window(st, window, prefetch, win_id, win_layout)
      new_cursor = if ci != nil, do: ci, else: cursor
      {[frame | frames], new_cursor, st}
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
        ) :: {WindowFrame.t(), Cursor.t() | nil, state()}
  defp render_agent_chat_window(state, window, prefetch, _win_id, win_layout) do
    # Build ViewContext once for all agent renderers
    ctx = ViewContext.from_editor_state(state)

    # Split the content rect to carve out a sidebar when wide enough.
    win_layout = Layout.add_sidebar(win_layout)
    {row_off, col_off, chat_width, height} = win_layout.content

    # Render the sidebar (dashboard) if the layout carved one out.
    sidebar_draws =
      case win_layout.sidebar do
        {sr, sc, sw, sh} ->
          separator_col = sc - 1

          separator =
            for row <- 0..(sh - 1) do
              DisplayList.draw(
                sr + row,
                separator_col,
                "│",
                Face.new(fg: state.theme.editor.split_border_fg)
              )
            end

          separator ++ DashboardRenderer.render(ctx, {sr, sc, sw, sh})

        nil ->
          []
      end

    # Compute prompt height and subdivide the content rect.
    # Subdivide the content rect for chat content vs prompt input.
    prompt_height = PromptRenderer.prompt_height(ctx, chat_width)
    input_v_gap = 1
    chat_height = max(height - prompt_height - input_v_gap, 1)
    prompt_row = row_off + chat_height + input_v_gap

    # Render the prompt (agent chrome, not buffer content)
    prompt_rect = {prompt_row, col_off, chat_width, prompt_height}
    prompt_draws = PromptRenderer.render(ctx, prompt_rect)

    # When help overlay is visible, render help content instead of buffer
    help_visible = state.workspace.agent_ui.view.help_visible

    if help_visible do
      focus = state.workspace.agent_ui.view.focus
      help_groups = Minga.Keymap.Scope.Agent.help_groups(focus)
      chat_rect = {row_off, col_off, chat_width, chat_height}
      help_draws = render_help_overlay(help_groups, chat_rect, state.theme)

      frame = %WindowFrame{
        rect: {0, 0, chat_width, height},
        gutter: %{},
        lines: DisplayList.draws_to_layer(help_draws ++ prompt_draws ++ sidebar_draws),
        tilde_lines: %{},
        modeline: %{},
        cursor: nil
      }

      {frame, nil, state}
    else
      render_agent_chat_buffer(
        state,
        ctx,
        window,
        prefetch,
        win_layout,
        sidebar_draws,
        prompt_draws,
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
          [DisplayList.draw()],
          [DisplayList.draw()],
          keyword()
        ) :: {WindowFrame.t(), Cursor.t() | nil, state()}
  defp render_agent_chat_buffer(
         state,
         ctx,
         _window,
         %AgentChatPrefetch{} = prefetch,
         win_layout,
         sidebar_draws,
         prompt_draws,
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

    buf = window.buffer

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
        is_gui: MingaEditor.Frontend.gui?(state.capabilities),
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

    gui? = MingaEditor.Frontend.gui?(state.capabilities)

    # Render lines
    ln_style = if line_number_style == :none, do: :none, else: :absolute

    opts = %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: render_ctx,
      ln_style: ln_style,
      gutter_w: gutter_w,
      first_byte_off: 0,
      row_off: row_off,
      col_off: col_off,
      window: window,
      buffer: buf,
      visible_line_map: visible_line_map,
      fold_map: fold_map,
      wrap_on: true,
      options: snapshot.options
    }

    {gutter_draws, line_draws, rendered_rows, window} =
      render_agent_lines(gui?, snapshot.lines, visible_rows, opts)

    # Snapshot render state so future frames can detect changes.
    # Without this, dirty_lines stays empty and content is never re-rendered.
    # buf_version was already fetched above for detect_invalidation.
    last_visible = first_line + length(snapshot.lines) - 1

    window =
      window
      |> Window.snapshot_after_render(
        viewport.top,
        Viewport.cache_key(viewport),
        gutter_w,
        line_count,
        cursor_line,
        buf_version,
        ctx_fp
      )
      |> Window.prune_cache(first_line, last_visible)

    # Persist the updated window back to input
    ws = state.workspace
    new_map = Map.put(ws.windows.map, window.id, window)
    state = %{state | workspace: %{ws | windows: %{ws.windows | map: new_map}}}

    tilde_draws = build_tilde_draws(rendered_rows, chat_height, row_off, col_off)

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
      visible_line_map: visible_line_map
    }

    {window_model, additional_window_models} =
      agent_window_models(gui?, state, model_scroll, render_ctx, ctx, chat_width, prompt_rect)

    frame =
      agent_window_frame(gui?, %{
        chat_width: chat_width,
        height: height,
        gutter_draws: gutter_draws,
        line_draws: line_draws,
        prompt_draws: prompt_draws,
        sidebar_draws: sidebar_draws,
        tilde_draws: tilde_draws,
        cursor: final_cursor,
        window_model: window_model,
        additional_window_models: additional_window_models
      })

    {frame, final_cursor, state}
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

  @spec render_agent_lines(boolean(), [String.t()], non_neg_integer(), map()) ::
          {[DisplayList.draw()], [DisplayList.draw()], non_neg_integer(), Window.t()}
  defp render_agent_lines(true, _lines, visible_rows, %{window: window}) do
    {[], [], visible_rows, window}
  end

  defp render_agent_lines(false, lines, _visible_rows, opts) do
    ContentHelpers.render_lines_nowrap(lines, opts)
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
    Cursor.new(cr, cc, Minga.Editing.cursor_shape(params.state))
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
          boolean(),
          state(),
          WindowScroll.t(),
          MingaEditor.Renderer.Context.t(),
          ViewContext.t(),
          pos_integer(),
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}
        ) :: {RenderWindow.t() | nil, [RenderWindow.t()]}
  defp agent_window_models(
         false,
         _state,
         _model_scroll,
         _render_ctx,
         _ctx,
         _chat_width,
         _prompt_rect
       ),
       do: {nil, []}

  defp agent_window_models(true, state, model_scroll, render_ctx, ctx, chat_width, prompt_rect) do
    window_model =
      Telemetry.span(
        [:minga, :render, :window_model_build],
        %{window_id: model_scroll.win_id},
        fn ->
          WindowModelBuilder.build(state, model_scroll, render_ctx, content_kind: :agent_chat)
        end
      )

    inner_width = PromptRenderer.input_inner_width(PromptRenderer.input_box_width(chat_width))
    prompt_window_model = PromptRenderWindow.build(ctx, inner_width, prompt_rect)
    {window_model, [prompt_window_model]}
  end

  @spec agent_window_frame(boolean(), map()) :: WindowFrame.t()
  defp agent_window_frame(true, params) do
    %WindowFrame{
      rect: {0, 0, params.chat_width, params.height},
      gutter: %{},
      lines: DisplayList.draws_to_layer(params.sidebar_draws),
      tilde_lines: %{},
      modeline: %{},
      cursor: params.cursor,
      window_model: params.window_model,
      additional_window_models: params.additional_window_models
    }
  end

  defp agent_window_frame(false, params) do
    %WindowFrame{
      rect: {0, 0, params.chat_width, params.height},
      gutter: DisplayList.draws_to_layer(params.gutter_draws),
      lines:
        DisplayList.draws_to_layer(
          params.line_draws ++ params.prompt_draws ++ params.sidebar_draws
        ),
      tilde_lines: DisplayList.draws_to_layer(params.tilde_draws),
      modeline: %{},
      cursor: params.cursor
    }
  end

  # Renders help overlay content as display list draws in the chat area.
  # Shows keybinding groups from Scope.Agent.help_groups/1 with category
  # headers in accent color and key/description pairs.
  @spec render_help_overlay(
          [{String.t(), [{String.t(), String.t()}]}],
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()},
          MingaEditor.UI.Theme.t()
        ) :: [DisplayList.draw()]
  defp render_help_overlay(help_groups, {row_off, col_off, width, height}, theme) do
    at = MingaEditor.UI.Theme.agent_theme(theme)
    blank = String.duplicate(" ", width)
    bg_face = Face.new(bg: at.panel_bg)

    # Background fill
    bg_cmds =
      for row <- 0..(height - 1) do
        DisplayList.draw(row_off + row, col_off, blank, bg_face)
      end

    # Header
    header_face = Face.new(fg: at.text_fg, bg: at.panel_bg, bold: true)
    hint_face = Face.new(fg: at.hint_fg, bg: at.panel_bg)
    label_face = Face.new(fg: at.dashboard_label, bg: at.panel_bg, bold: true)
    key_face = Face.new(fg: at.text_fg, bg: at.panel_bg)
    desc_face = Face.new(fg: at.hint_fg, bg: at.panel_bg)

    header_row = 1

    draws = [
      DisplayList.draw(row_off + header_row, col_off + 2, "Keyboard Shortcuts", header_face),
      DisplayList.draw(
        row_off + header_row,
        col_off + width - 24,
        "? or Esc to close",
        hint_face
      )
    ]

    # Render groups
    key_col_width = min(div(width, 3), 20)
    row = header_row + 2

    {draws, _row} =
      Enum.reduce(help_groups, {draws, row}, fn {title, bindings}, {acc, r} ->
        if r >= height - 1,
          do: {acc, r},
          else:
            render_help_group(title, bindings, acc, r,
              row_off: row_off,
              col_off: col_off,
              width: width,
              height: height,
              key_col_width: key_col_width,
              label_face: label_face,
              key_face: key_face,
              desc_face: desc_face
            )
      end)

    bg_cmds ++ draws
  end

  @spec render_help_group(
          String.t(),
          [{String.t(), String.t()}],
          [DisplayList.draw()],
          non_neg_integer(),
          keyword()
        ) :: {[DisplayList.draw()], non_neg_integer()}
  defp render_help_group(title, bindings, draws, row, opts) do
    height = Keyword.fetch!(opts, :height)

    if row >= height - 1 do
      {draws, row}
    else
      row_off = Keyword.fetch!(opts, :row_off)
      col_off = Keyword.fetch!(opts, :col_off)
      label_face = Keyword.fetch!(opts, :label_face)

      title_draw = DisplayList.draw(row_off + row, col_off + 2, title, label_face)
      row = row + 1

      {binding_draws, row} =
        Enum.map_reduce(bindings, row, fn
          {_key, _desc}, r when r >= height - 1 -> {[], r}
          {key, desc}, r -> {render_help_binding(key, desc, r, opts), r + 1}
        end)

      {[title_draw | List.flatten(binding_draws)] ++ draws, row + 1}
    end
  end

  @spec render_help_binding(String.t(), String.t(), non_neg_integer(), keyword()) ::
          [DisplayList.draw()]
  defp render_help_binding(key, desc, row, opts) do
    row_off = Keyword.fetch!(opts, :row_off)
    col_off = Keyword.fetch!(opts, :col_off)
    key_col_width = Keyword.fetch!(opts, :key_col_width)
    key_face = Keyword.fetch!(opts, :key_face)
    desc_face = Keyword.fetch!(opts, :desc_face)

    key_text = String.pad_trailing(key, key_col_width)

    [
      DisplayList.draw(row_off + row, col_off + 4, key_text, key_face),
      DisplayList.draw(row_off + row, col_off + 4 + key_col_width, desc, desc_face)
    ]
  end

  defp cursor_text_from_snapshot(lines, cursor_line, first_line) do
    idx = cursor_line - first_line

    if idx >= 0 and idx < length(lines) do
      Enum.at(lines, idx, "")
    else
      ""
    end
  end

  defp build_tilde_draws(rendered_rows, chat_height, row_off, col_off) do
    if rendered_rows < chat_height do
      for r <- rendered_rows..(chat_height - 1) do
        DisplayList.draw(r + row_off, col_off, "~", Face.new(fg: 0x555555))
      end
    else
      []
    end
  end
end
