defmodule Minga.Editor.Renderer do
  @moduledoc """
  Buffer and UI rendering for the editor.

  Converts editor state into a list of terminal draw commands sent to the Zig
  port. Pure `state → :ok` — side-effects are limited to the `PortManager`
  call at the end.

  This module orchestrates focused sub-modules:

  * `Renderer.Gutter`          — line number rendering
  * `Renderer.Line`            — line content and selection rendering
  * `Renderer.SearchHighlight` — search/substitute highlight overlays
  * `Renderer.Minibuffer`      — command/search/status line
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.Modeline
  alias Minga.Editor.PickerUI
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.Line, as: LineRenderer
  alias Minga.Editor.Renderer.Minibuffer
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Mode
  alias Minga.Mode.VisualState
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol
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

  @doc "Renders the no-buffer splash screen."
  @spec render(state()) :: :ok
  def render(%{buf: %{buffer: nil}} = state) do
    commands = [
      Protocol.encode_clear(),
      Protocol.encode_draw(0, 0, "Minga v#{Minga.version()} — No file open"),
      Protocol.encode_draw(1, 0, "Use: mix minga <filename>"),
      Protocol.encode_cursor(0, 0),
      Protocol.encode_batch_end()
    ]

    PortManager.send_commands(state.port_manager, commands)
  end

  def render(state) do
    if EditorState.split?(state) do
      render_split(state)
    else
      render_single(state)
    end
  end

  # ── Single window render (original path, no overhead) ─────────────────────

  @spec render_single(state()) :: :ok
  defp render_single(state) do
    # 1. Get cursor (byte-indexed) for vertical viewport scrolling.
    #    Horizontal scroll is deferred until we have line text for byte→grapheme conversion.
    {cursor_line, cursor_byte_col} = BufferServer.cursor(state.buf.buffer)
    cursor = {cursor_line, cursor_byte_col}
    viewport = Viewport.scroll_to_cursor(state.viewport, {cursor_line, 0})
    {first_line, _last_line} = Viewport.visible_range(viewport)
    visible_rows = Viewport.content_rows(viewport)

    # 2. Fetch all remaining render data in a single GenServer call.
    snapshot = BufferServer.render_snapshot(state.buf.buffer, first_line, visible_rows)
    lines = snapshot.lines
    {cursor_line, _cursor_byte_col} = snapshot.cursor
    line_count = snapshot.line_count

    # 3. Convert cursor byte_col → grapheme col using current line text.
    #    This is the render boundary: all downstream code uses grapheme columns.
    cursor_line_text = cursor_line_text(lines, cursor_line, first_line)
    cursor_col = Unicode.grapheme_col(cursor_line_text, cursor_byte_col)

    # 4. Compute gutter dimensions and horizontal scroll in grapheme units.
    line_number_style = state.line_numbers

    gutter_w =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    content_w = max(viewport.cols - gutter_w, 1)

    viewport = Viewport.scroll_to_cursor(viewport, {cursor_line, cursor_col})

    clear = [Protocol.encode_clear()]

    # Apply live substitution preview if typing :%s/pattern/replacement
    {lines, preview_matches} =
      SearchHighlight.maybe_substitute_preview(state, lines, first_line)

    visual_selection = visual_selection_grapheme_bounds(state, cursor, lines, first_line)

    search_matches =
      case preview_matches do
        [] -> SearchHighlight.search_matches_for_lines(state, lines, first_line)
        _ -> preview_matches
      end

    # 4. Build render context (invariant per frame) and render lines.
    highlight =
      if state.highlight.capture_names != [], do: state.highlight, else: nil

    render_ctx = %Context{
      viewport: viewport,
      visual_selection: visual_selection,
      search_matches: search_matches,
      gutter_w: gutter_w,
      content_w: content_w,
      confirm_match: SearchHighlight.current_confirm_match(state),
      highlight: highlight
    }

    {gutter_commands, line_commands, _byte_offset} =
      lines
      |> Enum.with_index()
      |> Enum.reduce(
        {[], [], snapshot.first_line_byte_offset},
        fn {line_text, screen_row}, {gutters, contents, byte_offset} ->
          buf_line = first_line + screen_row

          gutter_cmd =
            Gutter.render_number(screen_row, buf_line, cursor_line, gutter_w, line_number_style)

          content_cmds =
            LineRenderer.render(line_text, screen_row, buf_line, render_ctx, byte_offset)

          new_gutters = if gutter_cmd == [], do: gutters, else: [gutter_cmd | gutters]
          next_byte_offset = byte_offset + byte_size(line_text) + 1

          {new_gutters, contents ++ content_cmds, next_byte_offset}
        end
      )

    gutter_commands = Enum.reverse(gutter_commands)

    tilde_commands =
      if length(lines) < visible_rows do
        for row <- length(lines)..(visible_rows - 1) do
          Protocol.encode_draw(row, gutter_w, "~", fg: 0x555555)
        end
      else
        []
      end

    # ── Modeline (row N-2) ──
    file_name = snapshot_display_name(snapshot)
    dirty_marker = if snapshot.dirty, do: " ● ", else: ""
    line_count = snapshot.line_count
    buf_count = length(state.buf.buffers)
    buf_index = state.buf.active_buffer + 1
    modeline_row = viewport.rows - 2

    filetype = Map.get(snapshot, :filetype, :text)

    modeline_commands =
      Modeline.render(modeline_row, viewport.cols, %{
        mode: state.mode,
        mode_state: state.mode_state,
        file_name: file_name,
        filetype: filetype,
        dirty_marker: dirty_marker,
        cursor_line: cursor_line,
        cursor_col: cursor_col,
        line_count: line_count,
        buf_index: buf_index,
        buf_count: buf_count,
        macro_recording: MacroRecorder.recording?(state.macro_recorder)
      })

    # ── Minibuffer (row N-1) ──
    minibuffer_row = viewport.rows - 1
    minibuffer_command = Minibuffer.render(state, minibuffer_row, viewport.cols)

    # ── Picker overlay ──
    {picker_commands, picker_cursor} = PickerUI.render(state, viewport)

    # ── Cursor placement + shape ──
    cursor_shape_command =
      if state.picker_ui.picker do
        Protocol.encode_cursor_shape(:beam)
      else
        Protocol.encode_cursor_shape(Modeline.cursor_shape(state.mode))
      end

    cursor_command =
      resolve_cursor_command(
        picker_cursor,
        state.mode,
        state.mode_state,
        minibuffer_row,
        cursor_line,
        cursor_col,
        viewport,
        gutter_w
      )

    whichkey_commands = render_whichkey(state, viewport)

    all_commands =
      clear ++
        gutter_commands ++
        line_commands ++
        tilde_commands ++
        modeline_commands ++
        [minibuffer_command] ++
        whichkey_commands ++
        picker_commands ++
        [cursor_shape_command, cursor_command, Protocol.encode_batch_end()]

    PortManager.send_commands(state.port_manager, all_commands)
    :ok
  end

  # ── Multi-window render ──────────────────────────────────────────────────

  @spec render_split(state()) :: :ok
  defp render_split(state) do
    screen = EditorState.screen_rect(state)
    layouts = WindowTree.layout(state.window_tree, screen)
    full_viewport = state.viewport

    clear = [Protocol.encode_clear()]

    # Render each window's buffer content + modeline within its rect
    {window_commands, active_cursor_info} =
      Enum.reduce(layouts, {[], nil}, fn layout_entry, acc ->
        render_window_in_layout(state, layout_entry, acc)
      end)

    # Render vertical separators between side-by-side panes
    separator_commands = render_separators(state.window_tree, screen, full_viewport.rows)

    # ── Global elements (minibuffer, whichkey, picker) use full viewport ──
    minibuffer_row = full_viewport.rows - 1
    minibuffer_command = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

    {picker_commands, picker_cursor} = PickerUI.render(state, full_viewport)
    whichkey_commands = render_whichkey(state, full_viewport)

    # ── Cursor ──
    cursor_shape_command =
      if state.picker_ui.picker do
        Protocol.encode_cursor_shape(:beam)
      else
        Protocol.encode_cursor_shape(Modeline.cursor_shape(state.mode))
      end

    cursor_command =
      case picker_cursor do
        {row, col} ->
          Protocol.encode_cursor(row, col)

        nil ->
          case active_cursor_info do
            {row, col} -> Protocol.encode_cursor(row, col)
            nil -> Protocol.encode_cursor(0, 0)
          end
      end

    all_commands =
      clear ++
        window_commands ++
        separator_commands ++
        [minibuffer_command] ++
        whichkey_commands ++
        picker_commands ++
        [cursor_shape_command, cursor_command, Protocol.encode_batch_end()]

    PortManager.send_commands(state.port_manager, all_commands)
    :ok
  end

  @spec render_window_in_layout(
          state(),
          {Window.id(), WindowTree.rect()},
          {[binary()], {non_neg_integer(), non_neg_integer()} | nil}
        ) ::
          {[binary()], {non_neg_integer(), non_neg_integer()} | nil}
  defp render_window_in_layout(
         state,
         {win_id, {row_off, col_off, width, height}},
         {cmds_acc, cursor_acc}
       ) do
    window = Map.get(state.windows, win_id)

    if window == nil or window.buffer == nil do
      {cmds_acc, cursor_acc}
    else
      is_active = win_id == state.active_window
      win_viewport = Viewport.new(height, width)

      {win_cmds, cursor_info} =
        render_window_content(state, window, win_viewport, {row_off, col_off}, is_active)

      new_cursor_acc = if is_active and cursor_info != nil, do: cursor_info, else: cursor_acc
      {cmds_acc ++ win_cmds, new_cursor_acc}
    end
  end

  # Renders a single window's buffer content within its rect.
  # Returns {draw_commands, cursor_position | nil}.
  @spec render_window_content(
          state(),
          Window.t(),
          Viewport.t(),
          {non_neg_integer(), non_neg_integer()},
          boolean()
        ) :: {[binary()], {non_neg_integer(), non_neg_integer()} | nil}
  defp render_window_content(state, window, win_viewport, {row_off, col_off}, is_active) do
    buffer = window.buffer
    {cursor_line, cursor_byte_col} = BufferServer.cursor(buffer)
    cursor = {cursor_line, cursor_byte_col}

    viewport = Viewport.scroll_to_cursor(win_viewport, {cursor_line, 0})
    {first_line, _last_line} = Viewport.visible_range(viewport)
    # Reserve 1 row for per-window modeline
    visible_rows = max(Viewport.content_rows(viewport) - 1, 1)

    snapshot = BufferServer.render_snapshot(buffer, first_line, visible_rows)
    lines = snapshot.lines
    {cursor_line, _} = snapshot.cursor
    line_count = snapshot.line_count

    cursor_line_text = cursor_line_text(lines, cursor_line, first_line)
    cursor_col = Unicode.grapheme_col(cursor_line_text, cursor_byte_col)

    line_number_style = state.line_numbers

    gutter_w =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    content_w = max(viewport.cols - gutter_w, 1)
    viewport = Viewport.scroll_to_cursor(viewport, {cursor_line, cursor_col})

    # Only show visual selection in the active window
    visual_selection =
      if is_active do
        visual_selection_grapheme_bounds(state, cursor, lines, first_line)
      else
        nil
      end

    highlight =
      if state.highlight.capture_names != [], do: state.highlight, else: nil

    render_ctx = %Context{
      viewport: viewport,
      visual_selection: visual_selection,
      search_matches: SearchHighlight.search_matches_for_lines(state, lines, first_line),
      gutter_w: gutter_w,
      content_w: content_w,
      confirm_match: SearchHighlight.current_confirm_match(state),
      highlight: highlight
    }

    {gutter_commands, line_commands, _byte_offset} =
      lines
      |> Enum.with_index()
      |> Enum.reduce(
        {[], [], snapshot.first_line_byte_offset},
        fn {line_text, screen_row}, {gutters, contents, byte_offset} ->
          buf_line = first_line + screen_row

          gutter_cmd =
            Gutter.render_number(screen_row, buf_line, cursor_line, gutter_w, line_number_style)

          content_cmds =
            LineRenderer.render(line_text, screen_row, buf_line, render_ctx, byte_offset)

          # Offset all commands by window position
          gutter_cmd = offset_commands(List.wrap(gutter_cmd), row_off, col_off)
          content_cmds = offset_commands(content_cmds, row_off, col_off)

          {gutters ++ gutter_cmd, contents ++ content_cmds,
           byte_offset + byte_size(line_text) + 1}
        end
      )

    tilde_commands =
      if length(lines) < visible_rows do
        for row <- length(lines)..(visible_rows - 1) do
          Protocol.encode_draw(row + row_off, col_off + gutter_w, "~", fg: 0x555555)
        end
      else
        []
      end

    # Per-window modeline
    file_name = snapshot_display_name(snapshot)
    dirty_marker = if snapshot.dirty, do: " ● ", else: ""
    buf_count = length(state.buf.buffers)
    buf_index = state.buf.active_buffer + 1
    modeline_row = row_off + viewport.rows - Viewport.footer_rows()

    filetype = Map.get(snapshot, :filetype, :text)

    modeline_commands =
      Modeline.render(modeline_row, viewport.cols, %{
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
        macro_recording: false
      })

    modeline_commands = offset_commands(modeline_commands, 0, col_off)

    commands = gutter_commands ++ line_commands ++ tilde_commands ++ modeline_commands

    cursor_info =
      if is_active do
        {cursor_line - viewport.top + row_off, gutter_w + cursor_col - viewport.left + col_off}
      else
        nil
      end

    {commands, cursor_info}
  end

  # Renders vertical separator lines for vertical splits.
  @spec render_separators(WindowTree.t(), WindowTree.rect(), pos_integer()) :: [binary()]
  defp render_separators(tree, screen_rect, total_rows) do
    separator_cols = collect_separator_cols(tree, screen_rect)

    Enum.flat_map(separator_cols, fn col ->
      for row <- 0..(total_rows - 2) do
        Protocol.encode_draw(row, col, "│", fg: 0x555555)
      end
    end)
  end

  @spec collect_separator_cols(WindowTree.t(), WindowTree.rect()) :: [non_neg_integer()]
  defp collect_separator_cols({:leaf, _}, _rect), do: []

  defp collect_separator_cols({:split, :vertical, left, right}, {row, col, width, height}) do
    left_width = div(width - 1, 2)
    separator_col = col + left_width
    right_width = width - left_width - 1

    [separator_col] ++
      collect_separator_cols(left, {row, col, left_width, height}) ++
      collect_separator_cols(right, {row, separator_col + 1, right_width, height})
  end

  defp collect_separator_cols({:split, :horizontal, top, bottom}, {row, col, width, height}) do
    top_height = div(height, 2)
    bottom_height = height - top_height

    collect_separator_cols(top, {row, col, width, top_height}) ++
      collect_separator_cols(bottom, {row + top_height, col, width, bottom_height})
  end

  # Offsets draw command row/col positions by the given amounts.
  # Only offsets draw_text commands (opcode 0x10) — cursor commands are handled separately.
  @spec offset_commands([binary()], non_neg_integer(), non_neg_integer()) :: [binary()]
  defp offset_commands(commands, 0, 0), do: commands

  defp offset_commands(commands, row_off, col_off) do
    Enum.map(commands, fn
      <<0x10, row::16, col::16, rest::binary>> ->
        <<0x10, row + row_off::16, col + col_off::16, rest::binary>>

      other ->
        other
    end)
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec visual_selection_bounds(state(), GapBuffer.position()) :: visual_selection()
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
          GapBuffer.position(),
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
        {:char, {sl, byte_col_to_grapheme(lines, sl, sc, first_line)},
         {el, byte_col_to_grapheme(lines, el, ec, first_line)}}
    end
  end

  @spec byte_col_to_grapheme(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  defp byte_col_to_grapheme(lines, line, byte_col, first_line) do
    line_text = cursor_line_text(lines, line, first_line)
    Unicode.grapheme_col(line_text, byte_col)
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

  @spec sort_positions(GapBuffer.position(), GapBuffer.position()) ::
          {GapBuffer.position(), GapBuffer.position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @spec resolve_cursor_command(
          {non_neg_integer(), non_neg_integer()} | nil,
          Mode.mode(),
          Mode.state(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Viewport.t(),
          non_neg_integer()
        ) :: binary()
  defp resolve_cursor_command(
         {row, col},
         _mode,
         _mode_state,
         _mb_row,
         _cur_line,
         _cur_col,
         _vp,
         _gutter_w
       ) do
    Protocol.encode_cursor(row, col)
  end

  defp resolve_cursor_command(
         nil,
         :search,
         mode_state,
         minibuffer_row,
         _cur_line,
         _cur_col,
         _vp,
         _gutter_w
       ) do
    search_col = String.length(mode_state.input) + 1
    Protocol.encode_cursor(minibuffer_row, search_col)
  end

  defp resolve_cursor_command(
         nil,
         :command,
         mode_state,
         minibuffer_row,
         _cur_line,
         _cur_col,
         _vp,
         _gutter_w
       ) do
    cmd_col = String.length(mode_state.input) + 1
    Protocol.encode_cursor(minibuffer_row, cmd_col)
  end

  defp resolve_cursor_command(
         nil,
         _mode,
         _mode_state,
         _mb_row,
         cursor_line,
         cursor_col,
         viewport,
         gutter_w
       ) do
    Protocol.encode_cursor(cursor_line - viewport.top, gutter_w + cursor_col - viewport.left)
  end

  @spec render_whichkey(state(), Viewport.t()) :: [binary()]
  defp render_whichkey(%{whichkey: %{show: true, node: node}}, viewport)
       when is_map(node) do
    bindings = WhichKey.bindings_from_node(node)
    lines = WhichKey.render_popup(bindings)

    popup_row = max(0, viewport.rows - 3 - length(lines))

    ([Protocol.encode_draw(popup_row, 0, String.duplicate("─", viewport.cols), fg: 0x888888)] ++
       lines)
    |> Enum.with_index(popup_row + 1)
    |> Enum.map(fn {line_text, row} ->
      padded = String.pad_trailing(line_text, viewport.cols)
      Protocol.encode_draw(row, 0, padded, fg: 0xEEEEEE, bg: 0x333333)
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
end
