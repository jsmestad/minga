defmodule Minga.Editor.FoldMapTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Editor.FoldMap
  alias Minga.Editing.Fold.Range, as: FoldRange

  # ── Generators ─────────────────────────────────────────────────────────────

  # Generates a list of non-overlapping fold ranges within 0..max_line.
  defp non_overlapping_ranges(max_line) do
    gen all(
          count <- integer(0..10),
          starts <- list_of(integer(0..(max_line - 2)), length: count),
          lengths <- list_of(integer(1..5), length: count)
        ) do
      starts
      |> Enum.zip(lengths)
      |> Enum.map(fn {s, l} -> {s, min(s + l, max_line)} end)
      |> Enum.filter(fn {s, e} -> e > s end)
      |> Enum.sort()
      |> remove_overlaps_gen()
      |> Enum.map(fn {s, e} -> FoldRange.new!(s, e) end)
    end
  end

  defp remove_overlaps_gen([]), do: []
  defp remove_overlaps_gen([single]), do: [single]

  defp remove_overlaps_gen([{s1, e1}, {s2, e2} | rest]) do
    if s2 <= e1 do
      remove_overlaps_gen([{s1, e1} | rest])
    else
      [{s1, e1} | remove_overlaps_gen([{s2, e2} | rest])]
    end
  end

  # ── Basic operations ───────────────────────────────────────────────────────

  describe "new/0" do
    test "creates empty fold map" do
      fm = FoldMap.new()
      assert FoldMap.empty?(fm)
      assert FoldMap.count(fm) == 0
    end
  end

  describe "fold/2 and unfold_at/2" do
    test "fold adds a range" do
      fm = FoldMap.new()
      range = FoldRange.new!(5, 10)
      fm = FoldMap.fold(fm, range)

      assert FoldMap.count(fm) == 1
      refute FoldMap.empty?(fm)
    end

    test "fold rejects overlapping range" do
      range1 = FoldRange.new!(5, 10)
      range2 = FoldRange.new!(8, 15)

      fm = FoldMap.new() |> FoldMap.fold(range1) |> FoldMap.fold(range2)
      assert FoldMap.count(fm) == 1
    end

    test "fold accepts non-overlapping range" do
      range1 = FoldRange.new!(5, 10)
      range2 = FoldRange.new!(15, 20)

      fm = FoldMap.new() |> FoldMap.fold(range1) |> FoldMap.fold(range2)
      assert FoldMap.count(fm) == 2
    end

    test "unfold_at removes fold containing the line" do
      range = FoldRange.new!(5, 10)
      fm = FoldMap.new() |> FoldMap.fold(range) |> FoldMap.unfold_at(7)
      assert FoldMap.empty?(fm)
    end

    test "unfold_at is no-op for line not in any fold" do
      range = FoldRange.new!(5, 10)
      fm = FoldMap.new() |> FoldMap.fold(range)
      fm2 = FoldMap.unfold_at(fm, 20)
      assert FoldMap.count(fm2) == 1
    end

    test "unfold_at on empty map is no-op" do
      fm = FoldMap.new()
      assert FoldMap.unfold_at(fm, 5) == fm
    end
  end

  describe "toggle/3" do
    test "toggle folds when line is in an available range" do
      available = [FoldRange.new!(5, 10)]
      fm = FoldMap.new() |> FoldMap.toggle(7, available)
      assert FoldMap.count(fm) == 1
    end

    test "toggle unfolds when line is already folded" do
      range = FoldRange.new!(5, 10)
      fm = FoldMap.new() |> FoldMap.fold(range) |> FoldMap.toggle(7, [range])
      assert FoldMap.empty?(fm)
    end

    test "toggle is no-op when line has no available range" do
      fm = FoldMap.new() |> FoldMap.toggle(7, [])
      assert FoldMap.empty?(fm)
    end
  end

  describe "fold_all/2 and unfold_all/1" do
    test "fold_all creates folds from all non-overlapping ranges" do
      ranges = [FoldRange.new!(0, 5), FoldRange.new!(10, 15), FoldRange.new!(20, 25)]
      fm = FoldMap.fold_all(FoldMap.new(), ranges)
      assert FoldMap.count(fm) == 3
    end

    test "fold_all removes overlapping ranges" do
      ranges = [FoldRange.new!(0, 10), FoldRange.new!(5, 15)]
      fm = FoldMap.fold_all(FoldMap.new(), ranges)
      assert FoldMap.count(fm) == 1
    end

    test "unfold_all clears all folds" do
      ranges = [FoldRange.new!(0, 5), FoldRange.new!(10, 15)]
      fm = FoldMap.fold_all(FoldMap.new(), ranges) |> FoldMap.unfold_all()
      assert FoldMap.empty?(fm)
    end
  end

  # ── Query operations ───────────────────────────────────────────────────────

  describe "folded?/2" do
    test "start line is not folded (it's visible as summary)" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      refute FoldMap.folded?(fm, 5)
    end

    test "hidden lines are folded" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      assert FoldMap.folded?(fm, 6)
      assert FoldMap.folded?(fm, 10)
    end

    test "lines outside any fold are not folded" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      refute FoldMap.folded?(fm, 4)
      refute FoldMap.folded?(fm, 11)
    end

    test "empty fold map returns false for any line" do
      fm = FoldMap.new()
      refute FoldMap.folded?(fm, 0)
      refute FoldMap.folded?(fm, 100)
    end
  end

  describe "fold_at/2" do
    test "returns the fold containing the line" do
      range = FoldRange.new!(5, 10)
      fm = FoldMap.new() |> FoldMap.fold(range)
      assert {:ok, ^range} = FoldMap.fold_at(fm, 7)
    end

    test "returns :none for line outside any fold" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      assert :none = FoldMap.fold_at(fm, 20)
    end
  end

  describe "fold_start?/2" do
    test "returns true for start line of a fold" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      assert FoldMap.fold_start?(fm, 5)
    end

    test "returns false for non-start lines" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      refute FoldMap.fold_start?(fm, 6)
      refute FoldMap.fold_start?(fm, 10)
      refute FoldMap.fold_start?(fm, 4)
    end
  end

  # ── Coordinate translation ─────────────────────────────────────────────────

  describe "buffer_to_visible/2" do
    test "identity when no folds" do
      fm = FoldMap.new()
      assert FoldMap.buffer_to_visible(fm, 0) == 0
      assert FoldMap.buffer_to_visible(fm, 50) == 50
    end

    test "lines before fold are unchanged" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(10, 15))
      assert FoldMap.buffer_to_visible(fm, 0) == 0
      assert FoldMap.buffer_to_visible(fm, 9) == 9
    end

    test "fold start line is visible" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(10, 15))
      assert FoldMap.buffer_to_visible(fm, 10) == 10
    end

    test "hidden lines map to fold start's visible position" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(10, 15))
      # Lines 11-15 are hidden. They map to visible line 10 + (offset within fold)
      # Actually, hidden lines map to start line's visible position
      # buffer 11 -> hidden by 1 line -> visible 10
      assert FoldMap.buffer_to_visible(fm, 11) == 10
      assert FoldMap.buffer_to_visible(fm, 15) == 10
    end

    test "lines after fold are shifted" do
      # Fold at 10-15 hides 5 lines (11,12,13,14,15)
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(10, 15))
      assert FoldMap.buffer_to_visible(fm, 16) == 11
      assert FoldMap.buffer_to_visible(fm, 20) == 15
    end

    test "multiple folds accumulate offset" do
      fm =
        FoldMap.new()
        |> FoldMap.fold(FoldRange.new!(5, 10))
        |> FoldMap.fold(FoldRange.new!(20, 25))

      # First fold hides 5 lines (6-10)
      assert FoldMap.buffer_to_visible(fm, 15) == 10
      # Second fold hides 5 more (21-25), but shifted by first fold's 5
      assert FoldMap.buffer_to_visible(fm, 26) == 16
    end
  end

  describe "visible_to_buffer/2" do
    test "identity when no folds" do
      fm = FoldMap.new()
      assert FoldMap.visible_to_buffer(fm, 0) == 0
      assert FoldMap.visible_to_buffer(fm, 50) == 50
    end

    test "lines before fold map correctly" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(10, 15))
      assert FoldMap.visible_to_buffer(fm, 9) == 9
    end

    test "fold summary line maps to fold start" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(10, 15))
      assert FoldMap.visible_to_buffer(fm, 10) == 10
    end

    test "visible line after fold maps to correct buffer line" do
      # Fold at 10-15: visible 11 should be buffer 16
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(10, 15))
      assert FoldMap.visible_to_buffer(fm, 11) == 16
    end

    test "multiple folds" do
      fm =
        FoldMap.new()
        |> FoldMap.fold(FoldRange.new!(5, 10))
        |> FoldMap.fold(FoldRange.new!(20, 25))

      # visible 5 = buffer 5 (fold start)
      assert FoldMap.visible_to_buffer(fm, 5) == 5
      # visible 6 = buffer 11 (after first fold)
      assert FoldMap.visible_to_buffer(fm, 6) == 11
      # visible 15 = buffer 20 (second fold start)
      assert FoldMap.visible_to_buffer(fm, 15) == 20
      # visible 16 = buffer 26 (after second fold)
      assert FoldMap.visible_to_buffer(fm, 16) == 26
    end
  end

  describe "visible_line_count/2" do
    test "equals total when no folds" do
      fm = FoldMap.new()
      assert FoldMap.visible_line_count(fm, 100) == 100
    end

    test "subtracts hidden lines" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(10, 15))
      # 5 lines hidden (11-15), 100 - 5 = 95
      assert FoldMap.visible_line_count(fm, 100) == 95
    end

    test "multiple folds" do
      fm =
        FoldMap.new()
        |> FoldMap.fold(FoldRange.new!(5, 10))
        |> FoldMap.fold(FoldRange.new!(20, 25))

      # 10 lines hidden total
      assert FoldMap.visible_line_count(fm, 50) == 40
    end
  end

  describe "next_visible/2 and prev_visible/2" do
    test "next_visible without folds" do
      fm = FoldMap.new()
      assert FoldMap.next_visible(fm, 5) == 6
    end

    test "next_visible skips over fold" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      # From line 5 (fold start), next visible is 11 (after fold end)
      assert FoldMap.next_visible(fm, 5) == 11
    end

    test "next_visible from line before fold" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      assert FoldMap.next_visible(fm, 4) == 5
    end

    test "prev_visible without folds" do
      fm = FoldMap.new()
      assert FoldMap.prev_visible(fm, 5) == 4
    end

    test "prev_visible skips over fold" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      # From line 11, prev visible is 5 (fold start)
      assert FoldMap.prev_visible(fm, 11) == 5
    end

    test "prev_visible lands on fold start when inside fold" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      # Hypothetical: cursor at hidden line 8, prev should go to 5
      assert FoldMap.prev_visible(fm, 8) == 5
    end

    test "prev_visible at line 0 stays at 0" do
      fm = FoldMap.new()
      assert FoldMap.prev_visible(fm, 0) == 0
    end
  end

  describe "unfold_containing/2" do
    test "unfolds ranges containing any of the given lines" do
      fm =
        FoldMap.new()
        |> FoldMap.fold(FoldRange.new!(5, 10))
        |> FoldMap.fold(FoldRange.new!(20, 25))

      # Unfold the range containing line 8
      fm = FoldMap.unfold_containing(fm, [8])
      assert FoldMap.count(fm) == 1
      assert :none = FoldMap.fold_at(fm, 8)
      assert {:ok, _} = FoldMap.fold_at(fm, 22)
    end

    test "unfolds multiple ranges" do
      fm =
        FoldMap.new()
        |> FoldMap.fold(FoldRange.new!(5, 10))
        |> FoldMap.fold(FoldRange.new!(20, 25))

      fm = FoldMap.unfold_containing(fm, [8, 22])
      assert FoldMap.empty?(fm)
    end

    test "no-op on empty fold map" do
      fm = FoldMap.new()
      assert FoldMap.unfold_containing(fm, [5]) == fm
    end

    test "no-op when lines are not in any fold" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      fm2 = FoldMap.unfold_containing(fm, [20])
      assert FoldMap.count(fm2) == 1
    end
  end

  # ── Property-based tests ───────────────────────────────────────────────────

  describe "coordinate roundtrip properties" do
    property "buffer_to_visible then visible_to_buffer is identity for visible lines" do
      check all(ranges <- non_overlapping_ranges(200)) do
        fm = FoldMap.from_ranges(ranges)
        total = 201

        # Check roundtrip for every visible buffer line
        for buf_line <- 0..200 do
          unless FoldMap.folded?(fm, buf_line) do
            visible = FoldMap.buffer_to_visible(fm, buf_line)
            roundtripped = FoldMap.visible_to_buffer(fm, visible)

            assert roundtripped == buf_line,
                   "roundtrip failed: buf #{buf_line} -> vis #{visible} -> buf #{roundtripped}"
          end
        end

        # visible_line_count matches the count of non-hidden lines
        visible_count =
          Enum.count(0..200, fn line -> not FoldMap.folded?(fm, line) end)

        assert FoldMap.visible_line_count(fm, total) == visible_count
      end
    end

    property "visible_to_buffer returns non-hidden lines" do
      check all(ranges <- non_overlapping_ranges(100)) do
        fm = FoldMap.from_ranges(ranges)
        visible_count = FoldMap.visible_line_count(fm, 101)

        for vis <- 0..max(visible_count - 1, 0) do
          buf = FoldMap.visible_to_buffer(fm, vis)

          refute FoldMap.folded?(fm, buf),
                 "visible line #{vis} mapped to hidden buffer line #{buf}"
        end
      end
    end

    property "next_visible always returns a non-hidden line" do
      check all(ranges <- non_overlapping_ranges(50)) do
        fm = FoldMap.from_ranges(ranges)

        for line <- 0..49 do
          next = FoldMap.next_visible(fm, line)
          assert next > line
          refute FoldMap.folded?(fm, next), "next_visible(#{line}) = #{next} is hidden"
        end
      end
    end

    property "prev_visible always returns a non-hidden line" do
      check all(ranges <- non_overlapping_ranges(50)) do
        fm = FoldMap.from_ranges(ranges)

        for line <- 1..50 do
          prev = FoldMap.prev_visible(fm, line)
          assert prev < line
          refute FoldMap.folded?(fm, prev), "prev_visible(#{line}) = #{prev} is hidden"
        end
      end
    end

    property "fold_start lines are never folded (hidden)" do
      check all(ranges <- non_overlapping_ranges(100)) do
        fm = FoldMap.from_ranges(ranges)

        for range <- FoldMap.folds(fm) do
          refute FoldMap.folded?(fm, range.start_line)
        end
      end
    end
  end
end
