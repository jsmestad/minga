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
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.Session

  defp build_state(tab_bar) do
    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %Session.State{}
    }

    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.install_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          tab_bar
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
  end

  defp empty_tab_bar do
    TabBar.new(Tab.new_file(1, "scratch"))
  end

  defp tab_bar_with_session(session_pid) do
    {tb, agent_tab} = TabBar.insert(empty_tab_bar(), :agent, "Agent")
    {tb, workspace} = TabBar.add_workspace(tb, "Agent")

    tb
    |> TabBar.move_tab_to_workspace(agent_tab.id, workspace.id)
    |> TabBar.set_workspace_session(workspace.id, session_pid)
  end

  defp tab_bar_with_orphan_session(session_pid) do
    {tb, agent_tab} = TabBar.insert(empty_tab_bar(), :agent, "Agent")

    workspace =
      Workspace.new_agent(99, "Orphan", session_pid) |> Workspace.set_agent_status(:thinking)

    TabBar.accept_tab(tb, Tab.project_agent_lifecycle(agent_tab, workspace))
  end

  defp tab_bar_with_orphan_remote_session(session_pid) do
    {tb, agent_tab} = TabBar.insert(empty_tab_bar(), :agent, "Agent")

    workspace =
      Workspace.new_agent(99, "Orphan", session_pid)
      |> Workspace.put_remote_session("home", "session-1", :connected, 0)

    TabBar.accept_tab(tb, Tab.project_agent_lifecycle(agent_tab, workspace))
  end

  defp tab_bar_with_remote_session(session_pid) do
    {tb, agent_tab} = TabBar.insert(empty_tab_bar(), :agent, "Agent")
    {tb, workspace} = TabBar.add_workspace(tb, "Agent", session_pid)

    workspace =
      workspace
      |> Workspace.set_session(session_pid)
      |> Workspace.put_remote_session("home", "session-1", :connected, 0)

    tb
    |> TabBar.move_tab_to_workspace(agent_tab.id, workspace.id)
    |> TabBar.accept_workspace(workspace)
  end

  defp workspace_state_with_project_view(session_pid, project_view) do
    {tb, workspace} = TabBar.add_workspace(empty_tab_bar(), "Workgroup", session_pid)

    tb =
      TabBar.set_workspace_project_view(tb, workspace.id, project_view)

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
        |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("original message")

      foreign_pid = spawn(fn -> :ok end)

      result = BufferManagement.handle_agent_session_down(state, foreign_pid, :killed)

      assert result.shell_runtime.state.notice.message == "original message",
             "notice must not be overwritten by crashes from other editors' sessions"

      assert result.shell_runtime.state.tab_bar == state.shell_runtime.state.tab_bar,
             "tab_bar must be untouched when no tab references the crashed session"
    end

    test "ignores normal exit for session not referenced by any tab" do
      state =
        build_state(empty_tab_bar())
        |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("original message")

      foreign_pid = spawn(fn -> :ok end)

      result = BufferManagement.handle_agent_session_down(state, foreign_pid, :normal)

      assert result.shell_runtime.state.notice.message == "original message"
    end

    test "sets crash status when a tab references the crashed session" do
      session_pid = spawn(fn -> :ok end)
      state = build_state(tab_bar_with_session(session_pid))

      result = BufferManagement.handle_agent_session_down(state, session_pid, :killed)

      assert result.shell_runtime.state.notice.message ==
               "Agent session crashed (SPC a n to restart)"
    end

    test "clears orphan tab-only sessions when the session crashes" do
      session_pid = spawn(fn -> :ok end)
      state = build_state(tab_bar_with_orphan_session(session_pid))

      result = BufferManagement.handle_agent_session_down(state, session_pid, :killed)

      tab = TabBar.get(result.shell_runtime.state.tab_bar, 2)
      assert tab.payload.session == nil
      assert tab.payload.agent_status == :error

      assert result.shell_runtime.state.notice.message ==
               "Agent session crashed (SPC a n to restart)"
    end

    test "sets ended status when an owned session exits normally" do
      session_pid = spawn(fn -> :ok end)
      state = build_state(tab_bar_with_session(session_pid))

      result = BufferManagement.handle_agent_session_down(state, session_pid, :normal)

      assert result.shell_runtime.state.notice.message == "Agent session ended"
    end

    test "treats workspaces membership as ownership" do
      session_pid = spawn(fn -> :ok end)
      {tb, _group} = TabBar.add_workspace(empty_tab_bar(), "Workgroup", session_pid)
      state = build_state(tb)

      result = BufferManagement.handle_agent_session_down(state, session_pid, :killed)

      assert result.shell_runtime.state.notice.message ==
               "Agent session crashed (SPC a n to restart)"
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
      assert TabBar.get_workspace(result.shell_runtime.state.tab_bar, workspace_id) == nil

      assert TabBar.find_workspace_by_session(result.shell_runtime.state.tab_bar, session_pid) ==
               nil

      assert result.shell_runtime.state.notice.message == "Agent session ended"
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
      workspace = TabBar.get_workspace(result.shell_runtime.state.tab_bar, workspace_id)

      assert workspace.payload.session == nil
      assert workspace.payload.agent_status == :error
      assert workspace.review.state == :needs_review
      assert WorkspaceReview.pending?(workspace.review)

      assert result.shell_runtime.state.notice.message ==
               "Agent session ended, workspace drafts need review"

      assert Minga.Buffer.content(buffer) == "one\n"
    end

    test "keeps a workspace when project view close fails", %{tmp_dir: dir} do
      session_pid = spawn(fn -> :ok end)

      project_view =
        ProjectView.new(CloseFailingBackend, dir, self(), workspace_id: 42)

      {state, workspace_id} = workspace_state_with_project_view(session_pid, project_view)

      result = BufferManagement.handle_agent_session_down(state, session_pid, :normal)
      workspace = TabBar.get_workspace(result.shell_runtime.state.tab_bar, workspace_id)

      assert_receive {:project_view_close_called, ^dir}
      assert workspace.payload.session == nil
      assert workspace.payload.agent_status == :error
      assert workspace.review.state == :needs_review
      assert workspace.review.last_error == :close_failed
      assert WorkspaceReview.pending?(workspace.review)

      assert result.shell_runtime.state.notice.message ==
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
      workspace = TabBar.get_workspace(result.shell_runtime.state.tab_bar, workspace_id)

      assert workspace.payload.session == nil
      assert workspace.payload.agent_status == :error
      assert workspace.review.state == :needs_review
      assert workspace.review.last_error == :diff_failed
      assert WorkspaceReview.pending?(workspace.review)

      assert result.shell_runtime.state.notice.message ==
               "Agent session crashed, workspace review needs attention"
    end

    test "preserves remote tab on noconnection" do
      session_pid = spawn(fn -> :ok end)
      state = build_state(tab_bar_with_remote_session(session_pid))

      result = BufferManagement.handle_agent_session_down(state, session_pid, :noconnection)

      tab_bar = result.shell_runtime.state.tab_bar
      remote_workspace = TabBar.find_workspace_by_session(tab_bar, session_pid)
      remote_tab = TabBar.find_by_session(tab_bar, session_pid)

      assert remote_workspace.payload.session == session_pid
      assert remote_workspace.payload.remote_session.connection_status == :disconnected
      assert remote_tab.payload.connection_status == :disconnected
      assert result.shell_runtime.state.notice.message == "[home] disconnected, reconnecting..."
    end

    test "marks orphan remote tabs disconnected on noconnection" do
      session_pid = spawn(fn -> :ok end)
      state = build_state(tab_bar_with_orphan_remote_session(session_pid))

      result = BufferManagement.handle_agent_session_down(state, session_pid, :noconnection)

      tab_bar = result.shell_runtime.state.tab_bar
      remote_tab = TabBar.find_by_session(tab_bar, session_pid)

      assert TabBar.find_workspace_by_session(tab_bar, session_pid) == nil
      assert remote_tab.payload.connection_status == :disconnected
      assert result.shell_runtime.state.notice.message == "[home] disconnected, reconnecting..."
    end
  end
end
