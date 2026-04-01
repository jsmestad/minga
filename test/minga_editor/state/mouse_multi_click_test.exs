defmodule MingaEditor.State.MouseMultiClickTest do
  @moduledoc "Tests for multi-click detection logic in Mouse state."
  use ExUnit.Case, async: true

  alias MingaEditor.State.Mouse

  describe "record_press/4 multi-click detection" do
    test "first press at any position gives click_count 1" do
      mouse = %Mouse{} |> Mouse.record_press(5, 10, 1)
      assert mouse.click_count == 1
    end

    test "native click_count > 1 is used directly (GUI)" do
      mouse = %Mouse{} |> Mouse.record_press(5, 10, 2)
      assert mouse.click_count == 2
    end

    test "native click_count 3 is used directly" do
      mouse = %Mouse{} |> Mouse.record_press(5, 10, 3)
      assert mouse.click_count == 3
    end

    test "native click_count clamped to max 3" do
      mouse = %Mouse{} |> Mouse.record_press(5, 10, 5)
      assert mouse.click_count == 3
    end

    test "two rapid presses at same position gives click_count 2" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)

      assert mouse.click_count == 2
    end

    test "three rapid presses at same position gives click_count 3" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)

      assert mouse.click_count == 3
    end

    test "four rapid presses cycles back to click_count 1" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)

      assert mouse.click_count == 1
    end

    test "press at different position resets click_count to 1" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(20, 30, 1)

      assert mouse.click_count == 1
    end

    test "press within click_distance counts as same position" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(6, 11, 1)

      assert mouse.click_count == 2
    end

    test "press beyond click_distance resets" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 15, 1)

      assert mouse.click_count == 1
    end

    test "stores last_press_time and last_press_pos" do
      mouse = %Mouse{} |> Mouse.record_press(5, 10, 1)
      assert mouse.last_press_time != nil
      assert mouse.last_press_pos == {5, 10}
    end
  end

  describe "start_drag/2 with multi-click" do
    test "drag preserves click_count as drag_click_count" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 2)
        |> Mouse.start_drag({5, 10})

      assert mouse.drag_click_count == 2
    end

    test "single-click drag has drag_click_count 1" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.start_drag({5, 10})

      assert mouse.drag_click_count == 1
    end
  end

  describe "hover tracking" do
    test "set_hover stores position" do
      mouse = %Mouse{} |> Mouse.set_hover(5, 10)
      assert mouse.hover_pos == {5, 10}
      assert mouse.hover_timer != nil
    end

    test "clear_hover removes position and timer" do
      mouse =
        %Mouse{}
        |> Mouse.set_hover(5, 10)
        |> Mouse.clear_hover()

      assert mouse.hover_pos == nil
      assert mouse.hover_timer == nil
    end

    test "set_hover cancels previous timer" do
      mouse =
        %Mouse{}
        |> Mouse.set_hover(5, 10)

      old_timer = mouse.hover_timer

      mouse = Mouse.set_hover(mouse, 6, 11)
      assert mouse.hover_timer != old_timer
      assert mouse.hover_pos == {6, 11}
    end
  end
end
