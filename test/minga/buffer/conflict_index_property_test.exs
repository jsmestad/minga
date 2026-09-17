defmodule Minga.Buffer.ConflictIndexPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.{ConflictIndex, Document, Lines, Operation}
  alias Minga.Git.MergeConflict

  property "marker indexing preserves the full parser's interpretation of malformed and nested blocks" do
    check all(lines <- marker_lines()) do
      document = Document.new(Enum.join(lines, "\n"))
      assert_matches_parser(document, ConflictIndex.new(document))
    end
  end

  property "inserting and replacing lines preserves conflict interpretation after every edit" do
    check all(
            lines <- marker_lines(),
            operations <- StreamData.list_of(edit(), min_length: 1, max_length: 25)
          ) do
      document = Document.new(Enum.join(lines, "\n"))
      index = ConflictIndex.new(document)

      Enum.reduce(operations, {document, index}, fn operation, {document, index} ->
        {:edited, updated, delta} = apply_edit(document, operation)
        index = ConflictIndex.apply_edit(index, updated, delta)
        assert_matches_parser(updated, index)
        {updated, index}
      end)
    end
  end

  defp marker_lines do
    StreamData.list_of(line(), max_length: 45)
  end

  defp line do
    StreamData.member_of([
      "<<<<<<< HEAD",
      "<<<<<<<< nested",
      "||||||| base",
      "=======",
      "======== separator",
      ">>>>>>> branch",
      "<<<<<<<",
      "|||||||",
      ">>>>>>>",
      "<<<<<< partial",
      "====== partial",
      " ||||||| indented",
      "text with <<<<<<< inside",
      "café 世界",
      "",
      "normal line"
    ])
  end

  defp edit do
    StreamData.tuple({
      StreamData.member_of([:insert_start, :insert_end, :replace_lines]),
      StreamData.integer(0..100),
      StreamData.integer(0..100),
      StreamData.map(StreamData.list_of(line(), max_length: 4), &Enum.join(&1, "\n"))
    })
  end

  defp apply_edit(document, {:replace_lines, first, last, text}) do
    count = Document.line_count(document)
    first = rem(first, count)
    last = rem(last, count)
    Operation.replace_lines(document, min(first, last), max(first, last), text)
  end

  defp apply_edit(document, {:insert_start, line, _unused, text}) do
    document
    |> Document.move_to({rem(line, Document.line_count(document)), 0})
    |> Operation.insert_at_cursor(text)
  end

  defp apply_edit(document, {:insert_end, line, _unused, text}) do
    line = rem(line, Document.line_count(document))
    column = byte_size(Lines.fetch(document, line))

    document
    |> Document.move_to({line, column})
    |> Operation.insert_at_cursor(text)
  end

  defp assert_matches_parser(document, index) do
    content = Document.content(document)
    expected = MergeConflict.parse(content)
    actual = Enum.map(ConflictIndex.entries(index), &MergeConflict.region_from_entry(content, &1))
    assert actual == expected
    assert ConflictIndex.count(index) == length(expected)
  end
end
