defmodule MingaEditor.UI.Picker.FileSourceProjectSwitchTest do
  @moduledoc "Tests project-file choices against the globally registered Project."

  # Candidate production reroots the globally registered Project between workspaces.
  use ExUnit.Case, async: false

  alias Minga.Project
  alias Minga.Project.Root
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FileSource

  @moduletag :tmp_dir

  setup do
    original_workspace = Project.snapshot()
    on_exit(fn -> restore_project(original_workspace) end)
  end

  test "a stale picker context cannot read candidates from the replacement workspace", %{
    tmp_dir: tmp_dir
  } do
    project_a = Path.join(tmp_dir, "project_a")
    project_b = Path.join(tmp_dir, "project_b")
    File.mkdir_p!(project_a)
    File.mkdir_p!(project_b)
    File.write!(Path.join(project_a, "from-a.txt"), "A")
    File.write!(Path.join(project_b, "from-b.txt"), "B")
    {:ok, root_a} = Root.directory(project_a)
    {:ok, root_b} = Root.directory(project_b)

    activate_project!(root_a)

    stale_context =
      TestHelpers.base_state(content: "initial")
      |> Context.from_editor_state(%{project_root: root_a})

    assert Enum.any?(FileSource.candidates(stale_context), &(&1.id == "from-a.txt"))

    activate_project!(root_b)
    assert "from-b.txt" in Project.files()

    assert FileSource.candidates(stale_context) == []
  end

  @spec activate_project!(Root.t()) :: :ok
  defp activate_project!(%Root{path: path} = root) do
    Minga.Events.subscribe(:project_rebuilt)
    assert {:ok, snapshot} = Project.activate(root)

    if snapshot.rebuilding? do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^path}},
                     5_000
    end

    _ = :sys.get_state(Project)
    :ok
  end

  @spec restore_project(Minga.Project.WorkspaceSnapshot.t() | nil) :: :ok
  defp restore_project(nil) do
    Project.close()
    _ = :sys.get_state(Project)
    :ok
  end

  defp restore_project(%Minga.Project.WorkspaceSnapshot{root: root}) do
    Project.close()
    _ = :sys.get_state(Project)
    _ = Project.activate(root)
    :ok
  end
end
