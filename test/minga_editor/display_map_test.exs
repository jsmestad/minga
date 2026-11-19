defmodule MingaEditor.DisplayMapTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Core.Decorations.FoldRegion
  alias Minga.Core.WrapMap
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Viewport
  alias Minga.Editing.Fold.Range, as: FoldRange

  # ── No folds or decorations ──────────────────────────────────────────────

  describe "compute/5 with no folds or decorations" do
    test "returns nil for the fast path" do
      fm = FoldMap.new()
      decs = Decorations.new()
      assert DisplayMap.compute(fm, decs, 0, 30, 100) == nil
    end
  end

  # ── Per-window folds only ────────────────────────────────────────────────

  describe "compute/5 with per-window folds only" do
    test "produces entries matching FoldMap.VisibleLines behavior" do
      fm =
        FoldMap.new()
        |> FoldMap.fold(FoldRange.new!(5, 10))

      decs = Decorations.new()
      dm = DisplayMap.compute(fm, decs, 0, 15, 20)

      assert dm != nil
      entries = DisplayMap.to_visible_line_map(dm)

      # Lines 0-4 normal, line 5 is fold start (hiding 5 lines), then 11-15
      folds = Enum.filter(entries, fn {_, type} -> match?({:fold_start, _}, type) end)

      assert Enum.count(folds) == 1
      {5, {:fold_start, 5}} = hd(folds)

      # Line 6-10 should not appear
      visible_lines = Enum.map(entries, fn {line, _} -> line end)
      refute 6 in visible_lines
      refute 7 in visible_lines
      refute 10 in visible_lines
    end
  end

  # ── Decoration folds only ───────────────────────────────────────────────

  describe "compute/5 with decoration folds only" do
    test "closed decoration fold hides lines" do
      fm = FoldMap.new()

      decs = Decorations.new()
      {_id, decs} = Decorations.add_fold_region(decs, 5, 10, closed: true)

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      assert dm != nil

      entries = DisplayMap.to_visible_line_map(dm)

      # Line 5 should show as decoration fold, lines 6-10 hidden
      dec_folds =
        Enum.filter(entries, fn {_, type} -> match?({:decoration_fold, _}, type) end)

      assert Enum.count(dec_folds) == 1
      {5, {:decoration_fold, %FoldRegion{start_line: 5, end_line: 10}}} = hd(dec_folds)

      visible_lines = Enum.map(entries, fn {line, _} -> line end)
      refute 6 in visible_lines
      refute 10 in visible_lines
    end

    test "open decoration fold returns nil (fast path, nothing to map)" do
      fm = FoldMap.new()

      decs = Decorations.new()
      {_id, decs} = Decorations.add_fold_region(decs, 5, 10, closed: false)

      # Open folds don't affect display. closed_fold_regions is empty,
      # so compute returns nil for the zero-overhead fast path.
      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      assert dm == nil
    end
  end

  # ── Both per-window and decoration folds ─────────────────────────────────

  describe "compute/5 with both fold types" do
    test "both fold types hide their respective ranges" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(2, 4))

      decs = Decorations.new()
      {_id, decs} = Decorations.add_fold_region(decs, 8, 12, closed: true)

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      entries = DisplayMap.to_visible_line_map(dm)

      visible_lines = Enum.map(entries, fn {line, _} -> line end) |> MapSet.new()

      # Lines 3-4 hidden by window fold
      refute MapSet.member?(visible_lines, 3)
      refute MapSet.member?(visible_lines, 4)

      # Lines 9-12 hidden by decoration fold
      refute MapSet.member?(visible_lines, 9)
      refute MapSet.member?(visible_lines, 12)

      # Line 2 is fold start, line 8 is decoration fold start
      assert MapSet.member?(visible_lines, 2)
      assert MapSet.member?(visible_lines, 8)
    end

    test "window fold takes precedence over overlapping decoration fold" do
      # Window fold at 5-10, decoration fold at 8-15
      # Window fold hides 6-10, so decoration fold at line 8 is never reached
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      decs = Decorations.new()
      {_id, decs} = Decorations.add_fold_region(decs, 8, 15, closed: true)

      dm = DisplayMap.compute(fm, decs, 0, 20, 25)
      entries = DisplayMap.to_visible_line_map(dm)

      visible_lines = Enum.map(entries, fn {line, _} -> line end)

      # Lines 6-10 hidden by window fold
      refute 6 in visible_lines
      refute 8 in visible_lines
      refute 10 in visible_lines

      # Line 11 is visible (after window fold)
      assert 11 in visible_lines

      # Lines 12-15 should be hidden by decoration fold (starts at 8, but
      # since the fold start line 8 was hidden by the window fold, the
      # decoration fold is not activated). Lines 11-15 should be visible.
      # This is correct: a window fold that hides a decoration fold's start
      # line prevents the decoration fold from activating.
      assert 12 in visible_lines
      assert 15 in visible_lines
    end

    test "nested decoration folds: outer hides inner" do
      fm = FoldMap.new()
      decs = Decorations.new()
      {_id1, decs} = Decorations.add_fold_region(decs, 5, 15, closed: true)
      {_id2, decs} = Decorations.add_fold_region(decs, 8, 12, closed: true)

      dm = DisplayMap.compute(fm, decs, 0, 20, 25)
      entries = DisplayMap.to_visible_line_map(dm)

      visible_lines = Enum.map(entries, fn {line, _} -> line end)

      # Outer fold at 5-15 hides everything inside (including inner fold at 8-12)
      # Line 5 shows as decoration fold start
      assert 5 in visible_lines
      refute 8 in visible_lines
      refute 12 in visible_lines
      refute 15 in visible_lines

      # Line 16 is visible (after outer fold)
      assert 16 in visible_lines
    end

    test "decoration fold nested inside window fold is hidden entirely" do
      # Window fold at 2-20 hides everything including any decoration folds inside
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(2, 20))
      decs = Decorations.new()
      {_id, decs} = Decorations.add_fold_region(decs, 8, 12, closed: true)

      dm = DisplayMap.compute(fm, decs, 0, 15, 25)
      entries = DisplayMap.to_visible_line_map(dm)

      visible_lines = Enum.map(entries, fn {line, _} -> line end)
      refute 8 in visible_lines
      refute 12 in visible_lines

      # Only line 2 shows as fold start
      assert {2, {:fold_start, 18}} in entries
    end
  end

  # ── Virtual lines ────────────────────────────────────────────────────────

  describe "compute/5 with virtual lines" do
    test "virtual lines above appear before the buffer line" do
      fm = FoldMap.new()

      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"▎ Agent", Minga.Core.Face.new(bold: true)}],
          placement: :above
        )

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      entries = DisplayMap.to_visible_line_map(dm)

      # Find the virtual line entry
      vl_entries =
        Enum.filter(entries, fn {_, type} -> match?({:virtual_line, _}, type) end)

      assert Enum.count(vl_entries) == 1
      {5, {:virtual_line, _vt}} = hd(vl_entries)

      # The virtual line should appear before the normal line 5 entry
      vl_idx = Enum.find_index(entries, fn {_, t} -> match?({:virtual_line, _}, t) end)

      normal_5_idx =
        Enum.find_index(entries, fn
          {5, :normal} -> true
          _ -> false
        end)

      assert vl_idx < normal_5_idx
    end

    test "virtual lines below appear after the buffer line" do
      fm = FoldMap.new()
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"separator", Minga.Core.Face.new()}],
          placement: :below
        )

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      entries = DisplayMap.to_visible_line_map(dm)

      vl_idx = Enum.find_index(entries, fn {_, t} -> match?({:virtual_line, _}, t) end)

      normal_5_idx =
        Enum.find_index(entries, fn
          {5, :normal} -> true
          _ -> false
        end)

      assert vl_idx > normal_5_idx
    end

    test "virtual lines consume display rows" do
      fm = FoldMap.new()
      decs = Decorations.new()

      # Add 3 virtual lines above line 5
      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"header1", Minga.Core.Face.new()}],
          placement: :above
        )

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"header2", Minga.Core.Face.new()}],
          placement: :above
        )

      {_, decs} =
        Decorations.add_virtual_text(decs, {5, 0},
          segments: [{"header3", Minga.Core.Face.new()}],
          placement: :above
        )

      dm = DisplayMap.compute(fm, decs, 0, 10, 20)
      entries = DisplayMap.to_visible_line_map(dm)

      # 10 display rows: 5 normal lines (0-4) + 3 virtual lines + 2 more lines
      # Total entries should be 10
      assert Enum.count(entries) == 10
    end
  end

  # ── Coordinate translation ──────────────────────────────────────────────

  describe "display_row_for_buf_line/2" do
    test "returns correct row with folds" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(3, 6))
      decs = Decorations.new()
      dm = DisplayMap.compute(fm, decs, 0, 15, 20)

      # Line 0 is at row 0, line 3 is at row 3 (fold start), line 7 is at row 4
      assert DisplayMap.display_row_for_buf_line(dm, 0) == 0
      assert DisplayMap.display_row_for_buf_line(dm, 3) == 3
      assert DisplayMap.display_row_for_buf_line(dm, 7) == 4

      # Line 5 is hidden by fold
      assert DisplayMap.display_row_for_buf_line(dm, 5) == nil
    end
  end

  describe "to_visible_line_map/1 row ordering" do
    test "preserves display-row order with folds" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(3, 6))
      decs = Decorations.new()
      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      entries = DisplayMap.to_visible_line_map(dm)

      assert Enum.at(entries, 0) == {0, :normal}
      assert Enum.at(entries, 3) == {3, {:fold_start, 3}}
      assert Enum.at(entries, 4) == {7, :normal}
    end
  end

  test "each mixed row round-trips through the viewport anchor, including special rows" do
    folds = FoldMap.new()
    decorations = Decorations.new()
    face = Minga.Core.Face.new()

    {_, decorations} =
      Decorations.add_block_decoration(decorations, 0,
        placement: :above,
        render: fn _width -> [{"above block", face}] end
      )

    {_, decorations} =
      Decorations.add_virtual_text(decorations, {0, 0},
        placement: :above,
        segments: [{"above virtual", face}]
      )

    {_, decorations} =
      Decorations.add_virtual_text(decorations, {0, 0},
        placement: :below,
        segments: [{"below virtual", face}]
      )

    {_, decorations} =
      Decorations.add_block_decoration(decorations, 0,
        placement: :below,
        render: fn _width -> [{"below block", face}] end
      )

    [wraps] = WrapMap.compute(["abcdef"], 2)
    sources = %{0 => {"abcdef", 0, "abcdef", wraps, 3}}
    groups = folds |> DisplayMap.project(decorations, 1, 2) |> DisplayMap.source_window(0, 0, 0)
    viewport = Viewport.new(1, 2, 0)
    expected = [:block, :virtual_line, :wrapped, :wrapped, :wrapped, :virtual_line, :block]

    Enum.reduce(Enum.with_index(expected), viewport, fn {type, rank}, previous ->
      delta = if rank == 0, do: 0, else: 1
      {page, next, bottom?} = DisplayMap.visual_page(groups, folds, previous, sources, delta)
      assert [{0, entry}] = DisplayMap.to_visible_line_map(page)
      assert elem(entry, 0) == type
      assert bottom? == (rank == 6)
      assert {^page, ^next, ^bottom?} = DisplayMap.visual_page(groups, folds, next, sources, 0)
      next
    end)
  end

  test "keeps the source head at the top when wrap width changes or its last above row is removed" do
    folds = FoldMap.new()
    text = String.duplicate("a", 30)

    {id, decorations} =
      Decorations.add_virtual_text(Decorations.new(), {0, 0},
        placement: :above,
        segments: [{"header", Minga.Core.Face.new()}]
      )

    page = fn decorations, viewport, delta ->
      width = viewport.cols
      [wraps] = WrapMap.compute([text], width)
      sources = %{0 => {text, 0, text, wraps, length(wraps)}}

      groups =
        folds |> DisplayMap.project(decorations, 1, width) |> DisplayMap.source_window(0, 0, 0)

      DisplayMap.visual_page(groups, folds, viewport, sources, delta)
    end

    assert {%DisplayMap{entries: [{0, {:wrapped, 0}}]}, head, false} =
             page.(decorations, Viewport.new(1, 15, 0), 1)

    narrow = Viewport.fit_content(head, 10, 1)

    assert {%DisplayMap{entries: [{0, {:wrapped, 0}}]}, narrow_head, false} =
             page.(decorations, narrow, 0)

    assert {%DisplayMap{entries: [{0, {:wrapped, 1}}]}, _, false} =
             page.(decorations, narrow_head, 1)

    removed = Decorations.remove_virtual_text(decorations, id)

    assert {%DisplayMap{entries: [{0, {:wrapped, 0}}]}, _, false} = page.(removed, head, 0)
    assert {0, 0} = head |> Viewport.source_rows() |> Viewport.vertical_anchor()
  end

  # ── Fold region CRUD ────────────────────────────────────────────────────

  describe "decoration fold CRUD" do
    test "add and toggle fold region" do
      decs = Decorations.new()
      {id, decs} = Decorations.add_fold_region(decs, 5, 15, closed: true)

      assert Decorations.has_fold_regions?(decs)
      assert Decorations.closed_fold_regions(decs) != []

      decs = Decorations.toggle_fold_region(decs, id)
      assert Decorations.closed_fold_regions(decs) == []

      decs = Decorations.toggle_fold_region(decs, id)
      assert Decorations.closed_fold_regions(decs) != []
    end

    test "remove fold region" do
      decs = Decorations.new()
      {id, decs} = Decorations.add_fold_region(decs, 5, 15)
      assert Decorations.has_fold_regions?(decs)

      decs = Decorations.remove_fold_region(decs, id)
      refute Decorations.has_fold_regions?(decs)
    end

    test "fold_region_at finds containing fold" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_fold_region(decs, 5, 15)

      assert %FoldRegion{start_line: 5} = Decorations.fold_region_at(decs, 5)
      assert %FoldRegion{start_line: 5} = Decorations.fold_region_at(decs, 10)
      assert Decorations.fold_region_at(decs, 3) == nil
      assert Decorations.fold_region_at(decs, 16) == nil
    end

    test "fold anchor adjustment shifts on insert" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_fold_region(decs, 10, 20)

      decs = Decorations.adjust_for_edit(decs, {5, 0}, {5, 0}, {8, 0})
      fold = hd(decs.fold_regions)
      assert fold.start_line == 13
      assert fold.end_line == 23
    end

    test "fold anchor adjustment removes fold when edit spans it" do
      decs = Decorations.new()
      {_id, decs} = Decorations.add_fold_region(decs, 10, 20)

      decs = Decorations.adjust_for_edit(decs, {5, 0}, {25, 0}, {5, 0})
      assert decs.fold_regions == []
    end
  end
end
