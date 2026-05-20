defmodule MingaEditor.Commands.AgentSessionDownTest do
  @moduledoc """
  Pure-function tests for `BufferManagement.handle_agent_session_down/3`.

  The Editor subscribes to the global `Minga.Events` bus for
  `:agent_session_stopped` events, so handlers receive notifications for
  every agent session in the BEAM, not only the ones this editor owns.
  These tests pin the contract: only act on sessions referenced by a tab
  or workspace on this editor's tab bar.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace

  defp build_state(tab_bar) do
    state = %EditorState{
      port_manager: nil,
      workspace: %Workspace.State{viewport: Viewport.new(80, 24)}
    }

    EditorState.set_tab_bar(state, tab_bar)
  end

  defp empty_tab_bar do
    TabBar.new(Tab.new_file(1, "scratch"))
  end

  defp tab_bar_with_session(session_pid) do
    {tb, agent_tab} = TabBar.insert(empty_tab_bar(), :agent, "Agent")
    TabBar.update_tab(tb, agent_tab.id, &Tab.set_session(&1, session_pid))
  end

  defp tab_bar_with_remote_session(session_pid) do
    {tb, agent_tab} = TabBar.insert(empty_tab_bar(), :agent, "Agent")

    TabBar.update_tab(
      tb,
      agent_tab.id,
      &Tab.set_remote_session(&1, "home", "session-1", session_pid)
    )
  end

  describe "handle_agent_session_down/3 with TabBar shell" do
    test "ignores crash for session not referenced by any tab" do
      state =
        build_state(empty_tab_bar())
        |> EditorState.set_status("original message")

      foreign_pid = spawn(fn -> :ok end)

      result = BufferManagement.handle_agent_session_down(state, foreign_pid, :killed)

      assert result.shell_state.status_msg == "original message",
             "status_msg must not be overwritten by crashes from other editors' sessions"

      assert result.shell_state.tab_bar == state.shell_state.tab_bar,
             "tab_bar must be untouched when no tab references the crashed session"
    end

    test "ignores normal exit for session not referenced by any tab" do
      state =
        build_state(empty_tab_bar())
        |> EditorState.set_status("original message")

      foreign_pid = spawn(fn -> :ok end)

      result = BufferManagement.handle_agent_session_down(state, foreign_pid, :normal)

      assert result.shell_state.status_msg == "original message"
    end

    test "sets crash status when a tab references the crashed session" do
      session_pid = spawn(fn -> :ok end)
      state = build_state(tab_bar_with_session(session_pid))

      result = BufferManagement.handle_agent_session_down(state, session_pid, :killed)

      assert result.shell_state.status_msg == "Agent session crashed (SPC a n to restart)"
    end

    test "sets ended status when an owned session exits normally" do
      session_pid = spawn(fn -> :ok end)
      state = build_state(tab_bar_with_session(session_pid))

      result = BufferManagement.handle_agent_session_down(state, session_pid, :normal)

      assert result.shell_state.status_msg == "Agent session ended"
    end

    test "treats workspaces membership as ownership" do
      session_pid = spawn(fn -> :ok end)
      {tb, _group} = TabBar.add_workspace(empty_tab_bar(), "Workgroup", session_pid)
      state = build_state(tb)

      result = BufferManagement.handle_agent_session_down(state, session_pid, :killed)

      assert result.shell_state.status_msg == "Agent session crashed (SPC a n to restart)"
    end

    test "preserves remote tab on noconnection" do
      session_pid = spawn(fn -> :ok end)
      state = build_state(tab_bar_with_remote_session(session_pid))

      result = BufferManagement.handle_agent_session_down(state, session_pid, :noconnection)
      remote_tab = Enum.find(result.shell_state.tab_bar.tabs, &(&1.session == session_pid))

      assert remote_tab.connection_status == :disconnected
      assert result.shell_state.status_msg == "[home] disconnected, reconnecting..."
    end
  end
end
