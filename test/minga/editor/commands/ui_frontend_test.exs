defmodule Minga.Editor.Commands.UI.FrontendTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.BottomPanel
  alias Minga.Editor.Commands.UI.GUI, as: UIGUI
  alias Minga.Editor.Commands.UI.TUI, as: UITUI

  defp base_state do
    %{shell_state: %Minga.Shell.Traditional.State{bottom_panel: %BottomPanel{}}}
  end

  describe "GUI.toggle_bottom_panel/1" do
    test "opens panel when hidden" do
      state = UIGUI.toggle_bottom_panel(base_state())
      assert state.shell_state.bottom_panel.visible == true
    end

    test "closes panel when visible" do
      state = Minga.Editor.State.set_bottom_panel(base_state(), %BottomPanel{visible: true})
      state = UIGUI.toggle_bottom_panel(state)
      assert state.shell_state.bottom_panel.visible == false
    end
  end

  describe "GUI.bottom_panel_next_tab/1" do
    test "cycles to next tab" do
      state =
        Minga.Editor.State.set_bottom_panel(
          base_state(),
          %BottomPanel{tabs: [:messages, :diagnostics], active_tab: :messages}
        )

      state = UIGUI.bottom_panel_next_tab(state)
      assert state.shell_state.bottom_panel.active_tab == :diagnostics
    end
  end

  describe "GUI.bottom_panel_prev_tab/1" do
    test "cycles to previous tab" do
      state =
        Minga.Editor.State.set_bottom_panel(
          base_state(),
          %BottomPanel{tabs: [:messages, :diagnostics], active_tab: :diagnostics}
        )

      state = UIGUI.bottom_panel_prev_tab(state)
      assert state.shell_state.bottom_panel.active_tab == :messages
    end
  end

  describe "TUI variants are no-ops" do
    test "toggle_bottom_panel returns state unchanged" do
      state = base_state()
      assert UITUI.toggle_bottom_panel(state) == state
    end

    test "bottom_panel_next_tab returns state unchanged" do
      state = base_state()
      assert UITUI.bottom_panel_next_tab(state) == state
    end

    test "bottom_panel_prev_tab returns state unchanged" do
      state = base_state()
      assert UITUI.bottom_panel_prev_tab(state) == state
    end
  end
end
