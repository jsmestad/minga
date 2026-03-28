defmodule Minga.Agent.EditBoundaryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Agent.EditBoundary

  describe "new/2" do
    test "creates a boundary when start <= end" do
      assert {:ok, %EditBoundary{start_line: 5, end_line: 10}} = EditBoundary.new(5, 10)
    end

    test "creates a single-line boundary" do
      assert {:ok, %EditBoundary{start_line: 0, end_line: 0}} = EditBoundary.new(0, 0)
    end

    test "returns error when start > end" do
      assert {:error, msg} = EditBoundary.new(10, 5)
      assert msg =~ "start_line"
      assert msg =~ "end_line"
    end
  end

  describe "contains_line?/2" do
    setup do
      {:ok, boundary} = EditBoundary.new(5, 10)
      %{boundary: boundary}
    end

    test "returns true for lines within the range", %{boundary: b} do
      assert EditBoundary.contains_line?(b, 5)
      assert EditBoundary.contains_line?(b, 7)
      assert EditBoundary.contains_line?(b, 10)
    end

    test "returns false for lines outside the range", %{boundary: b} do
      refute EditBoundary.contains_line?(b, 4)
      refute EditBoundary.contains_line?(b, 11)
      refute EditBoundary.contains_line?(b, 0)
    end
  end

  describe "contains_range?/3" do
    setup do
      {:ok, boundary} = EditBoundary.new(5, 10)
      %{boundary: boundary}
    end

    test "returns true when the range is fully inside the boundary", %{boundary: b} do
      assert EditBoundary.contains_range?(b, 5, 10)
      assert EditBoundary.contains_range?(b, 6, 9)
    end

    test "returns false when the range extends outside the boundary", %{boundary: b} do
      refute EditBoundary.contains_range?(b, 4, 10)
      refute EditBoundary.contains_range?(b, 5, 11)
      refute EditBoundary.contains_range?(b, 0, 20)
    end
  end

  describe "adjust/3" do
    test "shifts both start and end when edit is above the boundary" do
      {:ok, b} = EditBoundary.new(10, 20)

      assert %EditBoundary{start_line: 13, end_line: 23} = EditBoundary.adjust(b, 5, 3)
      assert %EditBoundary{start_line: 7, end_line: 17} = EditBoundary.adjust(b, 5, -3)
    end

    test "shifts only end when edit is within the boundary" do
      {:ok, b} = EditBoundary.new(10, 20)

      assert %EditBoundary{start_line: 10, end_line: 22} = EditBoundary.adjust(b, 15, 2)
      assert %EditBoundary{start_line: 10, end_line: 18} = EditBoundary.adjust(b, 10, -2)
    end

    test "is a no-op when edit is below the boundary" do
      {:ok, b} = EditBoundary.new(10, 20)

      assert %EditBoundary{start_line: 10, end_line: 20} = EditBoundary.adjust(b, 21, 5)
    end

    test "returns nil when the boundary collapses from large negative delta above" do
      {:ok, b} = EditBoundary.new(10, 12)

      # Shift by -20 above the boundary
      result = EditBoundary.adjust(b, 5, -20)

      # Both lines clamp to 0, so 0 >= 0, returns {0, 0} not nil
      # Actually: max(10 + -20, 0) = 0, max(12 + -20, 0) = 0, 0 >= 0 → %{0, 0}
      assert %EditBoundary{start_line: 0, end_line: 0} = result
    end

    test "single-line boundary within-edit preserves itself" do
      {:ok, b} = EditBoundary.new(5, 5)

      # Edit at line 5 with delta -1: max(5 + -1, 5) = 5
      assert %EditBoundary{start_line: 5, end_line: 5} = EditBoundary.adjust(b, 5, -1)
    end

    test "zero-line boundary at line 0 survives within-edit" do
      {:ok, b} = EditBoundary.new(0, 0)

      assert %EditBoundary{start_line: 0, end_line: 0} = EditBoundary.adjust(b, 0, -1)
    end
  end

  describe "properties" do
    property "contains_line? is true for all lines in start..end" do
      check all(
              start <- integer(0..100),
              span <- integer(0..50)
            ) do
        {:ok, b} = EditBoundary.new(start, start + span)

        for line <- start..(start + span) do
          assert EditBoundary.contains_line?(b, line)
        end
      end
    end

    property "adjust with delta 0 is identity" do
      check all(
              start <- integer(0..100),
              span <- integer(0..50),
              edit_line <- integer(0..200)
            ) do
        {:ok, b} = EditBoundary.new(start, start + span)
        result = EditBoundary.adjust(b, edit_line, 0)
        assert result == b
      end
    end

    property "adjust with edits below is identity" do
      check all(
              start <- integer(0..100),
              span <- integer(0..50),
              offset <- integer(1..50)
            ) do
        end_line = start + span
        {:ok, b} = EditBoundary.new(start, end_line)
        result = EditBoundary.adjust(b, end_line + offset, 5)
        assert result == b
      end
    end

    property "adjust preserves span when edit is above and no clamping" do
      check all(
              start <- integer(1..100),
              span <- integer(0..50),
              delta <- integer(0..10),
              edit_line <- integer(0..(start - 1))
            ) do
        end_line = start + span
        {:ok, b} = EditBoundary.new(start, end_line)
        result = EditBoundary.adjust(b, edit_line, delta)

        # Positive deltas (or zero) above the boundary never clamp,
        # so the span is always preserved
        assert result.end_line - result.start_line == span
      end
    end
  end
end
