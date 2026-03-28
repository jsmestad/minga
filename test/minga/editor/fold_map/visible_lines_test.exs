defmodule Minga.Editor.FoldMap.VisibleLinesTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.FoldMap
  alias Minga.Editor.FoldMap.VisibleLines
  alias Minga.Editing.Fold.Range, as: FoldRange

  describe "compute/4" do
    test "returns nil when fold map is empty" do
      fm = FoldMap.new()
      assert VisibleLines.compute(fm, 0, 10, 100) == nil
    end

    test "returns entries skipping folded lines" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(3, 7))
      entries = VisibleLines.compute(fm, 0, 10, 20)

      # Lines 0,1,2 are normal, line 3 is fold start (hides 4 lines),
      # then lines 8,9,10,11,12,13 fill the remaining rows
      assert length(entries) == 10

      assert Enum.at(entries, 0) == {0, :normal}
      assert Enum.at(entries, 1) == {1, :normal}
      assert Enum.at(entries, 2) == {2, :normal}
      assert Enum.at(entries, 3) == {3, {:fold_start, 4}}
      # After fold (3-7), next visible is 8
      assert Enum.at(entries, 4) == {8, :normal}
      assert Enum.at(entries, 5) == {9, :normal}
    end

    test "handles fold at start of viewport" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(0, 5))
      entries = VisibleLines.compute(fm, 0, 5, 20)

      assert Enum.at(entries, 0) == {0, {:fold_start, 5}}
      assert Enum.at(entries, 1) == {6, :normal}
      assert Enum.at(entries, 2) == {7, :normal}
    end

    test "handles multiple folds" do
      fm =
        FoldMap.new()
        |> FoldMap.fold(FoldRange.new!(2, 4))
        |> FoldMap.fold(FoldRange.new!(8, 10))

      entries = VisibleLines.compute(fm, 0, 8, 20)

      assert Enum.at(entries, 0) == {0, :normal}
      assert Enum.at(entries, 1) == {1, :normal}
      assert Enum.at(entries, 2) == {2, {:fold_start, 2}}
      assert Enum.at(entries, 3) == {5, :normal}
      assert Enum.at(entries, 4) == {6, :normal}
      assert Enum.at(entries, 5) == {7, :normal}
      assert Enum.at(entries, 6) == {8, {:fold_start, 2}}
      assert Enum.at(entries, 7) == {11, :normal}
    end

    test "stops at total line count" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(2, 4))
      entries = VisibleLines.compute(fm, 0, 20, 6)

      # Only 4 visible lines exist (0, 1, fold@2, 5)
      assert length(entries) == 4
    end
  end

  describe "buffer_range/1" do
    test "returns nil for empty entries" do
      assert VisibleLines.buffer_range([]) == nil
    end

    test "returns first and last buffer lines" do
      entries = [{5, :normal}, {6, :normal}, {10, {:fold_start, 3}}, {14, :normal}]
      assert VisibleLines.buffer_range(entries) == {5, 14}
    end
  end
end
