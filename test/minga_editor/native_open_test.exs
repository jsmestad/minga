defmodule MingaEditor.NativeOpenTest do
  # Not async: directory opens switch the application-wide Project process.
  use Minga.Test.EditorCase, async: false

  @moduletag :tmp_dir

  alias Minga.Project
  alias MingaEditor.UI.Picker.FileSource

  test "a native directory open uses the Finder project-switch and file-picker behavior", %{
    tmp_dir: tmp_dir
  } do
    previous_root = Project.workspace_root()

    on_exit(fn ->
      case previous_root do
        nil ->
          Project.close()
          assert Project.root() == nil

        root ->
          assert {:ok, _snapshot} = Project.activate(root)
      end
    end)

    project = Path.join(tmp_dir, "project")
    File.mkdir!(project)
    ctx = start_editor("initial")

    assert :ok = MingaEditor.open_native(project, false, ctx.editor)

    state = editor_state(ctx)
    assert {:picker, %{picker_ui: picker_ui}} = state.shell_runtime.state.modal
    assert picker_ui.source == FileSource
    assert Project.root() == project
  end
end
