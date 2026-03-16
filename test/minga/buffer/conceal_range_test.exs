defmodule Minga.Buffer.ConcealRangeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Decorations.ConcealRange

  # ── ConcealRange struct ─────────────────────────────────────────────────

  describe "ConcealRange struct" do
    test "creates a conceal range with required fields" do
      range = %ConcealRange{
        id: make_ref(),
        start_pos: {0, 0},
        end_pos: {0, 2}
      }

      assert range.replacement == nil
      assert range.replacement_style == []
      assert range.priority == 0
      assert range.group == nil
    end

    test "creates a conceal range with replacement" do
      range = %ConcealRange{
        id: make_ref(),
        start_pos: {0, 0},
        end_pos: {0, 5},
        replacement: "·",
        replacement_style: [fg: 0x555555]
      }

      assert range.replacement == "·"
      assert range.replacement_style == [fg: 0x555555]
    end
  end

  describe "display_width/1" do
    test "returns 0 when no replacement" do
      range = %ConcealRange{id: make_ref(), start_pos: {0, 0}, end_pos: {0, 5}}
      assert ConcealRange.display_width(range) == 0
    end

    test "returns 1 when replacement is set" do
      range = %ConcealRange{
        id: make_ref(),
        start_pos: {0, 0},
        end_pos: {0, 5},
        replacement: "·"
      }

      assert ConcealRange.display_width(range) == 1
    end
  end

  describe "spans_line?/2" do
    test "returns true for lines within the range" do
      range = %ConcealRange{id: make_ref(), start_pos: {2, 0}, end_pos: {5, 3}}
      assert ConcealRange.spans_line?(range, 2)
      assert ConcealRange.spans_line?(range, 3)
      assert ConcealRange.spans_line?(range, 5)
    end

    test "returns false for lines outside the range" do
      range = %ConcealRange{id: make_ref(), start_pos: {2, 0}, end_pos: {5, 3}}
      refute ConcealRange.spans_line?(range, 1)
      refute ConcealRange.spans_line?(range, 6)
    end
  end

  describe "contains?/2" do
    test "returns true for positions inside the range" do
      range = %ConcealRange{id: make_ref(), start_pos: {0, 2}, end_pos: {0, 5}}
      assert ConcealRange.contains?(range, {0, 2})
      assert ConcealRange.contains?(range, {0, 3})
      assert ConcealRange.contains?(range, {0, 4})
    end

    test "returns false for end position (exclusive)" do
      range = %ConcealRange{id: make_ref(), start_pos: {0, 2}, end_pos: {0, 5}}
      refute ConcealRange.contains?(range, {0, 5})
    end

    test "returns false for positions outside" do
      range = %ConcealRange{id: make_ref(), start_pos: {0, 2}, end_pos: {0, 5}}
      refute ConcealRange.contains?(range, {0, 1})
      refute ConcealRange.contains?(range, {0, 6})
    end
  end

  # ── Decorations API ────────────────────────────────────────────────────

  describe "add_conceal/4" do
    test "adds a conceal range and returns id" do
      decs = Decorations.new()
      {id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})

      assert is_reference(id)
      assert length(decs.conceal_ranges) == 1
      assert decs.version == 1
    end

    test "adds a conceal range with replacement" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_conceal(decs, {0, 0}, {0, 2},
          replacement: "·",
          replacement_style: [fg: 0x555555],
          group: :markdown
        )

      [range] = decs.conceal_ranges
      assert range.replacement == "·"
      assert range.replacement_style == [fg: 0x555555]
      assert range.group == :markdown
    end

    test "adds multiple conceal ranges" do
      decs = Decorations.new()
      {_id1, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})
      {_id2, decs} = Decorations.add_conceal(decs, {0, 5}, {0, 7})

      assert length(decs.conceal_ranges) == 2
      assert decs.version == 2
    end
  end

  describe "remove_conceal/2" do
    test "removes a conceal range by id" do
      decs = Decorations.new()
      {id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})
      decs = Decorations.remove_conceal(decs, id)

      assert decs.conceal_ranges == []
      assert decs.version == 2
    end

    test "no-op when id doesn't exist" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})
      old_version = decs.version
      decs = Decorations.remove_conceal(decs, make_ref())

      assert length(decs.conceal_ranges) == 1
      assert decs.version == old_version
    end
  end

  describe "remove_conceal_group/2" do
    test "removes all conceals in a group" do
      decs = Decorations.new()
      {_id1, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2}, group: :markdown)
      {_id2, decs} = Decorations.add_conceal(decs, {0, 5}, {0, 7}, group: :markdown)
      {_id3, decs} = Decorations.add_conceal(decs, {1, 0}, {1, 3}, group: :other)

      decs = Decorations.remove_conceal_group(decs, :markdown)
      assert length(decs.conceal_ranges) == 1
      assert hd(decs.conceal_ranges).group == :other
    end
  end

  describe "conceals_for_line/2" do
    test "returns conceals for the given line sorted by start col" do
      decs = Decorations.new()
      {_id1, decs} = Decorations.add_conceal(decs, {0, 5}, {0, 7})
      {_id2, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})
      {_id3, decs} = Decorations.add_conceal(decs, {1, 0}, {1, 3})

      line_conceals = Decorations.conceals_for_line(decs, 0)
      assert length(line_conceals) == 2
      [first, second] = line_conceals
      assert elem(first.start_pos, 1) <= elem(second.start_pos, 1)
    end

    test "returns empty list when no conceals exist" do
      decs = Decorations.new()
      assert Decorations.conceals_for_line(decs, 0) == []
    end

    test "returns empty list for line with no conceals" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})
      assert Decorations.conceals_for_line(decs, 1) == []
    end
  end

  describe "has_conceal_ranges?/1" do
    test "returns false for empty" do
      refute Decorations.has_conceal_ranges?(Decorations.new())
    end

    test "returns true when conceals exist" do
      {_id, decs} = Decorations.add_conceal(Decorations.new(), {0, 0}, {0, 2})
      assert Decorations.has_conceal_ranges?(decs)
    end
  end

  # ── Column mapping ────────────────────────────────────────────────────────

  describe "buf_col_to_display_col with conceals" do
    test "no conceals: identity mapping" do
      decs = Decorations.new()
      assert Decorations.buf_col_to_display_col(decs, 0, 5) == 5
    end

    test "conceal before position shifts display left" do
      # Line: "**bold**" concealing first **
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})

      # buf_col 0 is at the start of the conceal, display_col is 0
      assert Decorations.buf_col_to_display_col(decs, 0, 0) == 0
      # buf_col 2 (after "**") maps to display_col 0 (conceal width 2, replacement 0)
      assert Decorations.buf_col_to_display_col(decs, 0, 2) == 0
      # buf_col 6 ("bold" ends at 6) maps to display_col 4
      assert Decorations.buf_col_to_display_col(decs, 0, 6) == 4
    end

    test "conceal with replacement: shifts by (concealed_width - 1)" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2}, replacement: "·")

      # buf_col 2 maps to display_col 1 (concealed 2 chars, replaced by 1)
      assert Decorations.buf_col_to_display_col(decs, 0, 2) == 1
      # buf_col 6 maps to display_col 5
      assert Decorations.buf_col_to_display_col(decs, 0, 6) == 5
    end

    test "multiple conceals accumulate offsets" do
      # "**bold** and **more**"
      # Conceal ** at 0..2 and ** at 6..8
      decs = Decorations.new()
      {_id1, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})
      {_id2, decs} = Decorations.add_conceal(decs, {0, 6}, {0, 8})

      # After first **: buf_col 2 -> display 0
      assert Decorations.buf_col_to_display_col(decs, 0, 2) == 0
      # "bold" starts at buf_col 2, ends at 6: display 0..4
      assert Decorations.buf_col_to_display_col(decs, 0, 6) == 4
      # After second **: buf_col 8 -> display 4 (both conceals removed 4 total)
      assert Decorations.buf_col_to_display_col(decs, 0, 8) == 4
      # buf_col 10 -> display 6
      assert Decorations.buf_col_to_display_col(decs, 0, 10) == 6
    end

    test "conceal on different line doesn't affect mapping" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {1, 0}, {1, 2})

      assert Decorations.buf_col_to_display_col(decs, 0, 5) == 5
    end
  end

  describe "display_col_to_buf_col with conceals" do
    test "no conceals: identity mapping" do
      decs = Decorations.new()
      assert Decorations.display_col_to_buf_col(decs, 0, 5) == 5
    end

    test "conceal before position shifts buffer right" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})

      # display_col 0 maps to buf_col 2 (the "b" in "bold" after hidden "**")
      assert Decorations.display_col_to_buf_col(decs, 0, 0) == 2
      # display_col 4 maps to buf_col 6
      assert Decorations.display_col_to_buf_col(decs, 0, 4) == 6
    end

    test "conceal with replacement" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2}, replacement: "·")

      # display_col 0 is the replacement char, maps to buf_col 0
      # display_col 1 maps to buf_col 2 (after the concealed range)
      assert Decorations.display_col_to_buf_col(decs, 0, 1) == 2
    end
  end

  # ── Anchor adjustment ────────────────────────────────────────────────────

  describe "adjust_for_edit with conceals" do
    test "insertion before conceal shifts it right" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {0, 5}, {0, 7})

      # Insert 2 chars at col 0
      decs = Decorations.adjust_for_edit(decs, {0, 0}, {0, 0}, {0, 2})

      [conceal] = decs.conceal_ranges
      assert conceal.start_pos == {0, 7}
      assert conceal.end_pos == {0, 9}
    end

    test "insertion after conceal doesn't move it" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})

      decs = Decorations.adjust_for_edit(decs, {0, 5}, {0, 5}, {0, 8})

      [conceal] = decs.conceal_ranges
      assert conceal.start_pos == {0, 0}
      assert conceal.end_pos == {0, 2}
    end

    test "deletion spanning conceal removes it" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {0, 2}, {0, 5})

      # Delete from col 0 to col 6 (spans the conceal)
      decs = Decorations.adjust_for_edit(decs, {0, 0}, {0, 6}, {0, 0})

      assert decs.conceal_ranges == []
    end

    test "deletion within conceal shrinks it" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_conceal(decs, {0, 2}, {0, 8})

      # Delete 2 chars inside the conceal (col 4 to 6)
      decs = Decorations.adjust_for_edit(decs, {0, 4}, {0, 6}, {0, 4})

      [conceal] = decs.conceal_ranges
      assert conceal.start_pos == {0, 2}
      assert conceal.end_pos == {0, 6}
    end
  end

  # ── empty?/1 with conceals ──────────────────────────────────────────────

  describe "empty?/1" do
    test "returns false when conceals exist" do
      {_id, decs} = Decorations.add_conceal(Decorations.new(), {0, 0}, {0, 2})
      refute Decorations.empty?(decs)
    end
  end

  # ── clear/1 with conceals ──────────────────────────────────────────────

  describe "clear/1" do
    test "clears conceal ranges" do
      {_id, decs} = Decorations.add_conceal(Decorations.new(), {0, 0}, {0, 2})
      decs = Decorations.clear(decs)
      assert decs.conceal_ranges == []
    end
  end

  # ── Property tests ──────────────────────────────────────────────────────

  describe "column mapping roundtrip" do
    property "buf_col outside conceals roundtrips through display_col" do
      # For buffer positions NOT inside concealed ranges, the roundtrip
      # buf_col -> display_col -> buf_col should be exact.
      check all(
              line_len <- integer(5..50),
              conceal_count <- integer(0..3),
              conceals <- conceal_ranges_gen(line_len, conceal_count)
            ) do
        decs = build_decs_with_conceals(conceals)

        # Test every buf_col that's not inside a concealed range
        for buf_col <- 0..line_len, not inside_any_conceal?(buf_col, conceals) do
          display_col = Decorations.buf_col_to_display_col(decs, 0, buf_col)
          roundtrip = Decorations.display_col_to_buf_col(decs, 0, display_col)

          assert roundtrip == buf_col,
                 "Roundtrip failed: buf_col=#{buf_col} -> display_col=#{display_col} -> #{roundtrip}, " <>
                   "conceals=#{inspect(conceals)}"
        end
      end
    end

    property "buf_col_to_display_col is monotonically non-decreasing" do
      check all(
              line_len <- integer(5..50),
              conceal_count <- integer(0..3),
              conceals <- conceal_ranges_gen(line_len, conceal_count)
            ) do
        decs = build_decs_with_conceals(conceals)

        display_cols = for b <- 0..line_len, do: Decorations.buf_col_to_display_col(decs, 0, b)

        # Each display_col should be >= the previous one
        display_cols
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [prev, curr] ->
          assert curr >= prev, "Display cols not monotonic: #{prev} -> #{curr}"
        end)
      end
    end

    property "display_col always <= buf_col when conceals have no replacement" do
      check all(
              line_len <- integer(5..50),
              conceal_count <- integer(1..3),
              conceals <- conceal_ranges_gen(line_len, conceal_count, false)
            ) do
        decs = build_decs_with_conceals(conceals)

        for buf_col <- 0..line_len do
          display_col = Decorations.buf_col_to_display_col(decs, 0, buf_col)
          assert display_col <= buf_col
        end
      end
    end
  end

  # ── Generators ─────────────────────────────────────────────────────────

  defp conceal_ranges_gen(line_len, count, with_replacement \\ true) do
    if count == 0 do
      constant([])
    else
      bind(non_overlapping_ranges(line_len, count), fn ranges ->
        constant(add_replacements(ranges, with_replacement))
      end)
    end
  end

  defp add_replacements(ranges, with_replacement) do
    Enum.map(ranges, fn {s, e} ->
      replacement = if with_replacement and :rand.uniform(2) == 1, do: "·", else: nil
      {s, e, replacement}
    end)
  end

  defp non_overlapping_ranges(line_len, count) do
    bind(list_of(integer(1..max(line_len - 1, 2)), length: count), fn widths ->
      constant(build_ranges(widths, line_len, count))
    end)
  end

  defp build_ranges(widths, line_len, count) do
    widths = Enum.map(widths, &min(&1, 3))
    total = Enum.sum(widths)

    if total >= line_len do
      [{0, min(2, line_len)}]
    else
      gap_each = max(div(line_len - total, count + 1), 1)

      {ranges, _pos} =
        Enum.reduce(widths, {[], gap_each}, fn w, {acc, pos} ->
          {[{min(pos, line_len - 1), min(pos + w, line_len)} | acc], pos + w + gap_each}
        end)

      Enum.reverse(ranges)
    end
  end

  defp build_decs_with_conceals(conceals) do
    Enum.reduce(conceals, Decorations.new(), fn {s, e, replacement}, decs ->
      opts = if replacement, do: [replacement: replacement], else: []
      {_id, decs} = Decorations.add_conceal(decs, {0, s}, {0, e}, opts)
      decs
    end)
  end

  defp inside_any_conceal?(buf_col, conceals) do
    Enum.any?(conceals, fn {s, e, _} -> buf_col >= s and buf_col < e end)
  end
end
