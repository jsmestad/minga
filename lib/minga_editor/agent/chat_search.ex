defmodule MingaEditor.Agent.ChatSearch do
  @moduledoc """
  Search through agent chat messages.

  Finds matches across all message types (user, assistant, thinking,
  tool results, system) and returns match positions as
  `{message_index, col_start, col_end}` tuples.
  """

  alias MingaAgent.Message

  @typedoc "A search match: message index, byte start, byte end."
  @type match :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  Finds all occurrences of `query` in the given messages.

  Returns a list of `{message_index, col_start, col_end}` tuples sorted
  by message index, then by position within the message. The search is
  case-insensitive by default; append `\\C` to the query for case-sensitive.
  """
  @spec find_matches([Message.t()], String.t()) :: [match()]
  def find_matches(_messages, ""), do: []

  def find_matches(messages, query) do
    {pattern, case_sensitive} = parse_query(query)

    if pattern == "" do
      []
    else
      messages
      |> Enum.with_index()
      |> Enum.flat_map(fn {msg, idx} ->
        text = Message.text(msg)
        find_in_text(text, pattern, idx, case_sensitive)
      end)
    end
  end

  @doc """
  Returns the message index of the match at the given position.

  Useful for scrolling the chat to the matched message.
  """
  @spec match_message_index(match()) :: non_neg_integer()
  def match_message_index({msg_idx, _start, _end}), do: msg_idx

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec parse_query(String.t()) :: {String.t(), boolean()}
  defp parse_query(query) do
    if String.ends_with?(query, "\\C") do
      {String.slice(query, 0..-3//1), true}
    else
      {query, false}
    end
  end

  @spec find_in_text(String.t(), String.t(), non_neg_integer(), boolean()) :: [match()]
  defp find_in_text(text, pattern, msg_idx, case_sensitive) do
    {search_text, search_pattern} =
      if case_sensitive do
        {text, pattern}
      else
        {String.downcase(text), String.downcase(pattern)}
      end

    pattern_len = String.length(search_pattern)
    find_all(search_text, search_pattern, pattern_len, msg_idx, 0, [])
  end

  @spec find_all(
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [match()]
        ) :: [match()]
  defp find_all(text, pattern, pattern_len, msg_idx, offset, acc) do
    case :binary.match(text, pattern) do
      :nomatch ->
        Enum.reverse(acc)

      {pos, _len} ->
        abs_pos = offset + pos
        match = {msg_idx, abs_pos, abs_pos + pattern_len}
        rest = binary_part(text, pos + 1, byte_size(text) - pos - 1)
        find_all(rest, pattern, pattern_len, msg_idx, abs_pos + 1, [match | acc])
    end
  end
end
