defmodule MingaEditor.State.EventRoutingTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Events, as: AgentEvents
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.{Tab, TabBar}
  alias MingaEditor.Viewport

  defp make_state(opts \\ []) do
    session = opts[:session] || spawn(fn -> :timer.sleep(:infinity) end)

    tb = TabBar.new(Tab.new_file(1, "main.ex"))

    state = %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80)
      },
      shell_state: %MingaEditor.Shell.Traditional.State{
        tab_bar: tb,
        agent: %AgentState{session: session, status: :idle}
      }
    }

    %{state: state, session: session}
  end

  describe "Agent.Events.handle/2 — status changes" do
    test "status_changed updates agent status" do
      %{state: state} = make_state()

      {new_state, effects} = AgentEvents.handle(state, {:status_changed, :thinking})

      assert AgentAccess.agent(new_state).status == :thinking
      assert :render in effects
    end

    test "status_changed to :thinking engages auto-scroll" do
      %{state: state} = make_state()

      {new_state, _effects} = AgentEvents.handle(state, {:status_changed, :thinking})

      assert AgentAccess.panel(new_state).scroll.pinned == true
    end

    test "status_changed to :error logs a message" do
      %{state: state} = make_state()

      {_new_state, effects} = AgentEvents.handle(state, {:status_changed, :error})

      assert {:log_message, "Agent: error"} in effects
    end

    test "status_changed to :idle stops spinner" do
      %{state: state} = make_state()
      state = AgentAccess.update_agent(state, &AgentState.start_spinner_timer/1)

      {new_state, _effects} = AgentEvents.handle(state, {:status_changed, :idle})

      assert AgentAccess.agent(new_state).spinner_timer == nil
    end
  end

  describe "Agent.Events.handle/2 — content deltas" do
    test "text_delta triggers throttled render" do
      %{state: state} = make_state()

      {_new_state, effects} = AgentEvents.handle(state, {:text_delta, "hello"})

      assert {:render, 1} in effects
    end

    test "thinking_delta triggers throttled render" do
      %{state: state} = make_state()

      {_new_state, effects} = AgentEvents.handle(state, {:thinking_delta, "hmm"})

      assert {:render, 50} in effects
    end

    test "messages_changed triggers buffer sync and tab label update" do
      %{state: state} = make_state()

      {new_state, effects} = AgentEvents.handle(state, :messages_changed)

      assert :sync_agent_buffer in effects
      assert {:update_tab_label, ""} in effects
      # message_version is bumped so the GUI fingerprint cache is invalidated
      assert AgentAccess.panel(new_state).message_version == 1
    end
  end

  describe "Agent.Events.handle/2 — errors" do
    test "error updates agent error state and logs" do
      %{state: state} = make_state()

      {new_state, effects} = AgentEvents.handle(state, {:error, "something broke"})

      assert AgentAccess.agent(new_state).error == "something broke"
      assert {:log_warning, "Agent error: something broke"} in effects
    end
  end

  describe "Agent.Events.handle/2 — spinner" do
    test "spinner_tick when busy ticks the spinner frame" do
      %{state: state} = make_state()
      state = AgentAccess.update_agent(state, &AgentState.set_status(&1, :thinking))
      state = AgentAccess.update_agent(state, &AgentState.start_spinner_timer/1)

      {new_state, effects} = AgentEvents.handle(state, :spinner_tick)

      assert AgentAccess.panel(new_state).spinner_frame == 1
      assert {:render, 16} in effects
    end

    test "spinner_tick when idle stops the spinner timer" do
      %{state: state} = make_state()

      {new_state, effects} = AgentEvents.handle(state, :spinner_tick)

      assert AgentAccess.agent(new_state).spinner_timer == nil
      assert effects == []
    end
  end

  describe "Agent.Events.handle/2 — approval" do
    test "approval_pending sets pending approval on agent" do
      %{state: state} = make_state()

      approval = %{tool_call_id: "123", name: "shell", args: %{"command" => "ls"}}
      {new_state, effects} = AgentEvents.handle(state, {:approval_pending, approval})

      assert AgentAccess.agent(new_state).pending_approval == %{
               tool_call_id: "123",
               name: "shell",
               args: %{"command" => "ls"}
             }

      assert :render in effects
      assert :sync_agent_buffer in effects
    end

    test "approval_pending unfocuses the prompt input" do
      %{state: state} = make_state()

      # Simulate the user typing in the prompt (input focused)
      state = AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, true))
      assert AgentAccess.input_focused?(state)

      approval = %{tool_call_id: "456", name: "write_file", args: %{}}
      {new_state, _effects} = AgentEvents.handle(state, {:approval_pending, approval})

      # Input must be unfocused so the ToolApproval handler can intercept y/n
      refute AgentAccess.input_focused?(new_state)
    end

    test "approval_resolved clears pending approval and syncs buffer" do
      %{state: state} = make_state()

      state =
        AgentAccess.update_agent(state, &AgentState.set_pending_approval(&1, %{name: "shell"}))

      {new_state, effects} = AgentEvents.handle(state, {:approval_resolved, :approved})

      assert AgentAccess.agent(new_state).pending_approval == nil
      assert :sync_agent_buffer in effects
    end
  end

  describe "Agent.Events.handle/2 — unknown events" do
    test "unknown events are a no-op" do
      %{state: state} = make_state()

      {new_state, effects} = AgentEvents.handle(state, {:some_future_event, "data"})

      assert new_state == state
      assert effects == []
    end
  end

  describe "set_tab_session/3" do
    test "sets the session pid on a tab for event routing" do
      %{state: state} = make_state()
      tab = TabBar.active(state.shell_state.tab_bar)
      new_session = spawn(fn -> :timer.sleep(:infinity) end)

      state = EditorState.set_tab_session(state, tab.id, new_session)

      tab = TabBar.get(state.shell_state.tab_bar, tab.id)
      assert tab.session == new_session
    end
  end

  describe "tab context excludes agent/agentic state" do
    test "snapshot_tab_context does not include agent or agentic" do
      %{state: state} = make_state()
      ctx = EditorState.snapshot_tab_context(state)

      refute Map.has_key?(ctx, :agent)
      refute Map.has_key?(ctx, :agentic)
    end
  end

  describe "Agent.Events.handle/2 — tab status sync" do
    test "status_changed syncs agent_status on the agent tab" do
      %{state: state, session: session} = make_state()

      {tb, agent_tab} = TabBar.add(state.shell_state.tab_bar, :agent, "Agent")
      tb = TabBar.update_tab(tb, agent_tab.id, &Tab.set_session(&1, session))
      state = MingaEditor.State.set_tab_bar(state, tb)

      {new_state, _effects} = AgentEvents.handle(state, {:status_changed, :thinking})

      agent_tab = TabBar.get(new_state.shell_state.tab_bar, agent_tab.id)
      assert agent_tab.agent_status == :thinking
    end

    test "status_changed to :idle updates tab status" do
      %{state: state, session: session} = make_state()

      {tb, agent_tab} = TabBar.add(state.shell_state.tab_bar, :agent, "Agent")
      tb = TabBar.update_tab(tb, agent_tab.id, &Tab.set_session(&1, session))
      state = MingaEditor.State.set_tab_bar(state, tb)

      {state, _} = AgentEvents.handle(state, {:status_changed, :thinking})
      {new_state, _} = AgentEvents.handle(state, {:status_changed, :idle})

      agent_tab = TabBar.get(new_state.shell_state.tab_bar, agent_tab.id)
      assert agent_tab.agent_status == :idle
    end
  end
end
