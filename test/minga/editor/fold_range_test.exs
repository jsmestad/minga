defmodule Minga.Editor.FoldRangeTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.FoldRange

  describe "new/3" do
    test "creates a valid range" do
      assert {:ok, range} = FoldRange.new(5, 10)
      assert range.start_line == 5
      assert range.end_line == 10
      assert range.kind == :block
      assert range.summary == nil
    end

    test "accepts options" do
      assert {:ok, range} = FoldRange.new(0, 5, summary: "··· 5 lines", kind: :heading)
      assert range.summary == "··· 5 lines"
      assert range.kind == :heading
    end

    test "rejects degenerate range where end equals start" do
      assert {:error, _} = FoldRange.new(5, 5)
    end

    test "rejects degenerate range where end is before start" do
      assert {:error, _} = FoldRange.new(10, 5)
    end
  end

  describe "new!/3" do
    test "returns range on valid input" do
      range = FoldRange.new!(2, 8)
      assert range.start_line == 2
      assert range.end_line == 8
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, fn -> FoldRange.new!(5, 3) end
    end
  end

  describe "hidden_count/1" do
    test "returns lines hidden by the fold" do
      range = FoldRange.new!(0, 10)
      assert FoldRange.hidden_count(range) == 10
    end

    test "minimum fold hides one line" do
      range = FoldRange.new!(5, 6)
      assert FoldRange.hidden_count(range) == 1
    end
  end

  describe "contains?/2" do
    test "start line is contained" do
      range = FoldRange.new!(5, 10)
      assert FoldRange.contains?(range, 5)
    end

    test "end line is contained" do
      range = FoldRange.new!(5, 10)
      assert FoldRange.contains?(range, 10)
    end

    test "middle line is contained" do
      range = FoldRange.new!(5, 10)
      assert FoldRange.contains?(range, 7)
    end

    test "line before range is not contained" do
      range = FoldRange.new!(5, 10)
      refute FoldRange.contains?(range, 4)
    end

    test "line after range is not contained" do
      range = FoldRange.new!(5, 10)
      refute FoldRange.contains?(range, 11)
    end
  end

  describe "hides?/2" do
    test "start line is visible (not hidden)" do
      range = FoldRange.new!(5, 10)
      refute FoldRange.hides?(range, 5)
    end

    test "lines after start are hidden" do
      range = FoldRange.new!(5, 10)
      assert FoldRange.hides?(range, 6)
      assert FoldRange.hides?(range, 10)
    end

    test "line before range is not hidden" do
      range = FoldRange.new!(5, 10)
      refute FoldRange.hides?(range, 4)
    end
  end

  describe "overlaps?/2" do
    test "identical ranges overlap" do
      a = FoldRange.new!(5, 10)
      assert FoldRange.overlaps?(a, a)
    end

    test "nested ranges overlap" do
      outer = FoldRange.new!(5, 20)
      inner = FoldRange.new!(8, 15)
      assert FoldRange.overlaps?(outer, inner)
      assert FoldRange.overlaps?(inner, outer)
    end

    test "adjacent but non-overlapping ranges do not overlap" do
      a = FoldRange.new!(5, 10)
      b = FoldRange.new!(11, 15)
      refute FoldRange.overlaps?(a, b)
    end

    test "touching at boundary overlaps" do
      a = FoldRange.new!(5, 10)
      b = FoldRange.new!(10, 15)
      assert FoldRange.overlaps?(a, b)
    end

    test "completely separate ranges do not overlap" do
      a = FoldRange.new!(0, 5)
      b = FoldRange.new!(20, 30)
      refute FoldRange.overlaps?(a, b)
    end
  end
end
