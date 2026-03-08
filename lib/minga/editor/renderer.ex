defmodule Minga.Editor.Renderer do
  @moduledoc """
  Buffer and UI rendering for the editor.

  Converts editor state into a `DisplayList.Frame`, then converts the frame
  to protocol command binaries and sends them to the Zig port. The display
  list intermediate representation enables BEAM-side frame diffing, multi-
  frontend rendering, and introspection.

  This module orchestrates focused sub-modules:

  * `Renderer.Gutter`          — line number rendering
  * `Renderer.Line`            — line content and selection rendering
  * `Renderer.SearchHighlight` — search/substitute highlight overlays
  * `Renderer.Minibuffer`      — command/search/status line
  * `DisplayList`              — frame assembly and protocol conversion
  """

  alias Minga.Agent.View.Renderer, as: ViewRenderer
  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Config.Options
  alias Minga.Diagnostics
  alias Minga.Editor.CompletionUI
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Frame, Overlay, WindowFrame}
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.Layout
  alias Minga.Editor.MacroRecorder
  # Submodules
  alias __MODULE__.Caps
  alias __MODULE__.Regions
  alias Minga.Editor.Modeline
  alias Minga.Editor.PickerUI
  alias Minga.Editor.Renderer.BufferLine
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.Minibuffer
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Title
  alias Minga.Editor.TreeRenderer
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Mode.VisualState
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol
  alias Minga.Theme
  alias Minga.WhichKey

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc """
  Represents the bounds of a visual selection for rendering.

  * `nil` — no active selection
  * `{:char, start_pos, end_pos}` — characterwise selection
  * `{:line, start_line, end_line}` — linewise selection
  """
  @type visual_selection ::
          nil
          | {:char, {non_neg_integer(), non_neg_integer()},
             {non_neg_integer(), non_neg_integer()}}
          | {:line, non_neg_integer(), non_neg_integer()}

  # Agent input area = 3 rows (border + text + padding); cursor goes on the text row.
  @agent_input_height 3

  @doc "Renders the no-buffer splash screen."
  @spec render(state()) :: :ok
  def render(%{buffers: %{active: nil}} = state) do
    splash_draws = [
      DisplayList.draw(0, 0, "Minga v#{Minga.version()} — No file open"),
      DisplayList.draw(1, 0, "Use: mix minga <filename>")
    ]

    frame = %Frame{
      cursor: {0, 0},
      cursor_shape: :block,
      splash: splash_draws
    }

    commands = DisplayList.to_commands(frame)
    PortManager.send_commands(state.port_manager, commands)
  end

  def render(state) do
    # Keep active window's cursor in sync before rendering
    state = EditorState.sync_active_window_cursor(state)
    # Compute layout once for the entire frame; downstream code reads state.layout.
    state = Layout.put(state)

    # DEBUG: dump layout to file
    layout = Layout.get(state)
    debug_layout(state, layout)

    if state.agentic.active do
      render_agentic(state)
    else
      render_windows(state)
    end

    send_title(state)
    send_window_bg(state)
  end

  defp debug_layout(state, layout) do
    vp = state.viewport
    ts = DateTime.utc_now() |> DateTime.to_string()

    lines = [
      "[#{ts}] viewport: #{vp.rows}x#{vp.cols}",
      "  editor_area: #{inspect(layout.editor_area)}",
      "  file_tree: #{inspect(layout.file_tree)}",
      "  minibuffer: #{inspect(layout.minibuffer)}",
      "  modeline: #{inspect(layout.window_layouts |> Map.values() |> Enum.map(& &1.modeline))}",
      ""
    ]

    File.write("/tmp/minga_layout_debug.log", Enum.join(lines, "\n"), [:append])
  rescue
    _ -> :ok
  end

  @spec send_title(state()) :: :ok
  defp send_title(state) do
    format = Options.get(:title_format) |> to_string()
    title = Title.format(state, format)

    # Only send when title changes (avoids redundant OSC writes every frame)
    if title != Process.get(:last_title) do
      Process.put(:last_title, title)
      PortManager.send_commands([Protocol.encode_set_title(title)])
    end

    :ok
  end

  @spec send_window_bg(state()) :: :ok
  defp send_window_bg(state) do
    bg = state.theme.editor.bg

    if bg != Process.get(:last_window_bg) do
      Process.put(:last_window_bg, bg)
      PortManager.send_commands([Protocol.encode_set_window_bg(bg)])
    end

    :ok
  end

  # ── Full-screen agentic view render ────────────────────────────────────────

  @spec render_agentic(state()) :: :ok
  defp render_agentic(state) do
    full_viewport = state.viewport
    layout = Layout.get(state)
    {minibuffer_row, _mbc, _mbw, _mbh} = layout.minibuffer

    # Build panel draw tuples
    panel_draws = ViewRenderer.render(state)

    # Minibuffer (always last row)
    minibuffer_draw = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

    # Overlay popups: skip when frontend has native float support.
    render_overlays = Caps.render_overlays?(state.capabilities)
    whichkey_draws = if render_overlays, do: render_whichkey(state, full_viewport), else: []

    # Picker overlay (e.g. SPC a m model picker).
    {picker_draws, picker_cursor} = PickerUI.render(state, full_viewport)

    # Cursor placement: agentic renderer knows where the input cursor goes.
    {cursor_row, cursor_col} = ViewRenderer.cursor_position(state)

    cursor_shape =
      if state.picker_ui.picker do
        :beam
      else
        if state.agent.panel.input_focused, do: :beam, else: :block
      end

    cursor =
      case picker_cursor do
        {pr, pc} -> {pr, pc}
        nil -> {cursor_row, cursor_col}
      end

    region_commands = Regions.define_regions(layout)

    overlays =
      [
        %Overlay{draws: whichkey_draws},
        %Overlay{draws: picker_draws, cursor: picker_cursor}
      ]
      |> Enum.reject(fn %Overlay{draws: d} -> d == [] end)

    frame = %Frame{
      cursor: cursor,
      cursor_shape: cursor_shape,
      agentic_view: panel_draws,
      minibuffer: [minibuffer_draw],
      overlays: overlays,
      regions: region_commands
    }

    commands = DisplayList.to_commands(frame)
    PortManager.send_commands(state.port_manager, commands)
    :ok
  end

  # ── Unified window render (single + split use the same path) ───────────────

  @spec render_windows(state()) :: :ok
  defp render_windows(state) do
    layout = Layout.get(state)
    full_viewport = state.viewport

    region_commands = Regions.define_regions(layout)

    # Render each window through the same path (single window = one-element map)
    {window_frames, active_cursor_info} =
      Enum.reduce(layout.window_layouts, {[], nil}, fn {win_id, win_layout}, acc ->
        render_window_entry(state, win_id, win_layout, acc)
      end)

    # Separators between split panes (no-op for single window)
    separator_draws =
      if EditorState.split?(state) do
        render_separators(
          state.windows.tree,
          layout.editor_area,
          elem(layout.editor_area, 3),
          state.theme
        )
      else
        []
      end

    # File tree
    tree_draws = TreeRenderer.render(state)

    # Agent panel (sidebar mode, not full-screen agentic view)
    agent_draws = render_agent_panel_from_layout(state, layout)

    # Minibuffer (always last row)
    {minibuffer_row, _mbc, _mbw, _mbh} = layout.minibuffer
    minibuffer_draw = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

    # Overlays (positioned relative to full terminal)
    render_overlays_flag = Caps.render_overlays?(state.capabilities)
    {picker_draws, picker_cursor} = PickerUI.render(state, full_viewport)
    whichkey_draws = if render_overlays_flag, do: render_whichkey(state, full_viewport), else: []

    completion_draws =
      case active_cursor_info do
        {cur_row, cur_col} ->
          CompletionUI.render(
            state.completion,
            %{
              cursor_row: cur_row,
              cursor_col: cur_col,
              viewport_rows: full_viewport.rows,
              viewport_cols: full_viewport.cols
            },
            state.theme
          )

        nil ->
          []
      end

    # Cursor shape
    cursor_shape =
      if state.picker_ui.picker do
        :beam
      else
        Modeline.cursor_shape(state.mode)
      end

    # Cursor position (picker overrides mode overrides buffer position)
    cursor =
      case picker_cursor do
        {row, col} ->
          {row, col}

        nil ->
          resolve_cursor(state, active_cursor_info, minibuffer_row)
      end

    # Agent panel input can steal the cursor
    {cursor, cursor_shape} =
      agent_cursor_override_from_layout(state, cursor, cursor_shape, layout)

    overlays =
      [
        %Overlay{draws: whichkey_draws},
        %Overlay{draws: completion_draws},
        %Overlay{draws: picker_draws, cursor: picker_cursor}
      ]
      |> Enum.reject(fn %Overlay{draws: d} -> d == [] end)

    frame = %Frame{
      cursor: cursor,
      cursor_shape: cursor_shape,
      windows: Enum.reverse(window_frames),
      file_tree: tree_draws,
      separators: separator_draws,
      agent_panel: agent_draws,
      minibuffer: [minibuffer_draw],
      overlays: overlays,
      regions: region_commands
    }

    commands = DisplayList.to_commands(frame)
    PortManager.send_commands(state.port_manager, commands)
    :ok
  end

  # Reduce callback: renders one window entry if its buffer is valid.
  @spec render_window_entry(
          state(),
          Window.id(),
          Layout.window_layout(),
          {[WindowFrame.t()], {non_neg_integer(), non_neg_integer()} | nil}
        ) ::
          {[WindowFrame.t()], {non_neg_integer(), non_neg_integer()} | nil}
  defp render_window_entry(state, win_id, win_layout, {wfs, cursor}) do
    window = Map.get(state.windows.map, win_id)

    if window == nil or window.buffer == nil do
      {wfs, cursor}
    else
      is_active = win_id == state.windows.active
      {win_frame, win_cursor} = render_window(state, window, win_layout, is_active)
      new_cursor = if is_active and win_cursor != nil, do: win_cursor, else: cursor
      {[win_frame | wfs], new_cursor}
    end
  end

  # Renders a single window's buffer content + modeline within its layout rect.
  # Returns a WindowFrame struct and the absolute cursor position for the active window.
  @spec render_window(state(), Window.t(), Layout.window_layout(), boolean()) ::
          {WindowFrame.t(), {non_neg_integer(), non_neg_integer()} | nil}
  defp render_window(state, window, win_layout, is_active) do
    {row_off, col_off, content_width, content_height} = win_layout.content

    # Cursor: active window reads live from buffer; inactive uses stored position
    {cursor_line, cursor_byte_col} = window_cursor(window, is_active)

    # Viewport from Layout content rect (reserved: 0 since Layout excluded modeline)
    wrap_on = wrap_enabled?()
    viewport = Viewport.new(content_height, content_width, 0)
    viewport = Viewport.scroll_to_cursor(viewport, {cursor_line, 0})
    {first_line, _last_line} = Viewport.visible_range(viewport)
    visible_rows = Viewport.content_rows(viewport)

    # Fetch buffer data (extra lines when wrapping since wrapped lines use more rows)
    fetch_rows = if wrap_on, do: visible_rows + div(visible_rows, 2), else: visible_rows
    snapshot = BufferServer.render_snapshot(window.buffer, first_line, fetch_rows)
    lines = snapshot.lines
    line_count = snapshot.line_count

    # Convert cursor byte_col → display col at the render boundary
    cursor_line_text = cursor_line_text(lines, cursor_line, first_line)
    cursor_col = Unicode.display_col(cursor_line_text, cursor_byte_col)

    # Gutter dimensions
    line_number_style = state.line_numbers

    {has_sign_column, gutter_w} =
      gutter_dimensions(state, window.buffer, line_number_style, line_count)

    content_w = max(viewport.cols - gutter_w, 1)

    # Horizontal scroll (disabled when wrapping)
    viewport = scroll_horizontal(viewport, cursor_line, cursor_col, wrap_on)

    # Substitution preview (active window only)
    {lines, preview_matches} =
      if is_active do
        SearchHighlight.maybe_substitute_preview(state, lines, first_line)
      else
        {lines, []}
      end

    cursor = {cursor_line, cursor_byte_col}

    # Build per-frame render context
    render_ctx =
      build_render_ctx(state, window, %{
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

    # Render lines
    line_opts = %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: render_ctx,
      ln_style: line_number_style,
      gutter_w: gutter_w,
      first_byte_off: snapshot.first_line_byte_offset,
      row_off: row_off,
      col_off: col_off
    }

    {gutter_draws, line_draws, rows_used} =
      if wrap_on do
        render_lines_wrapped(lines, visible_rows, line_opts)
      else
        render_lines_nowrap(lines, line_opts)
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

    # Per-window modeline (skip if layout gave it zero height)
    modeline_draws =
      render_window_modeline(
        state,
        win_layout,
        snapshot,
        is_active,
        cursor_line,
        cursor_col,
        line_count,
        col_off
      )

    # Dim inactive windows (Doom Emacs style)
    {gutter_draws, line_draws, tilde_draws, modeline_draws} =
      apply_inactive_dimming(is_active, gutter_draws, line_draws, tilde_draws, modeline_draws)

    # Build WindowFrame with absolute coordinates (not window-relative)
    # The draws already include row_off/col_off from BufferLine.maybe_offset.
    # We set rect origin to {0, 0} so to_commands doesn't double-offset.
    win_frame = %WindowFrame{
      rect: {0, 0, content_width, content_height},
      gutter: DisplayList.draws_to_layer(gutter_draws),
      lines: DisplayList.draws_to_layer(line_draws),
      tilde_lines: DisplayList.draws_to_layer(tilde_draws),
      modeline: DisplayList.draws_to_layer(modeline_draws),
      cursor:
        if(is_active,
          do:
            {cursor_line - viewport.top + row_off,
             gutter_w + cursor_col - viewport.left + col_off},
          else: nil
        )
    }

    # Return absolute cursor position for the active window
    cursor_info =
      if is_active do
        {cursor_line - viewport.top + row_off, gutter_w + cursor_col - viewport.left + col_off}
      else
        nil
      end

    {win_frame, cursor_info}
  end

  # Renders vertical separator lines for vertical splits, scoped to each
  # split's row range (not the full screen height).
  @spec render_separators(WindowTree.t(), WindowTree.rect(), pos_integer(), Minga.Theme.t()) ::
          [DisplayList.draw()]
  defp render_separators(tree, screen_rect, _total_rows, theme) do
    separators = collect_separators(tree, screen_rect)

    for {col, start_row, end_row} <- separators, row <- start_row..end_row do
      DisplayList.draw(row, col, "│", fg: theme.editor.split_border_fg)
    end
  end

  @typep separator_span :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @spec collect_separators(WindowTree.t(), WindowTree.rect()) :: [separator_span()]
  defp collect_separators({:leaf, _}, _rect), do: []

  defp collect_separators(
         {:split, :vertical, left, right, size},
         {row, col, width, height}
       ) do
    usable = width - 1
    left_width = WindowTree.clamp_size(size, usable)
    right_width = max(usable - left_width, 1)
    separator_col = col + left_width

    [{separator_col, row, row + height - 1}] ++
      collect_separators(left, {row, col, left_width, height}) ++
      collect_separators(right, {row, separator_col + 1, right_width, height})
  end

  defp collect_separators(
         {:split, :horizontal, top, bottom, size},
         {row, col, width, height}
       ) do
    top_height = WindowTree.clamp_size(size, height)
    bottom_height = max(height - top_height, 1)

    collect_separators(top, {row, col, width, top_height}) ++
      collect_separators(bottom, {row + top_height, col, width, bottom_height})
  end

  # ── Line rendering (no wrap) ──────────────────────────────────────────────

  @typep line_render_opts :: %{
           first_line: non_neg_integer(),
           cursor_line: non_neg_integer(),
           ctx: Context.t(),
           ln_style: Gutter.line_number_style(),
           gutter_w: non_neg_integer(),
           first_byte_off: non_neg_integer(),
           row_off: non_neg_integer(),
           col_off: non_neg_integer()
         }

  @spec render_lines_nowrap([String.t()], line_render_opts()) ::
          {[DisplayList.draw()], [DisplayList.draw()], non_neg_integer()}
  defp render_lines_nowrap(lines, opts) do
    %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: ctx,
      ln_style: ln_style,
      gutter_w: gutter_w,
      first_byte_off: first_byte_off,
      row_off: row_off,
      col_off: col_off
    } = opts

    sign_w = if ctx.has_sign_column, do: Gutter.sign_column_width(), else: 0

    {gutters, contents_rev, _byte_off} =
      lines
      |> Enum.with_index()
      |> Enum.reduce(
        {[], [], first_byte_off},
        fn {line_text, screen_row}, {g, c, byte_off} ->
          {g_cmds, c_cmds, _rows} =
            BufferLine.render(%{
              line_text: line_text,
              buf_line: first_line + screen_row,
              cursor_line: cursor_line,
              byte_offset: byte_off,
              screen_row: screen_row,
              ctx: ctx,
              ln_style: ln_style,
              gutter_w: gutter_w,
              sign_w: sign_w,
              wrap_entry: nil,
              max_rows: length(lines),
              row_offset: row_off,
              col_offset: col_off
            })

          next_byte_off = byte_off + byte_size(line_text) + 1
          {g_cmds ++ g, prepend_all(c, c_cmds), next_byte_off}
        end
      )

    {Enum.reverse(gutters), Enum.reverse(contents_rev), length(lines)}
  end

  # ── Line rendering (wrapped) ────────────────────────────────────────────────

  alias Minga.Editor.WrapMap

  @spec render_lines_wrapped([String.t()], pos_integer(), line_render_opts()) ::
          {[DisplayList.draw()], [DisplayList.draw()], non_neg_integer()}
  defp render_lines_wrapped(lines, max_rows, opts) do
    %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: ctx,
      ln_style: ln_style,
      gutter_w: gutter_w,
      first_byte_off: first_byte_off,
      row_off: row_off,
      col_off: col_off
    } = opts

    breakindent = wrap_option(:breakindent)
    linebreak = wrap_option(:linebreak)

    wrap_map =
      WrapMap.compute(lines, ctx.content_w, breakindent: breakindent, linebreak: linebreak)

    sign_w = if ctx.has_sign_column, do: Gutter.sign_column_width(), else: 0

    {gutters, contents, screen_row, _byte_off} =
      lines
      |> Enum.with_index()
      |> Enum.zip(wrap_map)
      |> Enum.reduce_while(
        {[], [], 0, first_byte_off},
        fn {{line_text, line_idx}, visual_rows}, {g, c, sr, byte_off} ->
          {g2, c2, rows_used} =
            BufferLine.render(%{
              line_text: line_text,
              buf_line: first_line + line_idx,
              cursor_line: cursor_line,
              byte_offset: byte_off,
              screen_row: sr,
              ctx: ctx,
              ln_style: ln_style,
              gutter_w: gutter_w,
              sign_w: sign_w,
              wrap_entry: visual_rows,
              max_rows: max_rows,
              row_offset: row_off,
              col_offset: col_off
            })

          sr2 = sr + rows_used
          next_byte_off = byte_off + byte_size(line_text) + 1

          if sr2 >= max_rows do
            {:halt, {g2 ++ g, prepend_all(c, c2), sr2, next_byte_off}}
          else
            {:cont, {g2 ++ g, prepend_all(c, c2), sr2, next_byte_off}}
          end
        end
      )

    {Enum.reverse(gutters), Enum.reverse(contents), screen_row}
  end

  @spec wrap_enabled?() :: boolean()
  # When wrap is on, disable horizontal scroll; lines don't extend past the viewport.
  @spec scroll_horizontal(Viewport.t(), non_neg_integer(), non_neg_integer(), boolean()) ::
          Viewport.t()
  defp scroll_horizontal(vp, cursor_line, _cursor_col, true = _wrap_on) do
    Viewport.scroll_to_cursor(%{vp | left: 0}, {cursor_line, 0})
  end

  defp scroll_horizontal(vp, cursor_line, cursor_col, false = _wrap_on) do
    Viewport.scroll_to_cursor(vp, {cursor_line, cursor_col})
  end

  defp wrap_enabled? do
    Options.get(:wrap)
  catch
    :exit, _ -> false
  end

  @spec wrap_option(atom()) :: boolean()
  defp wrap_option(name) do
    Options.get(name)
  catch
    :exit, _ -> true
  end

  # Prepend all items from `new_items` onto `acc` (reverse order).
  # Used instead of `acc ++ new_items` to avoid O(n²) list appending.
  @spec prepend_all([DisplayList.draw()], [DisplayList.draw()]) :: [DisplayList.draw()]
  defp prepend_all(acc, []), do: acc
  defp prepend_all(acc, new_items), do: Enum.reduce(new_items, acc, fn item, a -> [item | a] end)

  # Builds the per-frame render context for a window.
  @spec build_render_ctx(state(), Window.t(), map()) :: Context.t()
  defp build_render_ctx(state, window, params) do
    %{
      viewport: viewport,
      cursor: cursor,
      lines: lines,
      first_line: first_line,
      preview_matches: preview_matches,
      gutter_w: gutter_w,
      content_w: content_w,
      has_sign_column: has_sign_column,
      is_active: is_active
    } = params

    visual_selection =
      if is_active do
        visual_selection_grapheme_bounds(state, cursor, lines, first_line)
      else
        nil
      end

    search_matches =
      case preview_matches do
        [] -> SearchHighlight.search_matches_for_lines(state, lines, first_line)
        _ -> preview_matches
      end

    %Context{
      viewport: viewport,
      visual_selection: visual_selection,
      search_matches: search_matches,
      gutter_w: gutter_w,
      content_w: content_w,
      confirm_match: if(is_active, do: SearchHighlight.current_confirm_match(state), else: nil),
      highlight: window_highlight(state, window),
      has_sign_column: has_sign_column,
      diagnostic_signs: diagnostic_signs_for_window(state, window),
      git_signs: git_signs_for_window(state, window),
      search_colors: state.theme.search,
      gutter_colors: state.theme.gutter,
      git_colors: state.theme.git
    }
  end

  # Renders the per-window modeline, or empty list if the window is too short.
  @spec render_window_modeline(
          state(),
          Layout.window_layout(),
          map(),
          boolean(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp render_window_modeline(
         _state,
         %{modeline: {_, _, _, 0}},
         _snapshot,
         _active,
         _cl,
         _cc,
         _lc,
         _co
       ) do
    []
  end

  defp render_window_modeline(
         state,
         win_layout,
         snapshot,
         is_active,
         cursor_line,
         cursor_col,
         line_count,
         col_off
       ) do
    {modeline_row, _mc, modeline_width, _mh} = win_layout.modeline
    file_name = snapshot_display_name(snapshot)
    dirty_marker = if snapshot.dirty, do: " ● ", else: ""
    filetype = Map.get(snapshot, :filetype, :text)
    buf_count = length(state.buffers.list)
    buf_index = state.buffers.active_index + 1

    Modeline.render(
      modeline_row,
      modeline_width,
      %{
        mode: if(is_active, do: state.mode, else: :normal),
        mode_state: if(is_active, do: state.mode_state, else: nil),
        file_name: file_name,
        filetype: filetype,
        dirty_marker: dirty_marker,
        cursor_line: cursor_line,
        cursor_col: cursor_col,
        line_count: line_count,
        buf_index: buf_index,
        buf_count: buf_count,
        macro_recording:
          if(is_active, do: MacroRecorder.recording?(state.macro_recorder), else: false),
        agent_status: if(is_active, do: state.agent.status, else: nil),
        agent_theme_colors:
          if(is_active && state.agent.status, do: Theme.agent_theme(state.theme), else: nil)
      },
      state.theme,
      col_off
    )
  end

  @spec window_highlight(state(), Window.t()) :: Minga.Highlight.t() | nil
  defp window_highlight(state, window) do
    hl =
      if window.buffer == state.buffers.active do
        state.highlight.current
      else
        Map.get(state.highlight.cache, window.buffer, Minga.Highlight.from_theme(state.theme))
      end

    if hl.capture_names != [], do: hl, else: nil
  end

  @spec git_signs_for_window(state(), Window.t()) :: %{non_neg_integer() => atom()}
  defp git_signs_for_window(%{git_buffers: git_buffers}, %{buffer: buf}) when is_pid(buf) do
    case Map.get(git_buffers, buf) do
      nil -> %{}
      git_pid -> if Process.alive?(git_pid), do: GitBuffer.signs(git_pid), else: %{}
    end
  end

  @spec diagnostic_signs_for_window(state(), Window.t()) :: %{non_neg_integer() => atom()}
  defp diagnostic_signs_for_window(_state, %{buffer: buf}) when is_pid(buf) do
    case BufferServer.file_path(buf) do
      nil -> %{}
      path -> Diagnostics.severity_by_line(DocumentSync.path_to_uri(path))
    end
  end

  # Computes gutter dimensions for a buffer: whether the sign column is active,
  # and the total gutter width (sign column + line number digits).
  @spec gutter_dimensions(state(), pid(), Gutter.line_number_style(), non_neg_integer()) ::
          {boolean(), non_neg_integer()}
  defp gutter_dimensions(state, buf, line_number_style, line_count) do
    has_sign_column =
      Map.has_key?(state.git_buffers, buf) or BufferServer.file_path(buf) != nil

    sign_w = if has_sign_column, do: Gutter.sign_column_width(), else: 0

    number_w =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    {has_sign_column, number_w + sign_w}
  end

  # Active window reads live cursor from buffer; inactive windows use stored cursor.
  @spec window_cursor(Window.t(), boolean()) :: {non_neg_integer(), non_neg_integer()}
  defp window_cursor(window, true), do: BufferServer.cursor(window.buffer)
  defp window_cursor(window, false), do: window.cursor

  # ── Dimming (inactive window — Doom Emacs style) ────────────────────────────

  @spec apply_inactive_dimming(
          boolean(),
          [DisplayList.draw()],
          [DisplayList.draw()],
          [DisplayList.draw()],
          [DisplayList.draw()]
        ) ::
          {[DisplayList.draw()], [DisplayList.draw()], [DisplayList.draw()], [DisplayList.draw()]}
  defp apply_inactive_dimming(true, gutter, lines, tildes, modeline) do
    {gutter, lines, tildes, modeline}
  end

  defp apply_inactive_dimming(false, gutter, lines, tildes, modeline) do
    {gutter, lines, tildes, DisplayList.grayscale_draws(modeline)}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec visual_selection_bounds(state(), Document.position()) :: visual_selection()
  defp visual_selection_bounds(%{mode: :visual, mode_state: %VisualState{} = ms}, cursor) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type

    case visual_type do
      :char ->
        {start_pos, end_pos} = sort_positions(anchor, cursor)
        {:char, start_pos, end_pos}

      :line ->
        {anchor_line, _} = anchor
        {cursor_line, _} = cursor
        {:line, min(anchor_line, cursor_line), max(anchor_line, cursor_line)}
    end
  end

  defp visual_selection_bounds(_state, _cursor), do: nil

  # Converts byte-indexed visual selection positions to grapheme columns for rendering.
  @spec visual_selection_grapheme_bounds(
          state(),
          Document.position(),
          [String.t()],
          non_neg_integer()
        ) :: visual_selection()
  defp visual_selection_grapheme_bounds(state, cursor, lines, first_line) do
    case visual_selection_bounds(state, cursor) do
      nil ->
        nil

      {:line, _, _} = sel ->
        sel

      {:char, {sl, sc}, {el, ec}} ->
        {
          :char,
          {sl, byte_col_to_display(lines, sl, sc, first_line)},
          # End is exclusive: first display column *after* the last selected grapheme,
          # so selection width = end - start with no +1 needed for wide chars.
          {el, byte_col_to_display_end(lines, el, ec, first_line)}
        }
    end
  end

  # Converts a byte column to the inclusive display column where the grapheme starts.
  @spec byte_col_to_display(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  defp byte_col_to_display(lines, line, byte_col, first_line) do
    line_text = cursor_line_text(lines, line, first_line)
    Unicode.display_col(line_text, byte_col)
  end

  # Converts a byte column to the exclusive display column (first column AFTER the
  # grapheme at byte_col). Used for selection end positions so that:
  #   selection display width = end_exclusive - start_inclusive
  @spec byte_col_to_display_end(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  defp byte_col_to_display_end(lines, line, byte_col, first_line) do
    line_text = cursor_line_text(lines, line, first_line)
    next_byte = Unicode.next_grapheme_byte_offset(line_text, byte_col)
    Unicode.display_col(line_text, next_byte)
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

  @spec sort_positions(Document.position(), Document.position()) ::
          {Document.position(), Document.position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  # Resolves the cursor position from the active window's cursor info,
  # with mode-specific overrides for search/command/eval (cursor in minibuffer).
  @spec resolve_cursor(
          state(),
          {non_neg_integer(), non_neg_integer()} | nil,
          non_neg_integer()
        ) ::
          {non_neg_integer(), non_neg_integer()}
  defp resolve_cursor(
         %{mode: :search, mode_state: mode_state},
         _cursor_info,
         minibuffer_row
       ) do
    search_col = Unicode.display_width(mode_state.input) + 1
    {minibuffer_row, search_col}
  end

  defp resolve_cursor(
         %{mode: :command, mode_state: mode_state},
         _cursor_info,
         minibuffer_row
       ) do
    cmd_col = Unicode.display_width(mode_state.input) + 1
    {minibuffer_row, cmd_col}
  end

  defp resolve_cursor(
         %{mode: :eval, mode_state: mode_state},
         _cursor_info,
         minibuffer_row
       ) do
    # "Eval: " prefix is 6 display columns
    eval_col = Unicode.display_width(mode_state.input) + 6
    {minibuffer_row, eval_col}
  end

  defp resolve_cursor(_state, {row, col}, _minibuffer_row) do
    {row, col}
  end

  defp resolve_cursor(_state, nil, _minibuffer_row) do
    {0, 0}
  end

  @spec render_whichkey(state(), Viewport.t()) :: [DisplayList.draw()]
  defp render_whichkey(%{whichkey: %{show: true, node: node}, theme: theme}, viewport)
       when is_map(node) do
    bindings = WhichKey.bindings_from_node(node)
    lines = WhichKey.render_popup(bindings)

    popup_row = max(0, viewport.rows - 3 - length(lines))

    ([
       DisplayList.draw(popup_row, 0, String.duplicate("─", viewport.cols),
         fg: theme.popup.border_fg
       )
     ] ++
       lines)
    |> Enum.with_index(popup_row + 1)
    |> Enum.map(fn {line_text, row} ->
      padded = String.pad_trailing(line_text, viewport.cols)
      DisplayList.draw(row, 0, padded, fg: theme.popup.fg, bg: theme.popup.bg)
    end)
  end

  defp render_whichkey(_state, _viewport), do: []

  @spec snapshot_display_name(map()) :: String.t()
  defp snapshot_display_name(%{name: name} = snapshot) when is_binary(name) do
    ro = if Map.get(snapshot, :read_only, false), do: " [RO]", else: ""
    name <> ro
  end

  defp snapshot_display_name(snapshot) do
    base =
      case snapshot.file_path do
        nil -> "[scratch]"
        path -> Path.basename(path)
      end

    ro = if Map.get(snapshot, :read_only, false), do: " [RO]", else: ""
    base <> ro
  end

  # ── Agent panel rendering ────────────────────────────────────────────────

  alias Minga.Agent.ChatRenderer
  alias Minga.Agent.Session

  # Overrides cursor position when the agent panel input is focused.
  # Uses Layout's pre-computed agent_panel rect.
  @spec agent_cursor_override_from_layout(
          state(),
          {non_neg_integer(), non_neg_integer()},
          atom(),
          Layout.t()
        ) ::
          {{non_neg_integer(), non_neg_integer()}, atom()}
  defp agent_cursor_override_from_layout(
         %{agent: %{panel: %{visible: true, input_focused: true}}} = state,
         _cursor,
         _shape,
         %{agent_panel: {row, col, _w, h}} = _layout
       )
       when h > 0 do
    input_row = row + h - @agent_input_height + 1
    input_col = col + 2 + String.length(state.agent.panel.input_text)
    {{input_row, input_col}, :beam}
  end

  defp agent_cursor_override_from_layout(_state, cursor, shape, _layout) do
    {cursor, shape}
  end

  # Renders the agent panel sidebar using Layout's pre-computed rect.
  @spec render_agent_panel_from_layout(state(), Layout.t()) :: [DisplayList.draw()]
  defp render_agent_panel_from_layout(_state, %{agent_panel: nil}), do: []

  defp render_agent_panel_from_layout(state, %{agent_panel: rect}) do
    agent = state.agent

    messages =
      if agent.session do
        try do
          Session.messages(agent.session)
        catch
          :exit, _ -> []
        end
      else
        []
      end

    usage =
      if agent.session do
        try do
          Session.usage(agent.session)
        catch
          :exit, _ -> %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}
        end
      else
        %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}
      end

    panel_state = %{
      messages: messages,
      status: agent.status || :idle,
      input_text: agent.panel.input_text,
      scroll_offset: agent.panel.scroll_offset,
      spinner_frame: agent.panel.spinner_frame,
      usage: usage,
      model_name: agent.panel.model_name,
      thinking_level: agent.panel.thinking_level,
      error_message: agent.error
    }

    ChatRenderer.render(rect, panel_state, state.theme)
  end
end
