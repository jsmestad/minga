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
  def render(%{buffer: nil} = state) do
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
    # 1. Get cursor (O(1) with cached gap buffer) for viewport scrolling.
    cursor = BufferServer.cursor(state.buffer)
    viewport = Viewport.scroll_to_cursor(state.viewport, cursor)
    {first_line, _last_line} = Viewport.visible_range(viewport)
    visible_rows = Viewport.content_rows(viewport)

    # 2. Fetch all remaining render data in a single GenServer call.
    snapshot = BufferServer.render_snapshot(state.buffer, first_line, visible_rows)
    lines = snapshot.lines
    {cursor_line, cursor_col} = snapshot.cursor
    line_count = snapshot.line_count

    # 3. Compute gutter dimensions and re-check horizontal scroll.
    line_number_style = state.line_numbers

    gutter_w =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    content_w = max(viewport.cols - gutter_w, 1)

    viewport =
      if cursor_col >= viewport.left + content_w do
        %{viewport | left: cursor_col - content_w + 1}
      else
        viewport
      end

    clear = [Protocol.encode_clear()]

    # Apply live substitution preview if typing :%s/pattern/replacement
    {lines, preview_matches} =
      SearchHighlight.maybe_substitute_preview(state, lines, first_line)

    visual_selection = visual_selection_bounds(state, cursor)

    search_matches =
      case preview_matches do
        [] -> SearchHighlight.search_matches_for_lines(state, lines, first_line)
        _ -> preview_matches
      end

    # 4. Build render context (invariant per frame) and render lines.
    render_ctx = %Context{
      viewport: viewport,
      visual_selection: visual_selection,
      search_matches: search_matches,
      gutter_w: gutter_w,
      content_w: content_w,
      confirm_match: SearchHighlight.current_confirm_match(state)
    }

    {gutter_commands, line_commands} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {line_text, screen_row}, {gutters, contents} ->
        buf_line = first_line + screen_row

        gutter_cmd =
          Gutter.render_number(screen_row, buf_line, cursor_line, gutter_w, line_number_style)

        content_cmds = LineRenderer.render(line_text, screen_row, buf_line, render_ctx)

        new_gutters = if gutter_cmd == [], do: gutters, else: [gutter_cmd | gutters]
        {new_gutters, contents ++ content_cmds}
      end)

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
    buf_count = length(state.buffers)
    buf_index = state.active_buffer + 1
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
      if state.picker do
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
  defp render_whichkey(%{show_whichkey: true, whichkey_node: node}, viewport)
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
