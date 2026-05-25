defmodule MingaGitPorcelain.CommandsBranchDeleteTest do
  @moduledoc "Tests branch delete confirmation command handling."

  # Uses the global Minga.Project singleton to verify picker reopen behavior.
  use ExUnit.Case, async: false

  alias Minga.Git
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Mode.BranchDeleteConfirmState
  alias MingaEditor.Commands
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker
  alias MingaEditor.Viewport

  setup %{tmp_dir: dir} do
    reset_global_project!()
    GitStub.set_root(dir, dir)

    GitStub.set_branches(dir, [
      %Git.BranchInfo{name: "main", current: true},
      %Git.BranchInfo{name: "feature", current: false}
    ])

    Minga.Project.switch(dir)
    await_project_rebuild(dir)

    on_exit(fn ->
      GitStub.clear(dir)
      reset_global_project!()
    end)

    %{git_root: dir}
  end

  @tag :tmp_dir
  test "successful branch delete reports success and reopens the branch picker", %{
    git_root: git_root
  } do
    state = build_state()

    result = Commands.execute(state, {:branch_delete_confirm, git_root, "feature", false})

    assert result.shell_state.status_msg == "Deleted branch feature"

    assert {:picker,
            %{picker_ui: %{source: MingaGitPorcelain.UI.Picker.GitBranchSource, picker: picker}}} =
             result.shell_state.modal

    assert %Picker{items: items} = picker
    refute Enum.any?(items, fn item -> item.label == "feature" end)
  end

  @tag :tmp_dir
  test "unmerged safe-delete failure enters force confirmation", %{git_root: git_root} do
    GitStub.set_branch_delete_result(git_root, "feature", false, {:error, "not fully merged"})
    state = build_state()

    result = Commands.execute(state, {:branch_delete_confirm, git_root, "feature", false})

    assert result.shell_state.status_msg == "Delete failed: not fully merged"
    assert result.workspace.editing.mode == :branch_delete_confirm

    assert %BranchDeleteConfirmState{name: "feature", phase: :force, reason: "not fully merged"} =
             result.workspace.editing.mode_state
  end

  @tag :tmp_dir
  test "force delete failure reports force-specific error", %{git_root: git_root} do
    GitStub.set_branch_delete_result(git_root, "feature", true, {:error, "branch not found"})
    state = build_state()

    result = Commands.execute(state, {:branch_delete_confirm, git_root, "feature", true})

    assert result.shell_state.status_msg == "Force delete failed: branch not found"
  end

  defp build_state do
    %EditorState{port_manager: nil, workspace: %SessionState{viewport: Viewport.new(24, 80)}}
  end

  defp reset_global_project! do
    root = File.cwd!()
    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(root)
    await_project_rebuild(root)
  end

  defp await_project_rebuild(root) do
    if Minga.Project.rebuilding?() do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^root}},
                     5_000
    end

    _ = :sys.get_state(Minga.Project)
  end
end
