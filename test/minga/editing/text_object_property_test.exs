defmodule Minga.Editing.TextObjectPropertyTest do
  @moduledoc """
  Property-based tests for text objects.

  Verifies that text object ranges are always within buffer bounds,
  start <= end, and inner ranges are subsets of around ranges.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Editing.TextObject

  import Minga.Test.Generators

  defp assert_range_in_bounds({start_pos, end_pos}, content) do
    lines = String.split(content, "\n")
    line_count = length(lines)

    {sl, sc} = start_pos
    {el, ec} = end_pos

    assert sl >= 0, "start line #{sl} is negative"
    assert sl < line_count, "start line #{sl} >= line_count #{line_count}"
    assert sc >= 0, "start col #{sc} is negative"

    assert sc <= byte_size(Enum.at(lines, sl, "")),
           "start col #{sc} > line length #{byte_size(Enum.at(lines, sl, ""))}"

    assert el >= 0, "end line #{el} is negative"
    assert el < line_count, "end line #{el} >= line_count #{line_count}"
    assert ec >= 0, "end col #{ec} is negative"

    assert ec <= byte_size(Enum.at(lines, el, "")),
           "end col #{ec} > line length #{byte_size(Enum.at(lines, el, ""))}"
  end

  defp assert_start_before_end({start_pos, end_pos}) do
    {sl, sc} = start_pos
    {el, ec} = end_pos

    assert {sl, sc} <= {el, ec},
           "start #{inspect(start_pos)} > end #{inspect(end_pos)}"
  end

  defp assert_inner_within_around(inner_range, around_range) do
    {inner_start, inner_end} = inner_range
    {around_start, around_end} = around_range

    assert inner_start >= around_start,
           "inner start #{inspect(inner_start)} < around start #{inspect(around_start)}"

    assert inner_end <= around_end,
           "inner end #{inspect(inner_end)} > around end #{inspect(around_end)}"
  end

  # ── Word text objects ──────────────────────────────────────────────────

  property "inner_word range is within buffer bounds and start <= end" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      range = TextObject.inner_word(doc, pos)
      assert_range_in_bounds(range, content)
      assert_start_before_end(range)
    end
  end

  property "a_word range is within buffer bounds and start <= end" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      range = TextObject.a_word(doc, pos)
      assert_range_in_bounds(range, content)
      assert_start_before_end(range)
    end
  end

  property "inner_word range is within a_word range" do
    check all({content, pos} <- content_and_position(), max_runs: 200) do
      doc = Document.new(content)
      inner = TextObject.inner_word(doc, pos)
      around = TextObject.a_word(doc, pos)
      assert_inner_within_around(inner, around)
    end
  end

  # ── Quote text objects ─────────────────────────────────────────────────

  # Generate alphanumeric strings that won't contain delimiter characters
  defp safe_text(max_len \\ 20) do
    gen all(
          len <- integer(0..max_len),
          chars <-
            list_of(member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9) ++ [?_, ?\s]),
              length: len
            )
        ) do
      List.to_string(chars)
    end
  end

  defp safe_text_nonempty(max_len \\ 20) do
    gen all(
          len <- integer(1..max_len),
          chars <-
            list_of(member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9) ++ [?_, ?\s]),
              length: len
            )
        ) do
      List.to_string(chars)
    end
  end

  property "inner_quotes range is within buffer bounds when cursor is inside quotes" do
    check all(
            before <- safe_text(),
            inside <- safe_text_nonempty(),
            after_text <- safe_text()
          ) do
      content = "#{before}\"#{inside}\"#{after_text}"
      doc = Document.new(content)
      col = byte_size(before) + 1
      pos = {0, col}

      range = TextObject.inner_quotes(doc, pos, "\"")
      assert_range_in_bounds(range, content)
      assert_start_before_end(range)
    end
  end

  property "inner_quotes is within a_quotes when cursor is inside quotes" do
    check all(
            before <- safe_text(),
            inside <- safe_text_nonempty(),
            after_text <- safe_text()
          ) do
      content = "#{before}'#{inside}'#{after_text}"
      doc = Document.new(content)
      col = byte_size(before) + 1
      pos = {0, col}

      inner = TextObject.inner_quotes(doc, pos, "'")
      around = TextObject.a_quotes(doc, pos, "'")
      assert_inner_within_around(inner, around)
    end
  end

  # ── Paren text objects ─────────────────────────────────────────────────

  property "inner_parens range is within buffer bounds when cursor is inside parens" do
    check all(
            before <- safe_text(),
            inside <- safe_text_nonempty(),
            after_text <- safe_text()
          ) do
      content = "#{before}(#{inside})#{after_text}"
      doc = Document.new(content)
      col = byte_size(before) + 1
      pos = {0, col}

      range = TextObject.inner_parens(doc, pos, "(", ")")
      assert_range_in_bounds(range, content)
      assert_start_before_end(range)
    end
  end

  property "inner_parens is within a_parens when cursor is inside parens" do
    check all(
            before <- safe_text(),
            inside <- safe_text_nonempty(),
            after_text <- safe_text()
          ) do
      content = "#{before}[#{inside}]#{after_text}"
      doc = Document.new(content)
      col = byte_size(before) + 1
      pos = {0, col}

      inner = TextObject.inner_parens(doc, pos, "[", "]")
      around = TextObject.a_parens(doc, pos, "[", "]")
      assert_inner_within_around(inner, around)
    end
  end
end
