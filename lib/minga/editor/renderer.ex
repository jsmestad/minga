defmodule Minga.Editor.Renderer do
  @moduledoc """
  Buffer and UI rendering for the editor.

  Converts editor state into a list of terminal draw commands sent to the Zig
  port. Pure `state → :ok` — side-effects are limited to the `PortManager`
  call at the end.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Modeline
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.Mode.VisualState
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol
  alias Minga.WhichKey

  @gutter_fg 0x555555
  @gutter_current_fg 0xBBC2CF

  # Search match highlight: yellow-ish background with dark text
  @search_highlight_fg 0x000000
  @search_highlight_bg 0xECBE7B

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

  @typedoc "Column range of a selection on a single line."
  @type line_selection :: nil | :full | {non_neg_integer(), non_neg_integer()}

  @typedoc "A search match: `{line, col, length}` (absolute buffer coordinates)."
  @type search_match :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

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
    {lines, preview_matches} = maybe_substitute_preview(state, lines, first_line)

    visual_selection = visual_selection_bounds(state, cursor)

    search_matches =
      case preview_matches do
        [] -> search_matches_for_lines(state, lines, first_line)
        _ -> preview_matches
      end

    # 4. Render gutter + content lines.
    {gutter_commands, line_commands} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {line_text, screen_row}, {gutters, contents} ->
        buf_line = first_line + screen_row

        gutter_cmd =
          render_gutter_number(screen_row, buf_line, cursor_line, gutter_w, line_number_style)

        content_cmds =
          render_line(
            line_text,
            screen_row,
            buf_line,
            viewport,
            visual_selection,
            search_matches,
            gutter_w,
            content_w
          )

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

    # ── Modeline (row N-2) — Doom Emacs-style colored segments ──
    file_name =
      case snapshot.file_path do
        nil -> "[scratch]"
        path -> Path.basename(path)
      end

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
        buf_count: buf_count
      })

    # ── Minibuffer (row N-1) — command input or messages ──
    minibuffer_row = viewport.rows - 1

    minibuffer_command = render_minibuffer(state, minibuffer_row, viewport.cols)

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

    whichkey_commands = maybe_render_whichkey(state, viewport)

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

  @spec maybe_render_whichkey(state(), Viewport.t()) :: [binary()]
  defp maybe_render_whichkey(%{show_whichkey: true, whichkey_node: node}, viewport)
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

  defp maybe_render_whichkey(_state, _viewport), do: []

  @spec render_minibuffer(state(), non_neg_integer(), pos_integer()) :: binary()
  defp render_minibuffer(%{mode: :search, mode_state: ms}, row, cols) do
    prefix = if ms.direction == :forward, do: "/", else: "?"
    search_text = prefix <> ms.input

    Protocol.encode_draw(
      row,
      0,
      String.pad_trailing(search_text, cols),
      fg: 0xEEEEEE,
      bg: 0x000000
    )
  end

  defp render_minibuffer(%{mode: :command, mode_state: ms}, row, cols) do
    cmd_text = ":" <> ms.input

    Protocol.encode_draw(
      row,
      0,
      String.pad_trailing(cmd_text, cols),
      fg: 0xEEEEEE,
      bg: 0x000000
    )
  end

  defp render_minibuffer(%{status_msg: msg}, row, cols) when is_binary(msg) do
    Protocol.encode_draw(
      row,
      0,
      String.pad_trailing(msg, cols),
      fg: 0xFFCC00,
      bg: 0x000000
    )
  end

  defp render_minibuffer(_state, row, cols) do
    Protocol.encode_draw(
      row,
      0,
      String.duplicate(" ", cols),
      fg: 0x888888,
      bg: 0x000000
    )
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
    # +1 for the "/" or "?" prefix
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

  @spec visual_selection_bounds(state(), Minga.Buffer.GapBuffer.position()) ::
          visual_selection()
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

  @spec sort_positions(
          Minga.Buffer.GapBuffer.position(),
          Minga.Buffer.GapBuffer.position()
        ) :: {Minga.Buffer.GapBuffer.position(), Minga.Buffer.GapBuffer.position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @spec render_gutter_number(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          line_number_style()
        ) :: binary() | []
  defp render_gutter_number(_screen_row, _buf_line, _cursor_line, 0, :none), do: []

  defp render_gutter_number(screen_row, buf_line, cursor_line, gutter_w, style) do
    {number, fg} = gutter_number_and_color(buf_line, cursor_line, style)

    num_str = Integer.to_string(number)
    padded = String.pad_leading(num_str, gutter_w - 1)
    Protocol.encode_draw(screen_row, 0, padded, fg: fg)
  end

  @spec gutter_number_and_color(non_neg_integer(), non_neg_integer(), line_number_style()) ::
          {non_neg_integer(), non_neg_integer()}
  defp gutter_number_and_color(buf_line, _cursor_line, :absolute) do
    {buf_line + 1, @gutter_current_fg}
  end

  defp gutter_number_and_color(buf_line, cursor_line, :relative) do
    {abs(buf_line - cursor_line), @gutter_fg}
  end

  defp gutter_number_and_color(buf_line, cursor_line, :hybrid) do
    if buf_line == cursor_line do
      {buf_line + 1, @gutter_current_fg}
    else
      {abs(buf_line - cursor_line), @gutter_fg}
    end
  end

  @spec render_line(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Minga.Editor.Viewport.t(),
          visual_selection(),
          [search_match()],
          non_neg_integer(),
          pos_integer()
        ) :: [binary()]
  defp render_line(
         line_text,
         screen_row,
         buf_line,
         viewport,
         visual_selection,
         search_matches,
         gutter_w,
         content_w
       ) do
    graphemes = String.graphemes(line_text)
    line_len = length(graphemes)

    visible_graphemes =
      graphemes
      |> Enum.drop(viewport.left)
      |> Enum.take(content_w)

    # Visual selection takes priority over search highlights.
    case selection_cols_for_line(buf_line, line_len, visual_selection) do
      nil ->
        render_line_with_search(
          visible_graphemes,
          screen_row,
          buf_line,
          viewport,
          search_matches,
          gutter_w
        )

      :full ->
        [Protocol.encode_draw(screen_row, gutter_w, Enum.join(visible_graphemes), reverse: true)]

      {sel_start, sel_end} ->
        before_sel = Enum.take(visible_graphemes, max(0, sel_start - viewport.left))

        sel_graphemes =
          visible_graphemes
          |> Enum.drop(max(0, sel_start - viewport.left))
          |> Enum.take(sel_end - max(sel_start, viewport.left) + 1)

        after_sel =
          Enum.drop(
            visible_graphemes,
            max(0, sel_start - viewport.left) + length(sel_graphemes)
          )

        before_text = Enum.join(before_sel)
        sel_text = Enum.join(sel_graphemes)
        after_text = Enum.join(after_sel)

        [
          Protocol.encode_draw(screen_row, gutter_w, before_text),
          Protocol.encode_draw(
            screen_row,
            gutter_w + length(before_sel),
            sel_text,
            reverse: true
          ),
          Protocol.encode_draw(
            screen_row,
            gutter_w + length(before_sel) + length(sel_graphemes),
            after_text
          )
        ]
    end
  end

  # Renders a line with search match highlighting. When no matches exist on
  # this line, emits a single draw command. Otherwise, splits the visible
  # graphemes into alternating normal/highlighted spans.
  @spec render_line_with_search(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          Minga.Editor.Viewport.t(),
          [search_match()],
          non_neg_integer()
        ) :: [binary()]
  defp render_line_with_search(
         visible_graphemes,
         screen_row,
         buf_line,
         viewport,
         matches,
         gutter_w
       ) do
    highlight_set = build_highlight_set(matches, buf_line, viewport, visible_graphemes)

    if MapSet.size(highlight_set) == 0 do
      [Protocol.encode_draw(screen_row, gutter_w, Enum.join(visible_graphemes))]
    else
      render_highlighted_spans(
        visible_graphemes,
        viewport.left,
        highlight_set,
        screen_row,
        gutter_w
      )
    end
  end

  @spec build_highlight_set(
          [search_match()],
          non_neg_integer(),
          Minga.Editor.Viewport.t(),
          [String.t()]
        ) :: MapSet.t(non_neg_integer())
  defp build_highlight_set(matches, buf_line, viewport, visible_graphemes) do
    vis_start = viewport.left
    vis_end = vis_start + length(visible_graphemes) - 1

    matches
    |> Enum.filter(fn {line, _col, _len} -> line == buf_line end)
    |> Enum.flat_map(fn {_line, col, len} ->
      Enum.to_list(max(col, vis_start)..min(col + len - 1, vis_end)//1)
    end)
    |> MapSet.new()
  end

  @spec render_highlighted_spans(
          [String.t()],
          non_neg_integer(),
          MapSet.t(non_neg_integer()),
          non_neg_integer(),
          non_neg_integer()
        ) :: [binary()]
  defp render_highlighted_spans(visible_graphemes, vis_start, highlight_set, screen_row, gutter_w) do
    visible_graphemes
    |> Enum.with_index(vis_start)
    |> chunk_by_highlight(highlight_set)
    |> Enum.flat_map(fn {chars, abs_start_col, highlighted?} ->
      encode_span(chars, abs_start_col, vis_start, highlighted?, screen_row, gutter_w)
    end)
  end

  @spec encode_span(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [binary()]
  defp encode_span(chars, abs_start_col, vis_start, true, screen_row, gutter_w) do
    screen_col = gutter_w + (abs_start_col - vis_start)

    [
      Protocol.encode_draw(screen_row, screen_col, Enum.join(chars),
        fg: @search_highlight_fg,
        bg: @search_highlight_bg
      )
    ]
  end

  defp encode_span(chars, abs_start_col, vis_start, false, screen_row, gutter_w) do
    screen_col = gutter_w + (abs_start_col - vis_start)
    [Protocol.encode_draw(screen_row, screen_col, Enum.join(chars))]
  end

  # Groups a list of `{grapheme, abs_col}` tuples into contiguous spans of
  # highlighted or non-highlighted characters.
  @spec chunk_by_highlight(
          [{String.t(), non_neg_integer()}],
          MapSet.t(non_neg_integer())
        ) :: [{[String.t()], non_neg_integer(), boolean()}]
  defp chunk_by_highlight(indexed_graphemes, highlight_set) do
    indexed_graphemes
    |> Enum.chunk_while(
      nil,
      fn {char, col}, acc ->
        highlighted = MapSet.member?(highlight_set, col)

        case acc do
          nil ->
            {:cont, {[char], col, highlighted}}

          {chars, start_col, ^highlighted} ->
            {:cont, {[char | chars], start_col, highlighted}}

          {chars, start_col, prev_hl} ->
            {:cont, {Enum.reverse(chars), start_col, prev_hl}, {[char], col, highlighted}}
        end
      end,
      fn
        nil -> {:cont, []}
        {chars, start_col, hl} -> {:cont, {Enum.reverse(chars), start_col, hl}, nil}
      end
    )
  end

  # Applies a live substitution preview when the user is typing a substitute
  # command with both pattern and replacement present. Replaces the visible
  # lines with the preview result without mutating the buffer.
  # Returns `{preview_lines, highlight_matches}`.
  @spec maybe_substitute_preview(state(), [String.t()], non_neg_integer()) ::
          {[String.t()], [search_match()]}
  defp maybe_substitute_preview(
         %{mode: :command, mode_state: %Minga.Mode.CommandState{input: input}},
         lines,
         first_line
       ) do
    case extract_substitute_parts(input) do
      {pattern, replacement} when is_binary(replacement) ->
        global? = substitute_has_global_flag?(input)
        substitute_preview_lines(lines, first_line, pattern, replacement, global?)

      _ ->
        {lines, []}
    end
  end

  defp maybe_substitute_preview(_state, lines, _first_line), do: {lines, []}

  @spec substitute_preview_lines(
          [String.t()],
          non_neg_integer(),
          String.t(),
          String.t(),
          boolean()
        ) :: {[String.t()], [search_match()]}
  defp substitute_preview_lines(lines, first_line, pattern, replacement, global?) do
    lines
    |> Enum.with_index(first_line)
    |> Enum.map_reduce([], fn {line, line_num}, acc ->
      {new_line, _count, spans} =
        Minga.Search.substitute_line_with_spans(line, pattern, replacement, global?)

      matches = Enum.map(spans, fn {col, len} -> {line_num, col, len} end)
      {new_line, acc ++ matches}
    end)
  end

  # Checks if the substitute command input contains the /g flag.
  @spec substitute_has_global_flag?(String.t()) :: boolean()
  defp substitute_has_global_flag?(input) do
    # The flags come after the third delimiter. Count delimiters to find flags.
    trimmed = String.trim_leading(input, "%")

    case trimmed do
      <<"s", delimiter, rest::binary>> when delimiter in [?/, ?#, ?|] ->
        delim = <<delimiter>>
        flags_str = extract_flags_after_replacement(rest, delim, 0)
        String.contains?(flags_str, "g")

      _ ->
        false
    end
  end

  @spec extract_flags_after_replacement(String.t(), String.t(), non_neg_integer()) :: String.t()
  defp extract_flags_after_replacement("", _delim, _count), do: ""

  defp extract_flags_after_replacement("\\" <> <<_c::utf8, rest::binary>>, delim, count) do
    extract_flags_after_replacement(rest, delim, count)
  end

  defp extract_flags_after_replacement(<<c::utf8, rest::binary>>, delim, 0) do
    if <<c::utf8>> == delim do
      extract_flags_after_replacement(rest, delim, 1)
    else
      extract_flags_after_replacement(rest, delim, 0)
    end
  end

  defp extract_flags_after_replacement(<<c::utf8, rest::binary>>, delim, 1) do
    if <<c::utf8>> == delim, do: rest, else: extract_flags_after_replacement(rest, delim, 1)
  end

  # Computes search matches for the visible line range.
  #
  # Priority: live search/substitute pattern > stored last_search_pattern.
  @spec search_matches_for_lines(state(), [String.t()], non_neg_integer()) :: [search_match()]
  defp search_matches_for_lines(state, lines, first_line) do
    pattern = active_search_pattern(state)

    if is_binary(pattern) and pattern != "" do
      Minga.Search.find_all_in_range(lines, pattern, first_line)
    else
      []
    end
  end

  # Returns the pattern to highlight, checking live input first.
  @spec active_search_pattern(state()) :: String.t() | nil
  defp active_search_pattern(%{mode: :search, mode_state: %Minga.Mode.SearchState{input: input}})
       when input != "" do
    input
  end

  defp active_search_pattern(%{
         mode: :command,
         mode_state: %Minga.Mode.CommandState{input: input}
       }) do
    extract_substitute_pattern(input)
  end

  defp active_search_pattern(%{last_search_pattern: pattern})
       when is_binary(pattern) and pattern != "" do
    pattern
  end

  defp active_search_pattern(_state), do: nil

  # Extracts the search pattern from a partial substitute command input.
  # Matches `%s/pattern...` or `s/pattern...` while the user is typing.
  @spec extract_substitute_pattern(String.t()) :: String.t() | nil
  defp extract_substitute_pattern(input) do
    case extract_substitute_parts(input) do
      {pattern, _replacement} -> pattern
      nil -> nil
    end
  end

  # Extracts both pattern and replacement from a substitute command input.
  # Returns `{pattern, replacement}` or `nil`.
  @spec extract_substitute_parts(String.t()) :: {String.t(), String.t() | nil} | nil
  defp extract_substitute_parts(input) do
    trimmed = String.trim_leading(input, "%")

    case trimmed do
      <<"s", delimiter, rest::binary>> when delimiter in [?/, ?#, ?|] ->
        split_substitute_input(rest, <<delimiter>>)

      _ ->
        nil
    end
  end

  @spec split_substitute_input(String.t(), String.t()) :: {String.t(), String.t() | nil} | nil
  defp split_substitute_input(rest, delim) do
    case extract_until_delimiter(rest, delim, []) do
      {pattern, after_pattern} ->
        replacement = extract_replacement(after_pattern, delim)
        {pattern, replacement}

      nil ->
        if rest == "", do: nil, else: {rest, nil}
    end
  end

  # Extracts text up to the next unescaped delimiter.
  # Returns `{extracted, rest_after_delimiter}` or `nil` if no delimiter found.
  @spec extract_until_delimiter(String.t(), String.t(), [String.t()]) ::
          {String.t(), String.t()} | nil
  defp extract_until_delimiter("", _delimiter, acc) do
    # No delimiter found — return nil (still typing the pattern)
    if acc == [], do: nil, else: nil
  end

  defp extract_until_delimiter("\\" <> <<c::utf8, rest::binary>>, delimiter, acc) do
    extract_until_delimiter(rest, delimiter, [<<c::utf8>>, "\\" | acc])
  end

  defp extract_until_delimiter(<<c::utf8, rest::binary>>, delimiter, acc) do
    if <<c::utf8>> == delimiter do
      pattern = acc |> Enum.reverse() |> Enum.join()
      if pattern == "", do: nil, else: {pattern, rest}
    else
      extract_until_delimiter(rest, delimiter, [<<c::utf8>> | acc])
    end
  end

  # Extracts the replacement string from text after the pattern delimiter.
  # The replacement extends until the next unescaped delimiter or end of input.
  @spec extract_replacement(String.t(), String.t()) :: String.t() | nil
  defp extract_replacement("", _delimiter), do: nil

  defp extract_replacement(input, delimiter) do
    do_extract_replacement(input, delimiter, [])
  end

  @spec do_extract_replacement(String.t(), String.t(), [String.t()]) :: String.t()
  defp do_extract_replacement("", _delimiter, acc) do
    acc |> Enum.reverse() |> Enum.join()
  end

  defp do_extract_replacement("\\" <> <<c::utf8, rest::binary>>, delimiter, acc) do
    do_extract_replacement(rest, delimiter, [<<c::utf8>>, "\\" | acc])
  end

  defp do_extract_replacement(<<c::utf8, rest::binary>>, delimiter, acc) do
    if <<c::utf8>> == delimiter do
      acc |> Enum.reverse() |> Enum.join()
    else
      do_extract_replacement(rest, delimiter, [<<c::utf8>> | acc])
    end
  end

  @spec selection_cols_for_line(
          non_neg_integer(),
          non_neg_integer(),
          visual_selection()
        ) :: line_selection()
  defp selection_cols_for_line(_buf_line, _line_len, nil), do: nil

  defp selection_cols_for_line(buf_line, _line_len, {:line, start_line, end_line}) do
    if buf_line >= start_line and buf_line <= end_line, do: :full, else: nil
  end

  defp selection_cols_for_line(buf_line, _line_len, {:char, {start_line, _sc}, {end_line, _ec}})
       when buf_line < start_line or buf_line > end_line,
       do: nil

  defp selection_cols_for_line(_buf_line, _line_len, {:char, {same, start_col}, {same, end_col}}),
    do: {start_col, end_col}

  defp selection_cols_for_line(buf_line, line_len, {:char, {buf_line, start_col}, _end_pos}),
    do: {start_col, max(0, line_len - 1)}

  defp selection_cols_for_line(buf_line, _line_len, {:char, _start_pos, {buf_line, end_col}}),
    do: {0, end_col}

  defp selection_cols_for_line(_buf_line, _line_len, {:char, _start_pos, _end_pos}),
    do: :full
end
