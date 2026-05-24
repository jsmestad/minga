defmodule MingaEditor.DropOpenDirectoryTest do
  @moduledoc "Tests dropped-directory GUI actions that switch the active project."

  # Dropped-directory handling switches the global Minga.Project singleton before opening the picker.
  use Minga.Test.EditorCase, async: false

  setup do
    reset_global_project!()

    on_exit(fn ->
      reset_global_project!()
    end)

    :ok
  end

  @tag :tmp_dir
  test "dropping a directory opens the file picker", %{tmp_dir: tmp_dir} do
    subdir = Path.join(tmp_dir, "project")
    File.mkdir_p!(subdir)
    File.write!(Path.join(subdir, "main.ex"), "defmodule Main do\nend")

    ctx = start_editor("initial")

    send(ctx.editor, {:minga_input, {:gui_action, {:open_file, subdir}}})
    state = editor_state(ctx)

    assert {:picker, _payload} = state.shell_state.modal
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
