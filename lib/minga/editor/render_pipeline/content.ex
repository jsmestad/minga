defmodule Minga.Editor.RenderPipeline.Content do
  @moduledoc """
  Stage 4: Content.

  Builds display list draws for each window's buffer content and agent
  chat windows. Produces `WindowFrame` structs with gutter, lines, and
  tildes (but without modeline, which is added in the Chrome stage).
  """

  alias Minga.Agent.View.Renderer, as: ViewRenderer
  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, WindowFrame}
  alias Minga.Editor.DisplayMap
  alias Minga.Editor.FoldMap
  alias Minga.Editor.Layout
  alias Minga.Editor.Modeline
  alias Minga.Editor.RenderPipeline.ContentHelpers
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

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
    layout.window_layouts
    |> Enum.reduce({[], nil, state}, fn {win_id, win_layout}, {frames, cursor, st} ->
      window = Map.get(st.windows.map, win_id)
      maybe_render_agent_window(window, win_id, win_layout, frames, cursor, st)
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
      window: window
    } = scroll

    {row_off, col_off, content_width, content_height} = win_layout.content
    visible_rows = Viewport.content_rows(viewport)

    cursor = {cursor_line, cursor_byte_col}

    # Build per-frame render context
    render_ctx =
      ContentHelpers.build_render_ctx(state, window, %{
        viewport: viewport,
        cursor: cursor,
        lines: lines,
        first_line: first_line,
        preview_matches: preview_matches,
        gutter_w: gutter_w,
        content_w: content_w,
        has_sign_column: has_sign_column,
        is_active: is_active
      })

    # Compute context fingerprint and check for context changes.
    # If any context input (visual selection, search, highlights, signs,
    # horizontal scroll, active status) changed, all lines are dirty.
    ctx_fp = ContentHelpers.context_fingerprint(render_ctx, is_active)
    window = Window.detect_context_change(window, ctx_fp)

    # Render lines with dirty-aware loop
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
      fold_map: window.fold_map
    }

    {gutter_draws, line_draws, rows_used, window} =
      if wrap_on do
        # Wrapping and folding are mutually exclusive for now.
        # Strip fold-specific keys so the type matches line_render_opts.
        wrap_opts = Map.drop(line_opts, [:visible_line_map, :fold_map])
        {g, l, r} = ContentHelpers.render_lines_wrapped(lines, visible_rows, wrap_opts)
        {g, l, r, window}
      else
        ContentHelpers.render_lines_nowrap(lines, line_opts)
      end

    # Tilde lines for empty space below content
    tilde_draws =
      if rows_used < visible_rows do
        for row <- rows_used..(visible_rows - 1) do
          DisplayList.draw(row + row_off, col_off + gutter_w, "~",
            fg: state.theme.editor.tilde_fg
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

        cr = visible_cursor - viewport.top + row_off
        # Adjust cursor column for inline virtual text that shifts content right
        adjusted_cursor_col =
          Decorations.buf_col_to_display_col(render_ctx.decorations, cursor_line, cursor_col)

        cc = gutter_w + adjusted_cursor_col - viewport.left + col_off
        Cursor.new(cr, cc, Modeline.cursor_shape(state.vim))
      else
        nil
      end

    win_frame = %WindowFrame{
      rect: {0, 0, content_width, content_height},
      gutter: DisplayList.draws_to_layer(gutter_draws),
      lines: DisplayList.draws_to_layer(line_draws),
      tilde_lines: DisplayList.draws_to_layer(tilde_draws),
      modeline: %{},
      cursor: buf_cursor
    }

    cursor_info = buf_cursor

    # Snapshot tracking fields and prune cache to visible range
    last_visible = first_line + length(lines) - 1

    updated_window =
      window
      |> Window.snapshot_after_render(
        viewport.top,
        gutter_w,
        snapshot.line_count,
        cursor_line,
        scroll.buf_version,
        ctx_fp
      )
      |> Window.prune_cache(first_line, last_visible)

    new_map = Map.put(state.windows.map, scroll.win_id, updated_window)
    state = %{state | windows: %{state.windows | map: new_map}}

    {win_frame, cursor_info, state}
  end

  defp maybe_render_agent_window(
         %Window{content: {:agent_chat, _}} = window,
         win_id,
         win_layout,
         frames,
         cursor,
         st
       ) do
    {frame, ci, st} = render_agent_chat_window(st, window, win_id, win_layout)
    new_cursor = if ci != nil, do: ci, else: cursor
    {[frame | frames], new_cursor, st}
  end

  defp maybe_render_agent_window(_window, _win_id, _win_layout, frames, cursor, st) do
    {frames, cursor, st}
  end

  # Renders an agent chat window: buffer content through the standard
  # pipeline (for decorations, visual mode, search) plus the prompt
  # input from ViewRenderer.
  @spec render_agent_chat_window(state(), Window.t(), Window.id(), Layout.window_layout()) ::
          {WindowFrame.t(), Cursor.t() | nil, state()}
  defp render_agent_chat_window(state, window, _win_id, win_layout) do
    # Split the content rect to carve out a sidebar when wide enough.
    win_layout = Layout.add_sidebar(win_layout)
    {row_off, col_off, chat_width, height} = win_layout.content

    buf = window.buffer

    # Render the sidebar (dashboard) if the layout carved one out.
    sidebar_draws =
      case win_layout.sidebar do
        {sr, sc, sw, sh} ->
          separator_col = sc - 1

          separator =
            for row <- 0..(sh - 1) do
              DisplayList.draw(sr + row, separator_col, "│",
                fg: state.theme.editor.split_border_fg
              )
            end

          separator ++ ViewRenderer.render_dashboard_only(state, {sr, sc, sw, sh})

        nil ->
          []
      end

    # Compute prompt height and subdivide the content rect.
    # Subdivide the content rect for chat content vs prompt input.
    prompt_height = ViewRenderer.prompt_height(state, chat_width)
    input_v_gap = 1
    chat_height = max(height - prompt_height - input_v_gap, 1)
    prompt_row = row_off + chat_height + input_v_gap

    # Render the prompt (agent chrome, not buffer content)
    prompt_rect = {prompt_row, col_off, chat_width, prompt_height}
    prompt_draws = ViewRenderer.render_prompt_only(state, prompt_rect)

    # Render the chat content through the standard buffer pipeline
    is_active = agent_window_active?(state, window)
    {cursor_line, cursor_byte_col} = agent_window_cursor(window, buf, is_active)

    line_count = BufferServer.line_count(buf)
    viewport = agent_chat_viewport(window, chat_height, chat_width, cursor_line, line_count, buf)

    visible_rows = Viewport.content_rows(viewport)
    {first_line, _} = Viewport.visible_range(viewport)

    # Fetch enough lines to cover decorations that consume screen rows.
    # Over-fetch slightly so block decorations don't cause missing lines.
    fetch_rows = visible_rows + div(visible_rows, 2)
    snapshot = BufferServer.render_snapshot(buf, first_line, fetch_rows)

    cursor_line_text = cursor_text_from_snapshot(snapshot.lines, cursor_line, first_line)

    cursor_col = Unicode.display_col(cursor_line_text, cursor_byte_col)
    line_number_style = BufferServer.get_option(buf, :line_numbers)
    gutter_w = if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)
    content_w = max(chat_width - gutter_w, 1)

    # Build render context (includes decorations from the buffer)
    render_ctx =
      ContentHelpers.build_render_ctx(state, window, %{
        viewport: viewport,
        cursor: {cursor_line, cursor_byte_col},
        lines: snapshot.lines,
        first_line: first_line,
        preview_matches: [],
        gutter_w: gutter_w,
        content_w: content_w,
        has_sign_column: false,
        is_active: is_active
      })

    # Compute the display map (block decorations, fold regions, virtual lines).
    # Without this, the sequential fast path skips all decoration rendering.
    decorations = render_ctx.decorations
    fold_map = window.fold_map

    visible_line_map =
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

    # Detect scroll/structural invalidation (viewport_top, gutter, line count,
    # buffer version). The normal buffer path does this in the Scroll stage;
    # agent chat skips that stage, so we must do it here.
    buf_version = BufferServer.version(buf)
    window = Window.detect_invalidation(window, viewport.top, gutter_w, line_count, buf_version)

    # Detect context changes to invalidate dirty-line cache
    ctx_fp = ContentHelpers.context_fingerprint(render_ctx, is_active)
    window = Window.detect_context_change(window, ctx_fp)

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
      wrap_on: true
    }

    {gutter_draws, line_draws, rendered_rows, window} =
      ContentHelpers.render_lines_nowrap(snapshot.lines, opts)

    # Snapshot render state so future frames can detect changes.
    # Without this, dirty_lines stays empty and content is never re-rendered.
    # buf_version was already fetched above for detect_invalidation.
    last_visible = first_line + length(snapshot.lines) - 1

    window =
      window
      |> Window.snapshot_after_render(
        viewport.top,
        gutter_w,
        line_count,
        cursor_line,
        buf_version,
        ctx_fp
      )
      |> Window.prune_cache(first_line, last_visible)

    # Persist the updated window back to state
    state = put_in(state.windows.map[window.id], window)

    tilde_draws = build_tilde_draws(rendered_rows, chat_height, row_off, col_off)

    buf_cursor =
      if is_active do
        adjusted_cc =
          Decorations.buf_col_to_display_col(render_ctx.decorations, cursor_line, cursor_col)

        cr = cursor_line - viewport.top + row_off
        cc = gutter_w + adjusted_cc - viewport.left + col_off
        Cursor.new(cr, cc, Modeline.cursor_shape(state.vim))
      else
        nil
      end

    # Prompt cursor (overrides buffer cursor when input is focused).
    # cursor_position_in_rect needs the full content rect to compute
    # the prompt position correctly (it subdivides internally).
    full_rect = {row_off, col_off, chat_width, height}

    prompt_cursor =
      case ViewRenderer.cursor_position_in_rect(state, full_rect) do
        {row, col} -> Cursor.new(row, col, :beam)
        nil -> nil
      end

    final_cursor = if prompt_cursor != nil, do: prompt_cursor, else: buf_cursor

    frame = %WindowFrame{
      rect: {0, 0, chat_width, height},
      gutter: DisplayList.draws_to_layer(gutter_draws),
      lines: DisplayList.draws_to_layer(line_draws ++ prompt_draws ++ sidebar_draws),
      tilde_lines: DisplayList.draws_to_layer(tilde_draws),
      modeline: %{},
      cursor: final_cursor
    }

    {frame, final_cursor, state}
  end

  # Computes the viewport for the agent chat window.
  # When pinned (streaming), snaps to bottom. When unpinned (user scrolled up),
  # preserves scroll position and uses scroll_to_cursor for cursor tracking.
  @spec agent_chat_viewport(
          Window.t(),
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pid()
        ) :: Viewport.t()
  defp agent_chat_viewport(window, chat_height, chat_width, cursor_line, line_count, buf) do
    %Viewport{} = win_vp = window.viewport
    viewport = %{win_vp | rows: chat_height, cols: chat_width, reserved: 0}

    if window.pinned do
      visible = Viewport.content_rows(viewport)
      %Viewport{viewport | top: max(line_count - visible, 0)}
    else
      Viewport.scroll_to_cursor(viewport, {cursor_line, 0}, buf)
    end
  end

  defp agent_window_active?(state, window) do
    window.buffer == state.buffers.active or
      Map.get(state.windows.map, state.windows.active) == window
  end

  defp agent_window_cursor(_window, buf, true), do: BufferServer.cursor(buf)
  defp agent_window_cursor(window, _buf, false), do: window.cursor

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
        DisplayList.draw(r + row_off, col_off, "~", fg: 0x555555)
      end
    else
      []
    end
  end
end
