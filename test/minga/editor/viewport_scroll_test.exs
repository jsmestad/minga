defmodule Minga.Editor.ViewportScrollTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Viewport

  describe "scroll_line_down/3" do
    test "scrolls viewport down one line" do
      vp = Viewport.new(10, 80, 0)
      {new_vp, _cursor} = Viewport.scroll_line_down(vp, 5, 100)
      assert new_vp.top == 1
    end

    test "clamps cursor to viewport when it would go off-screen" do
      vp = Viewport.new(10, 80, 0)
      {new_vp, clamped} = Viewport.scroll_line_down(vp, 0, 100)
      assert new_vp.top == 1
      assert clamped == 1
    end

    test "does not scroll past end of file" do
      vp = %{Viewport.new(10, 80, 0) | top: 90}
      {new_vp, _cursor} = Viewport.scroll_line_down(vp, 95, 100)
      assert new_vp.top == 90
    end

    test "cursor stays in place when still visible" do
      vp = Viewport.new(10, 80, 0)
      {_new_vp, clamped} = Viewport.scroll_line_down(vp, 5, 100)
      assert clamped == 5
    end
  end

  describe "scroll_line_up/3" do
    test "scrolls viewport up one line" do
      vp = %{Viewport.new(10, 80, 0) | top: 5}
      {new_vp, _cursor} = Viewport.scroll_line_up(vp, 5, 100)
      assert new_vp.top == 4
    end

    test "clamps cursor when it would fall below viewport" do
      vp = %{Viewport.new(10, 80, 0) | top: 5}
      {new_vp, clamped} = Viewport.scroll_line_up(vp, 14, 100)
      assert new_vp.top == 4
      assert clamped == 13
    end

    test "does not scroll above line 0" do
      vp = Viewport.new(10, 80, 0)
      {new_vp, _cursor} = Viewport.scroll_line_up(vp, 0, 100)
      assert new_vp.top == 0
    end
  end

  describe "center_on/3" do
    test "centers cursor in the middle of the viewport" do
      vp = Viewport.new(20, 80, 0)
      new_vp = Viewport.center_on(vp, 50, 100)
      assert new_vp.top == 40
    end

    test "does not scroll above line 0" do
      vp = Viewport.new(20, 80, 0)
      new_vp = Viewport.center_on(vp, 3, 100)
      assert new_vp.top == 0
    end

    test "does not scroll past end of file" do
      vp = Viewport.new(20, 80, 0)
      new_vp = Viewport.center_on(vp, 99, 100)
      assert new_vp.top == 80
    end

    test "handles small files shorter than viewport" do
      vp = Viewport.new(20, 80, 0)
      new_vp = Viewport.center_on(vp, 5, 10)
      assert new_vp.top == 0
    end
  end

  describe "top_on/4" do
    test "scrolls cursor to top of viewport" do
      vp = Viewport.new(20, 80, 0)
      new_vp = Viewport.top_on(vp, 50, 100)
      assert new_vp.top == 50
    end

    test "respects scroll margin" do
      vp = Viewport.new(20, 80, 0)
      new_vp = Viewport.top_on(vp, 50, 100, 3)
      assert new_vp.top == 47
    end

    test "does not scroll past end of file" do
      vp = Viewport.new(20, 80, 0)
      new_vp = Viewport.top_on(vp, 99, 100)
      assert new_vp.top == 80
    end

    test "clamps margin for small viewports" do
      vp = Viewport.new(5, 80, 0)
      new_vp = Viewport.top_on(vp, 50, 100, 10)
      # margin clamped to div(4, 2) = 2
      assert new_vp.top == 48
    end
  end

  describe "bottom_on/4" do
    test "scrolls cursor to bottom of viewport" do
      vp = Viewport.new(20, 80, 0)
      new_vp = Viewport.bottom_on(vp, 50, 100)
      assert new_vp.top == 31
    end

    test "respects scroll margin" do
      vp = Viewport.new(20, 80, 0)
      new_vp = Viewport.bottom_on(vp, 50, 100, 3)
      assert new_vp.top == 34
    end

    test "does not scroll above line 0" do
      vp = Viewport.new(20, 80, 0)
      new_vp = Viewport.bottom_on(vp, 5, 100)
      assert new_vp.top == 0
    end
  end
end
