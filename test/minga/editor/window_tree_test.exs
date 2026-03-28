defmodule Minga.Editor.WindowTreeTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.WindowTree

  describe "new/1" do
    test "creates a single-leaf tree" do
      tree = WindowTree.new(1)
      assert tree == {:leaf, 1}
    end
  end

  describe "leaves/1" do
    test "single leaf returns one id" do
      assert WindowTree.leaves(WindowTree.new(1)) == [1]
    end

    test "split tree returns ids in order" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert WindowTree.leaves(tree) == [1, 2]
    end
  end

  describe "count/1" do
    test "single leaf" do
      assert WindowTree.count(WindowTree.new(1)) == 1
    end

    test "after one split" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert WindowTree.count(tree) == 2
    end

    test "after nested splits" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)
      assert WindowTree.count(tree) == 3
    end
  end

  describe "member?/2" do
    test "finds existing id" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert WindowTree.member?(tree, 1)
      assert WindowTree.member?(tree, 2)
    end

    test "returns false for missing id" do
      refute WindowTree.member?(WindowTree.new(1), 99)
    end
  end

  describe "split/4" do
    test "vertical split" do
      tree = WindowTree.new(1)

      assert {:ok, {:split, :vertical, {:leaf, 1}, {:leaf, 2}, 0}} =
               WindowTree.split(tree, 1, :vertical, 2)
    end

    test "horizontal split" do
      tree = WindowTree.new(1)

      assert {:ok, {:split, :horizontal, {:leaf, 1}, {:leaf, 2}, 0}} =
               WindowTree.split(tree, 1, :horizontal, 2)
    end

    test "split non-existent window returns error" do
      assert :error = WindowTree.split(WindowTree.new(1), 99, :vertical, 2)
    end

    test "nested split on right child" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)

      assert {:split, :vertical, {:leaf, 1}, {:split, :horizontal, {:leaf, 2}, {:leaf, 3}, 0}, 0} =
               tree
    end

    test "nested split on left child" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 1, :horizontal, 3)

      assert {:split, :vertical, {:split, :horizontal, {:leaf, 1}, {:leaf, 3}, 0}, {:leaf, 2}, 0} =
               tree
    end
  end

  describe "close/2" do
    test "cannot close the last window" do
      assert :error = WindowTree.close(WindowTree.new(1), 1)
    end

    test "closing left child promotes right" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert {:ok, {:leaf, 2}} = WindowTree.close(tree, 1)
    end

    test "closing right child promotes left" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert {:ok, {:leaf, 1}} = WindowTree.close(tree, 2)
    end

    test "closing non-existent window returns error" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert :error = WindowTree.close(tree, 99)
    end

    test "closing in nested tree preserves structure" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)

      # Close window 2, window 3 should take its place
      assert {:ok, {:split, :vertical, {:leaf, 1}, {:leaf, 3}, 0}} =
               WindowTree.close(tree, 2)
    end

    test "closing in deeply nested tree" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)
      {:ok, tree} = WindowTree.split(tree, 3, :vertical, 4)

      # Close window 3, window 4 takes its place
      {:ok, tree} = WindowTree.close(tree, 3)
      assert WindowTree.leaves(tree) == [1, 2, 4]
    end
  end

  describe "layout/2" do
    @screen {0, 0, 80, 24}

    test "single window gets full screen" do
      tree = WindowTree.new(1)
      assert [{1, {0, 0, 80, 24}}] = WindowTree.layout(tree, @screen)
    end

    test "vertical split divides width with separator" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      layouts = WindowTree.layout(tree, @screen)

      assert [{1, {0, 0, left_w, 24}}, {2, {0, right_col, right_w, 24}}] = layouts

      # Left gets floor((80-1)/2) = 39, separator at 39, right starts at 40
      assert left_w == 39
      assert right_col == 40
      assert right_w == 40
      # Total: 39 + 1 (sep) + 40 = 80
      assert left_w + 1 + right_w == 80
    end

    test "horizontal split divides height" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :horizontal, 2)
      layouts = WindowTree.layout(tree, @screen)

      assert [{1, {0, 0, 80, 12}}, {2, {12, 0, 80, 12}}] = layouts
    end

    test "nested splits produce correct rects" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)
      layouts = WindowTree.layout(tree, @screen)

      assert length(layouts) == 3

      [{1, {_, _, w1, _}}, {2, {r2, _, w2, h2}}, {3, {r3, _, w3, h3}}] = layouts

      # Window 1 is left half, windows 2 and 3 share right half vertically
      assert w1 == 39
      assert w2 == w3
      assert r3 == r2 + h2
      assert h2 + h3 == 24
    end
  end

  describe "focus_neighbor/4" do
    @screen {0, 0, 80, 24}

    test "navigating right from left pane" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert {:ok, 2} = WindowTree.focus_neighbor(tree, 1, :right, @screen)
    end

    test "navigating left from right pane" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert {:ok, 1} = WindowTree.focus_neighbor(tree, 2, :left, @screen)
    end

    test "navigating down from top pane" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :horizontal, 2)
      assert {:ok, 2} = WindowTree.focus_neighbor(tree, 1, :down, @screen)
    end

    test "navigating up from bottom pane" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :horizontal, 2)
      assert {:ok, 1} = WindowTree.focus_neighbor(tree, 2, :up, @screen)
    end

    test "no neighbor returns error" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert :error = WindowTree.focus_neighbor(tree, 1, :left, @screen)
      assert :error = WindowTree.focus_neighbor(tree, 2, :right, @screen)
    end

    test "no neighbor in single window" do
      tree = WindowTree.new(1)
      assert :error = WindowTree.focus_neighbor(tree, 1, :right, @screen)
    end

    test "navigating in nested layout" do
      # [1] | [2]
      #     | [3]
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)

      # Window 1 is tall (full height), so its center is between windows 2 and 3.
      # The nearest right neighbor depends on center-to-center distance.
      {:ok, right_neighbor} = WindowTree.focus_neighbor(tree, 1, :right, @screen)
      assert right_neighbor in [2, 3]

      assert {:ok, 3} = WindowTree.focus_neighbor(tree, 2, :down, @screen)

      assert {:ok, 1} = WindowTree.focus_neighbor(tree, 3, :left, @screen)
    end
  end

  # ── resize_at/5 ──────────────────────────────────────────────────────────────

  describe "resize_at/5" do
    @screen {0, 0, 80, 24}

    test "vertical resize moves separator right" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      # Default split: size=0, usable=79, left_width=39, separator at col 39
      layouts_before = WindowTree.layout(tree, @screen)
      [{1, {_, _, left_w_before, _}}, _] = layouts_before
      assert left_w_before == 39

      # Move separator from col 39 to col 50
      {:ok, resized} = WindowTree.resize_at(tree, @screen, :vertical, 39, 50)
      layouts_after = WindowTree.layout(resized, @screen)
      [{1, {_, _, left_w_after, _}}, {2, {_, _, right_w_after, _}}] = layouts_after

      assert left_w_after == 50
      assert right_w_after == 29
      assert left_w_after + 1 + right_w_after == 80
    end

    test "vertical resize moves separator left" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      # Separator at col 39, move to col 20
      {:ok, resized} = WindowTree.resize_at(tree, @screen, :vertical, 39, 20)
      [{1, {_, _, left_w, _}}, {2, {_, _, right_w, _}}] = WindowTree.layout(resized, @screen)

      assert left_w == 20
      assert right_w == 59
      assert left_w + 1 + right_w == 80
    end

    test "vertical resize clamps to minimum of 1 column" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      # Try to move separator to col 0 (past left boundary)
      {:ok, resized} = WindowTree.resize_at(tree, @screen, :vertical, 39, 0)
      [{1, {_, _, left_w, _}}, _] = WindowTree.layout(resized, @screen)

      assert left_w >= 1
    end

    test "vertical resize clamps to maximum (usable - 1)" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      # Try to move separator to col 79 (past right boundary)
      {:ok, resized} = WindowTree.resize_at(tree, @screen, :vertical, 39, 79)
      [{1, {_, _, left_w, _}}, {2, {_, _, right_w, _}}] = WindowTree.layout(resized, @screen)

      assert right_w >= 1
      assert left_w + 1 + right_w == 80
    end

    test "horizontal resize moves separator down" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :horizontal, 2)
      # Default: size=0, top_height=12, modeline_row=11
      {:ok, resized} = WindowTree.resize_at(tree, @screen, :horizontal, 11, 16)

      [{1, {_, _, _, top_h}}, {2, {bottom_row, _, _, bottom_h}}] =
        WindowTree.layout(resized, @screen)

      # new_top_height = max(min(16 - 0 + 1, 24 - 1), 1) = 17
      assert top_h == 17
      assert bottom_row == 17
      assert top_h + bottom_h == 24
    end

    test "horizontal resize moves separator up" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :horizontal, 2)
      # Default modeline_row=11. Move up to row 4.
      {:ok, resized} = WindowTree.resize_at(tree, @screen, :horizontal, 11, 4)
      [{1, {_, _, _, top_h}}, {2, {_, _, _, bottom_h}}] = WindowTree.layout(resized, @screen)

      # new_top_height = max(min(4 - 0 + 1, 23), 1) = 5
      assert top_h == 5
      assert top_h + bottom_h == 24
    end

    test "returns error for nonexistent separator position" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert :error = WindowTree.resize_at(tree, @screen, :vertical, 99, 50)
    end

    test "returns error for leaf tree" do
      tree = WindowTree.new(1)
      assert :error = WindowTree.resize_at(tree, @screen, :vertical, 39, 50)
    end

    test "nested: resize inner vertical split, outer unaffected" do
      # [1] | [2]
      #     | [3]
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)

      # The outer vertical separator is at col 39.
      # Inner horizontal split: right side gets cols 40..79 (width 40),
      # top_height = div(24, 2) = 12, modeline_row = 40_col_start? No — it's a row.
      # Right subtree rect: {0, 40, 40, 24}. top_height = 12, modeline_row = 0 + 12 - 1 = 11.
      # Resize the inner horizontal separator (at row 11) to row 15.
      {:ok, resized} = WindowTree.resize_at(tree, @screen, :horizontal, 11, 15)

      layouts = WindowTree.layout(resized, @screen)

      # Window 1 should be unchanged (full left side)
      [{1, {_, _, w1, h1}} | _] = layouts
      assert w1 == 39
      assert h1 == 24
    end

    test "resize with mismatched direction returns error when no matching separator" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      # Pure vertical split has no horizontal separator; any row position returns error
      assert :error = WindowTree.resize_at(tree, @screen, :horizontal, 11, 5)
    end
  end

  # ── window_at/4 ──────────────────────────────────────────────────────────────

  describe "window_at/4" do
    @screen {0, 0, 80, 24}

    test "single window: any coordinate returns that window" do
      tree = WindowTree.new(1)
      assert {:ok, 1, {0, 0, 80, 24}} = WindowTree.window_at(tree, @screen, 0, 0)
      assert {:ok, 1, {0, 0, 80, 24}} = WindowTree.window_at(tree, @screen, 12, 40)
      assert {:ok, 1, {0, 0, 80, 24}} = WindowTree.window_at(tree, @screen, 23, 79)
    end

    test "single window: outside bounds returns error" do
      tree = WindowTree.new(1)
      assert :error = WindowTree.window_at(tree, @screen, 24, 0)
      assert :error = WindowTree.window_at(tree, @screen, 0, 80)
    end

    test "vertical split: left side" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      # Left: {0, 0, 39, 24}, separator at col 39, right: {0, 40, 40, 24}
      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 12, 0)
      assert id == 1

      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 12, 38)
      assert id == 1
    end

    test "vertical split: right side" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 12, 40)
      assert id == 2

      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 12, 79)
      assert id == 2
    end

    test "vertical split: separator column returns error" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      # Separator is at col 39
      assert :error = WindowTree.window_at(tree, @screen, 12, 39)
    end

    test "horizontal split: top side" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :horizontal, 2)
      # Top: {0, 0, 80, 12}, bottom: {12, 0, 80, 12}
      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 0, 40)
      assert id == 1

      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 11, 40)
      assert id == 1
    end

    test "horizontal split: bottom side" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :horizontal, 2)
      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 12, 40)
      assert id == 2

      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 23, 40)
      assert id == 2
    end

    test "nested splits: correct window at various coordinates" do
      # [1] | [2]
      #     | [3]
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)

      # Window 1: left side, full height {0, 0, 39, 24}
      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 12, 10)
      assert id == 1

      # Window 2: top-right {0, 40, 40, 12}
      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 5, 50)
      assert id == 2

      # Window 3: bottom-right {12, 40, 40, 12}
      {:ok, id, _rect} = WindowTree.window_at(tree, @screen, 15, 50)
      assert id == 3
    end

    test "nested splits with offset screen rect" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      screen = {5, 10, 80, 24}

      {:ok, id, _rect} = WindowTree.window_at(tree, screen, 10, 15)
      assert id == 1

      {:ok, id, _rect} = WindowTree.window_at(tree, screen, 10, 55)
      assert id == 2
    end
  end

  # ── separator_at/4 ──────────────────────────────────────────────────────────

  describe "separator_at/4" do
    @screen {0, 0, 80, 24}

    test "vertical split: separator detected at correct column" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      # Separator at col 39, any row within bounds
      assert {:ok, {:vertical, 39}} = WindowTree.separator_at(tree, @screen, 0, 39)
      assert {:ok, {:vertical, 39}} = WindowTree.separator_at(tree, @screen, 12, 39)
      assert {:ok, {:vertical, 39}} = WindowTree.separator_at(tree, @screen, 23, 39)
    end

    test "vertical split: non-separator column returns error" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      assert :error = WindowTree.separator_at(tree, @screen, 12, 38)
      assert :error = WindowTree.separator_at(tree, @screen, 12, 40)
      assert :error = WindowTree.separator_at(tree, @screen, 12, 0)
    end

    test "horizontal split: separator detected at modeline row" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :horizontal, 2)
      # top_height = 12, modeline_row = 11
      assert {:ok, {:horizontal, 11}} = WindowTree.separator_at(tree, @screen, 11, 0)
      assert {:ok, {:horizontal, 11}} = WindowTree.separator_at(tree, @screen, 11, 40)
      assert {:ok, {:horizontal, 11}} = WindowTree.separator_at(tree, @screen, 11, 79)
    end

    test "horizontal split: non-separator row returns error" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :horizontal, 2)
      assert :error = WindowTree.separator_at(tree, @screen, 10, 40)
      assert :error = WindowTree.separator_at(tree, @screen, 12, 40)
    end

    test "single window: always returns error" do
      tree = WindowTree.new(1)
      assert :error = WindowTree.separator_at(tree, @screen, 12, 39)
      assert :error = WindowTree.separator_at(tree, @screen, 0, 0)
    end

    test "nested splits: detects outer vertical separator" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)

      # Outer vertical separator at col 39
      assert {:ok, {:vertical, 39}} = WindowTree.separator_at(tree, @screen, 12, 39)
    end

    test "nested splits: detects inner horizontal separator" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)

      # Inner horizontal separator: right subtree at {0, 40, 40, 24}
      # top_height = div(24, 2) = 12, modeline_row = 0 + 12 - 1 = 11
      assert {:ok, {:horizontal, 11}} = WindowTree.separator_at(tree, @screen, 11, 50)
    end

    test "vertical split: separator row outside bounds returns error" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      # Row 24 is outside height 24 (rows 0-23)
      assert :error = WindowTree.separator_at(tree, @screen, 24, 39)
    end

    test "offset screen rect: separator position accounts for offset" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      screen = {5, 10, 80, 24}
      # Separator at col 10 + 39 = 49
      assert {:ok, {:vertical, 49}} = WindowTree.separator_at(tree, screen, 15, 49)
      assert :error = WindowTree.separator_at(tree, screen, 15, 39)
    end
  end

  # ── clamp_size/2 ─────────────────────────────────────────────────────────────

  describe "clamp_size/2" do
    test "zero means half" do
      assert WindowTree.clamp_size(0, 80) == 40
      assert WindowTree.clamp_size(0, 79) == 39
    end

    test "positive size is clamped to [1, total-1]" do
      assert WindowTree.clamp_size(50, 80) == 50
      assert WindowTree.clamp_size(1, 80) == 1
      assert WindowTree.clamp_size(79, 80) == 79
    end

    test "size exceeding total is clamped" do
      assert WindowTree.clamp_size(100, 80) == 79
    end

    test "size of zero with small total" do
      assert WindowTree.clamp_size(0, 2) == 1
      assert WindowTree.clamp_size(0, 1) == 0
    end
  end
end
