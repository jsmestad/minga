defmodule Minga.Buffer.ConflictIndexPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.{ConflictIndex, Document, Lines, Operation}
  alias Minga.Git.MergeConflict

  property "marker indexing preserves the full parser's interpretation of malformed and nested blocks" do
    check all(lines <- marker_lines(), gap <- gap()) do
      document = lines |> Enum.join("\n") |> Document.new() |> place_gap(gap)
      assert_matches_parser(document, ConflictIndex.new(document))
    end
  end

  property "inserting and replacing lines preserves conflict interpretation after every edit" do
    check all(
            lines <- marker_lines(),
            gap <- gap(),
            operations <- StreamData.list_of(edit(), min_length: 1, max_length: 25)
          ) do
      document = lines |> Enum.join("\n") |> Document.new() |> place_gap(gap)
      index = ConflictIndex.new(document)

      Enum.reduce(operations, {document, index}, fn operation, {document, index} ->
        {:edited, updated, delta} = apply_edit(document, operation)
        index = ConflictIndex.apply_edit(index, updated, delta)
        assert_matches_parser(updated, index)
        {updated, index}
      end)
    end
  end

  property "documents without line-start markers index exactly like a marker-free parse" do
    check all(lines <- StreamData.list_of(non_marker_line(), max_length: 45), gap <- gap()) do
      document = lines |> Enum.join("\n") |> Document.new() |> place_gap(gap)
      index = ConflictIndex.new(document)
      assert index == %ConflictIndex{markers: [], entries: []}
      assert_matches_parser(document, index)
    end
  end

  defp marker_lines do
    StreamData.list_of(line(), max_length: 45)
  end

  defp non_marker_line do
    StreamData.member_of([
      "<<<<<< partial",
      "====== partial",
      " ||||||| indented",
      "\t>>>>>>> tabbed",
      "text with <<<<<<< inside",
      "ends with =======",
      "café 世界",
      "",
      "normal line"
    ])
  end

  defp gap do
    StreamData.tuple({StreamData.integer(0..100), StreamData.integer(0..100)})
  end

  # Moves the gap to a codepoint boundary so `before`/`after` can split any marker.
  defp place_gap(document, {line_seed, column_seed}) do
    line = rem(line_seed, Document.line_count(document))
    boundaries = document |> Lines.fetch(line) |> codepoint_boundaries()
    Document.move_to(document, {line, Enum.at(boundaries, rem(column_seed, length(boundaries)))})
  end

  defp codepoint_boundaries(text) do
    text
    |> String.codepoints()
    |> Enum.scan(0, &(byte_size(&1) + &2))
    |> then(&[0 | &1])
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
