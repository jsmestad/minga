defmodule Minga.Editing.ScrollTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Scroll

  describe "new/0" do
    test "starts pinned to bottom with offset 0" do
      s = Scroll.new()
      assert s.offset == 0
      assert s.pinned
      assert s.metrics == %{total_lines: 0, visible_height: 1}
    end
  end

  describe "new/1" do
    test "creates unpinned scroll at the given offset" do
      s = Scroll.new(42)
      assert s.offset == 42
      refute s.pinned
    end
  end

  describe "scroll_up/2" do
    test "decreases offset when unpinned" do
      s = Scroll.new(10) |> Scroll.scroll_up(3)
      assert s.offset == 7
      refute s.pinned
    end

    test "clamps to 0 when unpinned" do
      s = Scroll.new(2) |> Scroll.scroll_up(10)
      assert s.offset == 0
    end

    test "materializes from bottom when pinned" do
      s = Scroll.new() |> Scroll.update_metrics(100, 30) |> Scroll.scroll_up(5)
      # bottom = 100 - 30 = 70, then -5 = 65
      assert s.offset == 65
      refute s.pinned
    end

    test "materializes to 0 when pinned with no content" do
      s = Scroll.new() |> Scroll.scroll_up(1)
      # metrics default: total=0, height=1, bottom=0, then max(0-1,0)=0
      assert s.offset == 0
    end
  end

  describe "scroll_down/2" do
    test "increases offset when unpinned" do
      s = Scroll.new(10) |> Scroll.scroll_down(5)
      assert s.offset == 15
      refute s.pinned
    end

    test "materializes from bottom when pinned" do
      s = Scroll.new() |> Scroll.update_metrics(100, 30) |> Scroll.scroll_down(3)
      # bottom = 70, then +3 = 73
      assert s.offset == 73
      refute s.pinned
    end
  end

  describe "pin_to_bottom/1" do
    test "sets pinned without changing offset" do
      s = Scroll.new(42) |> Scroll.pin_to_bottom()
      assert s.pinned
      assert s.offset == 42
    end
  end

  describe "scroll_to_top/1" do
    test "sets offset to 0 and unpins" do
      s = Scroll.new() |> Scroll.update_metrics(100, 30) |> Scroll.scroll_to_top()
      assert s.offset == 0
      refute s.pinned
    end
  end

  describe "set_offset/2" do
    test "sets absolute offset and unpins" do
      s = Scroll.new() |> Scroll.set_offset(50)
      assert s.offset == 50
      refute s.pinned
    end
  end

  describe "update_metrics/3" do
    test "caches the provided dimensions" do
      s = Scroll.new() |> Scroll.update_metrics(200, 40)
      assert s.metrics.total_lines == 200
      assert s.metrics.visible_height == 40
    end
  end

  describe "resolve/3" do
    test "returns bottom offset when pinned" do
      s = Scroll.new()
      assert Scroll.resolve(s, 100, 30) == 70
    end

    test "returns 0 when pinned with insufficient content" do
      s = Scroll.new()
      assert Scroll.resolve(s, 10, 30) == 0
    end

    test "returns clamped offset when unpinned" do
      s = Scroll.new(50)
      assert Scroll.resolve(s, 100, 30) == 50
    end

    test "clamps offset to max when unpinned and overshooting" do
      s = Scroll.new(999)
      assert Scroll.resolve(s, 100, 30) == 70
    end
  end

  describe "multi-step scenarios" do
    test "pin → scroll_up → scroll_down round-trips correctly" do
      s =
        Scroll.new()
        |> Scroll.update_metrics(100, 30)
        |> Scroll.scroll_up(5)

      assert s.offset == 65

      s = Scroll.scroll_down(s, 5)
      assert s.offset == 70
    end

    test "repeated scroll_down from pinned doesn't produce sentinel values" do
      s =
        Scroll.new()
        |> Scroll.update_metrics(100, 30)
        |> Scroll.scroll_down(1)
        |> Scroll.scroll_down(1)
        |> Scroll.scroll_down(1)

      # First: bottom=70, +1=71. Then 72. Then 73.
      assert s.offset == 73
    end

    test "scroll_down then pin_to_bottom then scroll_up uses updated metrics" do
      s =
        Scroll.new()
        |> Scroll.update_metrics(100, 30)
        |> Scroll.scroll_down(5)

      assert s.offset == 75

      # Simulate new content arriving (metrics updated by renderer)
      s =
        s
        |> Scroll.pin_to_bottom()
        |> Scroll.update_metrics(120, 30)
        |> Scroll.scroll_up(1)

      # New bottom = 120 - 30 = 90, then -1 = 89
      assert s.offset == 89
    end
  end
end
