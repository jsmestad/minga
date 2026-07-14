defmodule MingaEditor.Shell.Traditional.TodoSearchWorkflowTest do
  # The workflow reads and mutates the process-global Project workspace.
  use ExUnit.Case, async: false

  alias Minga.Project
  alias Minga.Project.Root
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.TodoSearch
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.TodoSearchWorkflow
  alias MingaEditor.State.FileTree

  setup do
    original_workspace = Project.snapshot()

    on_exit(fn ->
      restore_project(original_workspace)
    end)

    :ok
  end

  test "schedules only the active typed Root and ignores the file-tree path" do
    active_path = temporary_root("active")
    stale_file_tree_path = temporary_root("stale-file-tree")
    {:ok, active_root} = Root.directory(active_path)
    activate_project!(active_root)
    scheduler = start_scheduler()

    state =
      TestHelpers.base_state(effect_scheduler: scheduler)
      |> put_file_tree_root(stale_file_tree_path)
      |> TodoSearchWorkflow.open()

    assert {:picker, %{picker_ui: %{load_status: :loading}}} =
             Runtime.state(state.shell_runtime).modal

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      status: :running,
                      request: %Request{
                        resource: {:todo_search, ^active_root},
                        effect: %TodoSearch{root: ^active_root}
                      }
                    }}
  end

  test "does not reconstruct a Root from the file-tree path when no workspace is active" do
    Project.close()
    _ = :sys.get_state(Project)
    file_tree_path = temporary_root("file-tree-only")
    scheduler = start_scheduler()

    state =
      TestHelpers.base_state(effect_scheduler: scheduler)
      |> put_file_tree_root(file_tree_path)
      |> TodoSearchWorkflow.open()

    assert {:picker, %{picker_ui: %{load_status: {:error, "No directory workspace active"}}}} =
             Runtime.state(state.shell_runtime).modal

    refute_received {:effect_lifecycle, %Outcome{request: %Request{handler: TodoSearch}}}
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

    :ok
  end

  @spec start_scheduler() :: pid()
  defp start_scheduler do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: task_supervisor, observer: self()},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())
    scheduler
  end

  @spec put_file_tree_root(MingaEditor.State.t(), String.t()) :: MingaEditor.State.t()
  defp put_file_tree_root(state, root_path) do
    file_tree = FileTree.set_project_root(state.workspace.file_tree, root_path)
    %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree)}
  end

  @spec temporary_root(String.t()) :: String.t()
  defp temporary_root(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "minga-todo-workflow-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      Project.remove(path)
      _ = :sys.get_state(Project)
      File.rm_rf(path)
    end)

    path
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
