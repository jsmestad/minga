defmodule MingaEditor.Agent.DiffReviewAuthoritativeStoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProjectView
  alias MingaEditor.Agent.DiffReview
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

  defp state_with_diff_review(root, project_view, %DiffReview{} = review) do
    preview = Preview.set_diff(Preview.new(), review)
    agent_ui = UIState.update_preview(UIState.new(), fn _ -> preview end)

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
      port_manager: self(),
      workspace: %SessionState{agent_ui: agent_ui, viewport: Viewport.new(24, 80)},
      shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{tab_bar: tab_bar})
    }
  end
end
