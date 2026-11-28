defmodule Minga.Buffer.EditDeltaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.EditDelta

  # A delta that replaces lines `start..old_end` with lines `start..new_end`. Byte fields are unused here.
  defp delta(start, old_end, new_end) do
    EditDelta.replacement(0, 0, {start, 0}, {old_end, 0}, "", {new_end, 0})
  end

  # The line-granular meaning of a delta: every line it spans is new.
  defp apply_to_model(lines, start, old_end, new_end, tag) do
    fresh = for offset <- 0..(new_end - start), do: {:new, tag, offset}
    Enum.take(lines, start) ++ fresh ++ Enum.drop(lines, old_end + 1)
  end

  # Applies splices to the base document, marking inserted lines without naming them.
  defp apply_splices(base, splices) do
    {kept, position} =
      Enum.reduce(splices, {[], 0}, fn {start, delete_count, insert_count}, {acc, position} ->
        retained = Enum.slice(base, position, start - position)
        inserted = List.duplicate(:changed, insert_count)
        {[inserted, retained | acc], start + delete_count}
      end)

    kept |> Enum.reverse() |> List.flatten() |> Kernel.++(Enum.drop(base, position))
  end

  defp edit_script(line_count) do
    gen all(steps <- list_of({integer(0..1_000), integer(0..3), integer(0..3)}, max_length: 30)) do
      {script, _count} =
        Enum.map_reduce(steps, line_count, fn {at, removed, added}, count ->
          start = rem(at, count)
          old_end = min(start + removed, count - 1)
          new_end = start + added
          {{start, old_end, new_end}, count - (old_end - start) + (new_end - start)}
        end)

      script
    end
  end

  describe "line_splices/1" do
    test "one insertion in the middle is one splice" do
      assert EditDelta.line_splices([delta(5, 5, 8)]) == [{5, 1, 4}]
    end

    test "an insertion above and an append stay two splices in base coordinates" do
      deltas = [delta(10, 10, 13), delta(103, 103, 106)]
      assert EditDelta.line_splices(deltas) == [{10, 1, 4}, {100, 1, 4}]
    end

    test "the same two edits in the other order give the same splices" do
      deltas = [delta(100, 100, 103), delta(10, 10, 13)]
      assert EditDelta.line_splices(deltas) == [{10, 1, 4}, {100, 1, 4}]
    end

    test "a large deletion and an edit elsewhere stay apart" do
      deltas = [delta(20, 1_020, 20), delta(5_000, 5_000, 5_003)]
      assert EditDelta.line_splices(deltas) == [{20, 1_001, 1}, {6_000, 1, 4}]
    end

    test "an in-place edit and a structural edit elsewhere stay apart" do
      deltas = [delta(3, 3, 3), delta(50, 50, 52)]
      assert EditDelta.line_splices(deltas) == [{3, 1, 1}, {50, 1, 3}]
    end

    test "edits on touching lines merge into one splice" do
      assert EditDelta.line_splices([delta(4, 4, 4), delta(5, 5, 5)]) == [{4, 2, 2}]
    end

    test "a second edit inside the first one's inserted lines merges with it" do
      assert EditDelta.line_splices([delta(10, 10, 14), delta(12, 12, 12)]) == [{10, 1, 5}]
    end

    test "no deltas give no splices" do
      assert EditDelta.line_splices([]) == []
    end

    property "retained lines are exactly the lines the edits left alone, and inserted counts add up" do
      check all(
              line_count <- integer(1..60),
              script <- edit_script(line_count)
            ) do
        base = Enum.to_list(0..(line_count - 1))

        {model, deltas} =
          script
          |> Enum.with_index()
          |> Enum.reduce({base, []}, fn {{start, old_end, new_end}, tag}, {model, deltas} ->
            {apply_to_model(model, start, old_end, new_end, tag),
             [delta(start, old_end, new_end) | deltas]}
          end)

        deltas = Enum.reverse(deltas)
        splices = EditDelta.line_splices(deltas)
        result = apply_splices(base, splices)

        assert length(result) == length(model)

        for {line, expected} <- Enum.zip(result, model), line != :changed do
          assert line == expected
        end

        assert length(splices) <= 16

        Enum.reduce(splices, 0, fn {start, delete_count, insert_count}, minimum ->
          assert start >= minimum
          assert delete_count >= 0
          assert insert_count >= 1
          assert start + delete_count <= line_count
          start + delete_count + 1
        end)
      end
    end

    property "the splices span the same lines as the single bounding range" do
      check all(
              line_count <- integer(1..60),
              script <- edit_script(line_count),
              script != []
            ) do
        deltas =
          Enum.map(script, fn {start, old_end, new_end} -> delta(start, old_end, new_end) end)

        ranges = deltas |> EditDelta.line_splices() |> EditDelta.inserted_line_ranges()

        assert {elem(hd(ranges), 0), elem(List.last(ranges), 1)} ==
                 EditDelta.affected_line_range(deltas)
      end
    end
  end

  describe "affected_line_ranges/2" do
    test "matches the lines the splices insert" do
      deltas = [delta(10, 10, 13), delta(103, 103, 106)]
      assert EditDelta.affected_line_ranges(deltas) == [{10, 13}, {103, 106}]

      assert EditDelta.affected_line_ranges(deltas) ==
               deltas |> EditDelta.line_splices() |> EditDelta.inserted_line_ranges()
    end

    test "carries a pending range through later edits above it" do
      assert EditDelta.affected_line_ranges([delta(2, 2, 5)], [{40, 41}]) == [{2, 5}, {43, 44}]
    end

    test "a pending range the edit overlaps merges with it" do
      assert EditDelta.affected_line_ranges([delta(40, 41, 40)], [{38, 40}]) == [{38, 40}]
    end

    test "no deltas return the pending ranges, merged where they touch" do
      assert EditDelta.affected_line_ranges([], [{7, 8}, {1, 2}, {3, 3}]) == [{1, 3}, {7, 8}]
    end

    property "consuming in two steps covers what consuming at once covers" do
      check all(
              line_count <- integer(1..60),
              script <- edit_script(line_count),
              split <- integer(0..30)
            ) do
        deltas =
          Enum.map(script, fn {start, old_end, new_end} -> delta(start, old_end, new_end) end)

        {first, second} = Enum.split(deltas, split)

        stepped = EditDelta.affected_line_ranges(second, EditDelta.affected_line_ranges(first))

        for {from, to} <- EditDelta.affected_line_ranges(deltas) do
          assert Enum.any?(stepped, fn {first, last} -> first <= from and to <= last end)
        end
      end
    end

    test "more than sixteen separate edits merge the closest neighbours" do
      deltas = for line <- 0..40, do: delta(line * 10, line * 10, line * 10)
      ranges = EditDelta.affected_line_ranges(deltas)
      assert length(ranges) == 16
      assert hd(ranges) |> elem(0) == 0
      assert List.last(ranges) |> elem(1) == 400
    end
  end

  describe "clamp_line_ranges/2" do
    test "a range past the end becomes the last line" do
      assert EditDelta.clamp_line_ranges([{3, 4}, {12, 12}], 10) == [{3, 4}, {9, 9}]
    end

    test "ranges that touch after clamping merge" do
      assert EditDelta.clamp_line_ranges([{8, 20}, {25, 30}], 10) == [{8, 9}]
    end

    test "an empty document keeps line zero" do
      assert EditDelta.clamp_line_ranges([{0, 3}], 0) == [{0, 0}]
    end
  end
end
