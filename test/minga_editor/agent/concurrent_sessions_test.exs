defmodule MingaEditor.Agent.ConcurrentSessionsTest do
  @moduledoc """
  Verifies that two agent sessions can coexist in two tabs and that
  switching tabs while one session is mid-stream does not interrupt
  it or route its events to the wrong tab.

  These tests exercise per-workspace session ownership: workspaces are the source of truth, while legacy tab session fields remain only as locators for event routing and migration paths. The editor's `state.shell_state.agent` struct holds rendering caches only.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias MingaEditor.Agent.UIState
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
      shell: MingaEditor.Shell.Traditional,
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :editor,
        agent_ui: UIState.new()
      },
      shell_state: %MingaEditor.Shell.Traditional.State{
        agent: %AgentState{},
        tab_bar: tb
      }
    }
  end

  defp build_tab_bar([first | rest], active_id) do
    tb = TabBar.new(first)

    tb =
      Enum.reduce(rest, tb, fn tab, acc ->
        %{acc | tabs: acc.tabs ++ [tab], next_id: max(acc.next_id, tab.id + 1)}
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

  defp agent_tab_context(agent_buf) do
    rows = 24
    cols = 80
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, agent_buf, rows, cols)

    %{
      keymap_scope: :agent,
      buffers: %Buffers{active: agent_buf, list: [agent_buf], active_index: 0},
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
        EditorState.set_tab_bar(state, %{state.shell_state.tab_bar | active_id: 2})

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

      tab_one = Enum.find(switched.shell_state.tab_bar.tabs, &(&1.id == 1))
      assert tab_one.session == streaming

      # Switching back restores the streaming session as the active one.
      back = EditorState.switch_tab(switched, 1)
      assert AgentAccess.session(back) == streaming
    end

    test "switch_tab repopulates the rendering cache from the incoming tab's session" do
      # The session struct on shell_state.agent is a rendering cache,
      # not the source of truth. After switch_tab/2, status/error/
      # pending_approval should reflect the *incoming* tab's session.
      {:ok, session_a} = StubServer.start_link()
      {:ok, session_b} = StubServer.start_link()

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
      assert cache.runtime.status == :idle
      assert cache.pending_approval == nil
    end

    test "switch_tab binds and syncs a background agent tab's chat buffer" do
      {:ok, background_session} =
        StubServer.start_link(
          messages: [
            {:user, "inspect background session"},
            {:assistant, "unique background answer"}
          ]
        )

      stale_agent_buf = AgentBufferSync.start_buffer()
      background_agent_buf = AgentBufferSync.start_buffer()

      tabs = [
        Tab.new_file(1, "main.ex"),
        Tab.new_agent(2, "Background")
        |> Tab.set_session(background_session)
        |> Tab.set_context(agent_tab_context(background_agent_buf))
      ]

      state =
        tabs
        |> base_state(1)
        |> AgentAccess.update_agent(&AgentState.set_buffer(&1, stale_agent_buf))

      switched = EditorState.switch_tab(state, 2)

      active_window =
        Map.fetch!(switched.workspace.windows.map, switched.workspace.windows.active)

      assert AgentAccess.session(switched) == background_session
      assert {:agent_chat, ^background_agent_buf} = active_window.content
      assert AgentAccess.agent(switched).buffer == background_agent_buf

      background_content = Buffer.content(background_agent_buf)
      stale_content = Buffer.content(stale_agent_buf)

      assert background_content =~ "inspect background session"
      assert background_content =~ "unique background answer"
      refute stale_content =~ "unique background answer"
    end
  end
end
