defmodule MingaEditor.State.EventRoutingTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Events, as: AgentEvents
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.RuntimeState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.{Tab, TabBar}

  defp make_state(opts \\ []) do
    session = opts[:session] || spawn(fn -> :timer.sleep(:infinity) end)

    # Default fixture has only a file tab; tests that exercise per-tab
    # routing add an agent tab and attach the session via Tab.set_session.
    tb = TabBar.new(Tab.new_file(1, "main.ex"))

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: self()},
      workspace: %MingaEditor.Session.State{},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          %TraditionalState{}
          |> TraditionalState.replace_agent(%AgentState{
            runtime: %RuntimeState{status: :idle}
          })
          |> TraditionalState.install_tab_bar(tb)
        )
    }

    %{state: state, session: session}
  end

  describe "Agent.Events direct routing" do
    test "routes status, stream, and session events through focused workflows" do
      %{state: state} = make_state()

      state = AgentEvents.dispatch(state, {:status_changed, :thinking})

      assert MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state).runtime.status ==
               :thinking

      assert state.workspace.agent_ui.panel.scroll.pinned
      assert MingaEditor.State.RenderCorrelation.scheduled?(state.render.render_correlation)

      state = AgentEvents.dispatch(state, {:text_delta, "hello"})
      assert state.workspace.agent_ui.panel.transcript.version == 1

      state = AgentEvents.dispatch(state, {:credentials_status, true})
      assert state.workspace.agent_ui.panel.credentials_configured
    end

    test "coalesced stream batches bump transcript presentation once" do
      %{state: state} = make_state()

      state =
        AgentEvents.dispatch_batch(state, [
          {:text_delta, "a"},
          {:thinking_delta, "b"},
          {:text_delta, "c"}
        ])

      assert state.workspace.agent_ui.panel.transcript.version == 1
      assert MingaEditor.State.RenderCorrelation.scheduled?(state.render.render_correlation)
    end

    test "empty batches and unknown events are no-ops" do
      %{state: state} = make_state()

      assert AgentEvents.dispatch_batch(state, []) == state
      assert AgentEvents.dispatch(state, {:some_future_event, "data"}) == state
    end
  end

  describe "set_tab_session/3" do
    test "sets the session pid on a tab for event routing" do
      %{state: state} = make_state()
      tab = TabBar.active(state.shell_runtime.state.tab_bar)
      new_session = spawn(fn -> :timer.sleep(:infinity) end)

      state =
        then(state, fn state ->
          %{
            state
            | shell_runtime:
                MingaEditor.Shell.Runtime.set_tab_session(
                  state.shell_runtime,
                  tab.id,
                  new_session
                )
          }
        end)

      tab = TabBar.get(state.shell_runtime.state.tab_bar, tab.id)
      workspace = TabBar.active_workspace(state.shell_runtime.state.tab_bar)
      assert tab.session == new_session
      assert workspace.session == new_session
    end
  end

  describe "tab context excludes shell agent runtime and projected workspace agent UI" do
    test "snapshot_tab_context keeps routing state without shell runtime or agent UI projection" do
      %{state: state} = make_state()

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          MingaEditor.Agent.PromptBuffer.set_input_focused(state.workspace.agent_ui, true)
        )

      ctx = MingaEditor.State.Tab.Context.snapshot(state.workspace)

      refute Map.has_key?(ctx, :agent)
      refute Map.has_key?(ctx, :agentic)
      refute :agent_ui in ctx.present_fields
      refute Map.has_key?(Map.from_struct(ctx), :agent_ui)

      workspace = TabBar.active_workspace(state.shell_runtime.state.tab_bar)
      assert workspace.agent_ui == state.workspace.agent_ui
      assert state.workspace.agent_ui.panel.input_focused
    end
  end

  describe "Agent.Events.dispatch/2 - tab status sync" do
    test "status_changed syncs agent_status on the agent tab" do
      %{state: state, session: session} = make_state()

      {tb, agent_tab} = TabBar.add(state.shell_runtime.state.tab_bar, :agent, "Agent")

      tb =
        tb
        |> TabBar.set_tab_session(agent_tab.id, session)
        |> TabBar.set_workspace_session(agent_tab.group_id, session)

      state =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              tb
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      new_state = AgentEvents.dispatch(state, {:status_changed, :thinking})

      agent_tab = TabBar.get(new_state.shell_runtime.state.tab_bar, agent_tab.id)
      assert agent_tab.agent_status == :thinking
    end

    test "status_changed to :idle updates tab status" do
      %{state: state, session: session} = make_state()

      {tb, agent_tab} = TabBar.add(state.shell_runtime.state.tab_bar, :agent, "Agent")

      tb =
        tb
        |> TabBar.set_tab_session(agent_tab.id, session)
        |> TabBar.set_workspace_session(agent_tab.group_id, session)

      state =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              tb
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      new_state = AgentEvents.dispatch(state, {:status_changed, :idle})

      agent_tab = TabBar.get(new_state.shell_runtime.state.tab_bar, agent_tab.id)
      assert agent_tab.agent_status == :idle
    end
  end
end
