defmodule MingaEditor.PickerBranchDeleteShortcutTest do
  @moduledoc "Tests the branch picker Ctrl-D shortcut in a serial test because it uses the global Minga.Project singleton."

  use ExUnit.Case, async: false

  alias Minga.Git
  alias Minga.Git.Stub, as: GitStub
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  @moduletag :tmp_dir

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

  test "Ctrl-D on a non-current local branch enters branch delete confirm", %{git_root: git_root} do
    picker =
      Picker.new([%Item{id: {:branch, "feature", false, false}, label: "feature"}],
        title: "Switch Branch"
      )

    state = picker_state(picker)

    result = PickerUI.handle_key(state, ?d, MingaEditor.Input.mod_ctrl())

    assert result.shell_state.modal == :none
    assert result.workspace.editing.mode == :branch_delete_confirm

    assert %Minga.Mode.BranchDeleteConfirmState{git_root: ^git_root, name: "feature"} =
             result.workspace.editing.mode_state
  end

  test "Ctrl-D on the current branch closes the picker and reports the error" do
    picker =
      Picker.new([%Item{id: {:branch, "main", true, false}, label: "main"}],
        title: "Switch Branch"
      )

    state = picker_state(picker)

    result = PickerUI.handle_key(state, ?d, MingaEditor.Input.mod_ctrl())

    assert result.shell_state.modal == :none
    assert result.shell_state.status_msg == "Cannot delete current branch"
    assert result.workspace.editing.mode == :normal
  end

  defp picker_state(picker) do
    picker_state = %PickerState{
      picker: picker,
      source: MingaEditor.UI.Picker.GitBranchSource,
      restore: 0
    }

    %EditorState{
      port_manager: nil,
      workspace: %SessionState{viewport: Viewport.new(24, 80), editing: VimState.new()},
      shell_state: %MingaEditor.Shell.Traditional.State{
        modal: {:picker, PickerPayload.new(picker_state)}
      }
    }
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
