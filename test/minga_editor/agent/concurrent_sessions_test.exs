defmodule MingaEditor.Agent.ConcurrentSessionsTest do
  @moduledoc """
  Verifies that two agent sessions can coexist in two tabs and that
  switching tabs while one session is mid-stream does not interrupt
  it or route its events to the wrong tab.

  These tests exercise per-tab session ownership: `Tab.session` is the
  source of truth, and `AgentAccess.session/1` reads it through the
  shell's `active_session/1` callback. The editor's
  `state.shell_state.agent` struct holds rendering caches only.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
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

    %{tb | active_id: active_id}
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

      # Sanity: both sessions are alive before the switch
      assert Process.alive?(session_a)
      assert Process.alive?(session_b)
      assert AgentAccess.session(state) == session_a

      # Switching tabs only repoints the active_id; it does not stop or
      # restart either session process.
      switched =
        EditorState.set_tab_bar(state, %{state.shell_state.tab_bar | active_id: 2})

      assert AgentAccess.session(switched) == session_b
      assert Process.alive?(session_a)
      assert Process.alive?(session_b)
    end

    test "two tabs with no session report nil regardless of which is active" do
      tabs = [Tab.new_agent(1, "Agent A"), Tab.new_agent(2, "Agent B")]

      assert AgentAccess.session(base_state(tabs, 1)) == nil
      assert AgentAccess.session(base_state(tabs, 2)) == nil
    end
  end

  describe "tab switch mid-stream" do
    test "mid-stream session is unaffected when its tab becomes inactive" do
      # The "stream" here is represented by the session being alive and
      # busy. Switching away from its tab must not kill it, must not
      # route its events to the wrong tab (we read session pid by tab),
      # and the originating tab's session pid must still be reachable.
      {:ok, streaming} = StubServer.start_link()
      {:ok, idle} = StubServer.start_link()

      tabs = [
        Tab.new_agent(1, "Streaming") |> Tab.set_session(streaming),
        Tab.new_agent(2, "Idle") |> Tab.set_session(idle)
      ]

      state = base_state(tabs, 1)
      assert AgentAccess.session(state) == streaming

      # Switch from tab 1 to tab 2 while tab 1's session is "streaming".
      switched =
        EditorState.set_tab_bar(state, %{state.shell_state.tab_bar | active_id: 2})

      # Tab 2's session is now in scope; tab 1's session is still alive.
      assert AgentAccess.session(switched) == idle
      assert Process.alive?(streaming)

      # Tab 1's session pid is still reachable via Tab.session.
      tab_one = Enum.find(switched.shell_state.tab_bar.tabs, &(&1.id == 1))
      assert tab_one.session == streaming

      # Switching back returns the streaming session as the active one.
      back =
        EditorState.set_tab_bar(switched, %{switched.shell_state.tab_bar | active_id: 1})

      assert AgentAccess.session(back) == streaming
    end
  end
end
