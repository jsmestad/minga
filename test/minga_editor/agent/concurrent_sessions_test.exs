defmodule MingaEditor.Agent.ConcurrentSessionsTest do
  @moduledoc """
  Verifies that two agent sessions can coexist in two tabs and that
  switching tabs while one session is mid-stream does not interrupt
  it or route its events to the wrong tab.

  These tests exercise per-workspace session ownership: workspaces are the source of truth, while legacy tab session fields remain only as locators for event routing and migration paths. The active Traditional runtime state holds rendering caches only.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Ingest
  alias Minga.Test.TranscriptFixture
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.Session
  alias MingaAgent.Session.Transcript, as: SourceTranscript
  alias MingaAgent.Session.Transcript.Cursor
  alias MingaAgent.ToolApproval
  alias MingaAgent.ToolApproval.Target
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Agent, as: TabAgent
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.State.ModalOverlay.Completion, as: ModalCompletion
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias Minga.Test.StubServer

  @transcript_sync [:minga, :agent, :transcript_sync]

  defp observe_sync do
    id = make_ref()
    test_pid = self()

    :ok =
      :telemetry.attach(
        id,
        @transcript_sync,
        &record_sync/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp record_sync(_event, measurements, metadata, observer) when self() == observer do
    send(observer, {:transcript_sync, metadata.outcome, measurements.entries_read})
    record_switch_calls(observer, metadata.outcome, measurements)
  end

  defp record_sync(_event, _measurements, _metadata, _observer), do: :ok

  defp record_switch_calls(observer, outcome, %{session_calls: calls}),
    do: send(observer, {:switch_calls, outcome, calls})

  defp record_switch_calls(_observer, _outcome, _measurements), do: :ok

  defp connect_arrivals(state, sessions) do
    ingest = start_supervised!({Ingest, editor: self()})
    Enum.each(sessions, fn session -> :ok = Session.subscribe(session, ingest) end)
    %{state | agent_connection: AgentConnection.connect_ingest(state.agent_connection, ingest)}
  end

  defp arrive(state, tab, session) do
    state = MingaEditor.TabWorkflow.switch(state, tab)

    assert_receive {:agent_event, ^session, {:editor_arrival_ready, _token, _capture}} = fence,
                   1000

    {:noreply, state} = MingaEditor.handle_info(fence, state)
    state
  end

  defp approval_for(session, request, call) do
    ToolApproval.new(name: "read_file", tool_call_id: call)
    |> ToolApproval.public(Target.new(session, request, call))
  end

  defp handle(state, msg) do
    {:noreply, updated} = MingaEditor.handle_info(msg, state)
    updated
  end

  defp tool_end(id, name) do
    %MingaAgent.Event.ToolEnd{tool_call_id: id, name: name, result: "done", outcome: :complete}
  end

  defp start_session(id) do
    start_supervised!(
      {Session, provider: Minga.Test.StubProvider, persist?: false, hooks_enabled?: false},
      id: id
    )
  end

  defp base_state(tabs, active_id) do
    tb = build_tab_bar(tabs, active_id)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{rendering: :disabled},
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        keymap_scope: :editor,
        agent_ui: UIState.new()
      },
      shell_runtime:
        Runtime.new(
          Registry.get(:traditional),
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Traditional.State.replace_agent(
              %MingaEditor.Shell.Traditional.State{},
              %AgentState{}
            ),
            tb
          )
        )
    }
  end

  defp build_tab_bar([first | rest], active_id) do
    tb = TabBar.new(first)

    tb =
      Enum.reduce(rest, tb, fn tab, acc ->
        %{acc | tabs: Enum.concat(acc.tabs, [tab]), next_id: max(acc.next_id, tab.id + 1)}
      end)

    tb
    |> attach_agent_workspaces()
    |> Map.put(:active_id, active_id)
  end

  defp attach_agent_workspaces(%TabBar{} = tb) do
    Enum.reduce(tb.tabs, tb, fn
      %Tab{kind: :agent, id: tab_id, label: label, payload: %TabAgent{session: session}}, acc
      when is_pid(session) ->
        {acc, workspace} = TabBar.add_workspace(acc, label, session)
        TabBar.move_tab_to_workspace(acc, tab_id, workspace.id)

      _tab, acc ->
        acc
    end)
  end

  defp agent_tab(id, label, session) do
    workspace = MingaEditor.State.Workspace.new_agent(id, label, session)

    id
    |> Tab.new_agent(label)
    |> Tab.project_agent_lifecycle(workspace)
  end

  defp agent_tab_context do
    rows = 24
    cols = 80
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, rows, cols)

    %{
      keymap_scope: :agent,
      buffers: %Buffers{active: nil, list: [], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => agent_window},
        active: win_id,
        next_id: win_id + 1
      },
      viewport: Viewport.new(rows, cols)
    }
  end

  describe "two concurrent sessions in two tabs" do
    test "Shell.Runtime.active_session/1 resolves to the active tab's session" do
      {:ok, session_a} = StubServer.start_link()
      {:ok, session_b} = StubServer.start_link()

      tabs = [
        agent_tab(1, "Agent A", session_a),
        agent_tab(2, "Agent B", session_b)
      ]

      state_a = base_state(tabs, 1)
      state_b = base_state(tabs, 2)

      assert MingaEditor.Shell.Runtime.active_session(state_a.shell_runtime) == session_a
      assert MingaEditor.Shell.Runtime.active_session(state_b.shell_runtime) == session_b
    end

    test "switching tabs leaves both session pids alive" do
      {:ok, session_a} = StubServer.start_link()
      {:ok, session_b} = StubServer.start_link()

      tabs = [
        agent_tab(1, "Agent A", session_a),
        agent_tab(2, "Agent B", session_b)
      ]

      state = base_state(tabs, 1)

      # Sanity: both sessions respond before the switch.
      assert GenServer.call(session_a, :status) == :idle
      assert GenServer.call(session_b, :status) == :idle
      assert MingaEditor.Shell.Runtime.active_session(state.shell_runtime) == session_a

      # Switching tabs only repoints the active_id; it does not stop or
      # restart either session process.
      switched =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              %{
                state.shell_runtime.state.tab_bar
                | active_id: 2
              }
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

      assert MingaEditor.Shell.Runtime.active_session(switched.shell_runtime) == session_b
      assert GenServer.call(session_a, :status) == :idle
      assert GenServer.call(session_b, :status) == :idle
    end

    test "two tabs with no session report nil regardless of which is active" do
      tabs = [Tab.new_agent(1, "Agent A"), Tab.new_agent(2, "Agent B")]

      assert MingaEditor.Shell.Runtime.active_session(base_state(tabs, 1).shell_runtime) == nil
      assert MingaEditor.Shell.Runtime.active_session(base_state(tabs, 2).shell_runtime) == nil
    end
  end

  describe "tab switch via switch_tab/2" do
    test "switch_tab leaves the outgoing session pid reachable on its tab" do
      # Note: per-tab event *routing* (so an event for the streaming
      # session lands on its tab's UI, not the active tab's) is
      # implemented in #1430. This test covers the lifecycle invariant
      # that #1428 owns: after switching away from a tab, its session
      # pid is still alive and still attached to the original tab.
      {:ok, streaming} = StubServer.start_link()
      {:ok, idle} = StubServer.start_link()

      tabs = [
        agent_tab(1, "Streaming", streaming),
        agent_tab(2, "Idle", idle)
      ]

      state = base_state(tabs, 1)
      assert MingaEditor.Shell.Runtime.active_session(state.shell_runtime) == streaming

      # Use the public switch_tab/2 aggregate transition so presentation state
      # refreshes from the target session as it does in production.
      switched = MingaEditor.TabWorkflow.switch(state, 2)

      # Tab 2's session is now in scope; tab 1's session is still alive
      # and still owned by tab 1.
      assert MingaEditor.Shell.Runtime.active_session(switched.shell_runtime) == idle
      assert GenServer.call(streaming, :status) == :idle

      tab_one = Enum.find(switched.shell_runtime.state.tab_bar.tabs, &(&1.id == 1))
      assert tab_one.payload.session == streaming

      # Switching back restores the streaming session as the active one.
      back = MingaEditor.TabWorkflow.switch(switched, 1)
      assert MingaEditor.Shell.Runtime.active_session(back.shell_runtime) == streaming
    end

    test "switch_tab repopulates the rendering cache from the incoming tab's session" do
      # The Traditional agent-surface presentation value is a rendering cache,
      # not the source of truth. After switch_tab/2, status/error/
      # pending_approval should reflect the *incoming* tab's session.
      {:ok, session_a} = StubServer.start_link()

      {:ok, session_b} =
        StubServer.start_link(status: :tool_executing, active_tool_name: "read_file")

      tabs = [
        agent_tab(1, "A", session_a),
        agent_tab(2, "B", session_b)
      ]

      state = base_state(tabs, 1)

      # Pre-stale the cache so we can prove the rebuild happened: set a
      # bogus error string. After switching tabs, rebuild_agent_from_session/2
      # should overwrite it from session_b's snapshot (StubServer returns
      # error: nil).
      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_state(
          state,
          (fn a ->
             %{a | error: "stale error from previous render"}
           end).(MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state))
        )

      switched = state |> connect_arrivals([session_b]) |> arrive(2, session_b)
      cache = MingaEditor.Shell.Traditional.State.agent(switched.shell_runtime.state)

      assert cache.error == nil
      assert cache.runtime.status == :tool_executing
      assert cache.runtime.active_tool_name == "read_file"
      assert cache.pending_approval == nil
    end

    test "an arrival timeout publishes the incoming conversation without live controls" do
      a =
        start_supervised!({StubServer, messages: [{:user, "outgoing conversation A"}]},
          id: :outgoing
        )

      b =
        start_supervised!({StubServer, messages: [{:user, "retained conversation B"}]}, id: :busy)

      pa = approval_for("session-a", "turn-a", "call-a")
      tabs = [agent_tab(1, "A", a), agent_tab(2, "B", b)]
      state = tabs |> base_state(1) |> connect_arrivals([a, b]) |> arrive(2, b) |> arrive(1, a)
      baseline = Minga.Test.AgentWorkflowDriver.chat_model(state)
      refute {1, {:user, "retained conversation B"}} in baseline.resident_messages

      state =
        AgentLifecycle.apply_session_snapshot(state, a, %{pending_approval: pa, error: "A only"})

      observe_sync()
      :ok = :sys.suspend(b)

      arrived =
        try do
          MingaEditor.TabWorkflow.switch(state, 2)
        after
          :ok = :sys.resume(b)
        end

      assert_receive {:switch_calls, :unavailable, 1}

      assert %{
               lifecycle: :unavailable,
               resident_messages: messages,
               transcript_epoch: epoch,
               pending_question: nil,
               stop_target: nil,
               queue_target: nil
             } = Minga.Test.AgentWorkflowDriver.chat_model(arrived)

      assert {1, {:user, "retained conversation B"}} in messages
      refute {1, {:user, "outgoing conversation A"}} in messages
      assert epoch != baseline.transcript_epoch

      assert %{pending_approval: nil, error: nil} =
               TraditionalState.agent(arrived.shell_runtime.state)

      assert TranscriptFixture.messages(arrived.workspace.agent_ui.panel.transcript) == [
               {:user, "retained conversation B"}
             ]

      assert_receive {_, %{status: :idle}} = snapshot_reply, 1000
      pending = handle(arrived, snapshot_reply)
      assert_receive {:agent_event, ^b, {:editor_arrival_ready, _, _}} = fence, 1000
      recovered = handle(pending, fence)

      assert_receive {:switch_calls, :unchanged, 2}

      assert %{lifecycle: :conversation, transcript_epoch: ^epoch, resident_messages: ^messages} =
               Minga.Test.AgentWorkflowDriver.chat_model(recovered)

      assert recovered.workspace.agent_ui.panel.transcript ===
               arrived.workspace.agent_ui.panel.transcript
    end

    test "a delayed Ingest capture releases the frame at the original deadline" do
      a = start_supervised!({StubServer, []}, id: :outgoing)
      approval = approval_for("session-b", "turn-b", "call-b")

      b =
        start_supervised!(
          {StubServer, pending_approval: approval, display_status: :approval_waiting},
          id: :incoming
        )

      state =
        [agent_tab(1, "A", a), agent_tab(2, "B", b)] |> base_state(1) |> connect_arrivals([a, b])

      observe_sync()
      pending = MingaEditor.TabWorkflow.switch(state, 2)
      assert_receive {:agent_event, ^b, {:editor_arrival_ready, token, _}} = capture, 1_000
      assert_receive {:agent_arrival_deadline, ^token} = deadline, 1_000

      waiting = handle(pending, deadline)
      assert_receive {:switch_calls, :unavailable, 2}
      assert %{lifecycle: :unavailable} = Minga.Test.AgentWorkflowDriver.chat_model(waiting)
      assert %{pending_approval: nil} = TraditionalState.agent(waiting.shell_runtime.state)

      recovered = handle(waiting, capture)
      assert %{lifecycle: :conversation} = Minga.Test.AgentWorkflowDriver.chat_model(recovered)

      assert %{pending_approval: %{approval: ^approval}} =
               TraditionalState.agent(recovered.shell_runtime.state)

      assert handle(recovered, deadline) === recovered
    end

    test "a late capture cannot update another tab or a later visit to the same tab" do
      a = start_supervised!({StubServer, []}, id: :outgoing)
      b = start_supervised!({StubServer, arrival_observer: self()}, id: :busy)
      p = approval_for("session-b", "turn-b", "call-p")
      q = approval_for("session-b", "turn-b", "call-q")

      state =
        [agent_tab(1, "A", a), agent_tab(2, "B", b)] |> base_state(1) |> connect_arrivals([a, b])

      observe_sync()
      first_visit = MingaEditor.TabWorkflow.switch(state, 2)
      assert_receive {:capture_requested, ^b, old_token}
      assert_receive {:switch_calls, :unavailable, 2}
      assert %{lifecycle: :unavailable} = Minga.Test.AgentWorkflowDriver.chat_model(first_visit)

      away = arrive(first_visit, 1, a)
      assert_receive {:switch_calls, :changed, 2}
      :ok = GenServer.call(b, {:release_capture, %{pending_approval: p, error: "old error"}, []})
      assert_receive {:agent_event, ^b, {:editor_arrival_ready, ^old_token, _}} = old, 1000
      assert handle(away, old) === away

      returning = MingaEditor.TabWorkflow.switch(away, 2)
      assert_receive {:capture_requested, ^b, new_token}
      refute new_token == old_token
      assert handle(returning, old) === returning

      pre_fence = [
        {:approval_pending, p},
        {:approval_resolved, p.target, :approve},
        {:approval_pending, q}
      ]

      snapshot = %{pending_approval: q, error: "current error", display_status: :approval_waiting}
      :ok = GenServer.call(b, {:release_capture, snapshot, pre_fence})

      for event <- pre_fence do
        assert_receive {:agent_event, ^b, ^event} = message, 1000

        assert %{pending_approval: nil, error: nil} =
                 TraditionalState.agent(handle(returning, message).shell_runtime.state)
      end

      assert_receive {:agent_event, ^b, {:editor_arrival_ready, ^new_token, _}} = current, 1000
      recovered = handle(returning, current)
      displayed = TraditionalState.agent(recovered.shell_runtime.state)
      assert displayed.pending_approval.approval == q
      assert displayed.error == "current error"
      assert_receive {:switch_calls, :changed, 2}
      retired = handle(recovered, {:agent_event, b, {:approval_resolved, q.target, :approve}})
      assert TraditionalState.agent(retired.shell_runtime.state).pending_approval == nil
    end

    test "shell preview keeps progress and completion while the arrival capture waits" do
      a = start_supervised!({StubServer, []}, id: :outgoing)
      b = start_supervised!({StubServer, arrival_observer: self()}, id: :busy)

      state =
        [agent_tab(1, "A", a), agent_tab(2, "B", b)]
        |> base_state(1)
        |> connect_arrivals([a, b])
        |> MingaEditor.TabWorkflow.switch(2)

      assert_receive {:capture_requested, ^b, token}
      start = {:tool_started, "shell-1", "shell", %{"command" => "printf local"}}
      output = {:tool_update, "shell-1", "shell", "working"}
      state = handle(state, {:agent_event, b, start})
      state = handle(state, {:agent_stream_batch, b, [output, {:text_delta, "already captured"}]})

      assert state.workspace.agent_ui.view.preview.content ==
               {:shell, "printf local", "working", :running}

      ended = %MingaAgent.Event.ToolEnd{
        tool_call_id: "shell-1",
        name: "shell",
        result: "complete",
        outcome: :complete
      }

      state = handle(state, {:agent_event, b, {:tool_ended, ended}})
      :ok = GenServer.call(b, {:release_capture, %{}, []})
      assert_receive {:agent_event, ^b, {:editor_arrival_ready, ^token, _}} = fence, 1000
      arrived = handle(state, fence)

      assert arrived.workspace.agent_ui.view.preview.content ==
               {:shell, "printf local", "complete", :done}
    end

    test "a turn that finishes in the background shows idle on return and the next turn counts from zero" do
      a = start_supervised!({StubServer, []}, id: :foreground)
      b = start_supervised!({StubServer, []}, id: :background)

      state =
        [agent_tab(1, "A", a), agent_tab(2, "B", b)]
        |> base_state(1)
        |> connect_arrivals([a, b])
        |> arrive(2, b)
        |> handle({:agent_event, b, {:status_changed, :thinking}})
        |> handle({:agent_event, b, {:tool_started, "read-1", "read_file", %{}}})

      assert %{active_action: "Running read_file", tool_count: 1} =
               state.workspace.agent_ui.view.activity

      returned =
        state
        |> arrive(1, a)
        |> handle({:agent_event, b, {:tool_ended, tool_end("read-1", "read_file")}})
        |> handle({:agent_event, b, {:status_changed, :idle}})
        |> arrive(2, b)

      assert %{active_action: "", started_at: nil, running_tools: running} =
               returned.workspace.agent_ui.view.activity

      assert running == %{}

      next = handle(returned, {:agent_event, b, {:status_changed, :thinking}})

      assert %{active_action: "Thinking", tool_count: 0} = next.workspace.agent_ui.view.activity
    end

    test "error recall stays with the volatile conversation after leaving a busy arrival" do
      a = start_supervised!({StubServer, []}, id: :outgoing)

      b =
        start_supervised!(
          {Session,
           provider: Minga.Test.SessionSlowMockProvider,
           provider_opts: [test_pid: self()],
           persist?: false,
           hooks_enabled?: false}
        )

      assert :ok = Session.send_prompt(b, "active turn")
      assert {:queued, :follow_up} = Session.queue_follow_up(b, "next turn")

      state =
        [agent_tab(1, "A", a), agent_tab(2, "B", b)]
        |> base_state(1)
        |> connect_arrivals([a, b])
        |> arrive(2, b)

      ui = MingaEditor.Agent.PromptBuffer.set_prompt_text(state.workspace.agent_ui, "draft B")
      state = MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)
      state = arrive(state, 1, a)
      assert :ok = :sys.suspend(b)

      away =
        try do
          state
          |> MingaEditor.TabWorkflow.switch(2)
          |> handle({:agent_event, b, {:error, "provider unavailable"}})
          |> arrive(1, a)
        after
          assert :ok = :sys.resume(b)
        end

      assert_receive {:volatile_queue_recalled, ^b, _, _, ["next turn"]} = recall, 1_000
      updated = handle(away, recall)
      assert MingaEditor.Agent.PromptBuffer.prompt_text(updated.workspace.agent_ui) == ""
      returned = arrive(updated, 2, b)

      assert MingaEditor.Agent.PromptBuffer.prompt_text(returned.workspace.agent_ui) ==
               "next turn\n\ndraft B"

      assert Session.get_queued_messages(b) == {[], []}
    end

    test "a manual authorization offer survives an arrival and its canonical capture" do
      a = start_supervised!({StubServer, []}, id: :outgoing)
      b = start_supervised!({StubServer, arrival_observer: self()}, id: :busy)

      state =
        [agent_tab(1, "A", a), agent_tab(2, "B", b)]
        |> base_state(1)
        |> connect_arrivals([a, b])
        |> MingaEditor.TabWorkflow.switch(2)

      assert_receive {:capture_requested, ^b, token}
      workspace = Runtime.active_tab(state.shell_runtime).group_id
      target = Session.ConnectionTarget.new(b, "record-b", nil, make_ref())
      operation = make_ref()

      connection = %Session.ConnectionSnapshot{
        target: target,
        conversation: make_ref(),
        credential_readiness: :unconfigured,
        model_selection: nil,
        provider_phase: :stopped,
        operation: {:connecting, operation},
        problem: nil
      }

      offer = %MingaAgent.OAuth.ManualReady{
        target: target,
        operation_ref: operation,
        worker: self(),
        flow_ref: make_ref(),
        url: "https://example.invalid/agent-authorization"
      }

      state = handle(state, {:agent_event, b, {:connection_changed, connection}})
      state = handle(state, {:agent_event, b, {:oauth_manual_requested, workspace, offer}})
      assert %{lifecycle: :unavailable} = Minga.Test.AgentWorkflowDriver.chat_model(state)

      assert %{authorization_url: url, target: ^target} =
               state.workspace.agent_ui.connection_prompt

      assert url == offer.url

      :ok = GenServer.call(b, {:release_capture, %{connection: connection}, []})
      assert_receive {:agent_event, ^b, {:editor_arrival_ready, ^token, _}} = fence, 1_000
      recovered = handle(state, fence)

      assert %{lifecycle: :conversation} = Minga.Test.AgentWorkflowDriver.chat_model(recovered)

      assert %{authorization_url: ^url, target: ^target} =
               recovered.workspace.agent_ui.connection_prompt
    end

    for count <- [100, 10_000] do
      test "local switch reads zero of #{count} unchanged entries and only changes made while away" do
        count = unquote(count)
        session_a = start_session(:session_a)
        session_b = start_session(:session_b)
        messages = for index <- 1..count, do: {:user, "B entry #{index}"}

        :sys.replace_state(session_b, fn source ->
          %{source | transcript: SourceTranscript.new(messages, DateTime.utc_now(), make_ref())}
        end)

        tabs = [agent_tab(1, "A", session_a), agent_tab(2, "B", session_b)]
        observe_sync()

        state =
          tabs
          |> base_state(1)
          |> connect_arrivals([session_a, session_b])
          |> arrive(2, session_b)

        assert_receive {:transcript_sync, :changed, ^count}
        retained = state.workspace.agent_ui.panel.transcript
        valid_cursor = retained.source_cursor
        assert valid_cursor != nil

        away = arrive(state, 1, session_a)
        assert_receive {:transcript_sync, :changed, _}

        back = arrive(away, 2, session_b)
        assert_receive {:transcript_sync, :unchanged, 0}
        assert back.workspace.agent_ui.panel.transcript === retained

        away = arrive(back, 1, session_a)
        assert_receive {:transcript_sync, :unchanged, 0}
        Session.add_system_message(session_b, "B received this while hidden")
        updated = arrive(away, 2, session_b)
        assert_receive {:transcript_sync, :changed, 1}
        assert updated.workspace.agent_ui.panel.transcript.source_cursor != valid_cursor

        assert {:system, "B received this while hidden", :info} in TranscriptFixture.messages(
                 updated.workspace.agent_ui.panel.transcript
               )
      end
    end

    test "metadata-only changes restyle from retained entries and strong source changes rebuild" do
      session = start_session(:primary)
      :ok = Session.send_prompt(session, "Only in the original conversation")
      observe_sync()

      state = base_state([agent_tab(1, "Agent", session)], 1)
      state = AgentLifecycle.sync_transcript(state)
      assert_receive {:transcript_sync, :changed, count}
      original = state.workspace.agent_ui.panel.transcript

      :sys.replace_state(session, fn source ->
        Map.update!(source, :transcript, &SourceTranscript.touch(&1, DateTime.utc_now()))
      end)

      theme = state.appearance.theme
      theme = %{theme | syntax: Map.put(theme.syntax, :test_theme_marker, true)}
      state = state |> EditorState.apply_theme(theme) |> AgentLifecycle.restyle_transcript()
      refute_received {:transcript_sync, _, _}
      state = AgentLifecycle.sync_transcript(state)
      assert_receive {:transcript_sync, :unchanged, 0}
      after_touch = state.workspace.agent_ui.panel.transcript
      assert after_touch.source_cursor != original.source_cursor
      assert after_touch.syntax == theme.syntax
      assert TranscriptFixture.messages(after_touch) == TranscriptFixture.messages(original)

      invalid = %Cursor{incarnation: nil, generation: 0, revision: 0}

      panel =
        Panel.install_transcript(
          state.workspace.agent_ui.panel,
          TranscriptProjection.advance_source_cursor(after_touch, invalid),
          :keep
        )

      state =
        state
        |> MingaEditor.Shell.Traditional.Workflow.install_agent_panel(panel)
        |> AgentLifecycle.sync_transcript()

      assert_receive {:transcript_sync, :reset, ^count}

      assert TranscriptFixture.messages(state.workspace.agent_ui.panel.transcript) ==
               TranscriptFixture.messages(original)

      :ok = Session.new_session(session)
      :ok = Session.send_prompt(session, "Only in the replacement conversation")
      replaced = AgentLifecycle.sync_transcript(state)
      assert_receive {:transcript_sync, :reset, _}
      messages = TranscriptFixture.messages(replaced.workspace.agent_ui.panel.transcript)
      assert {:user, "Only in the replacement conversation"} in messages
      refute {:user, "Only in the original conversation"} in messages

      :ok = stop_supervised(:primary)
      assert AgentLifecycle.sync_transcript(replaced) === replaced
      refute_received {:transcript_sync, _, _}
    end

    test "failed arriving snapshot never displays the outgoing Session's live state" do
      session_a = start_supervised!({StubServer, []})
      dead_session = spawn(fn -> :ok end)
      ref = Process.monitor(dead_session)
      assert_receive {:DOWN, ^ref, :process, ^dead_session, _}

      state =
        [agent_tab(1, "A", session_a), agent_tab(2, "B", dead_session)]
        |> base_state(1)
        |> connect_arrivals([session_a])

      observe_sync()
      target = Target.new("session-a", "request-a", "call-a")

      approval =
        ToolApproval.new(name: "read_file", tool_call_id: "call-a") |> ToolApproval.public(target)

      state =
        AgentLifecycle.apply_session_snapshot(state, session_a, %{
          status: :tool_executing,
          pending_approval: approval,
          error: "Only session A's error",
          active_tool_name: "read_file"
        })

      assert TraditionalState.agent(state.shell_runtime.state).pending_approval != nil
      arrived = MingaEditor.TabWorkflow.switch(state, 2)
      displayed = TraditionalState.agent(arrived.shell_runtime.state)

      assert AgentState.status(displayed) == :idle
      assert is_nil(displayed.pending_approval)
      assert is_nil(displayed.error)
      assert is_nil(displayed.runtime.active_tool_name)
      assert_receive {:switch_calls, :unavailable, 1}
      assert %{lifecycle: :unavailable} = Minga.Test.AgentWorkflowDriver.chat_model(arrived)
    end

    test "sync_transcript preserves cached transcript when the session dies before cleanup" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      stale_message = {:assistant, "keep visible until cleanup"}

      state =
        [agent_tab(1, "Agent", pid)]
        |> base_state(1)
        |> install_fixture(
          TranscriptFixture.projection([stale_message], message_ids: [{7, stale_message}])
        )

      preserved = AgentLifecycle.sync_transcript(state)
      projection = preserved.workspace.agent_ui.panel.transcript
      assert TranscriptProjection.line_at(projection, 0) == {7, stale_message, 0, :text}
      assert TranscriptProjection.visible_pair(projection, 7) == {7, stale_message}
    end

    test "an empty supplied remote transcript clears the prior display" do
      stale = TranscriptFixture.projection([{:assistant, "stale answer"}], display_start_index: 3)
      state = base_state([Tab.new_agent(1, "Agent")], 1) |> install_fixture(stale)
      cleared = AgentLifecycle.cache_messages(state, [])
      projection = cleared.workspace.agent_ui.panel.transcript

      assert TranscriptProjection.presentation(projection) == []
      assert projection.display_start == 0
    end

    test "an empty live remote attachment publishes setup guidance as credential readiness changes" do
      session = start_supervised!({StubServer, []})
      file = Tab.new_file(1, "main.ex")
      remote = agent_tab(2, "Remote", session)

      state = [file, remote] |> base_state(1) |> connect_arrivals([session]) |> arrive(2, session)
      panel = state.workspace.agent_ui.panel

      state =
        state
        |> MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          Panel.set_credential_readiness(panel, :checking)
        )
        |> AgentLifecycle.cache_messages([])

      assert %{lifecycle: :conversation, resident_messages: checking} =
               Minga.Test.AgentWorkflowDriver.chat_model(state)

      setup_prompt = "Checking agent credentials and model availability..."
      assert Enum.any?(checking, &match?({_, {:system, ^setup_prompt, :info}}, &1))

      panel =
        state.workspace.agent_ui.panel
        |> Panel.set_model_name("unknown")
        |> Panel.set_credential_readiness(:unconfigured)

      updated =
        state
        |> MingaEditor.Shell.Traditional.Workflow.install_agent_panel(panel)
        |> AgentLifecycle.restyle_transcript()

      assert %{resident_messages: guidance} = Minga.Test.AgentWorkflowDriver.chat_model(updated)
      assert Enum.any?(guidance, &match?({_, {:system, "Pick a model" <> _, :info}}, &1))
    end

    test "restyling a retained answer uses the new palette without reading the Session" do
      message = {:assistant, "plain answer"}
      session = start_supervised!({StubServer, messages: [message]})
      state = base_state([agent_tab(1, "Agent", session)], 1) |> AgentLifecycle.sync_transcript()
      theme = state.appearance.theme
      theme = %{theme | syntax: Map.put(theme.syntax, "variable", fg: 0x123456)}
      observe_sync()

      updated = state |> EditorState.apply_theme(theme) |> AgentLifecycle.restyle_transcript()

      assert [{1, ^message, {:markdown_blocks, [%{lines: [[{"plain answer", 0x123456, 0, 0}]]}]}}] =
               TranscriptProjection.presentation(updated.workspace.agent_ui.panel.transcript)

      refute_received {:transcript_sync, _, _}
    end

    test "an empty assistant message keeps its semantic spacer" do
      {:ok, session} = StubServer.start_link(messages: [{:assistant, ""}])
      state = base_state([agent_tab(1, "Agent", session)], 1)

      updated = AgentLifecycle.sync_transcript(state)

      assert [{1, {:assistant, ""}, {:markdown_blocks, [%{kind: :spacer}]}}] =
               TranscriptProjection.presentation(updated.workspace.agent_ui.panel.transcript)
    end

    test "tab workflow orders restored replay modal spinner and incoming session presentation" do
      {:ok, incoming_session} =
        StubServer.start_link(
          status: :tool_executing,
          active_tool_name: "read_file",
          messages: [{:user, "incoming question"}, {:assistant, "incoming answer"}]
        )

      stale_context_ui = bump_ui_message_version(UIState.new(), 42)

      tabs = [
        Tab.new_file(1, "main.ex"),
        agent_tab(2, "Incoming", incoming_session)
        |> Tab.set_context(agent_tab_context(stale_context_ui))
      ]

      state = base_state(tabs, 1)

      incoming_workspace =
        TabBar.find_workspace_by_session(state.shell_runtime.state.tab_bar, incoming_session)

      incoming_ui = bump_ui_message_version(UIState.new(), 7)
      catchup = [EventRecord.new("incoming", :message_changed, %{})]

      tab_bar =
        state.shell_runtime.state.tab_bar
        |> TabBar.set_workspace_agent_ui(incoming_workspace.id, incoming_ui)
        |> TabBar.set_workspace_pending_catchup_events(incoming_workspace.id, catchup)

      outgoing_ui = bump_ui_message_version(UIState.new(), 100)

      outgoing_agent =
        %AgentState{}
        |> AgentState.set_status(:thinking)
        |> AgentState.start_spinner_timer()

      outgoing_spinner = outgoing_agent.spinner_timer

      shell_state =
        state.shell_runtime.state
        |> TraditionalState.install_tab_bar(tab_bar)
        |> TraditionalState.open_modal({:completion, ModalCompletion.new(1)})
        |> TraditionalState.replace_agent(outgoing_agent)

      state = %{
        state
        | workspace: MingaEditor.Session.State.set_agent_ui(state.workspace, outgoing_ui),
          shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
      }

      switched = state |> connect_arrivals([incoming_session]) |> arrive(2, incoming_session)
      agent = TraditionalState.agent(switched.shell_runtime.state)
      drained = TabBar.get_workspace(switched.shell_runtime.state.tab_bar, incoming_workspace.id)

      assert switched.workspace.agent_ui.panel.transcript.version > 7
      assert switched.workspace.agent_ui.panel.transcript.version < 100
      assert switched.workspace.agent_ui.panel.transcript.version != 42
      assert %WorkspaceAgent{agent_ui: nil, pending_catchup_events: []} = drained.payload

      assert TraditionalState.modal(switched.shell_runtime.state) == :none
      assert agent.spinner_timer != nil
      assert agent.spinner_timer != outgoing_spinner
      assert AgentState.status(agent) == :tool_executing
      assert agent.runtime.active_tool_name == "read_file"

      assert TranscriptFixture.messages(switched.workspace.agent_ui.panel.transcript) == [
               {:user, "incoming question"},
               {:assistant, "incoming answer"}
             ]

      _cleaned =
        MingaEditor.Shell.Traditional.Workflow.install_agent_spinner_stop(switched)

      drain_spinner_ticks()
      refute_receive :agent_spinner_tick, 150

      switched_away = MingaEditor.TabWorkflow.switch(switched, 1)

      stashed =
        TabBar.get_workspace(switched_away.shell_runtime.state.tab_bar, incoming_workspace.id)

      assert stashed.payload.agent_ui.panel.transcript.version ==
               switched.workspace.agent_ui.panel.transcript.version
    end

    test "switch_tab rebuilds a background agent tab's semantic transcript cache" do
      {:ok, background_session} =
        StubServer.start_link(
          messages: [
            {:user, "inspect background session"},
            {:assistant, "unique background answer"}
          ]
        )

      tabs = [
        Tab.new_file(1, "main.ex"),
        agent_tab(2, "Background", background_session)
        |> Tab.set_context(agent_tab_context())
      ]

      state =
        tabs
        |> base_state(1)
        |> install_fixture(TranscriptFixture.projection([{:assistant, "stale answer"}]))

      switched = state |> connect_arrivals([background_session]) |> arrive(2, background_session)

      active_window =
        Map.fetch!(switched.workspace.windows.map, switched.workspace.windows.active)

      assert MingaEditor.Shell.Runtime.active_session(switched.shell_runtime) ==
               background_session

      assert {:agent_chat, :semantic} = active_window.content

      assert TranscriptFixture.messages(switched.workspace.agent_ui.panel.transcript) == [
               {:user, "inspect background session"},
               {:assistant, "unique background answer"}
             ]

      assert %{visible?: true, lifecycle: :conversation, prompt: ""} =
               Minga.Test.AgentWorkflowDriver.chat_model(switched)
    end
  end

  defp install_fixture(state, projection) do
    panel = Panel.install_transcript(state.workspace.agent_ui.panel, projection, :keep)
    MingaEditor.Shell.Traditional.Workflow.install_agent_panel(state, panel)
  end

  @spec drain_spinner_ticks() :: :ok
  defp drain_spinner_ticks do
    receive do
      :agent_spinner_tick -> drain_spinner_ticks()
    after
      0 -> :ok
    end
  end

  @spec bump_ui_message_version(UIState.t(), non_neg_integer()) :: UIState.t()
  defp bump_ui_message_version(%UIState{} = ui, count) do
    panel =
      Enum.reduce(1..count//1, ui.panel, fn _step, panel -> Panel.bump_message_version(panel) end)

    UIState.replace_panel(ui, panel)
  end

  defp agent_tab_context(%UIState{} = agent_ui) do
    agent_tab_context()
    |> Map.put(:present_fields, [:keymap_scope, :buffers, :windows, :agent_ui])
    |> Map.put(:agent_ui, agent_ui)
  end
end
