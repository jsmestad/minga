defmodule MingaEditor.State.EventRoutingTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Events, as: AgentEvents
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.RuntimeState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.{Tab, TabBar, Workspace}
  alias MingaEditor.Viewport

  defp make_state(opts \\ []) do
    session = opts[:session] || spawn(fn -> :timer.sleep(:infinity) end)

    # Default fixture has only a file tab; tests that exercise per-tab
    # routing add an agent tab and attach the session via Tab.set_session.
    tb = TabBar.new(Tab.new_file(1, "main.ex"))

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80)
      },
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

  describe "Agent.Events.handle/2 — status changes" do
    test "status_changed updates agent status" do
      %{state: state} = make_state()

      {new_state, effects} = AgentEvents.handle(state, {:status_changed, :thinking})

      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).runtime.status ==
               :thinking

      assert :render in effects
    end

    test "status_changed to :thinking engages auto-scroll" do
      %{state: state} = make_state()

      {new_state, _effects} = AgentEvents.handle(state, {:status_changed, :thinking})

      assert new_state.workspace.agent_ui.panel.scroll.pinned == true
    end

    test "status_changed to :error logs a message" do
      %{state: state} = make_state()

      {_new_state, effects} = AgentEvents.handle(state, {:status_changed, :error})

      assert {:log_message, "Agent: error"} in effects
    end

    test "status_changed to :idle stops spinner" do
      %{state: state} = make_state()
      state = MingaEditor.Shell.Traditional.Workflow.install_agent_spinner_start(state)

      {new_state, _effects} = AgentEvents.handle(state, {:status_changed, :idle})

      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).spinner_timer ==
               nil
    end
  end

  describe "Agent.Events.handle/2 — content deltas" do
    # Live streaming coalesces deltas through MingaEditor.Agent.Ingest and applies
    # them via handle_batch/2; the single-delta handle/2 clauses remain for the
    # bounded remote event-replay path and delegate to the batch path, so they
    # now request one coalesced render and one transcript sync.
    test "text_delta requests a render and a transcript sync" do
      %{state: state} = make_state()

      {_new_state, effects} = AgentEvents.handle(state, {:text_delta, "hello"})

      assert {:render, 16} in effects
      assert :sync_agent_transcript in effects
    end

    test "thinking_delta requests a render and a transcript sync" do
      %{state: state} = make_state()

      {_new_state, effects} = AgentEvents.handle(state, {:thinking_delta, "hmm"})

      assert {:render, 16} in effects
      assert :sync_agent_transcript in effects
    end

    test "messages_changed triggers transcript sync and tab label update" do
      %{state: state} = make_state()

      {new_state, effects} = AgentEvents.handle(state, :messages_changed)

      assert :sync_agent_transcript in effects
      assert {:update_tab_label, ""} in effects
      # message_version is bumped so the GUI fingerprint cache is invalidated
      assert new_state.workspace.agent_ui.panel.message_version == 1
    end
  end

  describe "Agent.Events.handle_batch/2 — coalesced stream batch (#2289)" do
    test "N text/thinking deltas produce exactly one buffer sync and one version bump" do
      %{state: state} = make_state()

      batch = [
        {:text_delta, "a"},
        {:thinking_delta, "b"},
        {:text_delta, "c"},
        {:text_delta, "d"}
      ]

      {new_state, effects} = AgentEvents.handle_batch(state, batch)

      # One transcript sync, one render, not one per delta. AC 2.
      assert Enum.count(effects, &(&1 == :sync_agent_transcript)) == 1
      assert Enum.count(effects, &match?({:render, _}, &1)) == 1
      # A single coalesced batch bumps the version exactly once.
      assert new_state.workspace.agent_ui.panel.message_version == 1
    end

    test "a tool-update-only batch renders without syncing the transcript" do
      %{state: state} = make_state()

      batch = [{:tool_update, "id", "search", "partial"}]

      {new_state, effects} = AgentEvents.handle_batch(state, batch)

      refute :sync_agent_transcript in effects
      assert {:render, 16} in effects
      # No assistant text, so the transcript version is untouched.
      assert new_state.workspace.agent_ui.panel.message_version == 0
    end

    test "an empty batch is a no-op" do
      %{state: state} = make_state()

      assert {^state, []} = AgentEvents.handle_batch(state, [])
    end
  end

  describe "Agent.Events.handle/2 — errors" do
    test "error updates agent error state and re-renders without re-logging" do
      %{state: state} = make_state()

      {new_state, effects} = AgentEvents.handle(state, {:error, "something broke"})

      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).error ==
               "something broke"

      assert :render in effects
      # The session already surfaced this in the transcript and the provider
      # logged the raw detail to the Messages panel; re-logging here would
      # duplicate the Messages entry and force-open the panel.
      refute Enum.any?(effects, &match?({:log_warning, _}, &1))
    end
  end

  describe "Agent.Events.handle/2 — credentials status" do
    test "credentials_status updates the panel flag and re-renders" do
      %{state: state} = make_state()
      assert state.workspace.agent_ui.panel.credentials_configured == false

      {new_state, effects} = AgentEvents.handle(state, {:credentials_status, true})

      assert new_state.workspace.agent_ui.panel.credentials_configured == true
      assert :render in effects

      {restored, _effects} = AgentEvents.handle(new_state, {:credentials_status, false})
      assert restored.workspace.agent_ui.panel.credentials_configured == false
    end
  end

  describe "Agent.Events.handle/2 — spinner" do
    test "spinner_tick when busy ticks the spinner frame" do
      %{state: state} = make_state()
      state = MingaEditor.Shell.Traditional.Workflow.install_agent_status(state, :thinking)
      state = MingaEditor.Shell.Traditional.Workflow.install_agent_spinner_start(state)

      {new_state, effects} = AgentEvents.handle(state, :spinner_tick)

      assert new_state.workspace.agent_ui.panel.spinner_frame == 1
      assert {:render, 16} in effects
    end

    test "spinner_tick when idle stops the spinner timer" do
      %{state: state} = make_state()

      {new_state, effects} = AgentEvents.handle(state, :spinner_tick)

      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).spinner_timer ==
               nil

      assert effects == []
    end
  end

  describe "Agent.Events.handle/2 — approval" do
    test "approval_pending sets pending approval on agent" do
      %{state: state} = make_state()

      approval = %{tool_call_id: "123", name: "shell", args: %{"command" => "ls"}}
      {new_state, effects} = AgentEvents.handle(state, {:approval_pending, approval})

      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).pending_approval ==
               %{
                 tool_call_id: "123",
                 name: "shell",
                 args: %{"command" => "ls"}
               }

      assert :render in effects
      assert :sync_agent_transcript in effects
    end

    test "approval_pending unfocuses the prompt input" do
      %{state: state} = make_state()

      # Simulate the user typing in the prompt (input focused)
      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          MingaEditor.Agent.PromptBuffer.set_input_focused(state.workspace.agent_ui, true)
        )

      assert state.workspace.agent_ui.panel.input_focused

      approval = %{tool_call_id: "456", name: "write_file", args: %{}}
      {new_state, _effects} = AgentEvents.handle(state, {:approval_pending, approval})

      # Input must be unfocused so the ToolApproval handler can intercept y/n
      refute new_state.workspace.agent_ui.panel.input_focused
    end

    test "approval_resolved clears pending approval and syncs transcript" do
      %{state: state} = make_state()

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_approval(state, %{name: "shell"})

      {new_state, effects} = AgentEvents.handle(state, {:approval_resolved, :approved})

      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).pending_approval ==
               nil

      assert :sync_agent_transcript in effects
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

  describe "tab context excludes shell agent runtime but includes workspace agent UI" do
    test "snapshot_tab_context keeps per-tab agent UI without shell runtime fields" do
      %{state: state} = make_state()

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          MingaEditor.Agent.PromptBuffer.set_input_focused(state.workspace.agent_ui, true)
        )

      ctx = EditorState.snapshot_tab_context(state)

      refute Map.has_key?(ctx, :agent)
      refute Map.has_key?(ctx, :agentic)
      assert :agent_ui in ctx.present_fields
      assert ctx.agent_ui == state.workspace.agent_ui
      assert ctx.agent_ui.panel.input_focused
    end
  end

  describe "Agent.Events.handle/2 — tab status sync" do
    test "status_changed syncs agent_status on the agent tab" do
      %{state: state, session: session} = make_state()

      {tb, agent_tab} = TabBar.add(state.shell_runtime.state.tab_bar, :agent, "Agent")

      tb =
        tb
        |> TabBar.update_tab(agent_tab.id, &Tab.set_session(&1, session))
        |> TabBar.update_workspace(agent_tab.group_id, &Workspace.set_session(&1, session))

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

      {new_state, _effects} = AgentEvents.handle(state, {:status_changed, :thinking})

      agent_tab = TabBar.get(new_state.shell_runtime.state.tab_bar, agent_tab.id)
      assert agent_tab.agent_status == :thinking
    end

    test "status_changed to :idle updates tab status" do
      %{state: state, session: session} = make_state()

      {tb, agent_tab} = TabBar.add(state.shell_runtime.state.tab_bar, :agent, "Agent")

      tb =
        tb
        |> TabBar.update_tab(agent_tab.id, &Tab.set_session(&1, session))
        |> TabBar.update_workspace(agent_tab.group_id, &Workspace.set_session(&1, session))

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

      {state, _} = AgentEvents.handle(state, {:status_changed, :thinking})
      {new_state, _} = AgentEvents.handle(state, {:status_changed, :idle})

      agent_tab = TabBar.get(new_state.shell_runtime.state.tab_bar, agent_tab.id)
      assert agent_tab.agent_status == :idle
    end
  end
end
