defmodule MingaEditor.Commands.ProjectTest do
  @moduledoc "Tests project commands that coordinate the global project service and editor state."

  # Project commands intentionally mutate the application-wide Project service.
  use ExUnit.Case, async: false

  alias Minga.Project
  alias MingaEditor.Commands.Project, as: ProjectCommands
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ProjectSource
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @moduletag :tmp_dir

  test "switch project activates one workspace lifecycle end to end" do
    root =
      Path.join(System.tmp_dir!(), "minga-explicit-project-#{System.unique_integer([:positive])}")

    file = Path.join(root, "inside.txt")
    File.mkdir_p!(root)
    File.write!(file, "content")
    {_output, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["add", "inside.txt"], cd: root, stderr_to_stdout: true)

    on_exit(fn ->
      Project.close()
      _ = :sys.get_state(Project)
      Project.remove(root)
      _ = :sys.get_state(Project)
      File.rm_rf!(root)
    end)

    Project.close()
    _ = :sys.get_state(Project)
    Minga.Events.subscribe(:project_rebuilt)
    state = TestHelpers.base_state(content: "buffer")

    state = ProjectSource.on_select(%Item{id: root, label: Path.basename(root)}, state)

    assert Project.root() == root
    assert %Minga.Project.Root{kind: :directory, path: ^root} = Project.workspace_root()
    assert EditorState.file_tree_state(state).project_root == root
    assert root in Project.known_projects()

    assert_receive {:minga_event, :project_rebuilt,
                    %Minga.Events.ProjectRebuiltEvent{root: ^root}},
                   5_000

    refute_receive {:minga_event, :project_rebuilt,
                    %Minga.Events.ProjectRebuiltEvent{root: ^root}},
                   100

    Minga.Events.broadcast(
      :buffer_opened,
      %Minga.Events.BufferEvent{buffer: self(), path: file}
    )

    _ = :sys.get_state(Project)
    assert Project.recent_files() == ["inside.txt"]
    assert Project.frecency_scores()["inside.txt"] > 0
  end

  test "closing a project clears the service and file tree root", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(root)
    Project.switch(root)
    _ = :sys.get_state(Project)

    state =
      TestHelpers.base_state(content: "buffer")
      |> set_file_tree_root(root)

    state = ProjectCommands.execute(state, :project_close)
    _ = :sys.get_state(Project)

    assert Project.root() == nil
    assert Project.workspace_root() == nil
    assert EditorState.file_tree_state(state).project_root == nil
  end

  @spec set_file_tree_root(EditorState.t(), String.t()) :: EditorState.t()
  defp set_file_tree_root(state, root) do
    file_tree = FileTreeState.set_project_root(state.workspace.file_tree, root)
    %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree)}
  end
end
