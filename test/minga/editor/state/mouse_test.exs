defmodule Minga.Editor.State.MouseTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Mouse

  describe "start_drag/2" do
    test "sets dragging to true and stores the anchor" do
      mouse = %Mouse{} |> Mouse.start_drag({5, 10})
      assert mouse.dragging == true
      assert mouse.anchor == {5, 10}
    end
  end

  describe "stop_drag/1" do
    test "clears dragging and anchor" do
      mouse = %Mouse{dragging: true, anchor: {5, 10}} |> Mouse.stop_drag()
      assert mouse.dragging == false
      assert mouse.anchor == nil
    end
  end

  describe "start_resize/3" do
    test "sets resize_dragging with direction and position" do
      mouse = %Mouse{} |> Mouse.start_resize(:vertical, 20)
      assert mouse.resize_dragging == {:vertical, 20}
    end
  end

  describe "update_resize/3" do
    test "updates the resize position" do
      mouse =
        %Mouse{}
        |> Mouse.start_resize(:vertical, 20)
        |> Mouse.update_resize(:vertical, 25)

      assert mouse.resize_dragging == {:vertical, 25}
    end
  end

  describe "stop_resize/1" do
    test "clears resize_dragging" do
      mouse = %Mouse{resize_dragging: {:horizontal, 10}} |> Mouse.stop_resize()
      assert mouse.resize_dragging == nil
    end
  end

  describe "resizing?/1" do
    test "returns true when resize drag is active" do
      assert Mouse.resizing?(%Mouse{resize_dragging: {:vertical, 10}})
    end

    test "returns false when no resize drag" do
      refute Mouse.resizing?(%Mouse{})
    end
  end
end
