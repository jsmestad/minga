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

    test "horizontal scroll with content_w smaller than cols (gutter scenario)" do
      # Simulates what scroll.ex does: use content_w (excluding gutter)
      # as the effective width for horizontal scroll.
      # viewport.cols = 130, gutter_w = 4, content_w = 126
      # cursor_col at 126 should trigger scroll (at the content edge)
      content_w = 126
      # reserved: 0 so content_rows == rows, isolating horizontal scroll
      vp = %Viewport{top: 0, left: 0, rows: 24, cols: content_w, reserved: 0}
      vp = Viewport.scroll_to_cursor(vp, {0, 126})
      assert vp.left == 1, "cursor at content edge should trigger horizontal scroll"
    end

    test "horizontal scroll preserves left when cursor is within content" do
      content_w = 126
      # reserved: 0 so content_rows == rows, isolating horizontal scroll
      vp = %Viewport{top: 0, left: 50, rows: 24, cols: content_w, reserved: 0}
      vp = Viewport.scroll_to_cursor(vp, {0, 100})
      assert vp.left == 50, "cursor within visible content should not change left"
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

  describe "scroll_line_up/4 with margin" do
    test "scrolls up and pushes cursor away from bottom edge" do
      # 20 visible rows (no reserved), margin 5, effective_margin = 5
      # cursor at line 19 (bottom of viewport), viewport top at 10
      vp = Viewport.new(20, 80, 0)
      vp = %{vp | top: 10}

      {new_vp, clamped} = Viewport.scroll_line_up(vp, 19, 100, 5)

      # top goes from 10 to 9
      assert new_vp.top == 9
      # max_cursor = 9 + 20 - 1 - 5 = 23, but cursor was 19, so 19 < 23, no clamp
      # But cursor 19 > new_top + visible - 1 = 28? No. 19 <= 28.
      # Wait: cursor 19 is in range. Check bottom margin: 19 > 28 - 5 = 23? No.
      assert clamped == 19
    end

    test "cursor at bottom edge gets pushed up by margin" do
      # 10 visible rows, margin 3, effective = 3
      # top = 10, cursor = 18 (= top + visible - 2, near bottom)
      vp = Viewport.new(10, 80, 0)
      vp = %{vp | top: 10}

      # After scroll up: top = 9, visible range = {9, 18}
      # max_cursor = 18 - 3 = 15
      {new_vp, clamped} = Viewport.scroll_line_up(vp, 18, 100, 3)

      assert new_vp.top == 9
      # cursor 18 > max(15, 9) = 15 → clamp to 15
      assert clamped == 15
    end

    test "scrolling up to top=0 with margin still reaches line 0" do
      # 10 visible rows, margin 4, effective = 4
      # top = 1, cursor at 9 (bottom edge)
      vp = Viewport.new(10, 80, 0)
      vp = %{vp | top: 1}

      {new_vp, clamped} = Viewport.scroll_line_up(vp, 9, 100, 4)

      # top goes to 0
      assert new_vp.top == 0
      # max_cursor = 0 + 10 - 1 - 4 = 5
      assert clamped == 5

      # Verify scroll_to_cursor won't override this top
      final_vp = Viewport.scroll_to_cursor(new_vp, {clamped, 0}, 4)
      assert final_vp.top == 0
    end

    test "repeated scroll_line_up reaches top=0 with consistent cursor" do
      # Simulate scrolling from top=15 to top=0 with 10 visible rows, margin=4
      vp = Viewport.new(10, 80, 0)
      vp = %{vp | top: 15}
      cursor = 20

      {final_vp, final_cursor} =
        Enum.reduce(1..15, {vp, cursor}, fn _, {v, c} ->
          Viewport.scroll_line_up(v, c, 100, 4)
        end)

      assert final_vp.top == 0

      # Verify render pipeline won't override: scroll_to_cursor should keep top=0
      render_vp = Viewport.scroll_to_cursor(final_vp, {final_cursor, 0}, 4)
      assert render_vp.top == 0
    end

    test "does not go below top=0" do
      vp = Viewport.new(10, 80, 0)
      vp = %{vp | top: 0}
      {new_vp, _} = Viewport.scroll_line_up(vp, 5, 100, 3)
      assert new_vp.top == 0
    end
  end

  describe "scroll_line_down/4 with margin" do
    test "scrolls down and pushes cursor away from top edge" do
      # 10 visible rows, margin 3, effective = 3
      # top = 5, cursor = 5 (at top edge)
      vp = Viewport.new(10, 80, 0)
      vp = %{vp | top: 5}

      # After scroll down: top = 6, visible range = {6, 15}
      # min_cursor = 6 + 3 = 9
      {new_vp, clamped} = Viewport.scroll_line_down(vp, 5, 100, 3)

      assert new_vp.top == 6
      # cursor 5 → first clamped to max(5, 6) = 6, then max(6, min(9, 15)) = 9
      assert clamped == 9
    end

    test "cursor in middle is not affected by margin" do
      # 20 visible rows, margin 5, effective = 5
      # top = 0, cursor = 10 (middle)
      vp = Viewport.new(20, 80, 0)

      {new_vp, clamped} = Viewport.scroll_line_down(vp, 10, 100, 5)

      assert new_vp.top == 1
      # min_cursor = 1 + 5 = 6. cursor 10 >= 6, so no push.
      assert clamped == 10
    end

    test "repeated scroll_line_down reaches bottom with consistent cursor" do
      # 10 visible rows, margin=3, 30 total lines
      vp = Viewport.new(10, 80, 0)
      cursor = 5

      {final_vp, final_cursor} =
        Enum.reduce(1..20, {vp, cursor}, fn _, {v, c} ->
          Viewport.scroll_line_down(v, c, 30, 3)
        end)

      # max_top = 30 - 10 = 20
      assert final_vp.top == 20

      # Verify render pipeline consistency
      render_vp = Viewport.scroll_to_cursor(final_vp, {final_cursor, 0}, 3)
      assert render_vp.top == 20
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

  describe "effective_rows/2" do
    test "line_spacing 1.0 returns raw rows unchanged" do
      assert Viewport.effective_rows(30, 1.0) == 30
    end

    test "line_spacing 1.5 reduces visible rows" do
      # 30 / 1.5 = 20
      assert Viewport.effective_rows(30, 1.5) == 20
    end

    test "line_spacing 1.2 reduces visible rows (GUI default)" do
      # 30 / 1.2 = 25
      assert Viewport.effective_rows(30, 1.2) == 25
    end

    test "line_spacing 2.0 halves visible rows" do
      # 20 / 2.0 = 10
      assert Viewport.effective_rows(20, 2.0) == 10
    end

    test "fractional result floors to integer" do
      # 30 / 1.3 ≈ 23.076... → 23
      assert Viewport.effective_rows(30, 1.3) == 23
    end

    test "effective_rows is always at least 1" do
      assert Viewport.effective_rows(1, 3.0) == 1
      assert Viewport.effective_rows(2, 5.0) == 1
    end

    test "default spacing (no second arg) returns raw rows" do
      assert Viewport.effective_rows(24) == 24
    end
  end
end
