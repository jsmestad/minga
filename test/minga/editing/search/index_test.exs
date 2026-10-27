defmodule Minga.Editing.Search.IndexTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.EditDelta
  alias Minga.Editing.Search
  alias Minga.Editing.Search.Index

  describe "build/3" do
    test "matches the existing literal and regex implementation" do
      lines = ["zero foo", "FOO one foo", "two 123 456", "foo"]

      for {query, options} <- [
            {"foo", []},
            {"foo", [case_sensitive: false]},
            {"\\d+", [regex: true]}
          ] do
        expected = Search.find_all_in_range(lines, query, 0, options)
        assert Index.to_matches(Index.build(lines, query, options)) == expected
      end
    end

    test "counts beyond the old u16 wire limit exactly" do
      index = Index.build(List.duplicate("x", 70_000), "x")
      assert Index.count(index) == 70_000
      assert Index.current_ordinal(index, {65_535, 0}) == 65_536
    end

    test "indexes more than 65,535 matches on one line for rank and navigation" do
      match_count = 70_000
      middle_col = 65_535 * 2
      previous_col = 65_534 * 2
      last_col = (match_count - 1) * 2
      index = Index.build([String.duplicate("x ", match_count)], "x")

      assert Index.count(index) == match_count
      assert Index.current_ordinal(index, {0, 0}) == 1
      assert Index.current_ordinal(index, {0, middle_col}) == 65_536
      assert Index.current_ordinal(index, {0, last_col}) == match_count
      assert Index.current_ordinal(index, {0, last_col + 1}) == 1

      assert %{line: 0, col: ^middle_col} =
               Index.next(index, {0, previous_col}, :forward)

      assert %{line: 0, col: ^previous_col} =
               Index.next(index, {0, middle_col}, :backward)

      assert %{line: 0, col: ^last_col, length: 1} = Index.match_at(index, {0, last_col})
      assert Index.match_at(index, {0, last_col - 1}) == nil
    end
  end

  describe "navigation" do
    setup do
      {:ok, index: Index.build(["foo foo", "none", "foo"], "foo")}
    end

    test "moves forward and backward with wraparound", %{index: index} do
      assert %{line: 0, col: 4} = Index.next(index, {0, 0}, :forward)
      assert %{line: 2, col: 0} = Index.next(index, {0, 4}, :forward)
      assert %{line: 0, col: 0} = Index.next(index, {2, 0}, :forward)
      assert %{line: 2, col: 0} = Index.next(index, {0, 0}, :backward)
      assert %{line: 0, col: 4} = Index.next(index, {2, 0}, :backward)
    end

    test "reports current ordinal and exact matches", %{index: index} do
      assert Index.current_ordinal(index, {0, 0}) == 1
      assert Index.current_ordinal(index, {0, 1}) == 2
      assert Index.current_ordinal(index, {2, 1}) == 1
      assert %{length: 3} = Index.match_at(index, {0, 4})
      assert Index.match_at(index, {0, 1}) == nil
    end
  end

  describe "matches_in_range/3" do
    test "returns ordered matches only from the inclusive line range" do
      index = Index.build(["foo foo", "foo", "none", "foo foo"], "foo")

      assert Enum.map(Index.matches_in_range(index, 1, 3), &{&1.line, &1.col}) == [
               {1, 0},
               {3, 0},
               {3, 4}
             ]
    end

    test "visits logarithmic nodes plus the dense requested result" do
      index = Index.build(List.duplicate("foo", 10_000), "foo")

      {matches, metrics} = Index.matches_in_range_with_metrics(index, 5_000, 5_000)

      assert Enum.map(matches, &{&1.line, &1.col}) == [{5_000, 0}]
      assert metrics.returned_matches == 1
      assert metrics.visited_nodes < 100
    end
  end

  describe "apply_edits/4" do
    test "updates one line without rescanning an unchanged suffix" do
      index = Index.build(["foo", "none", "foo", "foo"], "foo")

      delta =
        EditDelta.replacement(4, 8, {1, 0}, {1, 4}, "foo", {1, 3})

      updated = Index.apply_edits(index, [delta], 1, ["foo"])

      assert Enum.map(Index.to_matches(updated), &{&1.line, &1.col}) == [
               {0, 0},
               {1, 0},
               {2, 0},
               {3, 0}
             ]

      assert Index.metrics(updated).updated_lines == 1
      assert Index.metrics(updated).scanned_lines == 5
    end

    test "insertion near the start shifts the retained suffix lazily" do
      index = Index.build(["foo", "foo", "foo"], "foo")
      delta = EditDelta.insertion(0, {0, 0}, "new\n", {1, 0})

      updated = Index.apply_edits(index, [delta], 0, ["new", "foo"])

      assert Enum.map(Index.to_matches(updated), &{&1.line, &1.col}) == [
               {1, 0},
               {2, 0},
               {3, 0}
             ]

      assert Index.metrics(updated).updated_lines == 2
      assert Index.metrics(updated).suffix_shifts == 1
    end

    test "newline deletion removes merged lines and shifts the suffix" do
      index = Index.build(["foo", "foo", "foo"], "foo")
      delta = EditDelta.deletion(3, 4, {0, 3}, {1, 0})

      updated = Index.apply_edits(index, [delta], 0, ["foofoo"])

      assert Enum.map(Index.to_matches(updated), &{&1.line, &1.col}) == [
               {0, 0},
               {0, 3},
               {1, 0}
             ]
    end

    test "a batch agrees with a fresh search" do
      original = ["foo", "bar", "foo", "tail"]
      index = Index.build(original, "foo")

      first = EditDelta.insertion(3, {0, 3}, "\nfoo", {1, 3})
      second = EditDelta.replacement(8, 11, {2, 0}, {2, 3}, "none", {2, 4})
      current = ["foo", "foo", "bar", "none", "tail"]
      updated = Index.apply_edits(index, [first, second], 0, current)

      assert Index.to_matches(updated) == Search.find_all_in_range(current, "foo", 0)
    end
  end

  describe "bulk construction" do
    property "a fresh build satisfies treap invariants and answers every query like a naive scan" do
      check all(lines <- document(), {query, options} <- query()) do
        index = Index.build(lines, query, options)

        assert_treap(index.root)
        assert lazy_offsets(index.root) == []
        assert_queries(index, lines, query, options)
      end
    end

    property "edit sequences agree with a fresh search, including rebuilds of an emptied index" do
      check all(
              lines <- document(),
              {query, options} <- query(),
              edits <- list_of(edit(), max_length: 8)
            ) do
        index = Index.build(lines, query, options)

        Enum.reduce(edits, {index, lines}, fn edit, {index, lines} ->
          {delta, first_line, replacement, current} = apply_model_edit(lines, edit)
          updated = Index.apply_edits(index, [delta], first_line, replacement)

          assert_treap(updated.root)
          assert_queries(updated, current, query, options)
          {updated, current}
        end)
      end
    end

    test "an edit that removes every match rebuilds from an empty tree" do
      index = Index.build(["foo", "foo foo", "bar"], "foo")
      delta = EditDelta.replacement(0, 15, {0, 0}, {2, 3}, "", {1, 0})
      current = ["none", "foo é foo"]
      updated = Index.apply_edits(index, [delta], 0, current)

      assert_treap(updated.root)
      assert lazy_offsets(updated.root) == []
      assert Index.to_matches(updated) == Search.find_all_in_range(current, "foo", 0)
      assert updated.next_priority == index.next_priority + 1
    end
  end

  defp document do
    line =
      one_of([
        constant(""),
        string([?b, ?\s], max_length: 10),
        list_of(member_of(["a", "b", "é", "日", " ", "aa"]), max_length: 10)
        |> map(&Enum.join/1)
      ])

    list_of(line, min_length: 1, max_length: 25)
  end

  defp query do
    member_of([
      {"a", []},
      {"aa", []},
      {"A", [case_sensitive: false]},
      {"é", []},
      {"日 a", []},
      {"a", [whole_word: true]},
      {"a+", [regex: true]},
      {"z", []},
      {"", []}
    ])
  end

  defp edit do
    tuple({
      integer(0..30),
      integer(0..4),
      list_of(member_of(["", "a", "aa a", "b", "é a", "日 a"]), min_length: 1, max_length: 4)
    })
  end

  # Replaces current lines `first..last` with `replacement`, shifting the suffix
  # by the line-count difference.
  defp apply_model_edit(lines, {start, span, replacement}) do
    first_line = rem(start, length(lines))
    last_line = min(first_line + span, length(lines) - 1)
    new_last_line = first_line + length(replacement) - 1
    current = Enum.take(lines, first_line) ++ replacement ++ Enum.drop(lines, last_line + 1)
    delta = EditDelta.replacement(0, 0, {first_line, 0}, {last_line, 0}, "", {new_last_line, 0})

    {delta, first_line, replacement, current}
  end

  # Probes every match start, its neighbouring columns, and each line's edges,
  # including a line past the end of the document.
  defp assert_queries(index, lines, query, options) do
    expected = Search.find_all_in_range(lines, query, 0, options)
    reversed = Enum.reverse(expected)
    positions = Enum.map(expected, &{&1.line, &1.col})

    edges =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {text, line} -> [{line, 0}, {line, byte_size(text) + 1}] end)

    neighbours =
      Enum.flat_map(positions, fn {line, col} -> [{line, col - 1}, {line, col + 1}] end)

    cursors =
      [{length(lines), 0} | edges ++ positions ++ neighbours]
      |> Enum.reject(fn {_line, col} -> col < 0 end)
      |> Enum.uniq()

    assert Index.to_matches(index) == expected
    assert Index.count(index) == length(expected)

    for cursor <- cursors do
      expected_ordinal = expected_ordinal(positions, cursor)

      assert Index.current_ordinal(index, cursor) == expected_ordinal

      assert Index.next(index, cursor, :forward) ==
               (Enum.find(expected, &({&1.line, &1.col} > cursor)) || List.first(expected))

      assert Index.next(index, cursor, :backward) ==
               (Enum.find(reversed, &({&1.line, &1.col} < cursor)) || List.first(reversed))

      assert Index.match_at(index, cursor) ==
               Enum.find(expected, &({&1.line, &1.col} == cursor))
    end

    for first <- 0..length(lines), last <- first..length(lines) do
      assert Index.matches_in_range(index, first, last) ==
               Enum.filter(expected, &(&1.line in first..last))
    end
  end

  defp expected_ordinal([], _cursor), do: 0

  defp expected_ordinal(positions, cursor) do
    case Enum.find_index(positions, &(&1 >= cursor)) do
      nil -> 1
      rank -> rank + 1
    end
  end

  # Checks priority order, unique in-order lines, and cached counts after resolving lazy offsets.
  defp assert_treap(root) do
    {_count, lines} = walk_treap(root, 0, nil, [])
    lines = Enum.reverse(lines)
    assert lines == lines |> Enum.uniq() |> Enum.sort()
  end

  defp walk_treap(nil, _pending, _parent_priority, acc), do: {0, acc}

  defp walk_treap({line, matches, priority, left, right, lazy, count}, pending, parent, acc) do
    assert parent == nil or parent <= priority
    assert tuple_size(matches) > 0

    {left_count, acc} = walk_treap(left, pending + lazy, priority, acc)
    acc = [line + pending | acc]
    {right_count, acc} = walk_treap(right, pending + lazy, priority, acc)

    assert count == tuple_size(matches) + left_count + right_count
    {count, acc}
  end

  defp lazy_offsets(nil), do: []

  defp lazy_offsets({_line, _matches, _priority, left, right, lazy, _count}) do
    offsets = lazy_offsets(left) ++ lazy_offsets(right)
    if lazy == 0, do: offsets, else: [lazy | offsets]
  end
end
