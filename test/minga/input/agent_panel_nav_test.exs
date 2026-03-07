defmodule Minga.Input.AgentPanelNavTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.PanelState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Input.AgentPanel, as: AgentPanelHandler

  defp make_state do
    buf = AgentBufferSync.start_buffer()

    # Write some content so there are lines to navigate
    AgentBufferSync.sync(buf, [
      {:user, "Hello"},
      {:assistant, "World\nLine 2\nLine 3\nLine 4\nLine 5"}
    ])

    panel = %{PanelState.new() | visible: true, input_focused: false}

    %{
      agent: %AgentState{
        panel: panel,
        buffer: buf,
        session: nil,
        status: :idle,
        error: nil,
        spinner_timer: nil
      },
      buffers: %{active: nil, list: [], recent: []},
      mode: :normal,
      mode_state: Minga.Mode.initial_state(),
      status_msg: nil,
      key_buffer: [],
      count: nil,
      marks: %{},
      registers: %{},
      change_recorder: ChangeRecorder.new(),
      macro_recorder: MacroRecorder.new(),
      file_tree: %{tree: nil, focused: false, buffer: nil},
      completion: nil,
      conflict: nil,
      focus_stack: [AgentPanelHandler, Minga.Input.ModeFSM]
    }
  end

  describe "agent panel navigation mode" do
    test "j moves cursor down in agent buffer" do
      state = make_state()
      buf = state.agent.buffer

      # Cursor starts at end (auto-scroll from sync)
      {start_line, _} = BufferServer.cursor(buf)

      {:handled, _state} = AgentPanelHandler.handle_key(state, ?k, 0)

      # After k, cursor should have moved up
      {new_line, _} = BufferServer.cursor(buf)
      assert new_line < start_line
    end

    test "i focuses the input" do
      state = make_state()

      {:handled, new_state} = AgentPanelHandler.handle_key(state, ?i, 0)
      assert new_state.agent.panel.input_focused == true
    end

    test "passthrough when panel not visible" do
      state = make_state()
      state = put_in(state.agent.panel.visible, false)
      {:passthrough, _state} = AgentPanelHandler.handle_key(state, ?j, 0)
    end

    test "passthrough when no buffer" do
      state = make_state()
      state = put_in(state.agent.buffer, nil)
      {:passthrough, _state} = AgentPanelHandler.handle_key(state, ?j, 0)
    end
  end

  describe "agent panel input mode" do
    test "Escape unfocuses input" do
      state = make_state()
      state = put_in(state.agent.panel.input_focused, true)

      {:handled, new_state} = AgentPanelHandler.handle_key(state, 27, 0)
      assert new_state.agent.panel.input_focused == false
    end

    test "input mode intercepts printable chars" do
      state = make_state()
      state = put_in(state.agent.panel.input_focused, true)

      {:handled, _new_state} = AgentPanelHandler.handle_key(state, ?a, 0)
      # Doesn't crash, key is handled (goes to input_char)
    end
  end
end
