defmodule MingaEditor.UI.Picker.GitBranchSourceTest do
  @moduledoc "Tests branch picker branch-management actions."
  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.GitBranchSource
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.Viewport

  test "local branch items expose a delete action" do
    item = %Item{id: {:branch, "feature", false, false}, label: "feature"}

    assert [{"Delete", :delete}] = GitBranchSource.actions(item)
  end

  test "current and remote branch items do not expose delete actions" do
    current = %Item{id: {:branch, "main", true, false}, label: "main"}
    remote = %Item{id: {:branch, "origin/main", false, true}, label: "origin/main"}

    assert GitBranchSource.actions(current) == []
    assert GitBranchSource.actions(remote) == []
  end

  test "delete action on current branch reports an error without entering confirmation" do
    state = %EditorState{
      port_manager: nil,
      workspace: %SessionState{viewport: Viewport.new(24, 80)}
    }

    item = %Item{id: {:branch, "main", true, false}, label: "main"}

    result = GitBranchSource.on_action(:delete, item, state)

    assert result.shell_state.status_msg == "Cannot delete current branch"
    assert result.workspace.editing.mode == :normal
  end
end
