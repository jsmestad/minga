defmodule MingaEditor.Agent.ChatSearch do
  @moduledoc """
  Search through agent chat messages.

  Finds matches across all message types (user, assistant, thinking,
  tool results, system) and returns match positions as
  `{message_id, col_start, col_end}` tuples in display order.
  """

  alias MingaAgent.Message
  alias MingaEditor.Agent.UIState.TranscriptProjection.Index

  @typedoc "A search match: stable message ID, byte start, byte end."
  @type match :: {pos_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  Finds all occurrences of `query` in the given messages.

  Returns `{message_id, col_start, col_end}` tuples in display order,
  then by position within each message. The search is
  case-insensitive by default; append `\\C` to the query for case-sensitive.
  """
  @spec find_matches([Index.item()], String.t()) :: [match()]
  def find_matches(_messages, ""), do: []

  def find_matches(messages, query) do
    {pattern, case_sensitive} = parse_query(query)

    if pattern == "" do
      []
    else
      search_pattern = normalize_case(pattern, case_sensitive)
      pattern_len = byte_size(search_pattern)

      messages
      |> Enum.flat_map(fn {id, msg, _style} ->
        search_text = msg |> Message.text() |> normalize_case(case_sensitive)
        find_all(search_text, search_pattern, pattern_len, id, 0, [])
      end)
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec parse_query(String.t()) :: {String.t(), boolean()}
  defp parse_query(query) do
    if String.ends_with?(query, "\\C") do
      {String.slice(query, 0..-3//1), true}
    else
      {query, false}
    end
  end

  @spec normalize_case(String.t(), boolean()) :: String.t()
  defp normalize_case(text, true), do: text
  defp normalize_case(text, false), do: String.downcase(text)

  @spec find_all(
          String.t(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          [match()]
        ) :: [match()]
  defp find_all(text, pattern, pattern_len, id, offset, acc) do
    case :binary.match(text, pattern) do
      :nomatch ->
        Enum.reverse(acc)

      {pos, _len} ->
        abs_pos = offset + pos
        match = {id, abs_pos, abs_pos + pattern_len}
        rest = binary_part(text, pos + 1, byte_size(text) - pos - 1)
        find_all(rest, pattern, pattern_len, id, abs_pos + 1, [match | acc])
    end
  end
end
