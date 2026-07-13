defmodule MingaEditor.Commands.UI.FrontendTest do
  use ExUnit.Case, async: true

  alias MingaEditor.BottomPanel
  alias MingaEditor.Commands
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Observatory
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Runtime
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
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          %MingaEditor.Shell.Traditional.State{bottom_panel: %BottomPanel{}}
        )
    }
  end

  describe "bottom panel commands" do
    for {label, caps} <- [{"GUI", @gui}, {"Go TUI", @go_tui}] do
      test "#{label} toggle_bottom_panel opens panel when hidden" do
        state = Commands.execute(base_state(unquote(Macro.escape(caps))), :toggle_bottom_panel)
        assert state.shell_runtime.state.bottom_panel.visible == true
      end

      test "#{label} toggle_bottom_panel closes panel when visible" do
        state =
          MingaEditor.State.set_bottom_panel(
            base_state(unquote(Macro.escape(caps))),
            %BottomPanel{visible: true}
          )

        state = Commands.execute(state, :toggle_bottom_panel)
        assert state.shell_runtime.state.bottom_panel.visible == false
      end

      test "#{label} bottom_panel_next_tab cycles to next tab" do
        state =
          MingaEditor.State.set_bottom_panel(
            base_state(unquote(Macro.escape(caps))),
            %BottomPanel{tabs: [:messages, :diagnostics], active_tab: :messages}
          )

        state = Commands.execute(state, :bottom_panel_next_tab)
        assert state.shell_runtime.state.bottom_panel.active_tab == :diagnostics
      end

      test "#{label} bottom_panel_prev_tab cycles to previous tab" do
        state =
          MingaEditor.State.set_bottom_panel(
            base_state(unquote(Macro.escape(caps))),
            %BottomPanel{tabs: [:messages, :diagnostics], active_tab: :diagnostics}
          )

        state = Commands.execute(state, :bottom_panel_prev_tab)
        assert state.shell_runtime.state.bottom_panel.active_tab == :messages
      end
    end
  end

  describe "toggle_beam_observatory command" do
    for {label, caps} <- [{"GUI", @gui}, {"Go TUI", @go_tui}] do
      test "#{label} opens the observatory and stores a refresh timer" do
        state =
          Commands.execute(base_state(unquote(Macro.escape(caps))), :toggle_beam_observatory)

        assert state.shell_runtime.state.observatory_visible == true
        assert {timer, _token} = state.shell_runtime.state.observatory_timer

        Process.cancel_timer(timer)
      end
    end

    test "closes the observatory and clears transient state" do
      token = make_ref()
      timer = Process.send_after(self(), {:observatory_tick, token}, 60_000)

      state = MingaEditor.State.open_observatory(base_state(@gui), {timer, token})

      state = MingaEditor.State.set_observatory_data(state, %{tree: :placeholder})
      state = Commands.execute(state, :toggle_beam_observatory)

      assert state.shell_runtime.state.observatory_visible == false
      assert state.shell_runtime.state.observatory_timer == nil
      assert state.shell_runtime.state.observatory_data == nil
    end

    test "is a no-op for the legacy Zig cell-grid frontend (no semantic_ui)" do
      state = base_state(@zig)

      assert Commands.execute(state, :toggle_beam_observatory) == state
    end

    test "is a no-op when the active shell has no observatory fields" do
      entry = %Entry{
        id: :fake,
        source: {:extension, :test},
        module: MingaEditor.Test.FakeShell,
        display_name: "Fake",
        description: "Shell without observatory fields",
        capabilities: [:gui],
        default?: false,
        generation: 1
      }

      state = %{base_state(@gui) | shell_runtime: Runtime.new(entry, %{})}

      assert Commands.execute(state, :toggle_beam_observatory) == state
    end

    test "ignores stale refresh ticks" do
      state = Commands.execute(base_state(@gui), :toggle_beam_observatory)
      assert {timer, _token} = state.shell_runtime.state.observatory_timer

      assert {:noreply, ^state} = MingaEditor.handle_info({:observatory_tick, make_ref()}, state)

      Process.cancel_timer(timer)
    end
  end

  describe "observatory refresh runs off the Editor GenServer" do
    test "a tick spawns async collection without blocking or scheduling the next tick" do
      token = make_ref()
      state = observatory_state(@gui, token)

      # The tick handler returns the *unchanged* state: collection does not run
      # inline (no data set) and no next tick is scheduled here.
      assert {:noreply, ^state} = MingaEditor.handle_info({:observatory_tick, token}, state)
      assert state.shell_runtime.state.observatory_data == nil

      # The collection ran in a supervised Task and reported back as a message,
      # exactly like a picker/async-action result.
      assert_receive {:observatory_data_result, ^token, %Observatory.Data{}}, 2_000
    end

    test "a stale tick does not spawn collection" do
      token = make_ref()
      state = observatory_state(@gui, token)

      assert {:noreply, ^state} = MingaEditor.handle_info({:observatory_tick, make_ref()}, state)

      refute_receive {:observatory_data_result, _token, _data}, 200
    end

    test "the result handler applies data and schedules the next tick only now" do
      token = make_ref()
      state = observatory_state(@gui, token)
      data = Observatory.Data.visible(nil, [])

      assert {:noreply, new_state} =
               MingaEditor.handle_info({:observatory_data_result, token, data}, state)

      assert new_state.shell_runtime.state.observatory_data == data

      assert {next_timer, next_token} = new_state.shell_runtime.state.observatory_timer
      assert is_reference(next_timer)
      # A fresh token gates the next cycle; the prior token is now stale.
      assert next_token != token

      # The timer reference and fresh token prove the next cycle is armed. Its
      # remaining duration is scheduler-dependent under full-suite contention.
      _ = Process.cancel_timer(next_timer, async: false, info: false)
    end

    test "a stale data result is ignored and schedules nothing" do
      token = make_ref()
      state = observatory_state(@gui, token)

      data = Observatory.Data.visible(nil, [])

      assert {:noreply, ^state} =
               MingaEditor.handle_info({:observatory_data_result, make_ref(), data}, state)

      assert state.shell_runtime.state.observatory_data == nil
    end
  end

  # Builds editor state with the observatory open and a known refresh token, so
  # current_observatory_token?/2 matches without scheduling a real timer.
  defp observatory_state(caps, token) do
    MingaEditor.State.open_observatory(base_state(caps), {make_ref(), token})
  end
end
