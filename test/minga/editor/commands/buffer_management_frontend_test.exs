defmodule Minga.Editor.Commands.BufferManagement.FrontendTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.BottomPanel
  alias Minga.Editor.Commands.BufferManagement.GUI, as: BufGUI
  alias Minga.Editor.Commands.BufferManagement.TUI, as: BufTUI

  defp base_state(opts \\ []) do
    %{
      workspace: %{buffers: %{messages: Keyword.get(opts, :messages)}},
      shell_state: %Minga.Shell.Traditional.State{bottom_panel: %BottomPanel{}, status_msg: nil}
    }
  end

  describe "GUI.view_messages/1" do
    test "opens bottom panel on messages tab" do
      state = BufGUI.view_messages(base_state())
      assert state.shell_state.bottom_panel.visible == true
      assert state.shell_state.bottom_panel.active_tab == :messages
      assert state.shell_state.bottom_panel.filter == nil
    end

    test "clears dismissed state" do
      state = Minga.Editor.State.set_bottom_panel(base_state(), %BottomPanel{dismissed: true})
      state = BufGUI.view_messages(state)
      assert state.shell_state.bottom_panel.dismissed == false
    end
  end

  describe "GUI.view_warnings/1" do
    test "opens bottom panel with warnings filter" do
      state = BufGUI.view_warnings(base_state())
      assert state.shell_state.bottom_panel.visible == true
      assert state.shell_state.bottom_panel.active_tab == :messages
      assert state.shell_state.bottom_panel.filter == :warnings
    end
  end

  describe "TUI.view_messages/1" do
    test "returns status message when no messages buffer" do
      state = BufTUI.view_messages(base_state(messages: nil))
      assert state.shell_state.status_msg == "No messages buffer"
    end
  end

  describe "TUI.view_warnings/1" do
    test "returns status message when no messages buffer" do
      state = BufTUI.view_warnings(base_state(messages: nil))
      assert state.shell_state.status_msg == "No messages buffer"
    end
  end
end
