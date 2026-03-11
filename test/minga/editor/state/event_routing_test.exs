defmodule Minga.Editor.State.EventRoutingTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.{Tab, TabBar}
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport

  alias Minga.Surface.AgentView
  alias Minga.Surface.AgentView.State, as: AVState

  defp make_state(opts \\ []) do
    session1 = opts[:session1] || spawn(fn -> :timer.sleep(:infinity) end)
    session2 = opts[:session2] || spawn(fn -> :timer.sleep(:infinity) end)

    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent 1")
    tb = TabBar.update_tab(tb, agent_tab.id, &Tab.set_session(&1, session1))

    agent_ctx = %{
      keymap_scope: :agent,
      surface_module: AgentView,
      surface_state: %AVState{
        agent: %AgentState{session: session1, status: :idle},
        agentic: %ViewState{active: true, focus: :chat}
      }
    }

    tb = TabBar.update_context(tb, agent_tab.id, agent_ctx)

    # Add a second agent tab (background)
    {tb, agent_tab2} = TabBar.add(tb, :agent, "Agent 2")
    tb = TabBar.update_tab(tb, agent_tab2.id, &Tab.set_session(&1, session2))

    agent_ctx2 = %{
      keymap_scope: :agent,
      surface_module: AgentView,
      surface_state: %AVState{
        agent: %AgentState{session: session2, status: :idle},
        agentic: %ViewState{active: true, focus: :chat}
      }
    }

    tb = TabBar.update_context(tb, agent_tab2.id, agent_ctx2)

    # Switch back to agent_tab (first one) so it's active
    tb = TabBar.switch_to(tb, agent_tab.id)

    state = %EditorState{
      port_manager: self(),
      viewport: Viewport.new(24, 80),
      tab_bar: tb,
      buffers: %EditorState.Buffers{list: [], active: nil, active_index: 0},
      agentic: %ViewState{active: true, focus: :chat},
      windows: %Windows{},
      mode: :normal,
      mode_state: %{},
      keymap_scope: :agent,
      agent: %AgentState{session: session1, status: :idle},
      file_tree: nil
    }

    %{
      state: state,
      session1: session1,
      session2: session2,
      tab1_id: agent_tab.id,
      tab2_id: agent_tab2.id
    }
  end

  describe "route_agent_event/2" do
    test "routes active session to {:active, tab}" do
      %{state: state, session1: s1, tab1_id: tab_id} = make_state()
      assert {:active, %Tab{id: ^tab_id}} = EditorState.route_agent_event(state, s1)
    end

    test "routes background session to {:background, tab}" do
      %{state: state, session2: s2, tab2_id: tab_id} = make_state()
      assert {:background, %Tab{id: ^tab_id}} = EditorState.route_agent_event(state, s2)
    end

    test "returns :not_found for unknown session" do
      %{state: state} = make_state()
      unknown = spawn(fn -> :timer.sleep(:infinity) end)
      assert :not_found = EditorState.route_agent_event(state, unknown)
    end

    test "returns :not_found when tab_bar is nil" do
      state = %EditorState{
        port_manager: self(),
        viewport: Viewport.new(24, 80),
        tab_bar: nil,
        buffers: %EditorState.Buffers{},
        agentic: %ViewState{},
        windows: %Windows{},
        mode: :normal,
        mode_state: %{},
        keymap_scope: :editor,
        agent: %AgentState{},
        file_tree: nil
      }

      assert :not_found = EditorState.route_agent_event(state, self())
    end
  end

  describe "update_background_agent/3" do
    test "updates agent status in background tab's surface_state" do
      %{state: state, tab2_id: tab_id} = make_state()

      state =
        EditorState.update_background_agent(state, tab_id, &AgentState.set_status(&1, :thinking))

      tab = TabBar.get(state.tab_bar, tab_id)
      assert tab.context.surface_state.agent.status == :thinking
    end

    test "does not affect active tab's live state" do
      %{state: state, tab2_id: tab_id} = make_state()

      state =
        EditorState.update_background_agent(state, tab_id, &AgentState.set_status(&1, :thinking))

      assert state.agent.status == :idle
    end
  end

  describe "update_background_agentic/3" do
    test "updates agentic view state in background tab's surface_state" do
      %{state: state, tab2_id: tab_id} = make_state()

      state =
        EditorState.update_background_agentic(
          state,
          tab_id,
          &ViewState.set_focus(&1, :file_viewer)
        )

      tab = TabBar.get(state.tab_bar, tab_id)
      assert tab.context.surface_state.agentic.focus == :file_viewer
    end
  end

  describe "set_tab_session/3" do
    test "sets the session pid on a tab for event routing" do
      %{state: state, tab1_id: tab_id} = make_state()
      new_session = spawn(fn -> :timer.sleep(:infinity) end)

      state = EditorState.set_tab_session(state, tab_id, new_session)

      tab = TabBar.get(state.tab_bar, tab_id)
      assert tab.session == new_session
    end
  end

  describe "TabBar.find_by_session/2" do
    test "finds the correct agent tab by session pid" do
      %{state: state, session2: s2, tab2_id: tab_id} = make_state()
      assert %Tab{id: ^tab_id} = TabBar.find_by_session(state.tab_bar, s2)
    end

    test "returns nil for unknown session" do
      %{state: state} = make_state()
      unknown = spawn(fn -> :timer.sleep(:infinity) end)
      assert nil == TabBar.find_by_session(state.tab_bar, unknown)
    end
  end
end
