defmodule Minga.Editor.Commands.BufferManagement.FrontendTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.BottomPanel
  alias Minga.Editor.Commands.BufferManagement.GUI, as: BufGUI
  alias Minga.Editor.Commands.BufferManagement.TUI, as: BufTUI
  alias Minga.Editor.State.Buffers
  alias Minga.Test.StateFactory

  defp base_state(opts \\ []) do
    StateFactory.build(
      bottom_panel: %BottomPanel{},
      buffers: %Buffers{messages: Keyword.get(opts, :messages)},
      status_msg: nil
    )
  end

  describe "GUI.view_messages/1" do
    test "opens bottom panel on messages tab" do
      state = BufGUI.view_messages(base_state())
      assert state.bottom_panel.visible == true
      assert state.bottom_panel.active_tab == :messages
      assert state.bottom_panel.filter == nil
    end

    test "clears dismissed state" do
      state = %{base_state() | bottom_panel: %BottomPanel{dismissed: true}}
      state = BufGUI.view_messages(state)
      assert state.bottom_panel.dismissed == false
    end
  end

  describe "GUI.view_warnings/1" do
    test "opens bottom panel with warnings filter" do
      state = BufGUI.view_warnings(base_state())
      assert state.bottom_panel.visible == true
      assert state.bottom_panel.active_tab == :messages
      assert state.bottom_panel.filter == :warnings
    end
  end

  describe "TUI.view_messages/1" do
    test "returns status message when no messages buffer" do
      state = BufTUI.view_messages(base_state(messages: nil))
      assert state.status_msg == "No messages buffer"
    end
  end

  describe "TUI.view_warnings/1" do
    test "returns status message when no messages buffer" do
      state = BufTUI.view_warnings(base_state(messages: nil))
      assert state.status_msg == "No messages buffer"
    end
  end
end
