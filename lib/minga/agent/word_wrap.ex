defmodule Minga.Agent.WordWrap do
  @moduledoc """
  Word-wraps styled text segments to fit within a maximum column width.

  Takes a list of `{text, style_opts}` segments (as produced by the chat
  renderer) and a maximum width, and returns a list of visual lines where
  each visual line is itself a list of segments. Breaks at word boundaries
  when possible, falling back to character-level breaks for words that
  exceed the width.

  Continuation lines are indented by a configurable amount to visually
  distinguish them from the start of a new logical line.
  """

  @typedoc "A styled text segment: `{text, style_keyword_list}`."
  @type segment :: {String.t(), keyword()}

  @typedoc "A visual line is a list of styled segments."
  @type visual_line :: [segment()]

  @default_indent ""

  @doc """
  Wraps a list of styled segments to fit within `max_width` columns.

  Returns a list of visual lines. The first line uses the full width; subsequent
  (continuation) lines are indented by `indent` (default: 2 spaces).

  If `max_width` is less than 4, segments are returned as-is (no room to wrap).
  """
  @spec wrap_segments([segment()], pos_integer(), String.t()) :: [visual_line()]
  def wrap_segments(segments, max_width, indent \\ @default_indent)

  def wrap_segments(segments, max_width, _indent) when max_width < 4, do: [segments]
  def wrap_segments([], _max_width, _indent), do: [[]]

  def wrap_segments(segments, max_width, indent) do
    total_len = segments |> Enum.map(fn {text, _} -> String.length(text) end) |> Enum.sum()

    if total_len <= max_width do
      [segments]
    else
      # Flatten segments into styled characters, split into words, then wrap
      styled_chars = segments_to_styled_chars(segments)
      words = split_into_words(styled_chars)
      indent_width = String.length(indent)
      lines = layout_words(words, max_width, max_width - indent_width)
      format_lines(lines, indent)
    end
  end

  # ── Internals ───────────────────────────────────────────────────────────────

  # Expands segments into a flat list of `{grapheme, style}` pairs.
  @spec segments_to_styled_chars([segment()]) :: [{String.t(), keyword()}]
  defp segments_to_styled_chars(segments) do
    Enum.flat_map(segments, fn {text, style} ->
      text |> String.graphemes() |> Enum.map(&{&1, style})
    end)
  end

  # Groups styled chars into words (splitting on spaces). Spaces are discarded.
  @spec split_into_words([{String.t(), keyword()}]) :: [[{String.t(), keyword()}]]
  defp split_into_words(chars) do
    chars
    |> Enum.chunk_by(fn {ch, _} -> ch == " " end)
    |> Enum.reject(fn chunk -> match?([{" ", _} | _], chunk) end)
  end

  # Places words onto lines respecting widths. Returns a list of lists of styled chars.
  @spec layout_words([[{String.t(), keyword()}]], pos_integer(), pos_integer()) ::
          [[{String.t(), keyword()}]]
  defp layout_words(words, first_width, cont_width) do
    {completed_lines, current_line, _col, _is_first} =
      Enum.reduce(words, {[], [], 0, true}, fn word, {lines, current, col, is_first} ->
        available = if is_first, do: first_width, else: cont_width
        word_len = length(word)

        cond do
          # Starting a fresh line
          col == 0 and word_len <= available ->
            {lines, word, word_len, is_first}

          col == 0 ->
            # Word longer than the line; break it
            {extra, remainder} = break_at(word, available)
            finish_and_break(lines, extra, remainder, cont_width)

          # Word fits with a space
          col + 1 + word_len <= available ->
            space = [{" ", elem(List.last(current), 1)}]
            {lines, current ++ space ++ word, col + 1 + word_len, is_first}

          # Doesn't fit; start new line
          true ->
            new_lines = [current | lines]
            place_word_on_new_line(new_lines, word, word_len, cont_width)
        end
      end)

    Enum.reverse([current_line | completed_lines])
  end

  @spec place_word_on_new_line(
          [[{String.t(), keyword()}]],
          [{String.t(), keyword()}],
          non_neg_integer(),
          pos_integer()
        ) ::
          {[[{String.t(), keyword()}]], [{String.t(), keyword()}], non_neg_integer(), boolean()}
  defp place_word_on_new_line(lines, word, word_len, cont_width) when word_len <= cont_width do
    {lines, word, word_len, false}
  end

  defp place_word_on_new_line(lines, word, _word_len, cont_width) do
    {extra, remainder} = break_at(word, cont_width)
    finish_and_break(lines, extra, remainder, cont_width)
  end

  # Breaks a list of styled chars at `width`, returning {chunk, rest}.
  @spec break_at([{String.t(), keyword()}], pos_integer()) ::
          {[{String.t(), keyword()}], [{String.t(), keyword()}]}
  defp break_at(chars, width) do
    Enum.split(chars, width)
  end

  # Handles breaking a long word across multiple lines.
  @spec finish_and_break(
          [[{String.t(), keyword()}]],
          [{String.t(), keyword()}],
          [{String.t(), keyword()}],
          pos_integer()
        ) ::
          {[[{String.t(), keyword()}]], [{String.t(), keyword()}], non_neg_integer(), boolean()}
  defp finish_and_break(lines, chunk, [], _cont_width) do
    {[chunk | lines], [], 0, false}
  end

  defp finish_and_break(lines, chunk, remainder, cont_width)
       when length(remainder) <= cont_width do
    {[chunk | lines], remainder, length(remainder), false}
  end

  defp finish_and_break(lines, chunk, remainder, cont_width) do
    {next_chunk, rest} = break_at(remainder, cont_width)
    finish_and_break([chunk | lines], next_chunk, rest, cont_width)
  end

  # Converts styled-char lines back into merged segments, adding indent to continuation lines.
  @spec format_lines([[{String.t(), keyword()}]], String.t()) :: [visual_line()]
  defp format_lines(lines, indent) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {styled_chars, idx} ->
      merged = merge_styled_chars(styled_chars)

      if idx == 0 do
        merged
      else
        [{indent, []} | merged]
      end
    end)
    |> Enum.reject(&(&1 == []))
    |> case do
      [] -> [[]]
      result -> result
    end
  end

  # Merges consecutive styled chars with the same style back into segments.
  @spec merge_styled_chars([{String.t(), keyword()}]) :: [segment()]
  defp merge_styled_chars([]), do: []

  defp merge_styled_chars([{t1, style}, {t2, style} | rest]) do
    merge_styled_chars([{t1 <> t2, style} | rest])
  end

  defp merge_styled_chars([{text, style} | rest]) do
    [{text, style} | merge_styled_chars(rest)]
  end
end
