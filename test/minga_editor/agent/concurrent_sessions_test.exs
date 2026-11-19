defmodule MingaEditor.Agent.ConcurrentSessionsTest do
  @moduledoc """
  Verifies that two agent sessions can coexist in two tabs and that
  switching tabs while one session is mid-stream does not interrupt
  it or route its events to the wrong tab.

  These tests exercise per-workspace session ownership: workspaces are the source of truth, while legacy tab session fields remain only as locators for event routing and migration paths. The active Traditional runtime state holds rendering caches only.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Transcript
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
        fn _event, measurements, metadata, observer ->
          if self() == observer,
            do: send(observer, {:transcript_sync, metadata.outcome, measurements.entries_read})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(id) end)
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

      switched = MingaEditor.TabWorkflow.switch(state, 2)
      cache = MingaEditor.Shell.Traditional.State.agent(switched.shell_runtime.state)

      assert cache.error == nil
      assert cache.runtime.status == :tool_executing
      assert cache.runtime.active_tool_name == "read_file"
      assert cache.pending_approval == nil
    end

    for count <- [100, 10_000] do
      test "local switch reads zero of #{count} unchanged entries and one consistent snapshot on change" do
        count = unquote(count)
        session_a = start_session(:session_a)
        session_b = start_session(:session_b)
        messages = for index <- 1..count, do: {:user, "B entry #{index}"}

        :sys.replace_state(session_b, fn source ->
          %{source | transcript: SourceTranscript.new(messages, DateTime.utc_now(), make_ref())}
        end)

        tabs = [agent_tab(1, "A", session_a), agent_tab(2, "B", session_b)]
        observe_sync()
        state = base_state(tabs, 1) |> MingaEditor.TabWorkflow.switch(2)
        assert_receive {:transcript_sync, :changed, ^count}
        retained = state.workspace.agent_ui.panel.transcript
        valid_cursor = retained.source_cursor
        assert valid_cursor != nil

        away = MingaEditor.TabWorkflow.switch(state, 1)
        assert_receive {:transcript_sync, :changed, _}

        back = MingaEditor.TabWorkflow.switch(away, 2)
        assert_receive {:transcript_sync, :unchanged, 0}
        assert back.workspace.agent_ui.panel.transcript === retained

        away = MingaEditor.TabWorkflow.switch(back, 1)
        assert_receive {:transcript_sync, :unchanged, 0}
        Session.add_system_message(session_b, "B received this while hidden")
        updated = MingaEditor.TabWorkflow.switch(away, 2)
        entries_read = count + 2
        assert_receive {:transcript_sync, :changed, ^entries_read}
        assert updated.workspace.agent_ui.panel.transcript.source_cursor != valid_cursor

        assert {:system, "B received this while hidden", :info} in updated.workspace.agent_ui.panel.transcript.messages
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
      state = state |> EditorState.apply_theme(theme) |> AgentLifecycle.sync_transcript()
      assert_receive {:transcript_sync, :unchanged, 0}
      after_touch = state.workspace.agent_ui.panel.transcript
      assert after_touch.source_cursor != original.source_cursor
      assert after_touch.styled_fingerprint != original.styled_fingerprint
      assert after_touch.messages == original.messages

      invalid = %Cursor{incarnation: nil, generation: 0, revision: 0}

      panel =
        Panel.cache_transcript_display(
          state.workspace.agent_ui.panel,
          Transcript.display([]),
          [],
          source_cursor: invalid
        )

      state =
        state
        |> MingaEditor.Shell.Traditional.Workflow.install_agent_panel(panel)
        |> AgentLifecycle.sync_transcript()

      assert_receive {:transcript_sync, :reset, ^count}
      assert state.workspace.agent_ui.panel.transcript.messages == original.messages

      :ok = Session.new_session(session)
      :ok = Session.send_prompt(session, "Only in the replacement conversation")
      replaced = AgentLifecycle.sync_transcript(state)
      assert_receive {:transcript_sync, :reset, _}
      messages = replaced.workspace.agent_ui.panel.transcript.messages
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

      state = base_state([agent_tab(1, "A", session_a), agent_tab(2, "B", dead_session)], 1)
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
    end

    test "sync_transcript preserves cached transcript when the session dies before cleanup" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      stale_message = {:assistant, "keep visible until cleanup"}

      state =
        [agent_tab(1, "Agent", pid)]
        |> base_state(1)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               display = Transcript.display([stale_message], message_ids: [{7, stale_message}])

               Panel.cache_transcript_display(panel, display, [nil],
                 styled_fingerprint: TranscriptProjection.styled_cache_fingerprint(%{})
               )
             end).(state.workspace.agent_ui.panel)
          )
        end)

      preserved = AgentLifecycle.sync_transcript(state)
      panel = preserved.workspace.agent_ui.panel

      assert panel.transcript.line_index == [{0, :text}]
      assert panel.transcript.messages == [stale_message]
      assert panel.transcript.message_pairs == [{7, stale_message}]
      assert panel.transcript.styled == [nil]
    end

    test "cache_messages clears stale semantic transcript cache when the session has no messages" do
      stale_state =
        base_state([Tab.new_agent(1, "Agent")], 1)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               display =
                 Transcript.display([{:assistant, "stale answer"}],
                   display_start_index: 3,
                   message_ids: [{7, {:assistant, "stale answer"}}]
                 )

               Panel.cache_transcript_display(panel, display, [[[{"stale", 0, 0, 0}]]],
                 provenance_jump: MingaEditor.Agent.ProvenanceJump.request(7),
                 styled_fingerprint: TranscriptProjection.styled_cache_fingerprint(%{})
               )
             end).(state.workspace.agent_ui.panel)
          )
        end)

      cleared = AgentLifecycle.cache_messages(stale_state, [])
      panel = cleared.workspace.agent_ui.panel

      assert panel.transcript.line_index == []
      assert panel.transcript.messages == []
      assert panel.transcript.message_pairs == []
      assert panel.transcript.styled == nil
      assert panel.transcript.display_start == 0
      assert panel.transcript.provenance_jump == nil
    end

    test "update_styled_cache reuses unchanged displayed message styles" do
      message = {:assistant, "unchanged answer"}
      cached = [[{"cached styled answer", 0x98BE65, 0x21242B, 0x10}]]

      {:ok, session} = StubServer.start_link(messages: [message])

      state =
        [agent_tab(1, "Agent", session)]
        |> base_state(1)

      fingerprint = TranscriptProjection.styled_cache_fingerprint(state.appearance.theme.syntax)

      state =
        state
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               display = Transcript.display([message])

               Panel.cache_transcript_display(panel, display, cached,
                 styled_fingerprint: fingerprint
               )
             end).(state.workspace.agent_ui.panel)
          )
        end)

      updated = AgentLifecycle.update_styled_cache(state)

      assert updated.workspace.agent_ui.panel.transcript.styled == cached
    end

    test "update_styled_cache invalidates stale styles when the theme syntax changes" do
      message = {:assistant, "plain answer"}
      cached = [[{"plain answer", 0xBBC2CF, 0, 0}]]

      {:ok, session} = StubServer.start_link(messages: [message])

      state =
        [agent_tab(1, "Agent", session)]
        |> base_state(1)

      old_theme = state.appearance.theme
      new_theme = %{old_theme | syntax: Map.put(old_theme.syntax, "variable", fg: 0x123456)}
      fingerprint = TranscriptProjection.styled_cache_fingerprint(old_theme.syntax)

      state =
        state
        |> EditorState.apply_theme(new_theme)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               display = Transcript.display([message])

               Panel.cache_transcript_display(panel, display, cached,
                 styled_fingerprint: fingerprint
               )
             end).(state.workspace.agent_ui.panel)
          )
        end)

      updated = AgentLifecycle.update_styled_cache(state)

      assert [%{styled_lines: [[{"plain answer", fg, 0, 0}]], markdown_blocks: [block]}] =
               updated.workspace.agent_ui.panel.transcript.styled

      assert fg == 0x123456
      assert [[{"plain answer", ^fg, 0, 0}]] = block.lines
    end

    test "update_styled_cache restyles unchanged displayed messages when style cache is missing" do
      message = {:assistant, "unchanged answer"}

      {:ok, session} = StubServer.start_link(messages: [message])

      state =
        [agent_tab(1, "Agent", session)]
        |> base_state(1)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               Panel.cache_transcript_display(panel, Transcript.display([message]), nil)
             end).(state.workspace.agent_ui.panel)
          )
        end)

      updated = AgentLifecycle.update_styled_cache(state)

      assert [%{styled_lines: [[{"unchanged answer", _fg, 0, 0}]], markdown_blocks: [block]}] =
               updated.workspace.agent_ui.panel.transcript.styled

      assert block.kind == :paragraph
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

      switched = MingaEditor.TabWorkflow.switch(state, 2)
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

      assert switched.workspace.agent_ui.panel.transcript.messages == [
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
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               Panel.cache_transcript_display(
                 panel,
                 Transcript.display([{:assistant, "stale answer"}]),
                 nil
               )
             end).(state.workspace.agent_ui.panel)
          )
        end)

      switched = MingaEditor.TabWorkflow.switch(state, 2)

      active_window =
        Map.fetch!(switched.workspace.windows.map, switched.workspace.windows.active)

      assert MingaEditor.Shell.Runtime.active_session(switched.shell_runtime) ==
               background_session

      assert {:agent_chat, :semantic} = active_window.content

      assert switched.workspace.agent_ui.panel.transcript.messages == [
               {:user, "inspect background session"},
               {:assistant, "unique background answer"}
             ]
    end
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
