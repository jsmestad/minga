defmodule Minga.Buffer.ConflictIndexTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.ConflictIndex
  alias Minga.Buffer.Document
  alias Minga.Buffer.Operation
  alias Minga.Git.MergeConflict

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
