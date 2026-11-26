defmodule MingaEditor.Agent.FocusedEventWorkflowsTest do
  use Minga.Test.SessionCase, async: true

  alias Minga.Test.TranscriptSyncDriver
  alias MingaEditor.Agent.Compaction
  alias Minga.Git
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.FileChange
  alias MingaEditor.Agent.FileEventWorkflow
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.SessionEventWorkflow
  alias MingaEditor.Agent.StatusEventWorkflow
  alias MingaEditor.Agent.StreamEventWorkflow
  alias MingaEditor.Agent.ToolEventWorkflow
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Compaction, as: CompactionState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Commands.AgentSubStates
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Registry, as: ShellRegistry
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
  alias MingaEditor.WorkspaceWorkflow
  alias MingaEditor.Session.State, as: SessionState
  alias MingaAgent.Session
  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaEditor.Test.FakeShell

  test "status workflow preserves an unpinned transcript before installing a render" do
    state =
      event_state()
      |> TraditionalWorkflow.install_agent_ui(UIState.new() |> UIState.scroll_down(7))

    state = StatusEventWorkflow.status_changed(state, :thinking)

    assert TraditionalState.agent(state.shell_runtime.state).runtime.status == :thinking
    refute state.workspace.agent_ui.panel.scroll.pinned
    assert state.workspace.agent_ui.panel.scroll.offset == 7
    assert state.workspace.agent_ui.view.activity.started_at
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "context usage remains shell-generic when the active shell is not Traditional" do
    entry = Entry.builtin!(:fake, FakeShell, "Fake", "Fake shell", false)
    shell_state = Map.put(FakeShell.init([]), :session, self())
    state = %{event_state() | shell_runtime: Runtime.new(entry, shell_state)}

    updated = StatusEventWorkflow.context_usage(state, 90, 100)

    assert updated.workspace.agent_ui.view.context_estimate == 90
    assert RenderCorrelation.scheduled?(updated.render.render_correlation)
    assert Runtime.state(updated.shell_runtime) == shell_state
  end

  test "stream workflow applies one bounded batch transition and one render" do
    state = event_state()

    state =
      StreamEventWorkflow.batch(state, [
        {:text_delta, "one"},
        {:thinking_delta, "two"},
        {:tool_update, "tc", "shell", "partial"}
      ])

    assert state.workspace.agent_ui.panel.transcript.version == 1
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "live-session stream batches synchronize the transcript once" do
    {:ok, session} = start_supervised({Session, provider_opts: []})
    :ok = Session.seed_messages(session, [{:assistant, "Live streamed answer"}])
    state = event_state(session)

    state =
      StreamEventWorkflow.batch(state, [{:text_delta, "Live streamed answer"}])
      |> TranscriptSyncDriver.settle()

    assert {:assistant, "Live streamed answer"} in Minga.Test.TranscriptFixture.messages(
             state.workspace.agent_ui.panel.transcript
           )

    assert state.workspace.agent_ui.panel.transcript.version == 1
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "changed transcript names the Agent tab and workspace without another Session read" do
    {:ok, session} = start_supervised({Session, provider_opts: []})

    :ok =
      Session.seed_messages(session, [
        {:user, "Find the first failing check\nMore detail"},
        {:assistant, "Summarize focused workflows\nMore detail"}
      ])

    state = event_state(session)
    :erlang.trace(session, true, [:receive, {:tracer, self()}])
    state = state |> StreamEventWorkflow.messages_changed() |> TranscriptSyncDriver.settle()
    trace_barrier = :erlang.trace_delivered(session)
    assert_receive {:trace_delivered, ^session, ^trace_barrier}
    refute_received {:trace, ^session, :receive, {:"$gen_call", _from, :messages}}

    tabs = TraditionalState.tab_bar(state.shell_runtime.state)
    assert %Tab{label: "Find the first failing check"} = TabBar.active(tabs)

    assert %Workspace{label: "Summarize focused workflows", id: workspace_id} =
             TabBar.find_workspace_by_session(tabs, session)

    # An unchanged sync leaves names added independently of transcript updates alone.
    state = WorkspaceWorkflow.install_tab_bar(state, TabBar.update_label(tabs, 1, "Agent"))
    state = WorkspaceWorkflow.install_auto_named_workspace(state, workspace_id, "Queued next")
    state = state |> StreamEventWorkflow.messages_changed() |> TranscriptSyncDriver.settle()
    tabs = TraditionalState.tab_bar(state.shell_runtime.state)
    assert %Tab{label: "Agent"} = TabBar.active(tabs)
    assert %Workspace{label: "Queued next"} = TabBar.find_workspace_by_session(tabs, session)
  end

  test "a queued prompt never renames the task" do
    {:ok, session} = start_supervised({Session, provider_opts: []})
    state = event_state(session)

    workspace_before =
      state.shell_runtime.state
      |> TraditionalState.tab_bar()
      |> TabBar.find_workspace_by_session(session)

    for kind <- [:steering, :follow_up] do
      updated = SessionEventWorkflow.prompt_queued(state, session, "q3\nMore detail", kind)

      workspace =
        updated.shell_runtime.state
        |> TraditionalState.tab_bar()
        |> TabBar.find_workspace_by_session(session)

      assert workspace.label == workspace_before.label
      assert RenderCorrelation.scheduled?(updated.render.render_correlation)
    end
  end

  test "workspace auto-name transition no-ops when its target is unavailable" do
    missing_tab_bar =
      %{event_state() | shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{})}

    missing_workspace = event_state()
    fake_entry = Entry.builtin!(:fake, FakeShell, "Fake", "Fake shell", false)

    non_traditional = %{
      event_state()
      | shell_runtime: Runtime.new(fake_entry, FakeShell.init([]))
    }

    assert WorkspaceWorkflow.install_auto_named_workspace(missing_tab_bar, 1, "Name") ===
             missing_tab_bar

    assert WorkspaceWorkflow.install_auto_named_workspace(missing_workspace, 999, "Name") ===
             missing_workspace

    assert WorkspaceWorkflow.install_auto_named_workspace(non_traditional, 1, "Name") ===
             non_traditional
  end

  test "tool preview shows the completed read result while running activity clears" do
    state = event_state()

    state = ToolEventWorkflow.started(state, "tc1", "read_file", %{"path" => "lib/a.ex"})

    assert AgentState.active_tool_name(TraditionalState.agent(state.shell_runtime.state)) ==
             "read_file"

    assert state.workspace.agent_ui.view.preview.content == {:file, "lib/a.ex", ""}

    state =
      ToolEventWorkflow.ended(state, %MingaAgent.Event.ToolEnd{
        tool_call_id: "tc1",
        name: "read_file",
        result: "contents",
        outcome: :complete
      })

    assert AgentState.active_tool_name(TraditionalState.agent(state.shell_runtime.state)) == nil
    assert state.workspace.agent_ui.view.preview.content == {:file, "lib/a.ex", "contents"}
  end

  test "unsuccessful file and directory tools do not replace previews with failure text" do
    for {name, args} <- [
          {"read_file", %{"path" => "lib/a.ex"}},
          {"list_directory", %{"path" => "lib"}}
        ],
        outcome <- [:denied, :cancelled, :error] do
      started = ToolEventWorkflow.started(event_state(), "rejected", name, args)

      finished =
        ToolEventWorkflow.ended(started, %MingaAgent.Event.ToolEnd{
          tool_call_id: "rejected",
          name: name,
          result: "The tool did not produce file contents or directory entries",
          outcome: outcome,
          is_error: true
        })

      assert finished.workspace.agent_ui.view.preview == started.workspace.agent_ui.view.preview

      assert AgentState.active_tool_name(TraditionalState.agent(finished.shell_runtime.state)) ==
               nil
    end
  end

  test "tool workflow preserves batched shell output before interruption clears live activity" do
    state = ToolEventWorkflow.started(event_state(), "tc1", "shell", %{"command" => "mix test"})

    state = StreamEventWorkflow.batch(state, [{:tool_update, "tc1", "shell", "3 tests"}])

    assert state.workspace.agent_ui.view.preview.content ==
             {:shell, "mix test", "3 tests", :running}

    assert state.workspace.agent_ui.view.activity.active_action == "Running `mix test`"

    state = ToolEventWorkflow.interrupted(state, "tc1")

    assert state.workspace.agent_ui.view.preview.content == :empty
    assert state.workspace.agent_ui.view.activity.active_action == "Thinking"
    assert AgentState.active_tool_name(TraditionalState.agent(state.shell_runtime.state)) == nil
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "background tools keep a selected current or stale review while activity still advances" do
    preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "after"))
    stale = Preview.refresh_after_write(preview, "selected.ex")

    for preview <- [preview, stale],
        {tool, args, result} <- [
          {"shell", %{"command" => "mix test"}, "3 tests"},
          {"read_file", %{"path" => "other.ex"}, "other contents"},
          {"list_directory", %{"path" => "."}, "a.ex\nb.ex"}
        ] do
      state = event_state()
      ui = UIState.replace_preview(state.workspace.agent_ui, preview)
      state = TraditionalWorkflow.install_agent_ui(state, ui)
      started = ToolEventWorkflow.started(state, "tc1", tool, args)
      assert started.workspace.agent_ui.view.preview == preview

      assert AgentState.active_tool_name(TraditionalState.agent(started.shell_runtime.state)) ==
               tool

      updated = ToolEventWorkflow.updated(started, "tc1", tool, "partial output")
      assert updated.workspace.agent_ui.view.preview == preview

      ended =
        ToolEventWorkflow.ended(updated, %MingaAgent.Event.ToolEnd{
          tool_call_id: "tc1",
          name: tool,
          result: result,
          outcome: :complete
        })

      assert ended.workspace.agent_ui.view.preview == preview
      assert AgentState.active_tool_name(TraditionalState.agent(ended.shell_runtime.state)) == nil
      interrupted = ToolEventWorkflow.interrupted(ended, "tc1")
      assert interrupted.workspace.agent_ui.view.preview == preview
    end
  end

  test "file workflow records cumulative hunks and timeline without selecting a preview" do
    state = event_state()

    state = FileEventWorkflow.changed(state, file_change("/tmp/a.ex", "before", "after", "tc1"))
    timeline = state.workspace.agent_ui.view.edit_timeline

    assert EditTimeline.cumulative_hunks(timeline, "/tmp/a.ex") ==
             Git.diff_lines(["before"], ["after"])

    assert [entry] = timeline.entries["/tmp/a.ex"]
    assert entry.tool_call_id == "tc1"
    assert diff_review(state) == nil
    assert state.workspace.agent_ui.view.preview.content == :empty
    assert state.workspace.agent_ui.view.presentation.focus == :chat
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "a selected file keeps its stale reading revision and explicit Review acquires all cumulative writes" do
    state =
      event_state()
      |> FileEventWorkflow.changed(file_change("/tmp/a.ex", "a0", "a1", "tc1"))
      |> select_review("/tmp/a.ex")
      |> FileEventWorkflow.changed(file_change("/tmp/b.ex", "b0", "b1", "tc2"))
      |> FileEventWorkflow.changed(file_change("/tmp/a.ex", "a1", "a2", "tc3"))

    assert state.workspace.agent_ui.view.preview.freshness == :stale
    assert diff_review(state) == nil

    assert {:diff, %DiffReview{after_lines: ["a1"]}} =
             state.workspace.agent_ui.view.preview.content

    state = select_review(state, "/tmp/a.ex")

    assert %DiffReview{path: "/tmp/a.ex"} = review = diff_review(state)

    display_lines = DiffReview.to_display_lines(review)
    assert Enum.any?(display_lines, &match?(%{text: "a0", kind: :removed}, &1))
    assert Enum.any?(display_lines, &match?(%{text: "a2", kind: :added}, &1))
    refute Enum.any?(display_lines, &match?(%{text: "a1", kind: :removed}, &1))
    refute Map.has_key?(Map.from_struct(state.workspace.agent_ui.view), :diff_baselines)
  end

  @tag :tmp_dir
  test "rejecting an added hunk synchronizes cumulative authority before the next same-path edit",
       %{
         tmp_dir: dir
       } do
    path = Path.join(dir, "a.ex")
    File.write!(path, "x\na")
    {:ok, view} = MingaAgent.ProjectView.overlay(dir)

    state =
      owned_event_state(view)
      |> FileEventWorkflow.changed(file_change(path, "a", "x\na", "tc1"))
      |> select_review(path, view)
      |> AgentSubStates.reject_hunk()

    assert {:ok, "a"} = MingaAgent.ProjectView.read_file(view, "a.ex")

    assert :ok = MingaAgent.ProjectView.write_file(view, "a.ex", "a\nb")
    state = FileEventWorkflow.changed(state, file_change(path, "a", "a\nb", "tc2"))
    state = select_review(state, path, view)
    review = diff_review(state)

    assert DiffReview.summary(review) == {1, 0}
    display_lines = DiffReview.to_display_lines(review)
    assert Enum.any?(display_lines, &match?(%{text: "b", kind: :added}, &1))
    refute Enum.any?(display_lines, &match?(%{text: "a", kind: :added}, &1))
    refute Enum.any?(display_lines, &match?(%{text: "a", kind: :removed}, &1))

    state = AgentSubStates.reject_hunk(state)
    assert {:ok, "a"} = MingaAgent.ProjectView.read_file(view, "a.ex")
    refute diff_review(state)
  end

  @tag :tmp_dir
  test "path switch after rejection does not reuse stale hunks for the original path", %{
    tmp_dir: dir
  } do
    path_a = Path.join(dir, "a.ex")
    path_b = Path.join(dir, "b.ex")
    File.write!(path_a, "x\na")
    {:ok, view} = MingaAgent.ProjectView.overlay(dir)

    state =
      owned_event_state(view)
      |> FileEventWorkflow.changed(file_change(path_a, "a", "x\na", "tc1"))
      |> select_review(path_a, view)
      |> AgentSubStates.reject_hunk()
      |> FileEventWorkflow.changed(file_change(path_b, "b0", "b1", "tc2"))

    assert EditTimeline.cumulative_hunks(state.workspace.agent_ui.view.edit_timeline, path_b) ==
             Git.diff_lines(["b0"], ["b1"])

    assert :ok = MingaAgent.ProjectView.write_file(view, "a.ex", "a\nb")
    state = FileEventWorkflow.changed(state, file_change(path_a, "a", "a\nb", "tc3"))
    state = select_review(state, path_a, view)
    review = diff_review(state)

    assert %DiffReview{path: ^path_a} = review
    assert DiffReview.summary(review) == {1, 0}
    display_lines = DiffReview.to_display_lines(review)
    assert Enum.any?(display_lines, &match?(%{text: "b", kind: :added}, &1))
    refute Enum.any?(display_lines, &match?(%{text: "a", kind: :added}, &1))

    _state = AgentSubStates.reject_hunk(state)
    assert {:ok, "a"} = MingaAgent.ProjectView.read_file(view, "a.ex")
  end

  test "spinner ticks advance only while the foreground agent is busy" do
    busy = StatusEventWorkflow.status_changed(event_state(), :thinking)
    frame = busy.workspace.agent_ui.panel.spinner_frame
    busy = SessionEventWorkflow.spinner_tick(busy)

    assert busy.workspace.agent_ui.panel.spinner_frame == frame + 1
    assert RenderCorrelation.scheduled?(busy.render.render_correlation)

    idle = StatusEventWorkflow.status_changed(busy, :idle)
    idle_frame = idle.workspace.agent_ui.panel.spinner_frame
    idle = SessionEventWorkflow.spinner_tick(idle)

    assert idle.workspace.agent_ui.panel.spinner_frame == idle_frame
    assert TraditionalState.agent(idle.shell_runtime.state).spinner_timer == nil
  end

  test "credentials status alone updates presentation and schedules a render" do
    state = event_state()
    panel = state.workspace.agent_ui.panel
    state = SessionEventWorkflow.credentials_status(state, :configured)

    assert state.workspace.agent_ui.panel.credentials_configured
    assert state.workspace.agent_ui.panel.transcript.version == panel.transcript.version

    assert Minga.Test.TranscriptFixture.messages(state.workspace.agent_ui.panel.transcript) ==
             Minga.Test.TranscriptFixture.messages(panel.transcript)

    assert RenderCorrelation.scheduled?(state.render.render_correlation)
  end

  test "error status logs the user-visible agent failure marker" do
    :ok = Minga.Events.subscribe(:log_message)
    on_exit(fn -> Minga.Events.unsubscribe(:log_message) end)

    _state = StatusEventWorkflow.status_changed(event_state(), :error)

    assert_agent_error_logged()
  end

  test "approval arrival preserves composer focus while installing the displayed attachment" do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()]
      )

    agent_ui = UIState.new() |> UIState.set_input_focused(true)

    state =
      event_state(session)
      |> TraditionalWorkflow.install_agent_ui(agent_ui)

    approval = admit_approval(session)

    state =
      SessionEventWorkflow.approval_pending(state, session, approval)
      |> TranscriptSyncDriver.settle()

    assert %PendingApproval{session_pid: ^session, approval: ^approval} =
             TraditionalState.agent(state.shell_runtime.state).pending_approval

    assert state.workspace.agent_ui.panel.input_focused
    assert RenderCorrelation.scheduled?(state.render.render_correlation)
    assert Minga.Test.TranscriptFixture.messages(state.workspace.agent_ui.panel.transcript) != []
  end

  test "every approval retirement releases waiting presentation and synchronizes the transcript" do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()]
      )

    approval = admit_approval(session)

    agent_ui =
      UIState.new()
      |> PromptBuffer.ensure()
      |> PromptBuffer.set_prompt_text("unfinished draft\nkeep caret")
      |> UIState.set_input_focused(true)

    prompt = agent_ui.panel.prompt_buffer
    Minga.Buffer.move_to(prompt, {1, 3})

    state =
      event_state(session)
      |> TraditionalWorkflow.install_agent_ui(agent_ui)
      |> TraditionalWorkflow.install_agent_status(:idle)
      |> SessionEventWorkflow.approval_pending(session, approval)
      |> TranscriptSyncDriver.settle()

    assert AgentState.display_status(TraditionalState.agent(state.shell_runtime.state)) ==
             :approval_waiting

    assert :ok = Session.respond_to_approval(session, approval.target, :approve)
    assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout

    for resolution <- [
          :approve,
          :approve_session,
          :approve_turn,
          :reject,
          :approval_timeout,
          :interrupted
        ] do
      resolved =
        SessionEventWorkflow.approval_resolved(state, session, approval.target, resolution)
        |> TranscriptSyncDriver.settle()

      agent = TraditionalState.agent(resolved.shell_runtime.state)
      assert agent.pending_approval == nil
      assert AgentState.display_status(agent) == :idle

      assert Minga.Test.TranscriptFixture.messages(resolved.workspace.agent_ui.panel.transcript) !=
               []

      assert RenderCorrelation.scheduled?(resolved.render.render_correlation)
      assert resolved.workspace.agent_ui.panel.prompt_buffer == prompt

      assert PromptBuffer.prompt_text(resolved.workspace.agent_ui) ==
               "unfinished draft\nkeep caret"

      assert Minga.Buffer.cursor(prompt) == {1, 3}
      assert resolved.workspace.agent_ui.panel.input_focused
    end
  end

  test "late resolution events preserve a newer request or a different source attachment" do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()]
      )

    first = admit_approval(session)
    assert :ok = Session.respond_to_approval(session, first.target, :approve)
    assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
    assert :ok = Session.abort(session)
    second = admit_approval(session)
    refute first.target.request_id == second.target.request_id

    agent_ui =
      UIState.new()
      |> PromptBuffer.ensure()
      |> PromptBuffer.set_prompt_text("new request draft\nkeep caret")
      |> UIState.set_input_focused(true)

    prompt = agent_ui.panel.prompt_buffer
    Minga.Buffer.move_to(prompt, {1, 3})

    state =
      event_state(session)
      |> TraditionalWorkflow.install_agent_ui(agent_ui)
      |> SessionEventWorkflow.approval_pending(session, second)
      |> TranscriptSyncDriver.settle()

    pending = TraditionalState.agent(state.shell_runtime.state).pending_approval

    for {source, target} <- [{session, first.target}, {idle_process(), second.target}],
        resolution <- [:approve, :approval_timeout, :interrupted] do
      updated = SessionEventWorkflow.approval_resolved(state, source, target, resolution)
      assert TraditionalState.agent(updated.shell_runtime.state).pending_approval == pending
      assert updated.workspace.agent_ui.panel.prompt_buffer == prompt

      assert PromptBuffer.prompt_text(updated.workspace.agent_ui) ==
               "new request draft\nkeep caret"

      assert Minga.Buffer.cursor(prompt) == {1, 3}
      assert updated.workspace.agent_ui.panel.input_focused
    end
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

    assert state.workspace.agent_ui.view.compaction.execution == {:deferred, 95}
    refute CompactionState.requested?(state.workspace.agent_ui.view.compaction)

    state = StatusEventWorkflow.status_changed(state, :idle)

    assert state.workspace.agent_ui.view.compaction.execution == :requested
    assert state.workspace.agent_ui.view.compaction.threshold == :triggered
    assert EffectScheduler.active?(effect_scheduler, Compaction)
  end

  test "idle deferred compaction ignores stale shell session after registration fallback" do
    ShellRegistry.seed_builtin()

    old_session =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(old_session, :stop) end)
    task_supervisor = start_supervised!({Task.Supervisor, []})

    effect_scheduler =
      start_supervised!({EffectScheduler, task_supervisor: task_supervisor})

    agent_ui =
      UIState.new()
      |> UIState.replace_compaction(%CompactionState{
        threshold: :warned,
        execution: {:deferred, 95}
      })

    stale_entry = Entry.builtin!(:stale_fake, FakeShell, "Stale fake", "Stale fake shell", false)

    state = %{
      event_state(nil, effect_scheduler)
      | workspace: %SessionState{agent_ui: agent_ui},
        shell_runtime: Runtime.new(stale_entry, %{session: old_session})
    }

    state = StatusEventWorkflow.status_changed(state, :idle)

    assert Runtime.active_session(state.shell_runtime) == nil
    assert state.workspace.agent_ui.view.compaction.execution == :idle
    assert state.workspace.agent_ui.view.compaction.threshold == :fresh
    refute EffectScheduler.active?(effect_scheduler, Compaction)
  end

  test "context warning toast is emitted once without scheduling compaction" do
    {:ok, session} = start_supervised({Session, provider_opts: []})
    task_supervisor = start_supervised!({Task.Supervisor, []})

    effect_scheduler =
      start_supervised!({EffectScheduler, task_supervisor: task_supervisor})

    state = event_state(session, effect_scheduler)
    state = StatusEventWorkflow.context_usage(state, 80, 100)

    assert state.workspace.agent_ui.view.compaction.threshold == :warned

    assert state.workspace.agent_ui.view.toast.message ==
             "Context at 80%. Run /compact to free space."

    refute EffectScheduler.active?(effect_scheduler, Compaction)

    state = StatusEventWorkflow.context_usage(state, 85, 100)

    assert state.workspace.agent_ui.view.compaction.threshold == :warned
    assert state.workspace.agent_ui.view.toast_queue == :queue.new()
    refute EffectScheduler.active?(effect_scheduler, Compaction)
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

  @spec admit_approval(pid()) :: PublicApproval.t()
  defp admit_approval(session) do
    assert :ok = Session.send_prompt(session, "approval turn")
    assert_receive {:continuation_request, request}, @event_timeout
    send_provider_event(session, %Event.AgentStart{})

    send_provider_event(session, %Event.ToolApproval{
      tool_call_id: "tc1",
      name: "shell",
      args: %{"command" => "pwd"},
      reply_to: self()
    })

    %{pending_approval: %PublicApproval{} = approval} = Session.editor_snapshot(session)
    assert approval.target.request_id == request.request_id
    assert approval.target.tool_call_id == "tc1"
    approval
  end

  @spec assert_agent_error_logged(integer()) :: :ok
  defp assert_agent_error_logged(deadline \\ System.monotonic_time(:millisecond) + 500) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:minga_event, :log_message, %Minga.Events.LogMessageEvent{text: text}} ->
        if String.contains?(text, "Agent: error") do
          :ok
        else
          assert_agent_error_logged(deadline)
        end
    after
      remaining -> flunk("Agent: error was not routed to the messages log")
    end
  end

  @tag :tmp_dir
  test "agent file events draft an editor-owned workspace and the idle turn offers publication",
       %{tmp_dir: dir} do
    {:ok, view} = MingaAgent.ProjectView.overlay(dir)
    state = owned_event_state(view)
    workspace_id = TabBar.active_workspace(Runtime.state(state.shell_runtime).tab_bar).id
    path = Path.join(dir, "notes.md")

    state = FileEventWorkflow.changed(state, file_change(path, "one\n", "TWO\n", "tc1"))
    review = TabBar.get_workspace(Runtime.state(state.shell_runtime).tab_bar, workspace_id).review
    assert review.state == :draft
    assert [%{relative_path: "notes.md"}] = review.changed_files

    busy = StatusEventWorkflow.display_status_changed(state, self(), :tool_executing)

    assert TabBar.get_workspace(Runtime.state(busy.shell_runtime).tab_bar, workspace_id).review.state ==
             :draft

    state = StatusEventWorkflow.display_status_changed(busy, self(), :idle)
    review = TabBar.get_workspace(Runtime.state(state.shell_runtime).tab_bar, workspace_id).review
    assert review.state == :needs_review

    assert %{title: "1 agent-edited file is not on disk"} =
             MingaEditor.UI.NotificationCenter.find(
               state.feedback.notifications,
               "agent:unpublished_edits:#{workspace_id}"
             )
  end

  @spec file_change(String.t(), String.t(), String.t(), String.t()) :: FileChange.t()
  defp file_change(path, before_content, after_content, tool_call_id) do
    %FileChange{
      path: path,
      before_content: before_content,
      after_content: after_content,
      tool_call_id: tool_call_id,
      tool_name: "edit"
    }
  end

  @spec select_review(EditorState.t(), String.t(), MingaAgent.ProjectView.t() | nil) ::
          EditorState.t()
  defp select_review(state, path, project_view \\ nil) do
    timeline = state.workspace.agent_ui.view.edit_timeline
    index = EditTimeline.entry_count(timeline, path) - 1
    {:ok, content} = EditTimeline.content_at(timeline, path, index)
    review = DiffReview.from_hunks(path, content, EditTimeline.cumulative_hunks(timeline, path))

    review =
      case project_view do
        nil ->
          review

        %MingaAgent.ProjectView{project_root: root} ->
          {:ok, source} =
            MingaAgent.ProjectView.resolve_source(project_view, Path.relative_to(path, root))

          session = start_subscribed_session()
          %{connection: %{target: target}} = Session.editor_snapshot(session)
          DiffReview.bind_source(review, source, target)
      end

    preview = Preview.set_diff(Preview.new(), review)

    TraditionalWorkflow.install_agent_ui(
      state,
      UIState.replace_preview(state.workspace.agent_ui, preview)
    )
  end

  @spec diff_review(EditorState.t()) :: DiffReview.t() | nil
  defp diff_review(state) do
    MingaEditor.Agent.View.Preview.diff_review(state.workspace.agent_ui.view.preview)
  end

  @spec event_state(pid() | nil, EffectScheduler.server() | nil) :: EditorState.t()
  defp event_state(session \\ nil, effect_scheduler \\ nil) do
    tab_bar = tab_bar(session)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: nil},
      workspace: %SessionState{agent_ui: UIState.new()},
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

  @spec owned_event_state(MingaAgent.ProjectView.t()) :: EditorState.t()
  defp owned_event_state(view) do
    state = event_state(self())
    shell = Runtime.state(state.shell_runtime)
    workspace = TabBar.active_workspace(shell.tab_bar)
    tabs = TabBar.set_workspace_project_view(shell.tab_bar, workspace.id, view)
    shell = TraditionalState.install_tab_bar(shell, tabs)
    %{state | shell_runtime: Runtime.new(Runtime.default_entry(), shell)}
  end

  @spec tab_bar(pid() | nil) :: TabBar.t()
  defp tab_bar(nil), do: TabBar.new(Tab.new_agent(1, "Agent"))

  defp tab_bar(session) do
    {tab_bar, workspace} =
      TabBar.add_workspace(TabBar.new(Tab.new_agent(1, "Agent")), "Agent", session)

    TabBar.move_tab_to_workspace(tab_bar, 1, workspace.id)
  end
end
