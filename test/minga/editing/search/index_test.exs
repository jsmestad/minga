defmodule Minga.Editing.Search.IndexTest do
  use ExUnit.Case, async: true

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
end
