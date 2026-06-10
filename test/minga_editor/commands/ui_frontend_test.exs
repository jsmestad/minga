defmodule MingaEditor.Commands.UI.FrontendTest do
  use ExUnit.Case, async: true

  alias MingaEditor.BottomPanel
  alias MingaEditor.Commands
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  # The bottom-panel and observatory commands no longer branch on the frontend.
  # Both the macOS GUI and the Go TUI advertise `semantic_ui` and share the same
  # behaviour; only the legacy Zig cell-grid frontend (no `semantic_ui`) is
  # excluded. These tests drive the collapsed dispatch through `Commands.execute/2`.
  @gui %Capabilities{frontend_type: :native_gui, semantic_ui: true}
  @go_tui %Capabilities{frontend_type: :tui, semantic_ui: true}
  @zig %Capabilities{frontend_type: :tui, semantic_ui: false}

  defp base_state(caps) do
    %EditorState{
      port_manager: self(),
      capabilities: caps,
      workspace: %SessionState{viewport: Viewport.new(24, 80)},
      shell_state: %MingaEditor.Shell.Traditional.State{bottom_panel: %BottomPanel{}}
    }
  end

  describe "bottom panel commands" do
    for {label, caps} <- [{"GUI", @gui}, {"Go TUI", @go_tui}] do
      test "#{label} toggle_bottom_panel opens panel when hidden" do
        state = Commands.execute(base_state(unquote(Macro.escape(caps))), :toggle_bottom_panel)
        assert state.shell_state.bottom_panel.visible == true
      end

      test "#{label} toggle_bottom_panel closes panel when visible" do
        state =
          MingaEditor.State.set_bottom_panel(
            base_state(unquote(Macro.escape(caps))),
            %BottomPanel{visible: true}
          )

        state = Commands.execute(state, :toggle_bottom_panel)
        assert state.shell_state.bottom_panel.visible == false
      end

      test "#{label} bottom_panel_next_tab cycles to next tab" do
        state =
          MingaEditor.State.set_bottom_panel(
            base_state(unquote(Macro.escape(caps))),
            %BottomPanel{tabs: [:messages, :diagnostics], active_tab: :messages}
          )

        state = Commands.execute(state, :bottom_panel_next_tab)
        assert state.shell_state.bottom_panel.active_tab == :diagnostics
      end

      test "#{label} bottom_panel_prev_tab cycles to previous tab" do
        state =
          MingaEditor.State.set_bottom_panel(
            base_state(unquote(Macro.escape(caps))),
            %BottomPanel{tabs: [:messages, :diagnostics], active_tab: :diagnostics}
          )

        state = Commands.execute(state, :bottom_panel_prev_tab)
        assert state.shell_state.bottom_panel.active_tab == :messages
      end
    end
  end

  describe "toggle_beam_observatory command" do
    for {label, caps} <- [{"GUI", @gui}, {"Go TUI", @go_tui}] do
      test "#{label} opens the observatory and stores a refresh timer" do
        state =
          Commands.execute(base_state(unquote(Macro.escape(caps))), :toggle_beam_observatory)

        assert state.shell_state.observatory_visible == true
        assert {timer, _token} = state.shell_state.observatory_timer

        Process.cancel_timer(timer)
      end
    end

    test "closes the observatory and clears transient state" do
      token = make_ref()
      timer = Process.send_after(self(), {:observatory_tick, token}, 60_000)

      state = %{
        base_state(@gui)
        | shell_state:
            MingaEditor.Shell.Traditional.State.open_observatory(
              base_state(@gui).shell_state,
              {timer, token}
            )
      }

      state = MingaEditor.State.set_observatory_data(state, %{tree: :placeholder})
      state = Commands.execute(state, :toggle_beam_observatory)

      assert state.shell_state.observatory_visible == false
      assert state.shell_state.observatory_timer == nil
      assert state.shell_state.observatory_data == nil
    end

    test "is a no-op for the legacy Zig cell-grid frontend (no semantic_ui)" do
      state = base_state(@zig)

      assert Commands.execute(state, :toggle_beam_observatory) == state
    end

    test "is a no-op when the active shell has no observatory fields" do
      state = %{base_state(@gui) | shell_state: %{}}

      assert Commands.execute(state, :toggle_beam_observatory) == state
    end

    test "ignores stale refresh ticks" do
      state = Commands.execute(base_state(@gui), :toggle_beam_observatory)
      assert {timer, _token} = state.shell_state.observatory_timer

      assert {:noreply, ^state} = MingaEditor.handle_info({:observatory_tick, make_ref()}, state)

      Process.cancel_timer(timer)
    end
  end
end
