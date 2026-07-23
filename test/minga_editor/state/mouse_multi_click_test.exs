defmodule MingaEditor.State.MouseMultiClickTest do
  @moduledoc "Tests for multi-click detection logic in Mouse state."
  use ExUnit.Case, async: true

  alias MingaEditor.State.Mouse

  describe "record_press/4 multi-click detection" do
    test "first press at any position gives click_count 1" do
      mouse = %Mouse{} |> Mouse.record_press(5, 10, 1)
      assert Mouse.click_count(mouse) == 1
    end

    test "native click_count > 1 is used directly (GUI)" do
      mouse = %Mouse{} |> Mouse.record_press(5, 10, 2)
      assert Mouse.click_count(mouse) == 2
    end

    test "native click_count 3 is used directly" do
      mouse = %Mouse{} |> Mouse.record_press(5, 10, 3)
      assert Mouse.click_count(mouse) == 3
    end

    test "native click_count clamped to max 3" do
      mouse = %Mouse{} |> Mouse.record_press(5, 10, 5)
      assert Mouse.click_count(mouse) == 3
    end

    test "two rapid presses at same position gives click_count 2" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)

      assert Mouse.click_count(mouse) == 2
    end

    test "three rapid presses at same position gives click_count 3" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)

      assert Mouse.click_count(mouse) == 3
    end

    test "four rapid presses cycles back to click_count 1" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 10, 1)

      assert Mouse.click_count(mouse) == 1
    end

    test "press at different position resets click_count to 1" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(20, 30, 1)

      assert Mouse.click_count(mouse) == 1
    end

    test "press within click_distance counts as same position" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(6, 11, 1)

      assert Mouse.click_count(mouse) == 2
    end

    test "press beyond click_distance resets" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.record_press(5, 15, 1)

      assert Mouse.click_count(mouse) == 1
    end

    test "stores press time and position with tagged click state" do
      mouse = %Mouse{} |> Mouse.record_press(5, 10, 1)
      assert {:pressed, %{time: time, pos: {5, 10}, count: 1}} = mouse.clicks
      assert is_integer(time)
    end
  end

  describe "start_drag/2 with multi-click" do
    test "drag preserves click_count as drag click count" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 2)
        |> Mouse.start_drag({5, 10})

      assert Mouse.active_drag(mouse) == {:active, {5, 10}, nil, 2}
    end

    test "single-click drag has drag click count 1" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 1)
        |> Mouse.start_drag({5, 10})

      assert Mouse.active_drag(mouse) == {:active, {5, 10}, nil, 1}
    end
  end

  describe "hover tracking" do
    test "set_hover stores position without creating a process timer" do
      mouse = %Mouse{} |> Mouse.set_hover(5, 10)
      assert mouse.hover == {:active, {5, 10}, nil}
    end

    test "clear_hover removes position and timer" do
      mouse =
        %Mouse{}
        |> Mouse.set_hover(5, 10)
        |> Mouse.clear_hover()

      assert mouse.hover == :idle
    end

    test "prepare_hover returns previous timer for workflow cancellation" do
      old_timer = Process.send_after(self(), :old_hover, 10_000)
      mouse = %Mouse{hover: {:active, {5, 10}, old_timer}}

      {mouse, returned_timer, schedule?} = Mouse.prepare_hover(mouse, 6, 11)

      assert returned_timer == old_timer
      assert schedule?
      assert mouse.hover == {:active, {6, 11}, nil}
      Process.cancel_timer(old_timer)
    end
  end
end
