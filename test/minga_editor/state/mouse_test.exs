defmodule MingaEditor.State.MouseTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Mouse

  test "default state uses tagged idle concerns" do
    assert %Mouse{} == %Mouse{drag: :idle, resize: :idle, clicks: :idle, hover: :idle}
  end

  describe "hover_delay_ms/0" do
    test "is the 300ms VSCode default" do
      assert Mouse.hover_delay_ms() == 300
    end
  end

  describe "drag transitions" do
    test "start_drag/3 stores tagged active drag and stop_drag/1 clears it" do
      mouse = %Mouse{} |> Mouse.start_drag({5, 10}, 7)

      assert mouse.drag == {:active, %{anchor: {5, 10}, origin_window: 7, click_count: 1}}
      assert Mouse.dragging?(mouse)
      assert Mouse.active_drag(mouse) == {:active, {5, 10}, 7, 1}

      mouse = Mouse.stop_drag(mouse)

      assert mouse.drag == :idle
      refute Mouse.dragging?(mouse)
      assert Mouse.active_drag(mouse) == :idle
    end

    test "start_drag/2 preserves recorded native double-click count" do
      mouse =
        %Mouse{}
        |> Mouse.record_press(5, 10, 2)
        |> Mouse.start_drag({5, 10})

      assert Mouse.active_drag(mouse) == {:active, {5, 10}, nil, 2}
    end
  end

  describe "resize transitions" do
    test "start_resize/3, update_resize/3, and stop_resize/1 use tagged resize state" do
      mouse = %Mouse{} |> Mouse.start_resize(:vertical, 20)

      assert mouse.resize == {:active, {:vertical, 20}}
      assert Mouse.resizing?(mouse)

      mouse = Mouse.update_resize(mouse, :vertical, 25)

      assert mouse.resize == {:active, {:vertical, 25}}

      mouse = Mouse.stop_resize(mouse)

      assert mouse.resize == :idle
      refute Mouse.resizing?(mouse)
    end
  end

  describe "hover transitions" do
    test "prepare_hover/4 stores position and returns workflow scheduling decision" do
      old_timer = Process.send_after(self(), :old_hover, 10_000)
      mouse = %Mouse{hover: {:active, {1, 2}, old_timer}}

      {headless_mouse, returned_timer, schedule?} =
        Mouse.prepare_hover(mouse, 5, 10, backend: :headless)

      assert headless_mouse.hover == {:active, {5, 10}, nil}
      assert returned_timer == old_timer
      refute schedule?

      {_gui_mouse, _returned_timer, schedule?} = Mouse.prepare_hover(mouse, 6, 11, backend: :tui)
      assert schedule?
      Process.cancel_timer(old_timer)
    end

    test "accept_hover_timer/2 and prepare_clear_hover/1 preserve timer ownership" do
      timer = Process.send_after(self(), :hover, 10_000)

      mouse =
        %Mouse{}
        |> Mouse.set_hover(5, 10)
        |> Mouse.accept_hover_timer(timer)

      assert mouse.hover == {:active, {5, 10}, timer}

      {mouse, returned_timer} = Mouse.prepare_clear_hover(mouse)

      assert mouse.hover == :idle
      assert returned_timer == timer
      Process.cancel_timer(timer)
    end

    test "hover_position/1 returns active position only" do
      assert Mouse.hover_position(%Mouse{}) == nil
      assert %Mouse{} |> Mouse.set_hover(5, 10) |> Mouse.hover_position() == {5, 10}
    end
  end
end
