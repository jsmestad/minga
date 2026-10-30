defmodule Minga.Buffer.ConflictIndexTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.ConflictIndex
  alias Minga.Buffer.Document
  alias Minga.Buffer.Operation
  alias Minga.Git.MergeConflict

  @conflict_lines [
    "<<<<<<< HEAD",
    "ours",
    "||||||| base",
    "common",
    "=======",
    "theirs",
    ">>>>>>> branch"
  ]

  test "indexes two-way and diff3 conflicts without retaining side text" do
    content =
      Enum.join(
        [
          "before",
          "<<<<<<< HEAD",
          "ours",
          "||||||| base",
          "common",
          "=======",
          "theirs",
          ">>>>>>> branch",
          "after"
        ],
        "\n"
      )

    index = ConflictIndex.new(Document.new(content))

    assert [entry] = ConflictIndex.entries(index)
    assert entry.start_line == 1
    assert entry.base_marker_line == 3
    assert entry.separator_line == 5
    assert entry.end_line == 7
    refute Map.has_key?(Map.from_struct(entry), :current_lines)
    refute Map.has_key?(Map.from_struct(entry), :incoming_lines)

    region = MergeConflict.region_from_entry(content, entry)
    assert region.current_lines == ["ours"]
    assert region.base_lines == ["common"]
    assert region.incoming_lines == ["theirs"]
  end

  test "does not index incomplete or malformed marker blocks" do
    malformed = Document.new("<<<<<<< HEAD\nours\n>>>>>>> branch")
    assert ConflictIndex.entries(ConflictIndex.new(malformed)) == []

    incomplete = Document.new("<<<<<<< HEAD\nours\n=======\ntheirs")
    assert ConflictIndex.entries(ConflictIndex.new(incomplete)) == []
  end

  test "indexes repeated incomplete start markers in linear work" do
    small = Enum.map_join(1..1_000, "\n", &"<<<<<<< incomplete #{&1}")
    large = Enum.map_join(1..10_000, "\n", &"<<<<<<< incomplete #{&1}")

    small_cost = new_index_reductions(small)
    large_cost = new_index_reductions(large)

    assert large_cost <= small_cost * 15
  end

  test "ordinary edits update only conflict data affected by the delta" do
    document = Document.new("before\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\nafter")
    index = ConflictIndex.new(document)

    {document, index} = replace(document, index, {2, 0}, {2, 3}, "mine")
    assert [entry] = ConflictIndex.entries(index)

    assert MergeConflict.region_from_entry(Document.content(document), entry).current_lines == [
             "mine"
           ]

    {document, index} = insert(document, index, {0, 0}, "new\n")
    assert [shifted] = ConflictIndex.entries(index)
    assert shifted.start_line == 2
    assert shifted.end_line == 6

    {_document, index} = replace(document, index, {4, 0}, {4, 6}, "not a separator")
    assert ConflictIndex.entries(index) == []
  end

  test "completing a partially typed marker block creates a conflict" do
    document = Document.new("<<<<<<< HEAD\nours\n=======\ntheirs\nbranch")
    index = ConflictIndex.new(document)
    assert ConflictIndex.count(index) == 0

    {_document, index} = insert(document, index, {4, 0}, ">>>>>>> ")
    assert ConflictIndex.count(index) == 1
  end

  test "an orphan marker split by the gap stays indexed until later edits complete it" do
    for {marker_line, kind} <- [{0, :start}, {2, :base}, {4, :separator}, {6, :end}],
        marker <- [Enum.at(@conflict_lines, marker_line)],
        gap <- orphan_gap_positions(marker_line, marker) do
      lines = List.replace_at(List.duplicate("plain", 7), marker_line, marker)
      document = lines |> Enum.join("\n") |> Document.new() |> Document.move_to(gap)
      assert byte_size(document.before) == gap_offset(lines, gap)
      index = ConflictIndex.new(document)
      assert index == %ConflictIndex{markers: [{marker_line, kind}], entries: []}

      {document, index} =
        0..6
        |> Enum.reject(&(&1 == marker_line))
        |> Enum.reduce({document, index}, fn line, {document, index} ->
          {:edited, next, delta} =
            Operation.replace_lines(document, line, line, Enum.at(@conflict_lines, line))

          {next, ConflictIndex.apply_edit(index, next, delta)}
        end)

      content = Document.content(document)
      assert content == Enum.join(@conflict_lines, "\n")
      assert [entry] = ConflictIndex.entries(index)

      assert {entry.start_line, entry.base_marker_line, entry.separator_line, entry.end_line} ==
               {0, 2, 4, 6}

      assert [MergeConflict.region_from_entry(content, entry)] == MergeConflict.parse(content)
    end
  end

  test "marker prefixes inside lines or split by the gap without a line start are not markers" do
    lines = ["text with <<<<<<< inside", " ||||||| indented", "ends with =======", ">>>>>> short"]
    content = Enum.join(lines, "\n")
    assert MergeConflict.parse(content) == []

    for {text, line} <- Enum.with_index(lines), column <- 0..byte_size(text) do
      document = content |> Document.new() |> Document.move_to({line, column})
      assert byte_size(document.before) == gap_offset(lines, {line, column})
      assert ConflictIndex.new(document) == %ConflictIndex{markers: [], entries: []}
    end
  end

  test "new index on a marker-free document skips per-line marker classification" do
    plain = Enum.map_join(1..20_000, "\n", &"plain line #{&1}")
    {head, tail} = plain |> String.split("\n") |> Enum.split(10_000)
    with_orphan = Enum.join(head ++ [">>>>>>> orphan"] ++ tail, "\n")

    plain_cost = new_index_reductions(plain)
    orphan_cost = new_index_reductions(with_orphan)

    assert plain_cost * 10 < orphan_cost
  end

  test "editing inside a very large conflict retains a lightweight entry" do
    side = Enum.map_join(1..100_000, "\n", &"line #{&1}")
    document = Document.new("<<<<<<< HEAD\n#{side}\n=======\ntheirs\n>>>>>>> branch")
    index = ConflictIndex.new(document)

    {_document, updated} = insert(document, index, {50_000, 0}, "x")

    assert [entry] = ConflictIndex.entries(updated)
    assert entry.end_line == 100_003
    assert :erts_debug.size(updated) < 200
  end

  test "editing inside a conflict does not scale with the conflict body" do
    small = conflict_with_body(100)
    large = conflict_with_body(100_000)

    small_cost = middle_edit_reductions(small, 50)
    large_cost = middle_edit_reductions(large, 50_000)

    assert large_cost <= small_cost * 3 + 500
  end

  test "conflict queries do not scale with document line count" do
    small = ConflictIndex.new(Document.new(conflict_with_padding(100)))
    large = ConflictIndex.new(Document.new(conflict_with_padding(65_000)))

    small_cost = query_reductions(small)
    large_cost = query_reductions(large)

    assert large_cost <= small_cost * 2 + 200
  end

  defp new_index_reductions(content) do
    document = Document.new(content)
    {:reductions, before_count} = Process.info(self(), :reductions)
    index = ConflictIndex.new(document)
    {:reductions, after_count} = Process.info(self(), :reductions)
    assert ConflictIndex.entries(index) == []
    after_count - before_count
  end

  defp middle_edit_reductions(content, line) do
    document = Document.new(content)
    index = ConflictIndex.new(document)
    document = Document.move_to(document, {line, 0})
    {:edited, next_document, delta} = Operation.insert_at_cursor(document, "x")
    # Exclude fixture-construction garbage from the edit-complexity measurement.
    :erlang.garbage_collect()

    {:reductions, before_count} = Process.info(self(), :reductions)
    Enum.each(1..50, fn _ -> ConflictIndex.apply_edit(index, next_document, delta) end)
    {:reductions, after_count} = Process.info(self(), :reductions)
    after_count - before_count
  end

  defp query_reductions(index) do
    {:reductions, before_count} = Process.info(self(), :reductions)

    Enum.each(1..1_000, fn _ ->
      ConflictIndex.count(index)
      ConflictIndex.entries(index)
    end)

    {:reductions, after_count} = Process.info(self(), :reductions)
    after_count - before_count
  end

  defp conflict_with_body(line_count) do
    body = Enum.map_join(1..line_count, "\n", &"line #{&1}")
    "<<<<<<< HEAD\n#{body}\n=======\ntheirs\n>>>>>>> branch"
  end

  defp conflict_with_padding(line_count) do
    padding = Enum.map_join(1..line_count, "\n", &"plain #{&1}")
    padding <> "\n" <> conflict_with_body(1)
  end

  # Every byte boundary of the marker line, plus the boundary before its newline.
  defp orphan_gap_positions(line, marker) do
    before_newline = if line > 0, do: [{line - 1, byte_size("plain")}], else: []
    before_newline ++ for(column <- 0..byte_size(marker), do: {line, column})
  end

  defp gap_offset(lines, {line, column}) do
    lines |> Enum.take(line) |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum() |> Kernel.+(column)
  end

  defp insert(document, index, position, text) do
    document = Document.move_to(document, position)
    {:edited, next_document, delta} = Operation.insert_at_cursor(document, text)
    {next_document, ConflictIndex.apply_edit(index, next_document, delta)}
  end

  defp replace(document, index, from, to, text) do
    {:edited, next_document, delta} = Operation.replace_range(document, from, to, text)
    {next_document, ConflictIndex.apply_edit(index, next_document, delta)}
  end
end
