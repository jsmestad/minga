defmodule MingaEditor.Agent.DiffReviewAuthoritativeStoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProjectView
  alias MingaEditor.Agent.DiffReview
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

  @moduletag :tmp_dir

  test "ordinary file comparisons cannot keep or write an overlay edit", %{tmp_dir: root} do
    path = "file.txt"
    absolute_path = Path.join(root, path)
    File.write!(absolute_path, "before\n")
    {:ok, project_view} = ProjectView.overlay(root)
    assert :ok = ProjectView.write_file(project_view, path, "agent\n")
    review = DiffReview.new(absolute_path, "before\n", "agent\n")
    state = state_with_diff_review(root, project_view, review)

    decided = state |> AgentSubStates.accept_hunk() |> AgentSubStates.reject_all_hunks()

    assert Preview.diff_review(decided.workspace.agent_ui.view.preview) == review
    assert {:ok, "agent\n"} = ProjectView.read_file(project_view, path)
    assert File.read!(absolute_path) == "before\n"
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
end
