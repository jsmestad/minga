defmodule MingaEditor.Agent.DiffReviewAuthoritativeStoreTest do
  use Minga.Test.SessionCase, async: true

  alias MingaAgent.ProjectView
  alias MingaEditor.Agent.DiffReview
  alias Minga.Git
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.FileChange
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Commands.AgentSubStates
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  @moduletag :tmp_dir

  defp bind_live_source(review, source) do
    session = start_subscribed_session()
    assert_receive {:agent_event, ^session, {:connection_changed, %{target: target}}}
    DiffReview.bind_source(review, source, target)
  end

  test "rejecting a closed-file hunk updates project view before read and promote", %{
    tmp_dir: root
  } do
    path = "lib/a.ex"
    absolute_path = Path.join(root, path)
    before = "one\nold\nthree\n"
    after_edit = "one\nnew\nthree\n"

    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, before)

    {:ok, project_view} = ProjectView.overlay(root)
    assert :ok = ProjectView.write_file(project_view, path, after_edit)

    {:ok, source} = ProjectView.resolve_source(project_view, path)
    review = absolute_path |> DiffReview.new(before, after_edit) |> bind_live_source(source)
    state = state_with_diff_review(root, project_view, review)

    _state = AgentSubStates.reject_hunk(state)

    assert {:ok, ^before} = ProjectView.read_file(project_view, path)
    assert :ok = ProjectView.promote(project_view, :project_root)
    assert File.read!(absolute_path) == before
  end

  test "rejecting a stale hunk preserves intervening project-view edits", %{tmp_dir: root} do
    path = "file.txt"
    absolute_path = Path.join(root, path)
    File.write!(absolute_path, "original\n")
    {:ok, project_view} = ProjectView.overlay(root)
    assert :ok = ProjectView.write_file(project_view, path, "agent\n")
    {:ok, source} = ProjectView.resolve_source(project_view, path)

    review =
      absolute_path |> DiffReview.new("original\n", "agent\n") |> bind_live_source(source)

    state = state_with_diff_review(root, project_view, review)
    assert :ok = ProjectView.write_file(project_view, path, "human\n")

    state = AgentSubStates.reject_hunk(state)

    assert {:ok, "human\n"} = ProjectView.read_file(project_view, path)
    assert Preview.diff_review(state.workspace.agent_ui.view.preview) == review
  end

  test "empty creation and deletion remain visible as distinct saved changes", %{tmp_dir: root} do
    path = Path.join(root, "empty.txt")

    assert %DiffReview{} = creation = DiffReview.new(path, :absent, "")
    assert {1, 0} = DiffReview.summary(creation)
    assert %DiffReview{} = deletion = DiffReview.new(path, "", :absent)
    assert {0, 1} = DiffReview.summary(deletion)
    assert DiffReview.new(path, :absent, :absent) == nil
  end

  test "rejecting a saved comparison cannot mutate even matching live bytes", %{tmp_dir: root} do
    path = Path.join(root, "file.txt")
    File.write!(path, "agent\n")
    {:ok, project_view} = ProjectView.overlay(root)
    review = path |> DiffReview.new("original\n", "agent\n") |> DiffReview.as_retained()
    state = state_with_diff_review(root, project_view, review)

    state = AgentSubStates.reject_all_hunks(state)

    assert {:ok, "agent\n"} = ProjectView.read_file(project_view, "file.txt")
    assert Preview.diff_review(state.workspace.agent_ui.view.preview) == review
  end

  test "rejecting an unapplied proposal dismisses it without touching the project", %{
    tmp_dir: root
  } do
    path = Path.join(root, "file.txt")
    File.write!(path, "original\n")
    {:ok, project_view} = ProjectView.overlay(root)
    review = path |> DiffReview.new("original\n", "proposal\n") |> DiffReview.as_proposal()
    state = state_with_diff_review(root, project_view, review)

    state = AgentSubStates.reject_hunk(state)

    assert Preview.diff_review(state.workspace.agent_ui.view.preview) == nil
    assert {:ok, "original\n"} = ProjectView.read_file(project_view, "file.txt")
  end

  test "rejecting a hunk cannot write into a replacement overlay with matching bytes", %{
    tmp_dir: root
  } do
    path = Path.join(root, "file.txt")
    File.write!(path, "agent\n")
    {:ok, original} = ProjectView.overlay(root)
    {:ok, source} = ProjectView.resolve_source(original, "file.txt")
    review = path |> DiffReview.new("original\n", "agent\n") |> bind_live_source(source)
    {:ok, replacement} = ProjectView.overlay(root)
    state = state_with_diff_review(root, replacement, review)

    state = AgentSubStates.reject_all_hunks(state)

    assert {:ok, "agent\n"} = ProjectView.read_file(replacement, "file.txt")
    assert Preview.diff_review(state.workspace.agent_ui.view.preview) == review
  end

  test "rejecting a stale deletion does not replace a recreated file", %{tmp_dir: root} do
    path = "recreated.txt"
    absolute_path = Path.join(root, path)
    File.write!(absolute_path, "original\n")
    {:ok, project_view} = ProjectView.overlay(root)
    assert :ok = ProjectView.delete_file(project_view, path)
    {:ok, source} = ProjectView.resolve_source(project_view, path)

    review =
      absolute_path |> DiffReview.new("original\n", :absent) |> bind_live_source(source)

    state = state_with_diff_review(root, project_view, review)
    assert :ok = ProjectView.write_file(project_view, path, "recreated\n")

    state = AgentSubStates.reject_hunk(state)

    assert {:ok, "recreated\n"} = ProjectView.read_file(project_view, path)
    assert Preview.diff_review(state.workspace.agent_ui.view.preview) == review
  end

  test "rejecting a deletion restores the project view before promote", %{tmp_dir: root} do
    path = "lib/deleted.ex"
    absolute_path = Path.join(root, path)
    before = "one\ntwo\n"
    after_delete = :absent

    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, before)

    {:ok, project_view} = ProjectView.overlay(root)
    assert :ok = ProjectView.delete_file(project_view, path)

    {:ok, source} = ProjectView.resolve_source(project_view, path)

    review =
      absolute_path |> DiffReview.new(before, after_delete) |> bind_live_source(source)

    state = state_with_diff_review(root, project_view, review)

    _state = AgentSubStates.reject_hunk(state)

    assert {:ok, ^before} = ProjectView.read_file(project_view, path)
    assert :ok = ProjectView.promote(project_view, :project_root)
    assert File.read!(absolute_path) == before
  end

  test "rejecting an open-file hunk updates the fork before read and promote", %{tmp_dir: root} do
    path = "lib/open.ex"
    absolute_path = Path.join(root, path)
    before = "one\nold\nthree\n"
    after_edit = "one\nnew\nthree\n"

    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, before)

    {:ok, buffer} =
      start_supervised({Minga.Buffer.Process, content: before, file_path: absolute_path})

    {:ok, project_view} = ProjectView.overlay(root)
    assert :ok = ProjectView.write_file(project_view, path, after_edit)
    assert {:ok, ^after_edit} = ProjectView.read_file(project_view, path)

    {:ok, source} = ProjectView.resolve_source(project_view, path)
    review = absolute_path |> DiffReview.new(before, after_edit) |> bind_live_source(source)
    state = state_with_diff_review(root, project_view, review)

    _state = AgentSubStates.reject_hunk(state)

    assert {:ok, ^before} = ProjectView.read_file(project_view, path)
    assert :ok = ProjectView.promote(project_view, :project_root)
    assert Minga.Buffer.content(buffer) == before
    assert File.read!(absolute_path) == before
  end

  test "reject write failure leaves review and timeline unchanged", %{tmp_dir: root} do
    path = Path.join(root, "blocked")
    File.mkdir_p!(path)
    before = "old\n"
    after_edit = "new\n"
    review = DiffReview.new(path, before, after_edit)

    timeline =
      EditTimeline.new()
      |> EditTimeline.record_edit(%FileChange{
        path: path,
        before_content: before,
        after_content: after_edit,
        tool_call_id: "tc1",
        tool_name: "edit_file"
      })

    state = state_with_disk_diff_review(root, review, timeline)
    state = AgentSubStates.reject_hunk(state)

    assert %DiffReview{} = retained = Preview.diff_review(state.workspace.agent_ui.view.preview)
    assert DiffReview.resolution_at(retained, 0) == nil

    assert EditTimeline.cumulative_hunks(state.workspace.agent_ui.view.edit_timeline, path) ==
             review.hunks

    assert NoticeWorkflow.message(state) =~ "Could not reject hunk"
    assert NoticeWorkflow.message(state) =~ ":editable_view_unavailable"
    assert File.dir?(path)
  end

  test "reject_all preserves accepted hunks and drops rejected hunks from timeline", %{
    tmp_dir: root
  } do
    path = "lib/multi.ex"
    absolute_path = Path.join(root, path)
    before = "one\nold upper\nmiddle\nold lower\nthree\n"
    after_edit = "one\nnew upper\nmiddle\nnew lower\nthree\n"

    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, before)

    {:ok, project_view} = ProjectView.overlay(root)
    assert :ok = ProjectView.write_file(project_view, path, after_edit)

    {:ok, source} = ProjectView.resolve_source(project_view, path)
    review = absolute_path |> DiffReview.new(before, after_edit) |> bind_live_source(source)
    state = state_with_diff_review(root, project_view, review)

    state =
      state
      |> AgentSubStates.accept_hunk()
      |> AgentSubStates.reject_all_hunks()

    materialized = "one\nnew upper\nmiddle\nold lower\nthree\n"
    assert {:ok, ^materialized} = ProjectView.read_file(project_view, path)

    assert EditTimeline.cumulative_hunks(
             state.workspace.agent_ui.view.edit_timeline,
             absolute_path
           ) ==
             Git.diff_lines(String.split(before, "\n"), String.split(materialized, "\n"))

    refute Preview.diff_review(state.workspace.agent_ui.view.preview)
  end

  defp state_with_diff_review(root, project_view, %DiffReview{} = review) do
    timeline =
      EditTimeline.new()
      |> EditTimeline.reproject(
        review.path,
        DiffReview.original_lines(review),
        review.after_lines
      )

    state_with_diff_review(root, project_view, review, timeline)
  end

  defp state_with_diff_review(
         root,
         project_view,
         %DiffReview{} = review,
         %EditTimeline{} = timeline
       ) do
    preview = Preview.set_diff(Preview.new(), review)

    agent_ui =
      UIState.new() |> UIState.replace_preview(preview) |> UIState.replace_edit_timeline(timeline)

    agent_tab = Tab.set_group(Tab.new_agent(1, "Agent"), 1)

    agent_workspace =
      WorkspaceModel.new_agent(1, "Agent", nil, root)
      |> WorkspaceModel.set_project_view(project_view)
      |> WorkspaceModel.set_agent_ui(agent_ui)

    tab_bar = %{
      TabBar.new(agent_tab, root)
      | workspaces: [WorkspaceModel.new_manual(root), agent_workspace],
        next_workspace_id: 2
    }

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %SessionState{agent_ui: agent_ui},
      shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{tab_bar: tab_bar})
    }
  end

  defp state_with_disk_diff_review(root, %DiffReview{} = review, %EditTimeline{} = timeline) do
    preview = Preview.set_diff(Preview.new(), review)

    agent_ui =
      UIState.new() |> UIState.replace_preview(preview) |> UIState.replace_edit_timeline(timeline)

    agent_tab = Tab.set_group(Tab.new_agent(1, "Agent"), 1)

    agent_workspace =
      WorkspaceModel.new_agent(1, "Agent", nil, root) |> WorkspaceModel.set_agent_ui(agent_ui)

    tab_bar = %{
      TabBar.new(agent_tab, root)
      | workspaces: [WorkspaceModel.new_manual(root), agent_workspace],
        next_workspace_id: 2
    }

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %SessionState{agent_ui: agent_ui},
      shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{tab_bar: tab_bar})
    }
  end
end
