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

  @moduletag :tmp_dir

  alias MingaAgent.ProjectView
  alias MingaAgent.Test.ProjectView.CloseFailingBackend
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.Viewport
  alias MingaEditor.Session

  defp build_state(tab_bar) do
    state = %EditorState{
      port_manager: nil,
      workspace: %Session.State{viewport: Viewport.new(80, 24)}
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

  defp workspace_state_with_project_view(session_pid, project_view) do
    {tb, workspace} = TabBar.add_workspace(empty_tab_bar(), "Workgroup", session_pid)

    tb =
      TabBar.update_workspace(
        tb,
        workspace.id,
        &WorkspaceModel.set_project_view(&1, project_view)
      )

    {build_state(tb), workspace.id}
  end

  defp seed_project(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.txt"), "one\n")
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

    test "removes a clean project view workspace on normal session end", %{tmp_dir: dir} do
      session_pid = spawn(fn -> :ok end)
      seed_project(dir)
      {:ok, project_view} = ProjectView.overlay(dir)
      changeset_ref = Process.monitor(project_view.ref.changeset)
      fork_store_ref = Process.monitor(project_view.ref.fork_store)
      {state, workspace_id} = workspace_state_with_project_view(session_pid, project_view)

      result = BufferManagement.handle_agent_session_down(state, session_pid, :normal)

      assert_receive {:DOWN, ^changeset_ref, :process, _, _}
      assert_receive {:DOWN, ^fork_store_ref, :process, _, _}
      assert TabBar.get_workspace(result.shell_state.tab_bar, workspace_id) == nil
      assert TabBar.find_workspace_by_session(result.shell_state.tab_bar, session_pid) == nil
      assert result.shell_state.status_msg == "Agent session ended"
    end

    test "keeps a dirty project view workspace and marks review attention", %{tmp_dir: dir} do
      session_pid = spawn(fn -> :ok end)
      seed_project(dir)
      path = Path.join(dir, "lib/a.txt")

      {:ok, buffer} =
        start_supervised({Minga.Buffer.Process, content: File.read!(path), file_path: path})

      {:ok, project_view} = ProjectView.overlay(dir)
      assert :ok = ProjectView.write_file(project_view, "lib/a.txt", "draft\n")
      {state, workspace_id} = workspace_state_with_project_view(session_pid, project_view)

      result = BufferManagement.handle_agent_session_down(state, session_pid, :normal)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, workspace_id)

      assert workspace.session == nil
      assert workspace.agent_status == :error
      assert workspace.review.state == :needs_review
      assert WorkspaceReview.pending?(workspace.review)
      assert result.shell_state.status_msg == "Agent session ended, workspace drafts need review"
      assert Minga.Buffer.content(buffer) == "one\n"
    end

    test "keeps a workspace when project view close fails", %{tmp_dir: dir} do
      session_pid = spawn(fn -> :ok end)

      project_view =
        ProjectView.new(CloseFailingBackend, dir, self(), workspace_id: 42)

      {state, workspace_id} = workspace_state_with_project_view(session_pid, project_view)

      result = BufferManagement.handle_agent_session_down(state, session_pid, :normal)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, workspace_id)

      assert_receive {:project_view_close_called, ^dir}
      assert workspace.session == nil
      assert workspace.agent_status == :error
      assert workspace.review.state == :needs_review
      assert workspace.review.last_error == :close_failed
      assert WorkspaceReview.pending?(workspace.review)

      assert result.shell_state.status_msg ==
               "Agent session ended, workspace review needs attention"
    end

    test "keeps a workspace when project view diff fails", %{tmp_dir: dir} do
      session_pid = spawn(fn -> :ok end)

      project_view =
        ProjectView.new(MingaAgent.Test.ProjectView.FailingBackend, dir, %{ref: self()},
          workspace_id: 42
        )

      {state, workspace_id} = workspace_state_with_project_view(session_pid, project_view)

      result = BufferManagement.handle_agent_session_down(state, session_pid, :killed)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, workspace_id)

      assert workspace.session == nil
      assert workspace.agent_status == :error
      assert workspace.review.state == :needs_review
      assert workspace.review.last_error == :diff_failed
      assert WorkspaceReview.pending?(workspace.review)

      assert result.shell_state.status_msg ==
               "Agent session crashed, workspace review needs attention"
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
