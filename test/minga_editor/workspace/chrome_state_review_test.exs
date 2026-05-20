defmodule MingaEditor.Workspace.ChromeStateReviewTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileRef
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.Workspace.ChromeState

  test "draft and conflict counts come from WorkspaceReview file lists" do
    {:ok, draft_ref} = FileRef.from_path("/tmp/minga", "lib/draft.ex")
    {:ok, conflict_ref} = FileRef.from_path("/tmp/minga", "lib/conflict.ex")
    tab = Tab.new_file(1, "file.ex")
    {tb, workspace} = TabBar.add_workspace(TabBar.new(tab), "Agent")

    review = %WorkspaceReview{
      state: :conflict,
      changed_files: [draft_ref],
      conflict_files: [conflict_ref]
    }

    tb = TabBar.update_workspace(tb, workspace.id, &WorkspaceModel.set_review(&1, review))
    chrome = ChromeState.from_editor_state(%{shell_state: %{tab_bar: tb}})
    agent_summary = Enum.find(chrome.workspaces, &(&1.id == workspace.id))

    assert agent_summary.draft_count == 1
    assert agent_summary.conflict_count == 1
    assert chrome.draft_count == 1
    assert chrome.conflict_count == 1
  end
end
