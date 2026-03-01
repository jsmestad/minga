defmodule Minga.Editor.Renderer.SearchHighlight do
  @moduledoc """
  Search match highlighting, substitute preview, and pattern extraction for
  the renderer.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Port.Protocol

  @search_highlight_fg 0x000000
  @search_highlight_bg 0xECBE7B

  @typedoc "A search match: `{line, col, length}` (absolute buffer coordinates)."
  @type search_match :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Applies a live substitute preview when the user is typing `:%s/pat/repl`."
  @spec maybe_substitute_preview(state(), [String.t()], non_neg_integer()) ::
          {[String.t()], [search_match()]}
  def maybe_substitute_preview(
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

  def maybe_substitute_preview(_state, lines, _first_line), do: {lines, []}

  @doc "Computes search matches for the visible line range."
  @spec search_matches_for_lines(state(), [String.t()], non_neg_integer()) :: [search_match()]
  def search_matches_for_lines(state, lines, first_line) do
    pattern = active_search_pattern(state)

    if is_binary(pattern) and pattern != "" do
      Minga.Search.find_all_in_range(lines, pattern, first_line)
    else
      []
    end
  end

  @doc "Renders a line with search match highlighting spans."
  @spec render_line_with_search(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          Viewport.t(),
          [search_match()],
          non_neg_integer()
        ) :: [binary()]
  def render_line_with_search(
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

  # ── Private helpers ──────────────────────────────────────────────────────────

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

  @spec substitute_has_global_flag?(String.t()) :: boolean()
  defp substitute_has_global_flag?(input) do
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

  @spec extract_substitute_pattern(String.t()) :: String.t() | nil
  defp extract_substitute_pattern(input) do
    case extract_substitute_parts(input) do
      {pattern, _replacement} -> pattern
      nil -> nil
    end
  end

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

  @spec extract_until_delimiter(String.t(), String.t(), [String.t()]) ::
          {String.t(), String.t()} | nil
  defp extract_until_delimiter("", _delimiter, _acc), do: nil

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

  @spec build_highlight_set(
          [search_match()],
          non_neg_integer(),
          Viewport.t(),
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
end
