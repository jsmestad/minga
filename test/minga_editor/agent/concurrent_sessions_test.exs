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
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias Minga.Test.StubServer

  defp base_state(tabs, active_id) do
    tb = build_tab_bar(tabs, active_id)

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :editor,
        agent_ui: UIState.new()
      },
      shell_runtime:
        Runtime.new(
          Registry.get(:traditional),
          MingaEditor.Shell.Traditional.State.set_tab_bar(
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
    test "AgentAccess.session/1 resolves to the active tab's session" do
      {:ok, session_a} = StubServer.start_link()
      {:ok, session_b} = StubServer.start_link()

      tabs = [
        Tab.new_agent(1, "Agent A") |> Tab.set_session(session_a),
        Tab.new_agent(2, "Agent B") |> Tab.set_session(session_b)
      ]

      state_a = base_state(tabs, 1)
      state_b = base_state(tabs, 2)

      assert AgentAccess.session(state_a) == session_a
      assert AgentAccess.session(state_b) == session_b
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
      assert AgentAccess.session(state) == session_a

      # Switching tabs only repoints the active_id; it does not stop or
      # restart either session process.
      switched =
        EditorState.set_tab_bar(state, %{state.shell_runtime.state.tab_bar | active_id: 2})

      assert AgentAccess.session(switched) == session_b
      assert GenServer.call(session_a, :status) == :idle
      assert GenServer.call(session_b, :status) == :idle
    end

    test "two tabs with no session report nil regardless of which is active" do
      tabs = [Tab.new_agent(1, "Agent A"), Tab.new_agent(2, "Agent B")]

      assert AgentAccess.session(base_state(tabs, 1)) == nil
      assert AgentAccess.session(base_state(tabs, 2)) == nil
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
      assert AgentAccess.session(state) == streaming

      # Use the public switch_tab/2 path so the :rebuild_agent_session
      # effect runs; that's how the Editor switches tabs in production.
      switched = EditorState.switch_tab(state, 2)

      # Tab 2's session is now in scope; tab 1's session is still alive
      # and still owned by tab 1.
      assert AgentAccess.session(switched) == idle
      assert GenServer.call(streaming, :status) == :idle

      tab_one = Enum.find(switched.shell_runtime.state.tab_bar.tabs, &(&1.id == 1))
      assert tab_one.session == streaming

      # Switching back restores the streaming session as the active one.
      back = EditorState.switch_tab(switched, 1)
      assert AgentAccess.session(back) == streaming
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
        AgentAccess.update_agent(state, fn a ->
          %{a | error: "stale error from previous render"}
        end)

      switched = EditorState.switch_tab(state, 2)
      cache = AgentAccess.agent(switched)

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
        |> AgentAccess.update_agent(fn agent ->
          agent
          |> AgentState.set_status(:tool_executing)
          |> AgentState.set_active_tool_name("stale_tool")
        end)

      rebuilt = EditorState.rebuild_agent_from_session(state, tab)

      assert AgentAccess.agent(rebuilt).runtime.active_tool_name == nil
    end

    test "sync_transcript preserves cached transcript when the session dies before cleanup" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      stale_message = {:assistant, "keep visible until cleanup"}

      state =
        [Tab.new_agent(1, "Agent") |> Tab.set_session(pid)]
        |> base_state(1)
        |> AgentAccess.update_panel(fn panel ->
          %{
            panel
            | cached_line_index: [{0, :text}],
              cached_display_messages: [stale_message],
              cached_display_message_pairs: [{7, stale_message}],
              cached_styled_messages: [nil]
          }
        end)

      preserved = AgentLifecycle.sync_transcript(state)
      panel = AgentAccess.panel(preserved)

      assert panel.cached_line_index == [{0, :text}]
      assert panel.cached_display_messages == [stale_message]
      assert panel.cached_display_message_pairs == [{7, stale_message}]
      assert panel.cached_styled_messages == [nil]
    end

    test "cache_messages clears stale semantic transcript cache when the session has no messages" do
      stale_state =
        base_state([Tab.new_agent(1, "Agent")], 1)
        |> AgentAccess.update_panel(fn panel ->
          %{
            panel
            | cached_line_index: [{0, :text}],
              cached_display_messages: [{:assistant, "stale answer"}],
              cached_display_message_pairs: [{7, {:assistant, "stale answer"}}],
              cached_styled_messages: [[[{"stale", 0, 0, 0}]]],
              display_start_index: 3,
              provenance_jump: MingaEditor.Agent.ProvenanceJump.request(7)
          }
        end)

      cleared = AgentLifecycle.cache_messages(stale_state, [])
      panel = AgentAccess.panel(cleared)

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

      fingerprint = Panel.styled_cache_fingerprint(state.theme.syntax)

      state =
        state
        |> AgentAccess.update_panel(fn panel ->
          %{
            panel
            | cached_display_messages: [message],
              cached_styled_messages: cached,
              cached_styled_fingerprint: fingerprint
          }
        end)

      updated = AgentLifecycle.update_styled_cache(state)

      assert AgentAccess.panel(updated).cached_styled_messages == cached
    end

    test "update_styled_cache invalidates stale styles when the theme syntax changes" do
      message = {:assistant, "plain answer"}
      cached = [[{"plain answer", 0xBBC2CF, 0, 0}]]

      {:ok, session} = StubServer.start_link(messages: [message])

      state =
        [Tab.new_agent(1, "Agent") |> Tab.set_session(session)]
        |> base_state(1)

      old_theme = state.theme
      new_theme = %{old_theme | syntax: Map.put(old_theme.syntax, "variable", fg: 0x123456)}
      fingerprint = Panel.styled_cache_fingerprint(old_theme.syntax)

      state =
        state
        |> Map.put(:theme, new_theme)
        |> AgentAccess.update_panel(fn panel ->
          %{
            panel
            | cached_display_messages: [message],
              cached_styled_messages: cached,
              cached_styled_fingerprint: fingerprint
          }
        end)

      updated = AgentLifecycle.update_styled_cache(state)

      assert [%{styled_lines: [[{"plain answer", fg, 0, 0}]], markdown_blocks: [block]}] =
               AgentAccess.panel(updated).cached_styled_messages

      assert fg == 0x123456
      assert [[{"plain answer", ^fg, 0, 0}]] = block.lines
    end

    test "update_styled_cache restyles unchanged displayed messages when style cache is missing" do
      message = {:assistant, "unchanged answer"}

      {:ok, session} = StubServer.start_link(messages: [message])

      state =
        [Tab.new_agent(1, "Agent") |> Tab.set_session(session)]
        |> base_state(1)
        |> AgentAccess.update_panel(fn panel ->
          %{
            panel
            | cached_display_messages: [message],
              cached_styled_messages: nil
          }
        end)

      updated = AgentLifecycle.update_styled_cache(state)

      assert [%{styled_lines: [[{"unchanged answer", _fg, 0, 0}]], markdown_blocks: [block]}] =
               AgentAccess.panel(updated).cached_styled_messages

      assert block.kind == :paragraph
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
        |> AgentAccess.update_panel(fn panel ->
          %{panel | cached_display_messages: [{:assistant, "stale answer"}]}
        end)

      switched = EditorState.switch_tab(state, 2)

      active_window =
        Map.fetch!(switched.workspace.windows.map, switched.workspace.windows.active)

      assert AgentAccess.session(switched) == background_session
      assert {:agent_chat, :semantic} = active_window.content

      assert AgentAccess.panel(switched).cached_display_messages == [
               {:user, "inspect background session"},
               {:assistant, "unique background answer"}
             ]
    end
  end
end
