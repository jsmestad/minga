defmodule MingaEditor.Commands.UI.FrontendTest do
  use ExUnit.Case, async: true

  alias MingaEditor.BottomPanel
  alias MingaEditor.Commands
  alias MingaEditor.Commands.UI.GUI, as: UIGUI
  alias MingaEditor.Commands.UI.TUI, as: UITUI
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  defp base_state do
    %EditorState{
      port_manager: self(),
      workspace: %SessionState{viewport: Viewport.new(24, 80)},
      capabilities: %Capabilities{frontend_type: :native_gui},
      shell_state: %MingaEditor.Shell.Traditional.State{bottom_panel: %BottomPanel{}}
    }
  end

  describe "GUI.toggle_bottom_panel/1" do
    test "opens panel when hidden" do
      state = UIGUI.toggle_bottom_panel(base_state())
      assert state.shell_state.bottom_panel.visible == true
    end

    test "closes panel when visible" do
      state = MingaEditor.State.set_bottom_panel(base_state(), %BottomPanel{visible: true})
      state = UIGUI.toggle_bottom_panel(state)
      assert state.shell_state.bottom_panel.visible == false
    end
  end

  describe "GUI.bottom_panel_next_tab/1" do
    test "cycles to next tab" do
      state =
        MingaEditor.State.set_bottom_panel(
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
        MingaEditor.State.set_bottom_panel(
          base_state(),
          %BottomPanel{tabs: [:messages, :diagnostics], active_tab: :diagnostics}
        )

      state = UIGUI.bottom_panel_prev_tab(state)
      assert state.shell_state.bottom_panel.active_tab == :messages
    end
  end

  describe "toggle_beam_observatory command" do
    test "opens the observatory and stores a refresh timer" do
      state = Commands.execute(base_state(), :toggle_beam_observatory)

      assert state.shell_state.observatory_visible == true
      assert {timer, _token} = state.shell_state.observatory_timer

      Process.cancel_timer(timer)
    end

    test "closes the observatory and clears transient state" do
      token = make_ref()
      timer = Process.send_after(self(), {:observatory_tick, token}, 60_000)

      state = %{
        base_state()
        | shell_state:
            MingaEditor.Shell.Traditional.State.open_observatory(
              base_state().shell_state,
              {timer, token}
            )
      }

      state = MingaEditor.State.set_observatory_data(state, %{tree: :placeholder})
      state = Commands.execute(state, :toggle_beam_observatory)

      assert state.shell_state.observatory_visible == false
      assert state.shell_state.observatory_timer == nil
      assert state.shell_state.observatory_data == nil
    end

    test "is a no-op for non-GUI frontends" do
      state = %{base_state() | capabilities: %Capabilities{frontend_type: :tui}}

      assert Commands.execute(state, :toggle_beam_observatory) == state
    end

    test "is a no-op for the Board shell" do
      state =
        Map.merge(base_state(), %{
          shell: MingaEditor.Shell.Board,
          shell_state: MingaEditor.Shell.Board.State.new()
        })

      assert Commands.execute(state, :toggle_beam_observatory) == state
    end

    test "ignores stale refresh ticks" do
      state = Commands.execute(base_state(), :toggle_beam_observatory)
      assert {timer, _token} = state.shell_state.observatory_timer

      assert {:noreply, ^state} = MingaEditor.handle_info({:observatory_tick, make_ref()}, state)

      Process.cancel_timer(timer)
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
