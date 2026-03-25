defmodule Minga.Editor.Renderer.SearchHighlight do
  @moduledoc """
  Search match computation, substitute preview, and pattern extraction.

  Match positions are computed here. Rendering is handled by the
  decoration system: search matches become highlight range decorations
  in `ContentHelpers.maybe_update_search_decorations/4`.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Search.Match

  @typedoc "A search match with buffer position and length."
  @type search_match :: Match.t()

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Applies a live substitute preview when the user is typing `:%s/pat/repl`."
  @spec maybe_substitute_preview(state(), [String.t()], non_neg_integer()) ::
          {[String.t()], [search_match()]}
  def maybe_substitute_preview(
        %EditorState{workspace: %{vim: %{mode: :command, mode_state: %Minga.Mode.CommandState{input: input}}}},
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

      matches = Enum.map(spans, fn {col, len} -> Match.new(line_num, col, len) end)
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
  defp active_search_pattern(%EditorState{
         workspace: %{vim: %{mode: :search, mode_state: %Minga.Mode.SearchState{input: input}}}
       })
       when input != "" do
    input
  end

  defp active_search_pattern(%EditorState{
         workspace: %{vim: %{mode: :command, mode_state: %Minga.Mode.CommandState{input: input}}}
       }) do
    extract_substitute_pattern(input)
  end

  defp active_search_pattern(%EditorState{
         workspace: %{
           vim: %{
             mode: :substitute_confirm,
             mode_state: %Minga.Mode.SubstituteConfirmState{pattern: pattern}
           }
         }
       })
       when pattern != "" do
    pattern
  end

  defp active_search_pattern(%EditorState{workspace: %{search: %{last_pattern: pattern}}})
       when is_binary(pattern) and pattern != "" do
    pattern
  end

  defp active_search_pattern(_state), do: nil

  @doc "Returns the current match being confirmed, or nil."
  @spec current_confirm_match(state()) :: search_match() | nil
  def current_confirm_match(%EditorState{
        workspace: %{
          vim: %{
            mode: :substitute_confirm,
            mode_state: %Minga.Mode.SubstituteConfirmState{} = ms
          }
        }
      }) do
    Enum.at(ms.matches, ms.current)
  end

  def current_confirm_match(_state), do: nil

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
end
