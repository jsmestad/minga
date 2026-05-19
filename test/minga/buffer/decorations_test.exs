defmodule Minga.Core.DecorationsTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Core.Face

  defp add_hl(decs, start_pos, end_pos, opts \\ []) do
    style = Keyword.get(opts, :style, Face.new(bg: 0x3E4452))
    priority = Keyword.get(opts, :priority, 0)
    group = Keyword.get(opts, :group)

    all_opts = [style: style, priority: priority]
    all_opts = if group, do: Keyword.put(all_opts, :group, group), else: all_opts

    Decorations.add_highlight(decs, start_pos, end_pos, all_opts)
  end

  defp add_hls(specs) do
    Enum.reduce(specs, Decorations.new(), fn
      {start_pos, end_pos}, decs ->
        {_id, decs} = add_hl(decs, start_pos, end_pos)
        decs

      {start_pos, end_pos, opts}, decs ->
        {_id, decs} = add_hl(decs, start_pos, end_pos, opts)
        decs
    end)
  end

  defp add_annotation(decs, line, text, opts \\ []) do
    {_id, decs} = Decorations.add_annotation(decs, line, text, opts)
    decs
  end

  defp add_annotations(specs) do
    Enum.reduce(specs, Decorations.new(), fn
      {line, text}, decs -> add_annotation(decs, line, text)
      {line, text, opts}, decs -> add_annotation(decs, line, text, opts)
    end)
  end

  defp range(start_pos, end_pos, opts \\ []) do
    %{
      id: make_ref(),
      start: start_pos,
      end_: end_pos,
      style: Keyword.get(opts, :style, Face.new(bg: 0x3E4452)),
      priority: Keyword.get(opts, :priority, 0),
      group: Keyword.get(opts, :group)
    }
  end

  defp single_highlight_after_edit(
         initial_start,
         initial_end,
         edit_start,
         edit_end,
         new_end,
         query_line
       ) do
    decs = add_hls([{initial_start, initial_end}])
    decs = Decorations.adjust_for_edit(decs, edit_start, edit_end, new_end)
    [range] = Decorations.highlights_for_line(decs, query_line)
    range
  end

  defp annotation_lines(decs), do: Enum.map(decs.annotations, & &1.line)

  defp annotation_texts(decs, line),
    do: decs |> Decorations.annotations_for_line(line) |> Enum.map(& &1.text)

  describe "highlight storage" do
    test "new decorations are empty" do
      decs = Decorations.new()

      assert Decorations.empty?(decs)
      assert Decorations.highlight_count(decs) == 0
    end

    test "adds highlight ranges with ids, overlap support, counts, and version bumps" do
      decs = Decorations.new()
      assert decs.version == 0

      {id, decs} = add_hl(decs, {0, 0}, {0, 10})
      assert is_reference(id)
      refute Decorations.empty?(decs)
      assert Decorations.highlight_count(decs) == 1
      assert decs.version == 1

      {_id, decs} = add_hl(decs, {5, 0}, {5, 10})
      {_id, decs} = add_hl(decs, {3, 0}, {8, 0}, style: Face.new(bg: 0x00FF00))

      assert Decorations.highlight_count(decs) == 3
      assert decs.version == 3
    end

    test "removes highlights by id and ignores missing ids" do
      decs = Decorations.new()
      {id1, decs} = add_hl(decs, {0, 0}, {0, 10}, style: Face.new(bg: 0xFF0000))
      {_id2, decs} = add_hl(decs, {5, 0}, {5, 10}, style: Face.new(bg: 0x00FF00))

      decs = Decorations.remove_highlight(decs, id1)
      assert Decorations.highlight_count(decs) == 1

      assert Decorations.highlights_for_line(decs, 5)
             |> hd()
             |> Map.fetch!(:style)
             |> Map.fetch!(:bg) == 0x00FF00

      assert Decorations.remove_highlight(decs, make_ref()) |> Decorations.highlight_count() == 1
    end

    test "removes highlight groups and clears all decorations" do
      decs =
        add_hls([
          {{0, 0}, {0, 10}, [group: :search]},
          {{3, 0}, {3, 10}, [group: :search]},
          {{5, 0}, {5, 10}, [group: :diagnostics]}
        ])

      decs = Decorations.remove_group(decs, :search)
      assert Decorations.highlight_count(decs) == 1

      assert Decorations.highlights_for_line(decs, 5) |> hd() |> Map.fetch!(:group) ==
               :diagnostics

      assert Decorations.remove_group(decs, :missing) |> Decorations.highlight_count() == 1

      version = decs.version
      decs = Decorations.clear(decs)
      assert Decorations.empty?(decs)
      assert Decorations.highlight_count(decs) == 0
      assert decs.version > version
    end
  end

  describe "batch/2" do
    test "applies queued operations with a single version bump" do
      decs = add_hls([{{0, 0}, {0, 10}, [group: :old]}, {{5, 0}, {5, 10}, [group: :old]}])
      version = decs.version

      decs =
        Decorations.batch(decs, fn d ->
          d = Decorations.remove_group(d, :old)
          {_, d} = add_hl(d, {10, 0}, {10, 10}, group: :new)
          {_, d} = add_hl(d, {15, 0}, {15, 10}, group: :new)
          d
        end)

      assert decs.version == version + 1
      assert Decorations.highlight_count(decs) == 2

      assert decs
             |> Decorations.highlights_for_lines(0, 20)
             |> Enum.map(& &1.group)
             |> Enum.uniq() == [:new]
    end
  end

  describe "highlight queries" do
    test "returns ranges intersecting the line query and sorts by priority" do
      decs =
        add_hls([
          {{0, 0}, {3, 0}, [style: Face.new(bg: 0xFF0000)]},
          {{5, 0}, {8, 0}, [style: Face.new(bg: 0x00FF00), priority: 10]},
          {{5, 5}, {5, 15}, [style: Face.new(fg: 0x00FF00), priority: 5]},
          {{5, 0}, {5, 20}, [style: Face.new(bold: true), priority: 20]}
        ])

      assert decs |> Decorations.highlights_for_lines(4, 9) |> Enum.map(& &1.priority) == [
               5,
               10,
               20
             ]

      assert Decorations.highlights_for_lines(Decorations.new(), 0, 100) == []
    end

    test "returns highlights for single lines including multi-line ranges" do
      decs = add_hls([{{5, 0}, {5, 10}}, {{10, 0}, {10, 10}}, {{20, 0}, {25, 0}}])

      assert length(Decorations.highlights_for_line(decs, 5)) == 1
      assert length(Decorations.highlights_for_line(decs, 10)) == 1
      assert length(Decorations.highlights_for_line(decs, 22)) == 1
      assert Decorations.highlights_for_line(decs, 7) == []
    end
  end

  describe "adjust_for_edit/4" do
    test "adjusts highlight anchors around insertions and deletions" do
      cases = [
        {{5, 0}, {5, 10}, {2, 0}, {2, 0}, {5, 0}, 8, {8, 0}, {8, 10}},
        {{5, 0}, {10, 0}, {7, 0}, {7, 0}, {9, 0}, 5, {5, 0}, {12, 0}},
        {{10, 0}, {10, 10}, {2, 0}, {5, 0}, {2, 0}, 7, {7, 0}, {7, 10}},
        {{5, 0}, {15, 0}, {8, 0}, {11, 0}, {8, 0}, 5, {5, 0}, {12, 0}},
        {{5, 10}, {5, 20}, {5, 5}, {5, 5}, {5, 10}, 5, {5, 15}, {5, 25}},
        {{5, 10}, {5, 20}, {5, 15}, {5, 15}, {5, 18}, 5, {5, 10}, {5, 23}},
        {{10, 0}, {10, 10}, {20, 0}, {20, 0}, {21, 0}, 10, {10, 0}, {10, 10}}
      ]

      for {start_pos, end_pos, edit_start, edit_end, new_end, query_line, expected_start,
           expected_end} <- cases do
        range =
          single_highlight_after_edit(
            start_pos,
            end_pos,
            edit_start,
            edit_end,
            new_end,
            query_line
          )

        assert range.start == expected_start
        assert range.end_ == expected_end
      end
    end

    test "removes highlights fully covered by deletion and no-ops on empty decorations" do
      decs = add_hls([{{5, 0}, {8, 0}}])
      decs = Decorations.adjust_for_edit(decs, {3, 0}, {10, 0}, {3, 0})
      assert Decorations.empty?(decs)

      assert Decorations.adjust_for_edit(Decorations.new(), {0, 0}, {0, 0}, {1, 0})
             |> Decorations.empty?()
    end
  end

  describe "merge_highlights/3" do
    test "returns original segments when no ranges are present" do
      segments = [{"hello", Face.new(fg: 0xFF0000)}, {" world", Face.new(fg: 0x00FF00)}]
      assert Decorations.merge_highlights(segments, [], 0) == segments
    end

    test "applies full-line and partial ranges while preserving base properties" do
      segments = [{"hello", Face.new(fg: 0xFF0000)}, {" world", Face.new(fg: 0x00FF00)}]
      result = Decorations.merge_highlights(segments, [range({0, 0}, {1, 0})], 0)

      assert Enum.all?(result, fn {_text, style} -> style.bg == 0x3E4452 end)
      assert result |> hd() |> elem(1) |> Map.fetch!(:fg) == 0xFF0000

      result =
        Decorations.merge_highlights(
          [{"hello world", Face.new(fg: 0xFF0000)}],
          [range({0, 0}, {0, 5})],
          0
        )

      assert [{"hello", style1}, {" world", style2}] = result
      assert style1.bg == 0x3E4452
      assert style1.fg == 0xFF0000
      assert style2.bg == nil
      assert style2.fg == 0xFF0000
    end

    test "resolves overlapping ranges by priority" do
      ranges = [
        range({0, 0}, {0, 6}, style: Face.new(bg: 0xFF0000), priority: 1),
        range({0, 2}, {0, 4}, style: Face.new(bg: 0x00FF00), priority: 10)
      ]

      result = Decorations.merge_highlights([{"abcdef", Face.new()}], ranges, 0)
      assert Enum.map(result, fn {_text, style} -> style.bg end) == [0xFF0000, 0x00FF00, 0xFF0000]
    end

    test "applies ranges across multiple segments" do
      segments = [
        {"aaa", Face.new(fg: 0xFF0000)},
        {"bbb", Face.new(fg: 0x00FF00)},
        {"ccc", Face.new(fg: 0x0000FF)}
      ]

      result =
        Decorations.merge_highlights(
          segments,
          [range({0, 1}, {0, 8}, style: Face.new(bold: true))],
          0
        )

      assert length(result) >= 4
      assert {"a", first_style} = hd(result)
      refute first_style.bold || false
      assert Enum.any?(result, fn {_text, style} -> style.bold == true end)
    end

    test "handles multi-line ranges on intermediate, start, and end lines" do
      intermediate =
        Decorations.merge_highlights(
          [{"full line content", Face.new(fg: 0xFF0000)}],
          [range({3, 5}, {8, 10})],
          5
        )

      assert [{_, style}] = intermediate
      assert style.bg == 0x3E4452
      assert style.fg == 0xFF0000

      start_line =
        Decorations.merge_highlights(
          [{"0123456789", Face.new(fg: 0xFF0000)}],
          [range({0, 5}, {2, 0})],
          0
        )

      assert [{"01234", no_bg}, {"56789", with_bg}] = start_line
      assert no_bg.bg == nil
      assert with_bg.bg == 0x3E4452

      end_line =
        Decorations.merge_highlights(
          [{"0123456789", Face.new(fg: 0xFF0000)}],
          [range({0, 0}, {3, 5})],
          3
        )

      assert [{"01234", with_bg}, {"56789", no_bg}] = end_line
      assert with_bg.bg == 0x3E4452
      assert no_bg.bg == nil
    end
  end

  describe "merge_style_props/2" do
    test "overlays explicit properties and preserves base properties otherwise" do
      result =
        Decorations.merge_style_props(
          Face.new(fg: 0xFF0000, bold: true),
          Face.new(fg: 0x00FF00, bg: 0x3E4452)
        )

      assert result.fg == 0x00FF00
      assert result.bold == true
      assert result.bg == 0x3E4452

      base = Face.new(fg: 0xFF0000, bold: true)
      assert Decorations.merge_style_props(base, Face.new()) == base
      assert Decorations.merge_style_props(Face.new(), Face.new(bg: 0x3E4452)).bg == 0x3E4452
    end
  end

  describe "add_fold_region/4" do
    test "ignores single-line ranges and adds valid ranges" do
      decs = Decorations.new()
      {_id, unchanged} = Decorations.add_fold_region(decs, 5, 5, closed: true)
      assert unchanged.fold_regions == []
      assert unchanged.version == decs.version

      {_id, result} = Decorations.add_fold_region(decs, 5, 10, closed: true)
      assert length(result.fold_regions) == 1
      assert result.version == decs.version + 1
    end
  end

  describe "annotations" do
    test "adds annotations with ids, options, version bumps, and cache invalidation" do
      decs = Decorations.new()
      version = decs.version

      {id, decs} =
        Decorations.add_annotation(decs, 3, "urgent",
          kind: :inline_text,
          fg: 0xFF0000,
          bg: 0x00FF00,
          group: :tags,
          priority: 10
        )

      assert is_reference(id)
      assert Decorations.has_annotations?(decs)
      assert decs.version == version + 1

      decs = Decorations.build_ann_line_cache(decs)
      assert decs.ann_line_cache != nil
      decs = add_annotation(decs, 10, "second")
      assert decs.ann_line_cache == nil

      [ann] = Decorations.annotations_for_line(decs, 3)
      assert ann.kind == :inline_text
      assert ann.fg == 0xFF0000
      assert ann.bg == 0x00FF00
      assert ann.group == :tags
      assert ann.priority == 10
    end

    test "removes annotations by id and ignores missing ids" do
      decs = Decorations.new()
      {id1, decs} = Decorations.add_annotation(decs, 5, "first")
      {_id2, decs} = Decorations.add_annotation(decs, 10, "second")

      decs = Decorations.remove_annotation(decs, id1)
      assert Decorations.annotations_for_line(decs, 5) == []
      assert annotation_texts(decs, 10) == ["second"]

      version = decs.version
      assert Decorations.remove_annotation(decs, make_ref()).version == version
    end

    test "queries annotations by line with priority ordering and cache support" do
      decs =
        add_annotations([
          {5, "high", [priority: 20]},
          {5, "low", [priority: 5]},
          {5, "mid", [priority: 10]},
          {0, "other"}
        ])

      assert annotation_texts(decs, 5) == ["low", "mid", "high"]
      assert Decorations.annotations_for_line(decs, 10) == []
      assert length(Decorations.annotations_for_line(decs, 0)) == 1

      cached = Decorations.build_ann_line_cache(decs)
      assert cached.ann_line_cache != nil
      assert annotation_texts(cached, 5) == ["low", "mid", "high"]
      assert Decorations.annotations_for_line(cached, 3) == []
      assert Decorations.build_ann_line_cache(cached) == cached
      assert Decorations.build_ann_line_cache(Decorations.new()).ann_line_cache == %{}
    end

    test "removes annotation groups and ignores missing groups" do
      decs =
        add_annotations([
          {5, "lsp1", [group: :lsp]},
          {10, "lsp2", [group: :lsp]},
          {15, "agent", [group: :agent]}
        ])

      decs = Decorations.remove_group(decs, :lsp)
      assert Decorations.annotations_for_line(decs, 5) == []
      assert Decorations.annotations_for_line(decs, 10) == []
      assert annotation_texts(decs, 15) == ["agent"]

      assert Decorations.remove_group(decs, :missing)
             |> Decorations.annotations_for_line(15)
             |> length() == 1
    end
  end

  describe "adjust_for_edit/4 with annotations" do
    test "adjusts annotation lines around insertions and deletions" do
      cases = [
        {10, {2, 0}, {2, 0}, {5, 0}, [13]},
        {5, {20, 0}, {20, 0}, {23, 0}, [5]},
        {10, {2, 0}, {5, 0}, {2, 0}, [7]},
        {0, {0, 0}, {0, 0}, {2, 0}, [0]}
      ]

      for {line, edit_start, edit_end, new_end, expected_lines} <- cases do
        decs = add_annotation(Decorations.new(), line, "test")
        decs = Decorations.adjust_for_edit(decs, edit_start, edit_end, new_end)
        assert annotation_lines(decs) == expected_lines
      end
    end

    test "removes annotations covered by deletion and no-ops on empty annotations" do
      decs = add_annotation(Decorations.new(), 5, "test")
      decs = Decorations.adjust_for_edit(decs, {3, 0}, {8, 0}, {3, 0})
      refute Decorations.has_annotations?(decs)

      decs = Decorations.adjust_for_edit(Decorations.new(), {0, 0}, {0, 0}, {1, 0})
      refute Decorations.has_annotations?(decs)
    end
  end

  describe "annotation emptiness" do
    test "annotations affect has_annotations?/1 and empty?/1" do
      decs = Decorations.new()
      refute Decorations.has_annotations?(decs)
      assert Decorations.empty?(decs)

      decs = add_annotation(decs, 0, "test")
      assert Decorations.has_annotations?(decs)
      refute Decorations.empty?(decs)
    end
  end
end
