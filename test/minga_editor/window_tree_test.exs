defmodule MingaEditor.WindowTreeTest do
  use ExUnit.Case, async: true

  alias MingaEditor.WindowTree

  @screen {0, 0, 80, 24}

  describe "basic tree queries" do
    test "new tree starts as one leaf" do
      assert WindowTree.new(1) == {:leaf, 1}
      assert WindowTree.leaves(WindowTree.new(1)) == [1]
      assert WindowTree.count(WindowTree.new(1)) == 1
      assert WindowTree.member?(WindowTree.new(1), 1)
      refute WindowTree.member?(WindowTree.new(1), 99)
    end

    test "nested split preserves ordered leaves, count, and membership" do
      tree = nested_tree()

      assert WindowTree.leaves(tree) == [1, 2, 3]
      assert WindowTree.count(tree) == 3
      for id <- [1, 2, 3], do: assert(WindowTree.member?(tree, id))
      refute WindowTree.member?(tree, 99)
    end
  end

  describe "split/4" do
    test "splits leaves by direction and reports missing targets" do
      assert {:ok, {:split, :vertical, {:leaf, 1}, {:leaf, 2}, 0}} =
               WindowTree.split(WindowTree.new(1), 1, :vertical, 2)

      assert {:ok, {:split, :horizontal, {:leaf, 1}, {:leaf, 2}, 0}} =
               WindowTree.split(WindowTree.new(1), 1, :horizontal, 2)

      assert :error = WindowTree.split(WindowTree.new(1), 99, :vertical, 2)
    end

    test "splits nested leaves without reordering siblings" do
      {:ok, right_nested} = WindowTree.split(two_pane_tree(), 2, :horizontal, 3)
      {:ok, left_nested} = WindowTree.split(two_pane_tree(), 1, :horizontal, 3)

      assert right_nested ==
               {:split, :vertical, {:leaf, 1}, {:split, :horizontal, {:leaf, 2}, {:leaf, 3}, 0},
                0}

      assert left_nested ==
               {:split, :vertical, {:split, :horizontal, {:leaf, 1}, {:leaf, 3}, 0}, {:leaf, 2},
                0}
    end
  end

  describe "close/2" do
    test "closes leaves by promoting the sibling, but not the last window" do
      assert :error = WindowTree.close(WindowTree.new(1), 1)
      assert {:ok, {:leaf, 2}} = WindowTree.close(two_pane_tree(), 1)
      assert {:ok, {:leaf, 1}} = WindowTree.close(two_pane_tree(), 2)
      assert :error = WindowTree.close(two_pane_tree(), 99)
    end

    test "closes nested leaves while preserving surviving layout" do
      assert {:ok, {:split, :vertical, {:leaf, 1}, {:leaf, 3}, 0}} =
               WindowTree.close(nested_tree(), 2)

      tree = nested_tree() |> split!(3, :vertical, 4) |> close!(3)
      assert WindowTree.leaves(tree) == [1, 2, 4]
    end
  end

  describe "layout/2" do
    test "computes single, vertical, horizontal, and nested rects" do
      assert WindowTree.layout(WindowTree.new(1), @screen) == [{1, {0, 0, 80, 24}}]

      assert WindowTree.layout(two_pane_tree(), @screen) == [
               {1, {0, 0, 39, 24}},
               {2, {0, 40, 40, 24}}
             ]

      assert WindowTree.layout(split!(WindowTree.new(1), 1, :horizontal, 2), @screen) == [
               {1, {0, 0, 80, 12}},
               {2, {12, 0, 80, 12}}
             ]

      layouts = WindowTree.layout(nested_tree(), @screen)
      assert length(layouts) == 3
      [{1, {_, _, w1, _}}, {2, {r2, _, w2, h2}}, {3, {r3, _, w3, h3}}] = layouts
      assert w1 == 39
      assert w2 == w3
      assert r3 == r2 + h2
      assert h2 + h3 == 24
    end
  end

  describe "focus_neighbor/4" do
    test "finds cardinal neighbors and reports missing neighbors" do
      vertical = two_pane_tree()
      horizontal = split!(WindowTree.new(1), 1, :horizontal, 2)

      assert {:ok, 2} = WindowTree.focus_neighbor(vertical, 1, :right, @screen)
      assert {:ok, 1} = WindowTree.focus_neighbor(vertical, 2, :left, @screen)
      assert {:ok, 2} = WindowTree.focus_neighbor(horizontal, 1, :down, @screen)
      assert {:ok, 1} = WindowTree.focus_neighbor(horizontal, 2, :up, @screen)
      assert :error = WindowTree.focus_neighbor(vertical, 1, :left, @screen)
      assert :error = WindowTree.focus_neighbor(vertical, 2, :right, @screen)
      assert :error = WindowTree.focus_neighbor(WindowTree.new(1), 1, :right, @screen)
    end

    test "navigates nested layouts by nearest visible neighbor" do
      tree = nested_tree()

      assert {:ok, right_neighbor} = WindowTree.focus_neighbor(tree, 1, :right, @screen)
      assert right_neighbor in [2, 3]
      assert {:ok, 3} = WindowTree.focus_neighbor(tree, 2, :down, @screen)
      assert {:ok, 1} = WindowTree.focus_neighbor(tree, 3, :left, @screen)
    end
  end

  describe "resize_at/5" do
    test "resizes vertical and horizontal separators within bounds" do
      cases = [
        {:vertical, 39, 50, [{1, {0, 0, 50, 24}}, {2, {0, 51, 29, 24}}]},
        {:vertical, 39, 20, [{1, {0, 0, 20, 24}}, {2, {0, 21, 59, 24}}]},
        {:horizontal, 11, 16, [{1, {0, 0, 80, 17}}, {2, {17, 0, 80, 7}}]},
        {:horizontal, 11, 4, [{1, {0, 0, 80, 5}}, {2, {5, 0, 80, 19}}]}
      ]

      for {direction, old_pos, new_pos, expected_layout} <- cases do
        tree =
          if direction == :vertical,
            do: two_pane_tree(),
            else: split!(WindowTree.new(1), 1, :horizontal, 2)

        assert {:ok, resized} = WindowTree.resize_at(tree, @screen, direction, old_pos, new_pos)
        assert WindowTree.layout(resized, @screen) == expected_layout
      end
    end

    test "clamps vertical resize to non-empty panes" do
      for new_pos <- [0, 79] do
        assert {:ok, resized} =
                 WindowTree.resize_at(two_pane_tree(), @screen, :vertical, 39, new_pos)

        [{1, {_, _, left_w, _}}, {2, {_, _, right_w, _}}] = WindowTree.layout(resized, @screen)
        assert left_w >= 1
        assert right_w >= 1
        assert left_w + 1 + right_w == 80
      end
    end

    test "reports missing separators and only resizes the matching nested separator" do
      assert :error = WindowTree.resize_at(two_pane_tree(), @screen, :vertical, 99, 50)
      assert :error = WindowTree.resize_at(WindowTree.new(1), @screen, :vertical, 39, 50)
      assert :error = WindowTree.resize_at(two_pane_tree(), @screen, :horizontal, 11, 5)

      assert {:ok, resized} = WindowTree.resize_at(nested_tree(), @screen, :horizontal, 11, 15)
      [{1, {_, _, w1, h1}} | _] = WindowTree.layout(resized, @screen)
      assert w1 == 39
      assert h1 == 24
    end
  end

  describe "reset_split_at/4" do
    test "resets vertical, horizontal, and nested matching separators" do
      vertical = two_pane_tree() |> resize!(:vertical, 39, 30)
      assert {:ok, reset} = WindowTree.reset_split_at(vertical, @screen, :vertical, 30)
      assert WindowTree.layout(reset, @screen) == [{1, {0, 0, 39, 24}}, {2, {0, 40, 40, 24}}]

      horizontal = WindowTree.new(1) |> split!(1, :horizontal, 2) |> resize!(:horizontal, 11, 16)
      assert {:ok, reset} = WindowTree.reset_split_at(horizontal, @screen, :horizontal, 16)
      assert WindowTree.layout(reset, @screen) == [{1, {0, 0, 80, 12}}, {2, {12, 0, 80, 12}}]

      nested = resize!(nested_tree(), :horizontal, 11, 16)

      assert {:ok,
              {:split, :vertical, {:leaf, 1}, {:split, :horizontal, {:leaf, 2}, {:leaf, 3}, 0}, 0}} =
               WindowTree.reset_split_at(nested, @screen, :horizontal, 16)
    end

    test "reports missing or ambiguous separators unless an exact coordinate is provided" do
      ambiguous =
        {:split, :horizontal, {:split, :vertical, {:leaf, 1}, {:leaf, 2}, 39},
         {:split, :vertical, {:leaf, 3}, {:leaf, 4}, 39}, 0}

      assert :error = WindowTree.reset_split_at(two_pane_tree(), @screen, :vertical, 99)
      assert :error = WindowTree.reset_split_at(ambiguous, @screen, :vertical, 39)

      assert {:ok,
              {:split, :horizontal, {:split, :vertical, {:leaf, 1}, {:leaf, 2}, 39},
               {:split, :vertical, {:leaf, 3}, {:leaf, 4}, 0}, 0}} =
               WindowTree.reset_split_at_coordinate(ambiguous, @screen, 18, 39)
    end
  end

  describe "window_at/4" do
    test "maps coordinates to windows and rejects separators or out-of-bounds points" do
      assert {:ok, 1, {0, 0, 80, 24}} = WindowTree.window_at(WindowTree.new(1), @screen, 12, 40)
      assert :error = WindowTree.window_at(WindowTree.new(1), @screen, 24, 0)
      assert :error = WindowTree.window_at(WindowTree.new(1), @screen, 0, 80)

      vertical = two_pane_tree()
      assert_window_at(vertical, @screen, 12, 0, 1)
      assert_window_at(vertical, @screen, 12, 38, 1)
      assert :error = WindowTree.window_at(vertical, @screen, 12, 39)
      assert_window_at(vertical, @screen, 12, 40, 2)
      assert_window_at(vertical, @screen, 12, 79, 2)

      horizontal = split!(WindowTree.new(1), 1, :horizontal, 2)
      assert_window_at(horizontal, @screen, 0, 40, 1)
      assert_window_at(horizontal, @screen, 11, 40, 1)
      assert_window_at(horizontal, @screen, 12, 40, 2)
      assert_window_at(horizontal, @screen, 23, 40, 2)
    end

    test "maps nested and offset coordinates" do
      tree = nested_tree()
      assert_window_at(tree, @screen, 12, 10, 1)
      assert_window_at(tree, @screen, 5, 50, 2)
      assert_window_at(tree, @screen, 15, 50, 3)

      screen = {5, 10, 80, 24}
      assert_window_at(two_pane_tree(), screen, 10, 15, 1)
      assert_window_at(two_pane_tree(), screen, 10, 55, 2)
    end
  end

  describe "separator_at/4" do
    test "detects vertical, horizontal, nested, and offset separators" do
      vertical = two_pane_tree()

      for row <- [0, 12, 23],
          do: assert({:ok, {:vertical, 39}} = WindowTree.separator_at(vertical, @screen, row, 39))

      for col <- [0, 38, 40],
          do: assert(:error = WindowTree.separator_at(vertical, @screen, 12, col))

      assert :error = WindowTree.separator_at(vertical, @screen, 24, 39)

      horizontal = split!(WindowTree.new(1), 1, :horizontal, 2)

      for col <- [0, 40, 79],
          do:
            assert(
              {:ok, {:horizontal, 11}} = WindowTree.separator_at(horizontal, @screen, 11, col)
            )

      for row <- [10, 12],
          do: assert(:error = WindowTree.separator_at(horizontal, @screen, row, 40))

      assert :error = WindowTree.separator_at(WindowTree.new(1), @screen, 12, 39)

      nested = nested_tree()
      assert {:ok, {:vertical, 39}} = WindowTree.separator_at(nested, @screen, 12, 39)
      assert {:ok, {:horizontal, 11}} = WindowTree.separator_at(nested, @screen, 11, 50)

      screen = {5, 10, 80, 24}
      assert {:ok, {:vertical, 49}} = WindowTree.separator_at(vertical, screen, 15, 49)
      assert :error = WindowTree.separator_at(vertical, screen, 15, 39)
    end
  end

  describe "clamp_size/2" do
    test "returns half for zero and clamps explicit sizes to valid ranges" do
      cases = [
        {{0, 80}, 40},
        {{0, 79}, 39},
        {{50, 80}, 50},
        {{1, 80}, 1},
        {{79, 80}, 79},
        {{100, 80}, 79},
        {{0, 2}, 1},
        {{0, 1}, 0}
      ]

      for {{size, total}, expected} <- cases do
        assert WindowTree.clamp_size(size, total) == expected
      end
    end
  end

  defp two_pane_tree do
    split!(WindowTree.new(1), 1, :vertical, 2)
  end

  defp nested_tree do
    two_pane_tree() |> split!(2, :horizontal, 3)
  end

  defp split!(tree, target_id, direction, new_id) do
    assert {:ok, tree} = WindowTree.split(tree, target_id, direction, new_id)
    tree
  end

  defp close!(tree, id) do
    assert {:ok, tree} = WindowTree.close(tree, id)
    tree
  end

  defp resize!(tree, direction, old_pos, new_pos) do
    assert {:ok, tree} = WindowTree.resize_at(tree, @screen, direction, old_pos, new_pos)
    tree
  end

  defp assert_window_at(tree, screen, row, col, expected_id) do
    assert {:ok, ^expected_id, _rect} = WindowTree.window_at(tree, screen, row, col)
  end
end
