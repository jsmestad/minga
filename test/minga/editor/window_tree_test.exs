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

      assert {:ok, {:split, :vertical, {:leaf, 1}, {:leaf, 2}}} =
               WindowTree.split(tree, 1, :vertical, 2)
    end

    test "horizontal split" do
      tree = WindowTree.new(1)

      assert {:ok, {:split, :horizontal, {:leaf, 1}, {:leaf, 2}}} =
               WindowTree.split(tree, 1, :horizontal, 2)
    end

    test "split non-existent window returns error" do
      assert :error = WindowTree.split(WindowTree.new(1), 99, :vertical, 2)
    end

    test "nested split on right child" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 2, :horizontal, 3)

      assert {:split, :vertical, {:leaf, 1}, {:split, :horizontal, {:leaf, 2}, {:leaf, 3}}} = tree
    end

    test "nested split on left child" do
      {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
      {:ok, tree} = WindowTree.split(tree, 1, :horizontal, 3)

      assert {:split, :vertical, {:split, :horizontal, {:leaf, 1}, {:leaf, 3}}, {:leaf, 2}} = tree
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
      assert {:ok, {:split, :vertical, {:leaf, 1}, {:leaf, 3}}} =
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

      assert {:ok, 2} = WindowTree.focus_neighbor(tree, 1, :right, @screen)

      assert {:ok, 3} =
               WindowTree.focus_neighbor(tree, 1, :right, @screen)
               |> then(fn {:ok, _} ->
                 WindowTree.focus_neighbor(tree, 2, :down, @screen)
               end)

      assert {:ok, 1} = WindowTree.focus_neighbor(tree, 3, :left, @screen)
    end
  end
end
