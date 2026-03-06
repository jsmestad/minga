defmodule Minga.Agent.PanelStateTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState

  describe "new/0" do
    test "starts not visible" do
      panel = PanelState.new()
      refute panel.visible
    end

    test "starts with empty input" do
      panel = PanelState.new()
      assert panel.input_text == ""
    end

    test "starts at scroll offset 0" do
      panel = PanelState.new()
      assert panel.scroll_offset == 0
    end
  end

  describe "toggle/1" do
    test "toggles visibility on" do
      panel = PanelState.new() |> PanelState.toggle()
      assert panel.visible
    end

    test "toggles visibility off" do
      panel = PanelState.new() |> PanelState.toggle() |> PanelState.toggle()
      refute panel.visible
    end
  end

  describe "input operations" do
    test "insert_char appends character" do
      panel = PanelState.new() |> PanelState.insert_char("h") |> PanelState.insert_char("i")
      assert panel.input_text == "hi"
    end

    test "delete_char removes last character" do
      panel =
        PanelState.new()
        |> PanelState.insert_char("h")
        |> PanelState.insert_char("i")
        |> PanelState.delete_char()

      assert panel.input_text == "h"
    end

    test "delete_char on empty input is no-op" do
      panel = PanelState.new() |> PanelState.delete_char()
      assert panel.input_text == ""
    end

    test "clear_input empties the input" do
      panel = PanelState.new() |> PanelState.insert_char("test") |> PanelState.clear_input()
      assert panel.input_text == ""
    end
  end

  describe "scrolling" do
    test "scroll_down increases offset" do
      panel = PanelState.new() |> PanelState.scroll_down(10)
      assert panel.scroll_offset == 10
    end

    test "scroll_up decreases offset" do
      panel = PanelState.new() |> PanelState.scroll_down(10) |> PanelState.scroll_up(5)
      assert panel.scroll_offset == 5
    end

    test "scroll_up does not go below 0" do
      panel = PanelState.new() |> PanelState.scroll_up(10)
      assert panel.scroll_offset == 0
    end

    test "scroll_to_bottom sets large offset" do
      panel = PanelState.new() |> PanelState.scroll_to_bottom()
      assert panel.scroll_offset > 0
    end
  end

  describe "spinner" do
    test "tick_spinner increments frame" do
      panel = PanelState.new() |> PanelState.tick_spinner() |> PanelState.tick_spinner()
      assert panel.spinner_frame == 2
    end
  end

  describe "input focus" do
    test "set_input_focused changes focus state" do
      panel = PanelState.new() |> PanelState.set_input_focused(true)
      assert panel.input_focused
    end
  end
end
