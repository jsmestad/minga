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
      assert %Minga.UI.Face{name: "_"} = range.replacement_style
      assert range.priority == 0
      assert range.group == nil
    end

    test "creates a conceal range with replacement" do
      range = %ConcealRange{
        id: make_ref(),
        start_pos: {0, 0},
        end_pos: {0, 5},
        replacement: "·",
        replacement_style: Minga.UI.Face.new(fg: 0x555555)
      }

      assert range.replacement == "·"
      assert range.replacement_style.fg == 0x555555
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
          replacement_style: Minga.UI.Face.new(fg: 0x555555),
          group: :markdown
        )

      [range] = decs.conceal_ranges
      assert range.replacement == "·"
      assert range.replacement_style.fg == 0x555555
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

  # ── Overlap merging ────────────────────────────────────────────────────────

  describe "conceals_for_line overlap merging" do
    test "non-overlapping ranges preserved in order" do
      decs = Decorations.new()
      {_, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 3})
      {_, decs} = Decorations.add_conceal(decs, {0, 5}, {0, 8})
      {_, decs} = Decorations.add_conceal(decs, {0, 10}, {0, 12})
      conceals = Decorations.conceals_for_line(decs, 0)
      assert length(conceals) == 3

      assert [{0, 3}, {5, 8}, {10, 12}] ==
               Enum.map(conceals, fn c -> {elem(c.start_pos, 1), elem(c.end_pos, 1)} end)
    end

    test "adjacent ranges are not merged" do
      decs = Decorations.new()
      {_, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 5})
      {_, decs} = Decorations.add_conceal(decs, {0, 5}, {0, 10})
      conceals = Decorations.conceals_for_line(decs, 0)
      assert length(conceals) == 2
    end

    test "overlapping ranges merge to union" do
      decs = Decorations.new()
      {_, decs} = Decorations.add_conceal(decs, {0, 2}, {0, 7})
      {_, decs} = Decorations.add_conceal(decs, {0, 5}, {0, 10})
      conceals = Decorations.conceals_for_line(decs, 0)
      assert length(conceals) == 1
      [c] = conceals
      assert elem(c.start_pos, 1) == 2
      assert elem(c.end_pos, 1) == 10
    end

    test "fully nested range absorbed by outer" do
      decs = Decorations.new()
      {_, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 10})
      {_, decs} = Decorations.add_conceal(decs, {0, 3}, {0, 6})
      conceals = Decorations.conceals_for_line(decs, 0)
      assert length(conceals) == 1
      [c] = conceals
      assert elem(c.start_pos, 1) == 0
      assert elem(c.end_pos, 1) == 10
    end

    test "chain of overlapping ranges collapses to one" do
      decs = Decorations.new()
      {_, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 4})
      {_, decs} = Decorations.add_conceal(decs, {0, 3}, {0, 7})
      {_, decs} = Decorations.add_conceal(decs, {0, 6}, {0, 10})
      conceals = Decorations.conceals_for_line(decs, 0)
      assert length(conceals) == 1
      [c] = conceals
      assert elem(c.start_pos, 1) == 0
      assert elem(c.end_pos, 1) == 10
    end

    test "higher priority replacement wins on overlap" do
      decs = Decorations.new()
      {_, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 5}, replacement: "·", priority: 0)
      {_, decs} = Decorations.add_conceal(decs, {0, 3}, {0, 8}, replacement: "→", priority: 5)
      conceals = Decorations.conceals_for_line(decs, 0)
      assert length(conceals) == 1
      [c] = conceals
      assert c.replacement == "→"
    end

    test "same start, different end merges to longer" do
      decs = Decorations.new()
      {_, decs} = Decorations.add_conceal(decs, {0, 3}, {0, 7})
      {_, decs} = Decorations.add_conceal(decs, {0, 3}, {0, 10})
      conceals = Decorations.conceals_for_line(decs, 0)
      assert length(conceals) == 1
      [c] = conceals
      assert elem(c.start_pos, 1) == 3
      assert elem(c.end_pos, 1) == 10
    end

    test "duplicate ranges merge to one" do
      decs = Decorations.new()
      {_, decs} = Decorations.add_conceal(decs, {0, 4}, {0, 5})
      {_, decs} = Decorations.add_conceal(decs, {0, 4}, {0, 5})
      conceals = Decorations.conceals_for_line(decs, 0)
      assert length(conceals) == 1
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

  defp build_ranges(widths, line_len, _count) do
    widths = Enum.map(widths, &min(&1, 3))

    # Walk left to right. Each range starts at least 1 col after the previous end.
    # Skip any range that doesn't fit within line_len.
    {ranges, _cursor} =
      Enum.reduce(widths, {[], 0}, fn w, {acc, cursor} ->
        start_col = cursor + 1
        end_col = start_col + w

        if end_col <= line_len do
          {[{start_col, end_col} | acc], end_col}
        else
          # No room; skip this range
          {acc, cursor}
        end
      end)

    Enum.reverse(ranges)
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

  # ── Overlapping conceal generators ─────────────────────────────────────

  defp overlapping_conceals_gen(line_len) do
    bind(integer(2..5), fn count ->
      list_of(single_conceal_gen(line_len), length: count)
    end)
  end

  defp single_conceal_gen(line_len) do
    bind(
      {integer(0..max(line_len - 2, 0)), integer(1..min(line_len, 5)), member_of([nil, "·", "→"]),
       integer(0..3)},
      fn {start, width, replacement, priority} ->
        end_col = min(start + width, line_len)
        constant({start, end_col, replacement, priority})
      end
    )
  end

  defp build_decs_with_priority_conceals(conceals) do
    Enum.reduce(conceals, Decorations.new(), fn {s, e, replacement, priority}, decs ->
      opts = [priority: priority]
      opts = if replacement, do: [{:replacement, replacement} | opts], else: opts
      {_id, decs} = Decorations.add_conceal(decs, {0, s}, {0, e}, opts)
      decs
    end)
  end

  defp inside_any_merged_conceal?(buf_col, merged_conceals) do
    Enum.any?(merged_conceals, fn c ->
      {_, sc} = c.start_pos
      {_, ec} = c.end_pos
      buf_col >= sc and buf_col < ec
    end)
  end

  # ── Overlap property tests ────────────────────────────────────────────

  describe "column mapping with overlapping conceals" do
    property "conceals_for_line returns non-overlapping ranges" do
      check all(
              line_len <- integer(5..50),
              raw_conceals <- overlapping_conceals_gen(line_len)
            ) do
        decs = build_decs_with_priority_conceals(raw_conceals)
        merged = Decorations.conceals_for_line(decs, 0)

        merged
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [a, b] ->
          {_, a_end} = a.end_pos
          {_, b_start} = b.start_pos

          assert a_end <= b_start,
                 "Overlapping output: #{inspect(a)} overlaps #{inspect(b)}"
        end)
      end
    end

    property "buf_col_to_display_col is monotonic with overlapping input" do
      check all(
              line_len <- integer(5..50),
              raw_conceals <- overlapping_conceals_gen(line_len)
            ) do
        decs = build_decs_with_priority_conceals(raw_conceals)
        display_cols = for b <- 0..line_len, do: Decorations.buf_col_to_display_col(decs, 0, b)

        display_cols
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [prev, curr] ->
          assert curr >= prev,
                 "Not monotonic: #{prev} -> #{curr}, conceals=#{inspect(raw_conceals)}"
        end)
      end
    end

    property "roundtrip holds for non-concealed columns with overlapping input" do
      check all(
              line_len <- integer(5..50),
              raw_conceals <- overlapping_conceals_gen(line_len)
            ) do
        decs = build_decs_with_priority_conceals(raw_conceals)
        merged = Decorations.conceals_for_line(decs, 0)

        for buf_col <- 0..line_len,
            not inside_any_merged_conceal?(buf_col, merged) do
          display_col = Decorations.buf_col_to_display_col(decs, 0, buf_col)
          roundtrip = Decorations.display_col_to_buf_col(decs, 0, display_col)

          assert roundtrip == buf_col,
                 "Roundtrip failed: buf_col=#{buf_col} -> display_col=#{display_col} -> #{roundtrip}, " <>
                   "conceals=#{inspect(raw_conceals)}"
        end
      end
    end

    property "higher priority replacement wins on overlap" do
      check all(
              line_len <- integer(10..50),
              raw_conceals <- overlapping_conceals_gen(line_len)
            ) do
        decs = build_decs_with_priority_conceals(raw_conceals)
        merged = Decorations.conceals_for_line(decs, 0)

        for m <- merged do
          {_, ms} = m.start_pos
          {_, me} = m.end_pos

          overlapping_inputs =
            Enum.filter(raw_conceals, fn {s, e, _r, _p} -> s < me and e > ms end)

          if overlapping_inputs != [] do
            max_priority = overlapping_inputs |> Enum.map(fn {_, _, _, p} -> p end) |> Enum.max()

            top_tier =
              Enum.filter(overlapping_inputs, fn {_, _, _, p} -> p == max_priority end)

            # Only assert when there's a single unique max-priority replacement
            replacements = top_tier |> Enum.map(fn {_, _, r, _} -> r end) |> Enum.uniq()

            if length(replacements) == 1 do
              assert m.replacement == hd(replacements),
                     "Expected replacement #{inspect(hd(replacements))}, got #{inspect(m.replacement)}"
            else
              # Tie: just verify the replacement came from one of the top-tier inputs
              assert m.replacement in replacements,
                     "Replacement #{inspect(m.replacement)} not in top-tier #{inspect(replacements)}"
            end
          end
        end
      end
    end
  end
end
