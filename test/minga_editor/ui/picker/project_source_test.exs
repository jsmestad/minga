defmodule MingaEditor.UI.Picker.ProjectSourceTest do
  @moduledoc "Tests project picker selection behavior."

  # Uses the global Minga.Project singleton and FileSource shells out for file discovery.
  use Minga.Test.EditorCase, async: false, rendering: :disabled

  alias MingaEditor.Input.Picker, as: PickerInput
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ProjectSource

  @moduletag :tmp_dir

  setup do
    reset_global_project!()

    on_exit(fn ->
      reset_global_project!()
    end)

    :ok
  end

  test "selecting a project opens find file with the selected root, not the stale file tree root",
       %{tmp_dir: tmp_dir} do
    stale_root = Path.join(tmp_dir, "stale_root")
    selected_root = Path.join(tmp_dir, "selected_root")

    File.mkdir_p!(stale_root)
    File.mkdir_p!(selected_root)
    File.write!(Path.join(stale_root, "stale.txt"), "stale")
    File.write!(Path.join(selected_root, "target.txt"), "target")

    Minga.Events.subscribe(:project_rebuilt)
    Minga.Project.switch(stale_root)
    await_project_rebuild(stale_root)

    ctx =
      start_editor("stale",
        file_path: Path.join(stale_root, "stale.txt"),
        project_root: stale_root
      )

    state =
      ctx
      |> editor_state()
      |> open_project_picker(selected_root)

    assert {:handled, new_state} = PickerInput.handle_key(state, 13, 0)

    assert {:picker,
            %{
              picker_ui: %{
                context: %{project_root: ^selected_root},
                source: FileSource,
                load_status: :loading
              }
            }} = new_state.shell_state.modal

    assert EditorState.file_tree_state(new_state).project_root == selected_root
  end

  defp open_project_picker(state, selected_root) do
    picker =
      [%Item{id: selected_root, label: Path.basename(selected_root), description: selected_root}]
      |> Picker.new(title: ProjectSource.title(), max_visible: 10)

    picker_state = %PickerState{
      picker: picker,
      source: ProjectSource,
      restore: state.workspace.buffers.active_index,
      layout: :centered
    }

    ModalOverlay.open(state, :picker, PickerPayload.new(picker_state))
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
