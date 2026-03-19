defmodule Minga.Buffer.BlockDecorationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Decorations.BlockDecoration
  alias Minga.Editor.DisplayMap
  alias Minga.Editor.FoldMap
  alias Minga.Editor.FoldRange

  # ── CRUD ─────────────────────────────────────────────────────────────────

  describe "add_block_decoration/3" do
    test "adds a block decoration and returns its ID" do
      decs = Decorations.new()

      {id, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"▎ Agent", Minga.Face.new(fg: 0x51AFEF, bold: true)}] end
        )

      assert is_reference(id)
      assert Decorations.has_block_decorations?(decs)
    end

    test "adds multiple blocks to same anchor line" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"header", Minga.Face.new()}] end,
          priority: 1
        )

      {_, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :below,
          render: fn _w -> [{"separator", Minga.Face.new()}] end,
          priority: 2
        )

      {above, below} = Decorations.blocks_for_line(decs, 5)
      assert length(above) == 1
      assert length(below) == 1
    end

    test "increments version" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 0,
          placement: :above,
          render: fn _w -> [{"x", Minga.Face.new()}] end
        )

      assert decs.version == 1
    end
  end

  describe "remove_block_decoration/2" do
    test "removes by ID" do
      decs = Decorations.new()

      {id, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"x", Minga.Face.new()}] end
        )

      decs = Decorations.remove_block_decoration(decs, id)
      refute Decorations.has_block_decorations?(decs)
    end

    test "no-op for non-existent ID" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"x", Minga.Face.new()}] end
        )

      decs2 = Decorations.remove_block_decoration(decs, make_ref())
      assert Decorations.has_block_decorations?(decs2)
      assert decs2.version == decs.version
    end
  end

  # ── BlockDecoration struct ──────────────────────────────────────────────

  describe "resolve_height/2" do
    test "explicit height returns stored value" do
      block = %BlockDecoration{
        id: make_ref(),
        anchor_line: 0,
        placement: :above,
        height: 3,
        render: fn _w ->
          [
            [{"line1", Minga.Face.new()}],
            [{"line2", Minga.Face.new()}],
            [{"line3", Minga.Face.new()}]
          ]
        end
      }

      assert BlockDecoration.resolve_height(block, 80) == 3
    end

    test "dynamic height invokes callback and measures result" do
      block = %BlockDecoration{
        id: make_ref(),
        anchor_line: 0,
        placement: :above,
        height: :dynamic,
        render: fn _w -> [[{"line1", Minga.Face.new()}], [{"line2", Minga.Face.new()}]] end
      }

      assert BlockDecoration.resolve_height(block, 80) == 2
    end

    test "dynamic single-line returns 1" do
      block = %BlockDecoration{
        id: make_ref(),
        anchor_line: 0,
        placement: :above,
        height: :dynamic,
        render: fn _w -> [{"single", Minga.Face.new()}] end
      }

      assert BlockDecoration.resolve_height(block, 80) == 1
    end
  end

  describe "normalize_render_result/1" do
    test "single-line segments wrapped in list" do
      result = BlockDecoration.normalize_render_result([{"hello", Minga.Face.new(bold: true)}])
      assert result == [[{"hello", Minga.Face.new(bold: true)}]]
    end

    test "multi-line segments returned as-is" do
      input = [[{"line1", Minga.Face.new()}], [{"line2", Minga.Face.new()}]]
      assert BlockDecoration.normalize_render_result(input) == input
    end

    test "empty list returns empty line" do
      assert BlockDecoration.normalize_render_result([]) == [[]]
    end
  end

  # ── DisplayMap integration ──────────────────────────────────────────────

  describe "DisplayMap with block decorations" do
    test "block above appears before the buffer line" do
      fm = FoldMap.new()
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"▎ Agent", Minga.Face.new()}] end
        )

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      assert dm != nil

      entries = DisplayMap.to_visible_line_map(dm)

      block_idx =
        Enum.find_index(entries, fn {_, type} -> match?({:block, _, _}, type) end)

      normal_5_idx =
        Enum.find_index(entries, fn
          {5, :normal} -> true
          _ -> false
        end)

      assert block_idx != nil
      assert block_idx < normal_5_idx
    end

    test "block below appears after the buffer line" do
      fm = FoldMap.new()
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :below,
          render: fn _w -> [{"separator", Minga.Face.new()}] end
        )

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      entries = DisplayMap.to_visible_line_map(dm)

      block_idx =
        Enum.find_index(entries, fn {_, type} -> match?({:block, _, _}, type) end)

      normal_5_idx =
        Enum.find_index(entries, fn
          {5, :normal} -> true
          _ -> false
        end)

      assert block_idx > normal_5_idx
    end

    test "multi-line block occupies multiple display rows" do
      fm = FoldMap.new()
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 3,
          placement: :above,
          height: 3,
          render: fn _w ->
            [
              [{"line1", Minga.Face.new()}],
              [{"line2", Minga.Face.new()}],
              [{"line3", Minga.Face.new()}]
            ]
          end
        )

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      entries = DisplayMap.to_visible_line_map(dm)

      block_entries =
        Enum.filter(entries, fn {_, type} -> match?({:block, _, _}, type) end)

      assert length(block_entries) == 3

      # Each entry has a different line_index
      indices = Enum.map(block_entries, fn {_, {:block, _, idx}} -> idx end)
      assert indices == [0, 1, 2]
    end

    test "block inside closed fold is hidden" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 7,
          placement: :above,
          render: fn _w -> [{"hidden", Minga.Face.new()}] end
        )

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      entries = DisplayMap.to_visible_line_map(dm)

      block_entries =
        Enum.filter(entries, fn {_, type} -> match?({:block, _, _}, type) end)

      # Block at line 7 is inside fold 5-10, so it should be hidden
      assert block_entries == []
    end

    test "above block on fold start line remains visible when fold is closed" do
      fm = FoldMap.new() |> FoldMap.fold(FoldRange.new!(5, 10))
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"▎ Agent", Minga.Face.new(bold: true)}] end
        )

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)
      entries = DisplayMap.to_visible_line_map(dm)

      # The block above line 5 should be visible even though the fold hides 6-10
      block_entries =
        Enum.filter(entries, fn {_, type} -> match?({:block, _, _}, type) end)

      assert length(block_entries) == 1
      {5, {:block, _, 0}} = hd(block_entries)

      # And line 5 shows as fold start
      fold_entries =
        Enum.filter(entries, fn {_, type} -> match?({:fold_start, _}, type) end)

      assert length(fold_entries) == 1
    end

    test "next_visible_line skips block entries" do
      fm = FoldMap.new()
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"header", Minga.Face.new()}] end
        )

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)

      # Line 4 → next should be 5 (skipping the block entry)
      assert DisplayMap.next_visible_line(dm, 4) == 5
      # Line 5 → next should be 6 (block is above 5, doesn't affect forward nav)
      assert DisplayMap.next_visible_line(dm, 5) == 6
    end

    test "prev_visible_line skips block entries" do
      fm = FoldMap.new()
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :below,
          render: fn _w -> [{"separator", Minga.Face.new()}] end
        )

      dm = DisplayMap.compute(fm, decs, 0, 15, 20)

      # Line 6 → prev should be 5 (skipping the block below 5)
      assert DisplayMap.prev_visible_line(dm, 6) == 5
    end

    test "block consumes display rows" do
      fm = FoldMap.new()
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 0,
          placement: :above,
          render: fn _w -> [{"header", Minga.Face.new()}] end
        )

      dm = DisplayMap.compute(fm, decs, 0, 10, 20)
      entries = DisplayMap.to_visible_line_map(dm)

      # 10 display rows: 1 block + 9 normal lines (0-8)
      assert length(entries) == 10
    end
  end

  # ── Anchor adjustment ───────────────────────────────────────────────────

  describe "anchor adjustment for block decorations" do
    test "insertion before anchor shifts it" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 10,
          placement: :above,
          render: fn _w -> [{"header", Minga.Face.new()}] end
        )

      decs = Decorations.adjust_for_edit(decs, {5, 0}, {5, 0}, {8, 0})
      block = hd(decs.block_decorations)
      assert block.anchor_line == 13
    end

    test "deletion after anchor leaves it unchanged" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"header", Minga.Face.new()}] end
        )

      decs = Decorations.adjust_for_edit(decs, {10, 0}, {15, 0}, {10, 0})
      block = hd(decs.block_decorations)
      assert block.anchor_line == 5
    end

    test "deletion spanning anchor clamps to edit start" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 10,
          placement: :above,
          render: fn _w -> [{"header", Minga.Face.new()}] end
        )

      decs = Decorations.adjust_for_edit(decs, {5, 0}, {15, 0}, {5, 0})
      block = hd(decs.block_decorations)
      assert block.anchor_line == 5
    end
  end

  # ── Render callback ─────────────────────────────────────────────────────

  describe "render callback invocation" do
    test "callback receives available width" do
      :persistent_term.put(:test_block_width, nil)

      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 0,
          placement: :above,
          render: fn w ->
            :persistent_term.put(:test_block_width, w)
            [{"header", Minga.Face.new()}]
          end
        )

      # Invoke the render callback directly to verify it receives width
      block = hd(decs.block_decorations)
      block.render.(80)
      assert :persistent_term.get(:test_block_width) == 80
    after
      :persistent_term.erase(:test_block_width)
    end
  end

  # ── on_click dispatch ────────────────────────────────────────────────────

  describe "on_click field" do
    test "on_click callback is stored and callable" do
      test_pid = self()

      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"clickable", Minga.Face.new()}] end,
          on_click: fn row, col -> send(test_pid, {:block_clicked, row, col}) end
        )

      block = hd(decs.block_decorations)
      block.on_click.(0, 15)

      assert_receive {:block_clicked, 0, 15}
    end

    test "on_click is nil by default" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"header", Minga.Face.new()}] end
        )

      block = hd(decs.block_decorations)
      assert block.on_click == nil
    end
  end

  # ── empty? integration ─────────────────────────────────────────────────

  describe "empty? with block decorations" do
    test "not empty with only block decorations" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 0,
          placement: :above,
          render: fn _w -> [{"x", Minga.Face.new()}] end
        )

      refute Decorations.empty?(decs)
    end

    test "clear removes block decorations" do
      decs = Decorations.new()

      {_, decs} =
        Decorations.add_block_decoration(decs, 0,
          placement: :above,
          render: fn _w -> [{"x", Minga.Face.new()}] end
        )

      decs = Decorations.clear(decs)
      assert Decorations.empty?(decs)
    end
  end
end
