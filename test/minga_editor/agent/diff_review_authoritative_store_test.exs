defmodule MingaEditor.Agent.DiffReviewAuthoritativeStoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProjectView
  alias MingaEditor.Agent.DiffReview
  alias Minga.Git
  alias MingaEditor.Agent.EditTimeline
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
  alias MingaEditor.Viewport
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  @moduletag :tmp_dir

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

    review = DiffReview.new(absolute_path, before, after_edit)
    state = state_with_diff_review(root, project_view, review)

    _state = AgentSubStates.reject_hunk(state)

    assert {:ok, ^before} = ProjectView.read_file(project_view, path)
    assert :ok = ProjectView.promote(project_view, :project_root)
    assert File.read!(absolute_path) == before
  end

  test "rejecting a deletion restores the project view before promote", %{tmp_dir: root} do
    path = "lib/deleted.ex"
    absolute_path = Path.join(root, path)
    before = "one\ntwo\n"
    after_delete = ""

    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, before)

    {:ok, project_view} = ProjectView.overlay(root)
    assert :ok = ProjectView.delete_file(project_view, path)

    review = DiffReview.new(absolute_path, before, after_delete)
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

    review = DiffReview.new(absolute_path, before, after_edit)
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
      |> EditTimeline.record_edit(path, "tc1", "edit_file", before, after_edit)

    state = state_with_disk_diff_review(root, review, timeline)
    state = AgentSubStates.reject_hunk(state)

    assert %DiffReview{} = retained = Preview.diff_review(state.workspace.agent_ui.view.preview)
    assert DiffReview.resolution_at(retained, 0) == nil

    assert EditTimeline.cumulative_hunks(state.workspace.agent_ui.view.edit_timeline, path) ==
             review.hunks

    assert NoticeWorkflow.message(state) =~ "Could not reject hunk"
    assert NoticeWorkflow.message(state) =~ ":eisdir"
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

    review = DiffReview.new(absolute_path, before, after_edit)
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
      workspace: %SessionState{agent_ui: agent_ui, viewport: Viewport.new(24, 80)},
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
      workspace: %SessionState{agent_ui: agent_ui, viewport: Viewport.new(24, 80)},
      shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{tab_bar: tab_bar})
    }
  end
end
