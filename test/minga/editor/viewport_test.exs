defmodule Minga.Editor.ViewportTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Viewport

  describe "new/2" do
    test "creates viewport with given dimensions" do
      vp = Viewport.new(24, 80)
      assert vp.top == 0
      assert vp.left == 0
      assert vp.rows == 24
      assert vp.cols == 80
    end
  end

  describe "scroll_to_cursor/2" do
    test "no scroll when cursor is within viewport" do
      vp = Viewport.new(24, 80) |> Viewport.scroll_to_cursor({5, 10})
      assert vp.top == 0
      assert vp.left == 0
    end

    test "scrolls down when cursor moves past bottom" do
      vp = Viewport.new(10, 80) |> Viewport.scroll_to_cursor({15, 0})
      # 10 rows, 2 for footer = 8 visible. cursor at 15 means top = 15 - 8 + 1 = 8
      assert vp.top == 8
    end

    test "scrolls up when cursor moves above top" do
      vp = %Viewport{top: 10, left: 0, rows: 24, cols: 80}
      vp = Viewport.scroll_to_cursor(vp, {5, 0})
      assert vp.top == 5
    end

    test "scrolls right when cursor moves past right edge" do
      vp = Viewport.new(24, 20) |> Viewport.scroll_to_cursor({0, 25})
      assert vp.left == 6
    end

    test "scrolls left when cursor moves before left edge" do
      vp = %Viewport{top: 0, left: 10, rows: 24, cols: 80}
      vp = Viewport.scroll_to_cursor(vp, {0, 5})
      assert vp.left == 5
    end

    test "handles cursor at origin" do
      vp = Viewport.new(24, 80) |> Viewport.scroll_to_cursor({0, 0})
      assert vp.top == 0
      assert vp.left == 0
    end

    test "handles very small terminal (3 rows)" do
      vp = Viewport.new(3, 40) |> Viewport.scroll_to_cursor({5, 0})
      # 3 rows, 2 for footer = 1 visible. cursor at 5 means top = 5 - 1 + 1 = 5
      assert vp.top == 5
    end
  end

  describe "visible_range/1" do
    test "returns correct range for standard terminal" do
      vp = Viewport.new(24, 80)
      # 24 rows - 2 footer = 22 content rows → lines 0..21
      assert Viewport.visible_range(vp) == {0, 21}
    end

    test "returns correct range when scrolled" do
      vp = %Viewport{top: 10, left: 0, rows: 24, cols: 80}
      assert Viewport.visible_range(vp) == {10, 31}
    end

    test "handles small terminal" do
      vp = Viewport.new(2, 80)
      assert Viewport.visible_range(vp) == {0, 0}
    end
  end

  describe "content_rows/1" do
    test "returns rows minus footer for content" do
      vp = Viewport.new(24, 80)
      assert Viewport.content_rows(vp) == 22
    end

    test "minimum of 1 content row" do
      vp = Viewport.new(1, 80)
      assert Viewport.content_rows(vp) == 1
    end
  end
end
