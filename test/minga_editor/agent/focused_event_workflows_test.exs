defmodule MingaEditor.Agent.FocusedEventWorkflowsTest do
  use Minga.Test.SessionCase, async: true

  alias MingaEditor.Agent.Compaction
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.Events
  alias MingaEditor.Agent.FileEventWorkflow
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.SessionEventWorkflow
  alias MingaEditor.Agent.StatusEventWorkflow
  alias MingaEditor.Agent.StreamEventWorkflow
  alias MingaEditor.Agent.ToolEventWorkflow
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.EffectScheduler
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.Viewport
  alias MingaEditor.Session.State, as: SessionState
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.Session

  test "status workflow synchronizes owner state before installing a render" do
    state = event_state()

    state = StatusEventWorkflow.status_changed(state, :thinking)

    assert TraditionalState.agent(state.shell_runtime.state).runtime.status == :thinking
    assert state.workspace.agent_ui.panel.scroll.pinned
    assert state.workspace.agent_ui.view.activity.started_at
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "stream workflow applies one bounded batch transition and one render" do
    state = event_state()

    state =
      StreamEventWorkflow.batch(state, [
        {:text_delta, "one"},
        {:thinking_delta, "two"},
        {:tool_update, "tc", "shell", "partial"}
      ])

    assert state.workspace.agent_ui.panel.message_version == 1
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "stream workflow directly orders render, transcript synchronization, and label refresh" do
    {:ok, session} = start_supervised({Session, provider_opts: []})

    :ok =
      Session.seed_messages(session, [{:assistant, "Summarize focused workflows\nMore detail"}])

    state = event_state(session)

    state = StreamEventWorkflow.messages_changed(state)

    assert RenderCorrelation.scheduled?(state.render.render_correlation)
    assert state.workspace.agent_ui.panel.cached_display_messages != []
    assert state.workspace.agent_ui.panel.message_version == 1

    workspace =
      state.shell_runtime.state
      |> TraditionalState.tab_bar()
      |> TabBar.find_workspace_by_session(session)

    assert %Workspace{label: "Summarize focused workflows"} = workspace
  end

  test "tool workflow follows the session snapshot and clears completed activity" do
    state = event_state()

    state = ToolEventWorkflow.started(state, "tc1", "read_file", %{"path" => "lib/a.ex"})

    assert AgentState.active_tool_name(TraditionalState.agent(state.shell_runtime.state)) ==
             "read_file"

    assert state.workspace.agent_ui.view.preview.content == {:file, "lib/a.ex", ""}

    state = ToolEventWorkflow.ended(state, "tc1", "read_file", "contents", :done)
    assert AgentState.active_tool_name(TraditionalState.agent(state.shell_runtime.state)) == nil
    assert state.workspace.agent_ui.view.preview.content == {:file, "lib/a.ex", "contents"}
  end

  test "tool workflow preserves batched shell output before interruption clears live activity" do
    state = ToolEventWorkflow.started(event_state(), "tc1", "shell", %{"command" => "mix test"})

    state = StreamEventWorkflow.batch(state, [{:tool_update, "tc1", "shell", "3 tests"}])

    assert state.workspace.agent_ui.view.preview.content ==
             {:shell, "mix test", "3 tests", :running}

    assert state.workspace.agent_ui.view.activity.active_action == "Running shell"

    state = ToolEventWorkflow.interrupted(state, "tc1")

    assert state.workspace.agent_ui.view.preview.content == :empty
    assert state.workspace.agent_ui.view.activity.active_action == "Thinking"
    assert AgentState.active_tool_name(TraditionalState.agent(state.shell_runtime.state)) == nil
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "file workflow records baseline and timeline before installing the diff render" do
    state = event_state()

    state = FileEventWorkflow.changed(state, "/tmp/a.ex", "before", "after", "tc1", "edit")

    assert UIState.get_baseline(state.workspace.agent_ui, "/tmp/a.ex") == "before"
    assert [entry] = state.workspace.agent_ui.view.edit_timeline.entries["/tmp/a.ex"]
    assert entry.tool_call_id == "tc1"
    assert state.workspace.agent_ui.view.presentation.focus == :file_viewer
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "file catch-up replay preserves order and suppresses an already-applied identity" do
    records = [
      file_record("tc1", "before", "first"),
      file_record("tc1", "ignored", "duplicate"),
      file_record("tc2", "first", "second")
    ]

    state = Events.replay_catchup(event_state(), records)
    entries = EditTimeline.entries_for(state.workspace.agent_ui.view.edit_timeline, "/tmp/a.ex")

    assert Enum.map(entries, & &1.tool_call_id) == ["tc1", "tc2"]

    assert {:ok, "first"} =
             EditTimeline.content_at(state.workspace.agent_ui.view.edit_timeline, "/tmp/a.ex", 0)

    assert {:ok, "second"} =
             EditTimeline.content_at(state.workspace.agent_ui.view.edit_timeline, "/tmp/a.ex", 1)
  end

  test "session workflow installs approval state before render and transcript synchronization" do
    {:ok, session} = start_supervised({Session, provider_opts: []})
    state = event_state(session)
    approval = %{tool_call_id: "tc1", name: "shell", args: %{"command" => "pwd"}}

    state = SessionEventWorkflow.approval_pending(state, approval)

    assert TraditionalState.agent(state.shell_runtime.state).pending_approval == approval
    refute state.workspace.agent_ui.panel.input_focused
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
    assert state.workspace.agent_ui.panel.cached_display_messages != []
  end

  test "session workflow clears a resolved approval and synchronizes the transcript" do
    {:ok, session} = start_supervised({Session, provider_opts: []})
    approval = %{tool_call_id: "tc1", name: "shell", args: %{"command" => "pwd"}}

    state = event_state(session) |> SessionEventWorkflow.approval_pending(approval)
    state = SessionEventWorkflow.approval_resolved(state, :approved)

    assert TraditionalState.agent(state.shell_runtime.state).pending_approval == nil
    assert state.workspace.agent_ui.panel.cached_display_messages != []
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "session error recalls steering and follow-up prompts before the current draft" do
    session = start_slow_turn()
    assert {:queued, :steering} = Session.send_prompt(session, "steer first")
    assert {:queued, :follow_up} = Session.queue_follow_up(session, "follow second")

    state = event_state(session)

    prompt_ui =
      state.workspace.agent_ui
      |> PromptBuffer.ensure()
      |> PromptBuffer.set_prompt_text("current draft")

    state = TraditionalWorkflow.install_agent_ui(state, prompt_ui)

    state = SessionEventWorkflow.error(state, "provider failed")

    assert PromptBuffer.prompt_text(state.workspace.agent_ui) ==
             "steer first\n\nfollow second\n\ncurrent draft"

    assert Session.get_queued_messages(session) == {[], []}
    assert TraditionalState.agent(state.shell_runtime.state).error == "provider failed"
  end

  test "idle status admits deferred compaction for the active session" do
    {:ok, session} = start_supervised({Session, provider_opts: []})
    task_supervisor = start_supervised!({Task.Supervisor, []})

    effect_scheduler =
      start_supervised!({EffectScheduler, task_supervisor: task_supervisor})

    :ok = EffectScheduler.attach(effect_scheduler, self())

    state = event_state(session, effect_scheduler)
    state = StatusEventWorkflow.status_changed(state, :thinking)
    state = StatusEventWorkflow.context_usage(state, 95, 100)

    assert state.workspace.agent_ui.view.compact_pending_fill_pct == 95
    refute state.workspace.agent_ui.view.compaction_in_progress

    state = StatusEventWorkflow.status_changed(state, :idle)

    assert state.workspace.agent_ui.view.compact_pending_fill_pct == nil
    assert state.workspace.agent_ui.view.compaction_in_progress
    assert EffectScheduler.active?(effect_scheduler, Compaction)
  end

  test "session error cancellation path tolerates a session that exited before queue recall" do
    session = spawn(fn -> :ok end)
    monitor = Process.monitor(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, reason}
    assert reason in [:normal, :noproc]
    state = event_state(session)

    state = SessionEventWorkflow.error(state, "provider failed")

    assert TraditionalState.agent(state.shell_runtime.state).error == "provider failed"
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  @spec file_record(String.t(), String.t(), String.t()) :: EventRecord.t()
  defp file_record(tool_call_id, before_content, after_content) do
    EventRecord.new("session", :file_edit_proposed, %{
      "path" => "/tmp/a.ex",
      "before_content" => before_content,
      "after_content" => after_content,
      "tool_call_id" => tool_call_id,
      "tool_name" => "edit"
    })
  end

  @spec event_state(pid() | nil, EffectScheduler.server() | nil) :: EditorState.t()
  defp event_state(session \\ nil, effect_scheduler \\ nil) do
    tab_bar = tab_bar(session)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: nil},
      workspace: %SessionState{viewport: Viewport.new(24, 80), agent_ui: UIState.new()},
      effect_scheduler: effect_scheduler,
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          TraditionalState.install_tab_bar(
            TraditionalState.replace_agent(%TraditionalState{}, %AgentState{}),
            tab_bar
          )
        )
    }
  end

  @spec tab_bar(pid() | nil) :: TabBar.t()
  defp tab_bar(nil), do: TabBar.new(Tab.new_agent(1, "Agent"))

  defp tab_bar(session) do
    {tab_bar, workspace} =
      TabBar.add_workspace(TabBar.new(Tab.new_agent(1, "Agent")), "Agent", session)

    TabBar.move_tab_to_workspace(tab_bar, 1, workspace.id)
  end
end
