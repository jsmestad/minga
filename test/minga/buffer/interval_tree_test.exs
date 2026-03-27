defmodule Minga.Core.IntervalTreeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Core.IntervalTree

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp make_interval(start_pos, end_pos, value \\ nil) do
    %{id: make_ref(), start: start_pos, end_: end_pos, value: value}
  end

  defp make_interval_with_id(id, start_pos, end_pos, value \\ nil) do
    %{id: id, start: start_pos, end_: end_pos, value: value}
  end

  # ── Generators ─────────────────────────────────────────────────────────

  defp position_gen(max_line, max_col) do
    gen all(
          line <- integer(0..max_line),
          col <- integer(0..max_col)
        ) do
      {line, col}
    end
  end

  defp interval_gen(max_line, max_col) do
    gen all(
          start_line <- integer(0..max_line),
          start_col <- integer(0..max_col),
          end_line <- integer(start_line..max_line),
          end_col <- integer(0..max_col)
        ) do
      start_pos = {start_line, start_col}
      end_pos = {end_line, end_col}

      # Ensure start < end
      if start_pos < end_pos do
        make_interval(start_pos, end_pos)
      else
        make_interval(start_pos, {end_line + 1, end_col})
      end
    end
  end

  defp interval_list_gen(max_count, max_line, max_col) do
    gen all(intervals <- list_of(interval_gen(max_line, max_col), max_length: max_count)) do
      intervals
    end
  end

  # ── Construction ─────────────────────────────────────────────────────────

  describe "new/0" do
    test "creates an empty tree" do
      tree = IntervalTree.new()
      assert IntervalTree.empty?(tree)
      assert IntervalTree.size(tree) == 0
      assert IntervalTree.to_list(tree) == []
    end
  end

  describe "from_list/1" do
    test "builds from empty list" do
      tree = IntervalTree.from_list([])
      assert IntervalTree.empty?(tree)
    end

    test "builds from single interval" do
      interval = make_interval({0, 0}, {5, 0})
      tree = IntervalTree.from_list([interval])
      assert IntervalTree.size(tree) == 1
      assert [^interval] = IntervalTree.to_list(tree)
    end

    test "builds from multiple intervals" do
      intervals = [
        make_interval({0, 0}, {3, 0}),
        make_interval({5, 0}, {8, 0}),
        make_interval({10, 0}, {15, 0})
      ]

      tree = IntervalTree.from_list(intervals)
      assert IntervalTree.size(tree) == 3

      result = IntervalTree.to_list(tree)
      assert length(result) == 3
      assert Enum.sort_by(result, & &1.start) == Enum.sort_by(intervals, & &1.start)
    end

    test "builds balanced tree from many intervals" do
      intervals = for i <- 0..99, do: make_interval({i, 0}, {i + 1, 0})
      tree = IntervalTree.from_list(intervals)
      assert IntervalTree.size(tree) == 100

      # Tree height should be O(log n), not O(n)
      # For 100 nodes, AVL height should be at most ~8 (ceil(1.44 * log2(100+2)))
      assert tree.height <= 10
    end
  end

  # ── Insert ───────────────────────────────────────────────────────────────

  describe "insert/2" do
    test "inserts into empty tree" do
      interval = make_interval({0, 0}, {5, 0})
      tree = IntervalTree.new() |> IntervalTree.insert(interval)

      assert IntervalTree.size(tree) == 1
      refute IntervalTree.empty?(tree)
    end

    test "inserts multiple intervals maintaining AVL balance" do
      tree =
        Enum.reduce(0..49, IntervalTree.new(), fn i, t ->
          IntervalTree.insert(t, make_interval({i, 0}, {i + 5, 0}))
        end)

      assert IntervalTree.size(tree) == 50
      assert tree.height <= 8
    end

    test "inserts in reverse order maintains balance" do
      tree =
        Enum.reduce(49..0//-1, IntervalTree.new(), fn i, t ->
          IntervalTree.insert(t, make_interval({i, 0}, {i + 5, 0}))
        end)

      assert IntervalTree.size(tree) == 50
      assert tree.height <= 8
    end

    test "updates max_end correctly" do
      i1 = make_interval({0, 0}, {5, 0})
      i2 = make_interval({1, 0}, {20, 0})
      i3 = make_interval({10, 0}, {12, 0})

      tree =
        IntervalTree.new()
        |> IntervalTree.insert(i1)
        |> IntervalTree.insert(i2)
        |> IntervalTree.insert(i3)

      # The root's max_end should be {20, 0} (from i2)
      assert tree.max_end == {20, 0}
    end
  end

  # ── Delete ───────────────────────────────────────────────────────────────

  describe "delete/2" do
    test "deletes from empty tree returns empty" do
      tree = IntervalTree.delete(nil, make_ref())
      assert IntervalTree.empty?(tree)
    end

    test "deletes the only interval" do
      id = make_ref()
      interval = make_interval_with_id(id, {0, 0}, {5, 0})
      tree = IntervalTree.from_list([interval])

      tree = IntervalTree.delete(tree, id)
      assert IntervalTree.empty?(tree)
    end

    test "deletes a specific interval by ID" do
      id1 = make_ref()
      id2 = make_ref()
      id3 = make_ref()

      intervals = [
        make_interval_with_id(id1, {0, 0}, {3, 0}, :first),
        make_interval_with_id(id2, {5, 0}, {8, 0}, :second),
        make_interval_with_id(id3, {10, 0}, {15, 0}, :third)
      ]

      tree = IntervalTree.from_list(intervals)
      tree = IntervalTree.delete(tree, id2)

      assert IntervalTree.size(tree) == 2
      values = tree |> IntervalTree.to_list() |> Enum.map(& &1.value) |> Enum.sort()
      assert values == [:first, :third]
    end

    test "delete of non-existent ID is a no-op" do
      interval = make_interval({0, 0}, {5, 0})
      tree = IntervalTree.from_list([interval])

      tree2 = IntervalTree.delete(tree, make_ref())
      assert IntervalTree.size(tree2) == 1
    end

    test "deleting maintains AVL balance" do
      intervals = for i <- 0..19, do: make_interval({i, 0}, {i + 1, 0})
      tree = IntervalTree.from_list(intervals)

      # Delete every other interval
      tree =
        intervals
        |> Enum.take_every(2)
        |> Enum.reduce(tree, fn iv, t -> IntervalTree.delete(t, iv.id) end)

      assert IntervalTree.size(tree) == 10
      assert tree.height <= 6
    end

    test "deleting updates max_end correctly" do
      id_big = make_ref()

      intervals = [
        make_interval({0, 0}, {5, 0}),
        make_interval_with_id(id_big, {1, 0}, {100, 0}),
        make_interval({2, 0}, {10, 0})
      ]

      tree = IntervalTree.from_list(intervals)
      assert tree.max_end == {100, 0}

      tree = IntervalTree.delete(tree, id_big)
      assert tree.max_end == {10, 0}
    end
  end

  # ── Range query ──────────────────────────────────────────────────────────

  describe "query/3" do
    test "empty tree returns empty" do
      assert IntervalTree.query(nil, {0, 0}, {10, 0}) == []
    end

    test "finds overlapping intervals" do
      intervals = [
        make_interval({0, 0}, {5, 0}, :a),
        make_interval({3, 0}, {8, 0}, :b),
        make_interval({10, 0}, {15, 0}, :c),
        make_interval({20, 0}, {25, 0}, :d)
      ]

      tree = IntervalTree.from_list(intervals)

      # Query [2, 6) should match :a (ends at 5 > 2, starts at 0 < 6)
      # and :b (ends at 8 > 2, starts at 3 < 6)
      results = IntervalTree.query(tree, {2, 0}, {6, 0})
      values = Enum.map(results, & &1.value) |> Enum.sort()
      assert values == [:a, :b]
    end

    test "query with no matches returns empty" do
      intervals = [
        make_interval({0, 0}, {5, 0}),
        make_interval({10, 0}, {15, 0})
      ]

      tree = IntervalTree.from_list(intervals)
      assert IntervalTree.query(tree, {6, 0}, {9, 0}) == []
    end

    test "query at exact boundary (exclusive end)" do
      interval = make_interval({5, 0}, {10, 0}, :target)
      tree = IntervalTree.from_list([interval])

      # Query ending at interval start should not match (exclusive end)
      assert IntervalTree.query(tree, {0, 0}, {5, 0}) == []

      # Query starting at interval end should not match
      assert IntervalTree.query(tree, {10, 0}, {15, 0}) == []

      # Query barely overlapping should match
      results = IntervalTree.query(tree, {4, 0}, {6, 0})
      assert length(results) == 1
      assert hd(results).value == :target
    end

    test "query finds intervals completely contained within query range" do
      inner = make_interval({5, 0}, {8, 0}, :inner)
      tree = IntervalTree.from_list([inner])

      results = IntervalTree.query(tree, {0, 0}, {20, 0})
      assert length(results) == 1
      assert hd(results).value == :inner
    end

    test "query finds intervals that completely contain the query range" do
      outer = make_interval({0, 0}, {20, 0}, :outer)
      tree = IntervalTree.from_list([outer])

      results = IntervalTree.query(tree, {5, 0}, {8, 0})
      assert length(results) == 1
      assert hd(results).value == :outer
    end

    test "query with column-level precision" do
      interval = make_interval({5, 10}, {5, 30}, :same_line)
      tree = IntervalTree.from_list([interval])

      # Before the interval on the same line
      assert IntervalTree.query(tree, {5, 0}, {5, 10}) == []

      # Overlapping
      results = IntervalTree.query(tree, {5, 15}, {5, 20})
      assert length(results) == 1

      # After the interval on the same line
      assert IntervalTree.query(tree, {5, 30}, {5, 40}) == []
    end
  end

  describe "query_lines/3" do
    test "finds all intervals touching a line range" do
      intervals = [
        make_interval({0, 0}, {3, 0}, :a),
        make_interval({5, 10}, {5, 30}, :b),
        make_interval({8, 0}, {12, 0}, :c),
        make_interval({20, 0}, {25, 0}, :d)
      ]

      tree = IntervalTree.from_list(intervals)

      # Lines 4-9 should match :b (line 5) and :c (starts line 8)
      results = IntervalTree.query_lines(tree, 4, 9)
      values = Enum.map(results, & &1.value) |> Enum.sort()
      assert values == [:b, :c]
    end

    test "single line query" do
      interval = make_interval({5, 0}, {5, 20}, :target)
      tree = IntervalTree.from_list([interval])

      results = IntervalTree.query_lines(tree, 5, 5)
      assert length(results) == 1
    end

    test "multi-line interval found by any line in its range" do
      interval = make_interval({5, 0}, {10, 0}, :spanning)
      tree = IntervalTree.from_list([interval])

      # Query line 7 (middle of the interval)
      results = IntervalTree.query_lines(tree, 7, 7)
      assert length(results) == 1
      assert hd(results).value == :spanning
    end
  end

  # ── Stabbing query ──────────────────────────────────────────────────────

  describe "stabbing/2" do
    test "empty tree returns empty" do
      assert IntervalTree.stabbing(nil, {5, 0}) == []
    end

    test "finds intervals containing a point" do
      intervals = [
        make_interval({0, 0}, {10, 0}, :a),
        make_interval({3, 0}, {7, 0}, :b),
        make_interval({12, 0}, {15, 0}, :c)
      ]

      tree = IntervalTree.from_list(intervals)

      results = IntervalTree.stabbing(tree, {5, 0})
      values = Enum.map(results, & &1.value) |> Enum.sort()
      assert values == [:a, :b]
    end

    test "point at interval start is included" do
      interval = make_interval({5, 0}, {10, 0}, :target)
      tree = IntervalTree.from_list([interval])

      results = IntervalTree.stabbing(tree, {5, 0})
      assert length(results) == 1
    end

    test "point at interval end is excluded (half-open)" do
      interval = make_interval({5, 0}, {10, 0}, :target)
      tree = IntervalTree.from_list([interval])

      assert IntervalTree.stabbing(tree, {10, 0}) == []
    end
  end

  # ── Bulk operations ──────────────────────────────────────────────────────

  describe "map_filter/2" do
    test "transforms all intervals" do
      intervals = [
        make_interval({0, 0}, {5, 0}, :a),
        make_interval({10, 0}, {15, 0}, :b)
      ]

      tree = IntervalTree.from_list(intervals)

      # Shift all intervals down by 2 lines
      tree =
        IntervalTree.map_filter(tree, fn interval ->
          {sl, sc} = interval.start
          {el, ec} = interval.end_
          {:keep, %{interval | start: {sl + 2, sc}, end_: {el + 2, ec}}}
        end)

      results = IntervalTree.to_list(tree)
      starts = Enum.map(results, & &1.start) |> Enum.sort()
      assert starts == [{2, 0}, {12, 0}]
    end

    test "filters out intervals" do
      intervals = [
        make_interval({0, 0}, {5, 0}, :keep_me),
        make_interval({10, 0}, {15, 0}, :remove_me),
        make_interval({20, 0}, {25, 0}, :keep_me_too)
      ]

      tree = IntervalTree.from_list(intervals)

      tree =
        IntervalTree.map_filter(tree, fn interval ->
          if interval.value == :remove_me, do: :remove, else: {:keep, interval}
        end)

      assert IntervalTree.size(tree) == 2
      values = tree |> IntervalTree.to_list() |> Enum.map(& &1.value) |> Enum.sort()
      assert values == [:keep_me, :keep_me_too]
    end

    test "empty tree returns empty" do
      tree = IntervalTree.map_filter(nil, fn i -> {:keep, i} end)
      assert IntervalTree.empty?(tree)
    end
  end

  describe "to_list/1" do
    test "returns intervals sorted by start position" do
      intervals = [
        make_interval({10, 0}, {15, 0}),
        make_interval({0, 0}, {5, 0}),
        make_interval({5, 0}, {8, 0})
      ]

      tree = IntervalTree.from_list(intervals)
      result = IntervalTree.to_list(tree)

      starts = Enum.map(result, & &1.start)
      assert starts == Enum.sort(starts)
    end
  end

  # ── Property-based tests ─────────────────────────────────────────────────

  describe "property: query correctness" do
    property "query results match brute-force filter" do
      check all(
              intervals <- interval_list_gen(30, 50, 20),
              qs <- position_gen(50, 20),
              qe_line <- integer(elem(qs, 0)..55),
              qe_col <- integer(0..20)
            ) do
        qe = {qe_line, qe_col}

        # Skip degenerate queries where start >= end
        if qs < qe do
          tree = IntervalTree.from_list(intervals)

          tree_results =
            IntervalTree.query(tree, qs, qe)
            |> Enum.map(& &1.id)
            |> MapSet.new()

          brute_results =
            intervals
            |> Enum.filter(fn i -> i.start < qe and i.end_ > qs end)
            |> Enum.map(& &1.id)
            |> MapSet.new()

          assert tree_results == brute_results
        end
      end
    end

    property "insert then query finds the inserted interval" do
      check all(interval <- interval_gen(50, 20)) do
        tree = IntervalTree.new() |> IntervalTree.insert(interval)

        results = IntervalTree.query(tree, interval.start, interval.end_)
        ids = Enum.map(results, & &1.id)
        assert interval.id in ids
      end
    end

    property "delete removes exactly the targeted interval" do
      check all(intervals <- interval_list_gen(20, 50, 20), intervals != []) do
        tree = IntervalTree.from_list(intervals)
        target = Enum.random(intervals)

        tree = IntervalTree.delete(tree, target.id)
        remaining_ids = tree |> IntervalTree.to_list() |> Enum.map(& &1.id) |> MapSet.new()

        refute target.id in remaining_ids
        assert IntervalTree.size(tree) == length(intervals) - 1
      end
    end

    property "from_list and sequential insert produce same query results" do
      check all(
              intervals <- interval_list_gen(20, 50, 20),
              qs <- position_gen(50, 20),
              qe_line <- integer(elem(qs, 0)..55),
              qe_col <- integer(0..20)
            ) do
        qe = {qe_line, qe_col}

        if qs < qe do
          tree_bulk = IntervalTree.from_list(intervals)

          tree_seq =
            Enum.reduce(intervals, IntervalTree.new(), fn i, t ->
              IntervalTree.insert(t, i)
            end)

          bulk_ids =
            IntervalTree.query(tree_bulk, qs, qe)
            |> Enum.map(& &1.id)
            |> MapSet.new()

          seq_ids =
            IntervalTree.query(tree_seq, qs, qe)
            |> Enum.map(& &1.id)
            |> MapSet.new()

          assert bulk_ids == seq_ids
        end
      end
    end

    property "tree size is always correct after inserts and deletes" do
      check all(intervals <- interval_list_gen(30, 50, 20)) do
        tree = IntervalTree.from_list(intervals)
        assert IntervalTree.size(tree) == length(intervals)

        # Delete half
        {to_delete, to_keep} = Enum.split(intervals, div(length(intervals), 2))

        tree =
          Enum.reduce(to_delete, tree, fn i, t ->
            IntervalTree.delete(t, i.id)
          end)

        assert IntervalTree.size(tree) == length(to_keep)
      end
    end

    property "AVL balance invariant holds after random operations" do
      check all(intervals <- interval_list_gen(50, 100, 40)) do
        tree = IntervalTree.from_list(intervals)

        if tree != nil do
          assert_balanced(tree)
        end
      end
    end
  end

  # ── Edge cases ───────────────────────────────────────────────────────────

  describe "edge cases" do
    test "single-character interval (same line, adjacent columns)" do
      interval = make_interval({5, 10}, {5, 11}, :char)
      tree = IntervalTree.from_list([interval])

      assert IntervalTree.query(tree, {5, 10}, {5, 11}) == [interval]
      assert IntervalTree.query(tree, {5, 9}, {5, 10}) == []
      assert IntervalTree.query(tree, {5, 11}, {5, 12}) == []
    end

    test "many overlapping intervals on same line" do
      intervals =
        for i <- 0..19 do
          make_interval({5, i}, {5, i + 10}, :"overlap_#{i}")
        end

      tree = IntervalTree.from_list(intervals)

      results = IntervalTree.query(tree, {5, 5}, {5, 6})
      # All intervals where start < {5,6} and end > {5,5}
      # start < {5,6}: intervals with start col 0-5
      # end > {5,5}: intervals with end col > 5, i.e. start col + 10 > 5, all of them
      assert length(results) == 6
    end

    test "intervals spanning many lines" do
      interval = make_interval({0, 0}, {10_000, 0}, :huge)
      tree = IntervalTree.from_list([interval])

      results = IntervalTree.query_lines(tree, 5000, 5001)
      assert length(results) == 1
    end

    test "unicode-aware column positions" do
      # Positions are byte columns, so unicode characters may have col > grapheme index
      interval = make_interval({0, 6}, {0, 12}, :unicode_range)
      tree = IntervalTree.from_list([interval])

      results = IntervalTree.query(tree, {0, 8}, {0, 10})
      assert length(results) == 1
    end

    test "zero-width query (start == end) still finds containing intervals" do
      interval = make_interval({5, 0}, {10, 0}, :container)
      tree = IntervalTree.from_list([interval])

      # Zero-width query [p, p): the overlap condition s < qe AND e > qs
      # simplifies to s < p AND e > p, which is a stabbing query.
      # An interval spanning {5,0}-{10,0} contains point {7,0}, so it matches.
      results = IntervalTree.query(tree, {7, 0}, {7, 0})
      assert length(results) == 1
      assert hd(results).value == :container

      # But a point outside the interval finds nothing
      assert IntervalTree.query(tree, {11, 0}, {11, 0}) == []
    end
  end

  # ── AVL balance assertion helper ─────────────────────────────────────────

  defp assert_balanced(nil), do: :ok

  defp assert_balanced(node) do
    left_h = if node.left, do: node.left.height, else: 0
    right_h = if node.right, do: node.right.height, else: 0
    bf = left_h - right_h

    assert bf >= -1 and bf <= 1,
           "AVL violation: balance factor #{bf} at node with start #{inspect(node.interval.start)}"

    assert_balanced(node.left)
    assert_balanced(node.right)
  end
end
