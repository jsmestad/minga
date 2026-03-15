defmodule Minga.Editor.RenderPipeline.Content do
  @moduledoc """
  Stage 4: Content.

  Builds display list draws for each window's buffer content and agent
  chat windows. Produces `WindowFrame` structs with gutter, lines, and
  tildes (but without modeline, which is added in the Chrome stage).
  """

  alias Minga.Agent.View.Renderer, as: ViewRenderer
  alias Minga.Buffer.Decorations
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, WindowFrame}
  alias Minga.Editor.FoldMap
  alias Minga.Editor.Layout
  alias Minga.Editor.Modeline
  alias Minga.Editor.RenderPipeline.ContentHelpers
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
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
  @spec build_agent_chat_content(state(), Layout.t()) :: [WindowFrame.t()]
  def build_agent_chat_content(state, layout) do
    layout.window_layouts
    |> Enum.flat_map(fn {win_id, win_layout} ->
      window = Map.get(state.windows.map, win_id)

      case window do
        %Window{content: {:agent_chat, _buf}} ->
          [render_agent_chat_window(state, window, win_layout)]

        _ ->
          []
      end
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

  # Minimum sidebar width (cols). Below this threshold, the agent chat
  # renders in compact mode (chat+input only, no sidebar).
  @sidebar_min_cols 20

  @spec render_agent_chat_window(state(), Window.t(), Layout.window_layout()) :: WindowFrame.t()
  defp render_agent_chat_window(state, _window, win_layout) do
    {_row_off, _col_off, width, height} = win_layout.content

    # Compute the sidebar split from the content rect and chat_width_pct.
    # This is an agent-specific layout concern, so it lives here in the
    # agent content stage (4b), not in the generic Layout module.
    sidebar = compute_agent_sidebar(state, win_layout.content)

    {draws, chat_rect} =
      case sidebar do
        {chat_rect, sidebar_rect} ->
          {ViewRenderer.render_with_sidebar(state, chat_rect, sidebar_rect), chat_rect}

        nil ->
          {ViewRenderer.render_in_rect(state, win_layout.content), win_layout.content}
      end

    # Cursor position within the chat input area.
    agent_cursor =
      case ViewRenderer.cursor_position_in_rect(state, chat_rect) do
        {row, col} -> Cursor.new(row, col, :beam)
        nil -> nil
      end

    # Use {0, 0} for the rect origin. The agent renderer's draws already
    # use absolute screen coordinates (they include row_off/col_off from
    # the rect passed to render_with_sidebar / render_in_rect). Buffer
    # windows also use {0, 0} for the same reason. DisplayList.to_commands
    # offsets draws by the frame rect origin, so using {0, 0} avoids
    # double-offsetting.
    %WindowFrame{
      rect: {0, 0, width, height},
      gutter: %{},
      lines: DisplayList.draws_to_layer(draws),
      tilde_lines: %{},
      modeline: %{},
      cursor: agent_cursor
    }
  end

  # Splits a content rect into chat (left) and sidebar (right) rects
  # if there's enough horizontal space. Returns {chat_rect, sidebar_rect}
  # or nil if the sidebar doesn't fit.
  @spec compute_agent_sidebar(state(), Layout.rect()) :: {Layout.rect(), Layout.rect()} | nil
  defp compute_agent_sidebar(state, {row, col, width, height}) do
    chat_width_pct = AgentAccess.agentic(state).chat_width_pct
    chat_width = max(div(width * chat_width_pct, 100), 20)
    sidebar_width = width - chat_width - 1

    if sidebar_width >= @sidebar_min_cols do
      sidebar_col = col + chat_width + 1
      {{row, col, chat_width, height}, {row, sidebar_col, sidebar_width, height}}
    else
      nil
    end
  end
end
