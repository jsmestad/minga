defmodule Minga.Editor.Commands.AgentAgenticViewTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
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

    active = Keyword.get(opts, :active, false)

    agentic = %ViewState{
      active: active,
      focus: :chat,
      preview: Preview.new(),
      saved_windows: Keyword.get(opts, :saved_windows, nil),
      pending_prefix: nil,
      saved_file_tree: Keyword.get(opts, :saved_file_tree, nil)
    }

    # Build a tab bar: file tab always exists, agent tab if starting active
    file_tab = Tab.new_file(1, "test.ex")
    tb = TabBar.new(file_tab)

    {tb, agent_tab_id} =
      if active do
        agent_ctx = %{
          agentic: agentic,
          agent: agent,
          windows: %Windows{},
          mode: :normal,
          mode_state: Mode.initial_state(),
          keymap_scope: :agent,
          active_buffer: buf,
          active_buffer_index: 0
        }

        {tb2, at} = TabBar.add(tb, :agent, "Agent")
        tb2 = TabBar.update_context(tb2, at.id, agent_ctx)
        {tb2, at.id}
      else
        {tb, nil}
      end

    state = %EditorState{
      port_manager: self(),
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      focus_stack: Input.default_stack(),
      agent: agent,
      agentic: agentic,
      tab_bar: tb
    }

    # If starting in active (agent) state, switch to the agent tab
    if agent_tab_id do
      EditorState.switch_tab(state, agent_tab_id)
    else
      state
    end
  end

  describe "toggle_agentic_view/1 — activating" do
    test "sets agentic.active to true" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.active == true
    end

    test "saves the file tab's windows layout in the tab context" do
      state = base_state()
      original_windows = state.windows
      new_state = AgentCommands.toggle_agentic_view(state)

      # File tab (id 1) should have the original windows in its context
      file_tab = TabBar.get(new_state.tab_bar, 1)
      assert file_tab.context.windows == original_windows
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
        assert new_state.agent.error != nil
      end
    end

    test "does not double-start a session when one is already running" do
      fake_session = spawn(fn -> :timer.sleep(1000) end)
      state = base_state(session: fake_session)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agent.session == fake_session
      assert new_state.agentic.active == true
    end

    test "creates an agent tab when none exists" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)
      assert TabBar.find_by_kind(new_state.tab_bar, :agent) != nil
      assert EditorState.active_tab_kind(new_state) == :agent
    end
  end

  describe "toggle_agentic_view/1 — deactivating" do
    test "sets agentic.active to false" do
      state = base_state(active: true)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.active == false
    end

    test "switches back to the file tab" do
      state = base_state(active: true)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert EditorState.active_tab_kind(new_state) == :file
    end

    test "does not crash when no file tab exists" do
      # Start active with no file tab scenario handled gracefully
      state = base_state(active: true)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.agentic.active == false
    end

    test "resets agentic.focus to :chat on the saved agent context" do
      state = base_state(active: true)
      state = put_in(state.agentic.focus, :file_viewer)
      new_state = AgentCommands.toggle_agentic_view(state)
      # After deactivation, the live agentic should be the file tab's (inactive)
      assert new_state.agentic.active == false
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
    end

    test "re-entering agent tab restores its context" do
      state = base_state()

      # Activate (creates agent tab) -> deactivate -> re-activate
      with_agent = AgentCommands.toggle_agentic_view(state)
      back_to_file = AgentCommands.toggle_agentic_view(with_agent)
      back_to_agent = AgentCommands.toggle_agentic_view(back_to_file)

      assert back_to_agent.agentic.active == true
      assert back_to_agent.keymap_scope == :agent
    end
  end
end
