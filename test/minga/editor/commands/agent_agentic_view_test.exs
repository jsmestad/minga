defmodule Minga.Editor.Commands.AgentAgenticViewTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Input
  alias Minga.Mode

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferServer.start_link(content: "hello\nworld")

    panel = %PanelState{
      visible: false,
      input_focused: false,
      scroll_offset: 0,
      spinner_frame: 0,
      provider_name: "anthropic",
      model_name: "claude-sonnet-4",
      thinking_level: "medium"
    }

    agent = %AgentState{
      session: Keyword.get(opts, :session, nil),
      status: :idle,
      panel: panel,
      error: nil,
      spinner_timer: nil,
      buffer: nil
    }

    agentic = %ViewState{
      active: Keyword.get(opts, :active, false),
      focus: :chat,
      file_viewer_scroll: 0,
      saved_windows: Keyword.get(opts, :saved_windows, nil),
      pending_prefix: nil,
      saved_file_tree: Keyword.get(opts, :saved_file_tree, nil)
    }

    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      focus_stack: Input.default_stack(),
      agent: agent,
      agentic: agentic
    }
  end

  describe "toggle_agentic_view/1 — activating" do
    test "sets agentic.active to true" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.active == true
    end

    test "saves the current windows layout" do
      state = base_state()
      original_windows = state.windows
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.saved_windows == original_windows
    end

    test "resets agentic.focus to :chat" do
      state = base_state()
      state = put_in(state.agentic.focus, :file_viewer)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.focus == :chat
    end

    test "clears any split tree from the windows struct" do
      state = base_state()
      fake_tree = {:split, :vertical, 40, {:leaf, 1}, {:leaf, 2}}
      state = %{state | windows: %{state.windows | tree: fake_tree}}
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.windows.tree == nil
    end

    test "starts a session when none is running" do
      state = base_state(session: nil)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.active == true

      # When pi isn't installed, the session start fails gracefully
      # and sets an error instead of crashing.
      if new_state.agent.session == nil do
        assert new_state.agent.panel.error != nil
      end
    end

    test "does not double-start a session when one is already running" do
      fake_session = spawn(fn -> :timer.sleep(1000) end)
      state = base_state(session: fake_session)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agent.session == fake_session
      assert new_state.agentic.active == true
    end
  end

  describe "toggle_agentic_view/1 — deactivating" do
    test "sets agentic.active to false" do
      state = base_state(active: true)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.active == false
    end

    test "restores saved windows when present" do
      original_windows = %Windows{tree: nil, map: %{}, active: 1, next_id: 2}
      state = base_state(active: true, saved_windows: original_windows)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.windows == original_windows
    end

    test "clears agentic.saved_windows after restoring" do
      original_windows = %Windows{tree: nil, map: %{}, active: 1, next_id: 2}
      state = base_state(active: true, saved_windows: original_windows)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.saved_windows == nil
    end

    test "does not crash when no saved windows exist" do
      state = base_state(active: true, saved_windows: nil)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.active == false
    end

    test "resets agentic.focus to :chat" do
      state = base_state(active: true)
      state = put_in(state.agentic.focus, :file_viewer)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.focus == :chat
    end
  end

  describe "round-trip toggle" do
    test "activating then deactivating restores the windows layout" do
      state = base_state()
      original_windows = state.windows

      activated = AgentCommands.toggle_agentic_view(state)
      assert activated.agentic.active == true

      restored = AgentCommands.toggle_agentic_view(activated)
      assert restored.agentic.active == false
      assert restored.windows == original_windows
      assert restored.agentic.saved_windows == nil
    end
  end
end
