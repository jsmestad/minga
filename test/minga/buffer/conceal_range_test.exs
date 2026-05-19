defmodule Minga.Buffer.ConcealRangeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Core.Decorations
  alias Minga.Core.Decorations.ConcealRange
  alias Minga.Core.Face

  describe "ConcealRange" do
    test "stores defaults, replacements, line span, containment, and display width" do
      default = conceal({2, 0}, {5, 3})

      replacement =
        conceal({0, 0}, {0, 5}, replacement: "·", replacement_style: Face.new(fg: 0x555555))

      assert default.replacement == nil
      assert %Face{name: "_"} = default.replacement_style
      assert default.priority == 0
      assert default.group == nil
      assert ConcealRange.display_width(default) == 0
      assert ConcealRange.display_width(replacement) == 1
      assert replacement.replacement == "·"
      assert replacement.replacement_style.fg == 0x555555

      for line <- 2..5, do: assert(ConcealRange.spans_line?(default, line))
      for line <- [1, 6], do: refute(ConcealRange.spans_line?(default, line))

      single_line = conceal({0, 2}, {0, 5})
      for col <- 2..4, do: assert(ConcealRange.contains?(single_line, {0, col}))
      for col <- [1, 5, 6], do: refute(ConcealRange.contains?(single_line, {0, col}))
    end
  end

  describe "Decorations conceal API" do
    test "adds conceal ranges with options and versions each mutation", %{test: test_name} do
      decs = Decorations.new()
      {first_id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})

      assert is_reference(first_id)
      assert Decorations.has_conceal_ranges?(decs)
      refute Decorations.empty?(decs)
      assert decs.version == 1

      {_second_id, decs} =
        Decorations.add_conceal(decs, {0, 5}, {0, 7},
          replacement: "·",
          replacement_style: Face.new(fg: 0x555555),
          group: test_name
        )

      assert decs.version == 2
      assert length(decs.conceal_ranges) == 2

      assert Enum.any?(
               decs.conceal_ranges,
               &(&1.replacement == "·" and &1.replacement_style.fg == 0x555555 and
                   &1.group == test_name)
             )
    end

    test "removes by id, removes by group, and leaves missing ids unchanged" do
      {first_id, decs} =
        Decorations.add_conceal(Decorations.new(), {0, 0}, {0, 2}, group: :markdown)

      {_second_id, decs} = Decorations.add_conceal(decs, {0, 5}, {0, 7}, group: :markdown)
      {_third_id, decs} = Decorations.add_conceal(decs, {1, 0}, {1, 3}, group: :other)

      decs = Decorations.remove_conceal(decs, first_id)
      assert decs.version == 4
      assert length(decs.conceal_ranges) == 2

      unchanged = Decorations.remove_conceal(decs, make_ref())
      assert unchanged == decs

      only_other = Decorations.remove_conceal_group(decs, :markdown)
      assert Enum.map(only_other.conceal_ranges, & &1.group) == [:other]
      assert only_other.version == 5
    end

    test "queries conceals by line sorted by start column" do
      decs = build_decs([{0, 5, 7}, {0, 0, 2}, {1, 0, 3}])

      assert ranges_only(decs, 0) == [{0, 2}, {5, 7}]
      assert ranges_only(decs, 1) == [{0, 3}]
      assert ranges_only(decs, 2) == []
      assert Decorations.conceals_for_line(Decorations.new(), 0) == []
    end

    test "clear removes conceals and empty?/1 returns true again" do
      {_id, decs} = Decorations.add_conceal(Decorations.new(), {0, 0}, {0, 2})

      refute Decorations.empty?(decs)
      refute decs |> Decorations.clear() |> Decorations.has_conceal_ranges?()
      assert decs |> Decorations.clear() |> Decorations.empty?()
    end
  end

  describe "conceal overlap merging" do
    test "merges only truly overlapping ranges" do
      cases = [
        {[{0, 0, 3}, {0, 5, 8}, {0, 10, 12}], [{0, 3}, {5, 8}, {10, 12}]},
        {[{0, 0, 5}, {0, 5, 10}], [{0, 5}, {5, 10}]},
        {[{0, 2, 7}, {0, 5, 10}], [{2, 10}]},
        {[{0, 0, 10}, {0, 3, 6}], [{0, 10}]},
        {[{0, 0, 4}, {0, 3, 7}, {0, 6, 10}], [{0, 10}]},
        {[{0, 3, 7}, {0, 3, 10}], [{3, 10}]},
        {[{0, 4, 5}, {0, 4, 5}], [{4, 5}]}
      ]

      for {specs, expected} <- cases do
        assert ranges_only(build_decs(specs), 0) == expected
      end
    end

    test "higher priority replacement wins on overlap" do
      decs =
        build_decs([
          {0, 0, 5, replacement: "·", priority: 0},
          {0, 3, 8, replacement: "→", priority: 5}
        ])

      assert [{0, 8, "→"}] = ranges_with_replacements(decs, 0)
    end
  end

  describe "column mapping" do
    test "buffer columns map to display columns across conceal variants" do
      cases = [
        {Decorations.new(), [{5, 5}]},
        {build_decs([{0, 0, 2}]), [{0, 0}, {2, 0}, {6, 4}]},
        {build_decs([{0, 0, 2, replacement: "·"}]), [{2, 1}, {6, 5}]},
        {build_decs([{0, 0, 2}, {0, 6, 8}]), [{2, 0}, {6, 4}, {8, 4}, {10, 6}]},
        {build_decs([{1, 0, 2}]), [{5, 5}]}
      ]

      for {decs, assertions} <- cases do
        for {buf_col, display_col} <- assertions do
          assert Decorations.buf_col_to_display_col(decs, 0, buf_col) == display_col
        end
      end
    end

    test "display columns map back to buffer columns across conceal variants" do
      cases = [
        {Decorations.new(), [{5, 5}]},
        {build_decs([{0, 0, 2}]), [{0, 2}, {4, 6}]},
        {build_decs([{0, 0, 2, replacement: "·"}]), [{1, 2}]}
      ]

      for {decs, assertions} <- cases do
        for {display_col, buf_col} <- assertions do
          assert Decorations.display_col_to_buf_col(decs, 0, display_col) == buf_col
        end
      end
    end
  end

  describe "edit adjustment" do
    test "adjust_for_edit shifts, shrinks, preserves, or removes affected conceals" do
      cases = [
        {[{0, 5, 7}], {{0, 0}, {0, 0}, {0, 2}}, [{7, 9}]},
        {[{0, 0, 2}], {{0, 5}, {0, 5}, {0, 8}}, [{0, 2}]},
        {[{0, 2, 5}], {{0, 0}, {0, 6}, {0, 0}}, []},
        {[{0, 2, 8}], {{0, 4}, {0, 6}, {0, 4}}, [{2, 6}]}
      ]

      for {specs, {edit_start, edit_end, new_end}, expected} <- cases do
        adjusted =
          specs |> build_decs() |> Decorations.adjust_for_edit(edit_start, edit_end, new_end)

        assert raw_ranges(adjusted) == expected
      end
    end
  end

  describe "column mapping roundtrip" do
    property "buf_col outside conceals roundtrips through display_col" do
      check all(
              line_len <- integer(5..50),
              conceal_count <- integer(0..3),
              conceals <- conceal_ranges_gen(line_len, conceal_count)
            ) do
        decs = build_decs_with_conceals(conceals)

        for buf_col <- 0..line_len, not inside_any_conceal?(buf_col, conceals) do
          display_col = Decorations.buf_col_to_display_col(decs, 0, buf_col)
          roundtrip = Decorations.display_col_to_buf_col(decs, 0, display_col)

          assert roundtrip == buf_col,
                 "Roundtrip failed: buf_col=#{buf_col} -> display_col=#{display_col} -> #{roundtrip}, conceals=#{inspect(conceals)}"
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

        for buf_col <- 0..line_len, not inside_any_merged_conceal?(buf_col, merged) do
          display_col = Decorations.buf_col_to_display_col(decs, 0, buf_col)
          roundtrip = Decorations.display_col_to_buf_col(decs, 0, display_col)

          assert roundtrip == buf_col,
                 "Roundtrip failed: buf_col=#{buf_col} -> display_col=#{display_col} -> #{roundtrip}, conceals=#{inspect(raw_conceals)}"
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
            top_tier = Enum.filter(overlapping_inputs, fn {_, _, _, p} -> p == max_priority end)
            replacements = top_tier |> Enum.map(fn {_, _, r, _} -> r end) |> Enum.uniq()

            if length(replacements) == 1 do
              assert m.replacement == hd(replacements),
                     "Expected replacement #{inspect(hd(replacements))}, got #{inspect(m.replacement)}"
            else
              assert m.replacement in replacements,
                     "Replacement #{inspect(m.replacement)} not in top-tier #{inspect(replacements)}"
            end
          end
        end
      end
    end
  end

  defp conceal(start_pos, end_pos, opts \\ []) do
    struct!(
      ConcealRange,
      Keyword.merge([id: make_ref(), start_pos: start_pos, end_pos: end_pos], opts)
    )
  end

  defp build_decs(specs) do
    Enum.reduce(specs, Decorations.new(), fn spec, decs ->
      {line, start_col, end_col, opts} = normalize_spec(spec)
      {_id, decs} = Decorations.add_conceal(decs, {line, start_col}, {line, end_col}, opts)
      decs
    end)
  end

  defp normalize_spec({line, start_col, end_col}), do: {line, start_col, end_col, []}
  defp normalize_spec({line, start_col, end_col, opts}), do: {line, start_col, end_col, opts}

  defp ranges_only(decs, line) do
    decs
    |> Decorations.conceals_for_line(line)
    |> Enum.map(fn conceal -> {col(conceal.start_pos), col(conceal.end_pos)} end)
  end

  defp ranges_with_replacements(decs, line) do
    decs
    |> Decorations.conceals_for_line(line)
    |> Enum.map(fn conceal ->
      {col(conceal.start_pos), col(conceal.end_pos), conceal.replacement}
    end)
  end

  defp raw_ranges(decs) do
    decs.conceal_ranges
    |> Enum.map(fn conceal -> {col(conceal.start_pos), col(conceal.end_pos)} end)
    |> Enum.sort()
  end

  defp col({_line, col}), do: col

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
      constant(build_ranges(widths, line_len))
    end)
  end

  defp build_ranges(widths, line_len) do
    widths = Enum.map(widths, &min(&1, 3))

    {ranges, _cursor} =
      Enum.reduce(widths, {[], 0}, fn width, {acc, cursor} ->
        start_col = cursor + 1
        end_col = start_col + width

        if end_col <= line_len do
          {[{start_col, end_col} | acc], end_col}
        else
          {acc, cursor}
        end
      end)

    Enum.reverse(ranges)
  end

  defp build_decs_with_conceals(conceals) do
    Enum.reduce(conceals, Decorations.new(), fn {start_col, end_col, replacement}, decs ->
      opts = if replacement, do: [replacement: replacement], else: []
      {_id, decs} = Decorations.add_conceal(decs, {0, start_col}, {0, end_col}, opts)
      decs
    end)
  end

  defp inside_any_conceal?(buf_col, conceals) do
    Enum.any?(conceals, fn {start_col, end_col, _} ->
      buf_col >= start_col and buf_col < end_col
    end)
  end

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
    Enum.reduce(conceals, Decorations.new(), fn {start_col, end_col, replacement, priority},
                                                decs ->
      opts = [priority: priority]
      opts = if replacement, do: [{:replacement, replacement} | opts], else: opts
      {_id, decs} = Decorations.add_conceal(decs, {0, start_col}, {0, end_col}, opts)
      decs
    end)
  end

  defp inside_any_merged_conceal?(buf_col, merged_conceals) do
    Enum.any?(merged_conceals, fn conceal ->
      buf_col >= col(conceal.start_pos) and buf_col < col(conceal.end_pos)
    end)
  end
end
