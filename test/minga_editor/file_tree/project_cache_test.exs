defmodule MingaEditor.FileTree.ProjectCacheTest do
  use ExUnit.Case, async: true

  alias Minga.Project
  alias Minga.Project.Root
  alias Minga.Project.WorkspaceSnapshot
  alias MingaEditor.FileTree.ProjectCache
  alias MingaEditor.FileTree.ProjectCache.Snapshot

  @moduletag :tmp_dir

  test "derives one tree cache value from the Project workspace snapshot", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "project")
    other = Path.join(tmp_dir, "other")
    File.mkdir_p!(project)
    File.mkdir_p!(other)
    {:ok, root} = Root.directory(project)
    server = start_project!()

    assert {:ok, %WorkspaceSnapshot{root: ^root, files: [], rebuilding?: true}} =
             Project.activate(server, root)

    assert %Snapshot{root: ^project, active?: true, files: [], rebuilding?: true} =
             ProjectCache.snapshot(project, server)

    assert %Snapshot{root: ^other, active?: false, files: [], rebuilding?: false} =
             ProjectCache.snapshot(other, server)

    Minga.Events.subscribe(:project_rebuilt)
    worker = :sys.get_state(server).rebuild_pid
    :ok = Minga.Project.SlowFileFind.complete(worker, {:ok, ["lib/app.ex"]})

    assert_receive {:minga_event, :project_rebuilt,
                    %Minga.Events.ProjectRebuiltEvent{root: ^project}},
                   1_000

    assert %Snapshot{
             root: ^project,
             active?: true,
             files: ["lib/app.ex"],
             rebuilding?: false
           } = ProjectCache.snapshot(project, server)
  end

  defp start_project! do
    name = :"project_cache_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Project,
         name: name,
         subscribe: false,
         command_frecency: %{},
         file_find_module: Minga.Project.SlowFileFind},
        id: make_ref()
      )
    )

    name
  end
end
