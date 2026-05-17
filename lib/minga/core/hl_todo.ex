defmodule Minga.Core.HlTodo do
  @moduledoc """
  Finds TODO-style comment markers in a single line of text.

  This module is pure Layer 0 logic. It only identifies marker byte ranges; renderers decide how to style those ranges.
  """

  @typedoc "Supported TODO-style marker keyword."
  @type marker_keyword :: :todo | :fixme | :note | :hack | :review | :deprecated

  @typedoc "A keyword match as `{byte_start, byte_end, keyword}`."
  @type match ::
          {byte_start :: non_neg_integer(), byte_end :: non_neg_integer(), marker_keyword()}

  @marker_regex ~r/(^|\s)(#|\/\/|\/\*|%|--)\s*(TODO|FIXME|NOTE|HACK|REVIEW|DEPRECATED)\b/

  @doc "Returns byte ranges for TODO-style keywords immediately following a comment delimiter."
  @spec scan_line(String.t()) :: [match()]
  def scan_line(text) when is_binary(text) do
    @marker_regex
    |> Regex.scan(text, return: :index, capture: :all)
    |> Enum.map(&keyword_match(text, &1))
  end

  @spec keyword_match(String.t(), [{non_neg_integer(), non_neg_integer()}]) :: match()
  defp keyword_match(text, [_whole, _prefix, _delimiter, {start, length}]) do
    keyword = binary_part(text, start, length)
    {start, start + length, keyword_atom(keyword)}
  end

  @spec keyword_atom(String.t()) :: marker_keyword()
  defp keyword_atom("TODO"), do: :todo
  defp keyword_atom("FIXME"), do: :fixme
  defp keyword_atom("NOTE"), do: :note
  defp keyword_atom("HACK"), do: :hack
  defp keyword_atom("REVIEW"), do: :review
  defp keyword_atom("DEPRECATED"), do: :deprecated
end
