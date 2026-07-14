defmodule MingaEditor.Commands.ProjectTest do
  @moduledoc "Tests project commands that coordinate the global project service and editor state."

  # Project commands intentionally mutate the application-wide Project service.
  use ExUnit.Case, async: false

  alias Minga.Project
  alias MingaEditor.Commands.Project, as: ProjectCommands
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @moduletag :tmp_dir

  test "closing a project clears the service and file tree root", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(root)
    Project.switch(root)
    _ = :sys.get_state(Project)

    state =
      TestHelpers.base_state(content: "buffer")
      |> EditorState.update_file_tree(&FileTreeState.set_project_root(&1, root))

    state = ProjectCommands.execute(state, :project_close)
    _ = :sys.get_state(Project)

    assert Project.root() == nil
    assert Project.workspace_root() == nil
    assert EditorState.file_tree_state(state).project_root == nil
  end
end
