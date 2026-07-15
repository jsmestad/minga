defmodule MingaEditor.Agent.ConcurrentSessionsTest do
  @moduledoc """
  Verifies that two agent sessions can coexist in two tabs and that
  switching tabs while one session is mid-stream does not interrupt
  it or route its events to the wrong tab.

  These tests exercise per-workspace session ownership: workspaces are the source of truth, while legacy tab session fields remain only as locators for event routing and migration paths. The active Traditional runtime state holds rendering caches only.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaAgent.EventLog.EventRecord
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.ModalOverlay.Completion, as: ModalCompletion
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias Minga.Test.StubServer

  defp base_state(tabs, active_id) do
    tb = build_tab_bar(tabs, active_id)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{rendering: :disabled},
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
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
      %Tab{kind: :agent, id: tab_id, label: label, session: session}, acc when is_pid(session) ->
        {acc, workspace} = TabBar.add_workspace(acc, label, session)
        TabBar.move_tab_to_workspace(acc, tab_id, workspace.id)

      _tab, acc ->
        acc
    end)
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
        Tab.new_agent(1, "Agent A") |> Tab.set_session(session_a),
        Tab.new_agent(2, "Agent B") |> Tab.set_session(session_b)
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
        Tab.new_agent(1, "Agent A") |> Tab.set_session(session_a),
        Tab.new_agent(2, "Agent B") |> Tab.set_session(session_b)
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
        Tab.new_agent(1, "Streaming") |> Tab.set_session(streaming),
        Tab.new_agent(2, "Idle") |> Tab.set_session(idle)
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
      assert tab_one.session == streaming

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
        Tab.new_agent(1, "A") |> Tab.set_session(session_a),
        Tab.new_agent(2, "B") |> Tab.set_session(session_b)
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

    test "failed session snapshot clears stale active tool name" do
      dead_session = spawn(fn -> :ok end)
      ref = Process.monitor(dead_session)
      assert_receive {:DOWN, ^ref, :process, ^dead_session, _reason}

      tab = Tab.new_agent(1, "A") |> Tab.set_session(dead_session)

      state =
        [tab]
        |> base_state(1)
        |> then(fn state ->
          agent =
            state.shell_runtime.state
            |> MingaEditor.Shell.Traditional.State.agent()
            |> AgentState.set_status(:tool_executing)
            |> AgentState.set_active_tool_name("stale_tool")

          MingaEditor.Shell.Traditional.Workflow.install_agent_state(state, agent)
        end)

      rebuilt = MingaEditor.AgentLifecycle.rebuild_agent_from_session(state, tab)

      assert MingaEditor.Shell.Traditional.State.agent(rebuilt.shell_runtime.state).runtime.active_tool_name ==
               nil
    end

    test "sync_transcript preserves cached transcript when the session dies before cleanup" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      stale_message = {:assistant, "keep visible until cleanup"}

      state =
        [Tab.new_agent(1, "Agent") |> Tab.set_session(pid)]
        |> base_state(1)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               %{
                 panel
                 | cached_line_index: [{0, :text}],
                   cached_display_messages: [stale_message],
                   cached_display_message_pairs: [{7, stale_message}],
                   cached_styled_messages: [nil]
               }
             end).(state.workspace.agent_ui.panel)
          )
        end)

      preserved = AgentLifecycle.sync_transcript(state)
      panel = preserved.workspace.agent_ui.panel

      assert panel.cached_line_index == [{0, :text}]
      assert panel.cached_display_messages == [stale_message]
      assert panel.cached_display_message_pairs == [{7, stale_message}]
      assert panel.cached_styled_messages == [nil]
    end

    test "cache_messages clears stale semantic transcript cache when the session has no messages" do
      stale_state =
        base_state([Tab.new_agent(1, "Agent")], 1)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               %{
                 panel
                 | cached_line_index: [{0, :text}],
                   cached_display_messages: [{:assistant, "stale answer"}],
                   cached_display_message_pairs: [{7, {:assistant, "stale answer"}}],
                   cached_styled_messages: [[[{"stale", 0, 0, 0}]]],
                   display_start_index: 3,
                   provenance_jump: MingaEditor.Agent.ProvenanceJump.request(7)
               }
             end).(state.workspace.agent_ui.panel)
          )
        end)

      cleared = AgentLifecycle.cache_messages(stale_state, [])
      panel = cleared.workspace.agent_ui.panel

      assert panel.cached_line_index == []
      assert panel.cached_display_messages == []
      assert panel.cached_display_message_pairs == []
      assert panel.cached_styled_messages == nil
      assert panel.display_start_index == 0
      assert panel.provenance_jump == nil
    end

    test "update_styled_cache reuses unchanged displayed message styles" do
      message = {:assistant, "unchanged answer"}
      cached = [[{"cached styled answer", 0x98BE65, 0x21242B, 0x10}]]

      {:ok, session} = StubServer.start_link(messages: [message])

      state =
        [Tab.new_agent(1, "Agent") |> Tab.set_session(session)]
        |> base_state(1)

      fingerprint = Panel.styled_cache_fingerprint(state.appearance.theme.syntax)

      state =
        state
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               %{
                 panel
                 | cached_display_messages: [message],
                   cached_styled_messages: cached,
                   cached_styled_fingerprint: fingerprint
               }
             end).(state.workspace.agent_ui.panel)
          )
        end)

      updated = AgentLifecycle.update_styled_cache(state)

      assert updated.workspace.agent_ui.panel.cached_styled_messages == cached
    end

    test "update_styled_cache invalidates stale styles when the theme syntax changes" do
      message = {:assistant, "plain answer"}
      cached = [[{"plain answer", 0xBBC2CF, 0, 0}]]

      {:ok, session} = StubServer.start_link(messages: [message])

      state =
        [Tab.new_agent(1, "Agent") |> Tab.set_session(session)]
        |> base_state(1)

      old_theme = state.appearance.theme
      new_theme = %{old_theme | syntax: Map.put(old_theme.syntax, "variable", fg: 0x123456)}
      fingerprint = Panel.styled_cache_fingerprint(old_theme.syntax)

      state =
        state
        |> EditorState.apply_theme(new_theme)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               %{
                 panel
                 | cached_display_messages: [message],
                   cached_styled_messages: cached,
                   cached_styled_fingerprint: fingerprint
               }
             end).(state.workspace.agent_ui.panel)
          )
        end)

      updated = AgentLifecycle.update_styled_cache(state)

      assert [%{styled_lines: [[{"plain answer", fg, 0, 0}]], markdown_blocks: [block]}] =
               updated.workspace.agent_ui.panel.cached_styled_messages

      assert fg == 0x123456
      assert [[{"plain answer", ^fg, 0, 0}]] = block.lines
    end

    test "update_styled_cache restyles unchanged displayed messages when style cache is missing" do
      message = {:assistant, "unchanged answer"}

      {:ok, session} = StubServer.start_link(messages: [message])

      state =
        [Tab.new_agent(1, "Agent") |> Tab.set_session(session)]
        |> base_state(1)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               %{
                 panel
                 | cached_display_messages: [message],
                   cached_styled_messages: nil
               }
             end).(state.workspace.agent_ui.panel)
          )
        end)

      updated = AgentLifecycle.update_styled_cache(state)

      assert [%{styled_lines: [[{"unchanged answer", _fg, 0, 0}]], markdown_blocks: [block]}] =
               updated.workspace.agent_ui.panel.cached_styled_messages

      assert block.kind == :paragraph
    end

    test "tab workflow orders restored replay modal spinner and incoming session presentation" do
      {:ok, incoming_session} =
        StubServer.start_link(
          status: :tool_executing,
          active_tool_name: "read_file",
          messages: [{:user, "incoming question"}, {:assistant, "incoming answer"}]
        )

      tabs = [
        Tab.new_file(1, "main.ex"),
        Tab.new_agent(2, "Incoming")
        |> Tab.set_session(incoming_session)
        |> Tab.set_context(agent_tab_context())
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

      assert switched.workspace.agent_ui.panel.message_version > 7
      assert switched.workspace.agent_ui.panel.message_version < 100
      assert drained.pending_catchup_events == []
      assert TraditionalState.modal(switched.shell_runtime.state) == :none
      assert agent.spinner_timer != nil
      assert agent.spinner_timer != outgoing_spinner
      assert AgentState.status(agent) == :tool_executing
      assert agent.runtime.active_tool_name == "read_file"

      assert switched.workspace.agent_ui.panel.cached_display_messages == [
               {:user, "incoming question"},
               {:assistant, "incoming answer"}
             ]

      _cleaned =
        MingaEditor.Shell.Traditional.Workflow.install_agent_spinner_stop(switched)

      drain_spinner_ticks()
      refute_receive :agent_spinner_tick, 150
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
        Tab.new_agent(2, "Background")
        |> Tab.set_session(background_session)
        |> Tab.set_context(agent_tab_context())
      ]

      state =
        tabs
        |> base_state(1)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
            state,
            (fn panel ->
               %{panel | cached_display_messages: [{:assistant, "stale answer"}]}
             end).(state.workspace.agent_ui.panel)
          )
        end)

      switched = MingaEditor.TabWorkflow.switch(state, 2)

      active_window =
        Map.fetch!(switched.workspace.windows.map, switched.workspace.windows.active)

      assert MingaEditor.Shell.Runtime.active_session(switched.shell_runtime) ==
               background_session

      assert {:agent_chat, :semantic} = active_window.content

      assert switched.workspace.agent_ui.panel.cached_display_messages == [
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
end
