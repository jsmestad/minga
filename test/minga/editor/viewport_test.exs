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
      vp = Viewport.new(10, 80) |> Viewport.scroll_to_cursor({15, 0}, 0)
      # 10 rows, 2 for footer = 8 visible. cursor at 15 means top = 15 - 8 + 1 = 8
      assert vp.top == 8
    end

    test "scrolls up when cursor moves above top" do
      vp = %Viewport{top: 10, left: 0, rows: 24, cols: 80}
      vp = Viewport.scroll_to_cursor(vp, {5, 0}, 0)
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
      vp = Viewport.new(3, 40) |> Viewport.scroll_to_cursor({5, 0}, 0)
      # 3 rows, 2 for footer = 1 visible. cursor at 5 means top = 5 - 1 + 1 = 5
      assert vp.top == 5
    end

    test "scroll_margin keeps lines above cursor" do
      vp = %Viewport{top: 10, left: 0, rows: 24, cols: 80}
      vp = Viewport.scroll_to_cursor(vp, {8, 0}, 3)
      # Cursor at 8 with margin 3: want top = max(8-3, 0) = 5
      assert vp.top == 5
    end

    test "scroll_margin keeps lines below cursor" do
      # 24 rows - 2 footer = 22 visible; margin 3
      vp = Viewport.new(24, 80) |> Viewport.scroll_to_cursor({25, 0}, 3)
      # top = 25 - 22 + 1 + 3 = 7
      assert vp.top == 7
    end

    test "scroll_margin clamps to half visible area" do
      # 6 rows - 2 footer = 4 visible; margin 5 clamps to 1
      vp = Viewport.new(6, 80) |> Viewport.scroll_to_cursor({10, 0}, 5)
      # effective_margin = min(5, (4-1) div 2) = 1
      # top = 10 - 4 + 1 + 1 = 8
      assert vp.top == 8
    end

    test "scroll_margin zero behaves like no margin" do
      vp = Viewport.new(10, 80) |> Viewport.scroll_to_cursor({15, 0}, 0)
      assert vp.top == 8
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

  describe "gutter_width/1" do
    test "minimum width of 3 for small files (2 digits + separator)" do
      assert Viewport.gutter_width(1) == 3
      assert Viewport.gutter_width(9) == 3
      assert Viewport.gutter_width(0) == 3
    end

    test "stays at 3 for files up to 99 lines" do
      assert Viewport.gutter_width(10) == 3
      assert Viewport.gutter_width(99) == 3
    end

    test "grows to 4 for 100+ lines" do
      assert Viewport.gutter_width(100) == 4
      assert Viewport.gutter_width(999) == 4
    end

    test "grows to 5 for 1000+ lines" do
      assert Viewport.gutter_width(1000) == 5
      assert Viewport.gutter_width(9999) == 5
    end

    test "grows to 6 for 10000+ lines" do
      assert Viewport.gutter_width(10_000) == 6
    end
  end

  describe "content_cols/2" do
    test "subtracts gutter width from total cols" do
      vp = Viewport.new(24, 80)
      # 50 lines → gutter_width 3 → content_cols 77
      assert Viewport.content_cols(vp, 50) == 77
    end

    test "adjusts for larger line counts" do
      vp = Viewport.new(24, 80)
      # 1000 lines → gutter_width 5 → content_cols 75
      assert Viewport.content_cols(vp, 1000) == 75
    end

    test "minimum of 1 content column" do
      vp = Viewport.new(24, 3)
      assert Viewport.content_cols(vp, 100) >= 1
    end
  end
end
