defmodule MingaEditor.UI.Picker.FileSourceAsyncTest do
  @moduledoc "Tests FileSource behavior that does not mutate the global project singleton."

  use ExUnit.Case, async: false

  alias Minga.Project
  alias Minga.Project.Root
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.FileTree
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ProjectFileCandidate

  @moduletag :tmp_dir

  setup do
    original_workspace = Project.snapshot()
    on_exit(fn -> restore_project(original_workspace) end)
    :ok
  end

  test "on_bulk_select opens all marked project-relative files", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "bulk_project_#{:erlang.unique_integer([:positive])}")
    lib = Path.join(project, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(lib, "one.ex"), "one")
    File.write!(Path.join(lib, "two.ex"), "two")

    {:ok, root} = Root.directory(project)
    activation_id = activate_project!(root).activation_id

    state =
      TestHelpers.base_state(content: "initial")
      |> set_file_tree(%FileTree{project_root: project})

    initial_pids = state.workspace.buffers.list

    state =
      FileSource.on_bulk_select(
        [
          %Item{id: candidate!(root, "lib/one.ex", activation_id), label: "one.ex"},
          %Item{id: candidate!(root, "lib/two.ex", activation_id), label: "two.ex"}
        ],
        state
      )

    paths = Enum.map(state.workspace.buffers.list, &Minga.Buffer.file_path/1)
    new_pids = Enum.reject(state.workspace.buffers.list, &Enum.member?(initial_pids, &1))
    on_exit(fn -> Enum.each(new_pids, &stop_pid/1) end)

    assert Path.join(lib, "one.ex") in paths
    assert Path.join(lib, "two.ex") in paths
    assert Minga.Buffer.file_path(state.workspace.buffers.active) == Path.join(lib, "two.ex")
  end

  test "no-workspace picker returns no candidates without a cwd fallback" do
    context =
      TestHelpers.base_state(content: "loose file")
      |> Context.from_editor_state(%{project_root: nil})

    assert FileSource.candidates(context) == []
  end

  test "inactive picker roots do not start direct inventory", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "inactive-project")
    File.mkdir_p!(project)
    File.write!(Path.join(project, "would-have-been-scanned.txt"), "content")
    {:ok, root} = Root.directory(project)

    context =
      TestHelpers.base_state(content: "loose file")
      |> Context.from_editor_state(%{project_root: root})

    assert FileSource.candidates(context) == []
  end

  test "async fetch preserves an explicit project service failure" do
    context =
      TestHelpers.base_state(content: "loose file")
      |> Context.from_editor_state(%{project_error: "Project service is unavailable"})

    assert FileSource.async_fetch(context) == {:error, "Project service is unavailable"}
  end

  test "selection uses the candidate root after the file tree changes", %{tmp_dir: tmp_dir} do
    original_root = Path.join(tmp_dir, "original")
    current_tree_root = Path.join(tmp_dir, "current")
    File.mkdir_p!(original_root)
    File.mkdir_p!(current_tree_root)
    File.write!(Path.join(original_root, "same.txt"), "original")
    File.write!(Path.join(current_tree_root, "same.txt"), "current")
    {:ok, root} = Root.directory(original_root)
    activation_id = activate_project!(root).activation_id

    state =
      TestHelpers.base_state(content: "initial")
      |> set_file_tree(%FileTree{project_root: current_tree_root})

    initial_pids = state.workspace.buffers.list
    item = %Item{id: candidate!(root, "same.txt", activation_id), label: "same.txt"}
    state = FileSource.on_select(item, state)
    new_pids = Enum.reject(state.workspace.buffers.list, &Enum.member?(initial_pids, &1))
    on_exit(fn -> Enum.each(new_pids, &stop_pid/1) end)

    assert Minga.Buffer.file_path(state.workspace.buffers.active) ==
             Path.join(original_root, "same.txt")
  end

  test "offered actions omit Delete and stale delete delivery preserves disk bytes", %{
    tmp_dir: tmp_dir
  } do
    project = Path.join(tmp_dir, "stale-delete")
    path = Path.join(project, "kept.txt")
    bytes = <<0, 1, 2, "keep me">>
    File.mkdir_p!(project)
    File.write!(path, bytes)
    {:ok, root} = Root.directory(project)

    state = TestHelpers.base_state(content: "initial")
    item = %Item{id: candidate!(root, "kept.txt"), label: "kept.txt"}

    assert FileSource.actions(item) == [{"Open", :open}]
    assert FileSource.on_action(:delete, item, state) == state
    assert File.read!(path) == bytes
  end

  test "bulk actions expose open all marked", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(tmp_dir)
    {:ok, root} = Root.directory(tmp_dir)

    assert FileSource.bulk_actions([
             %Item{id: candidate!(root, "lib/one.ex"), label: "one.ex"}
           ]) == [{"Open all marked", :open_marked}]
  end

  describe "enrich/1" do
    test "builds icon, color, two-line description, and git annotation for winners", %{
      tmp_dir: tmp_dir
    } do
      {:ok, root} = Root.directory(tmp_dir)
      candidate = candidate!(root, "lib/foo/bar.ex")

      lean = %Item{
        id: candidate,
        label: "bar.ex",
        search_text: "lib/foo/bar.ex",
        meta: %{git: :modified}
      }

      [enriched] = FileSource.enrich([lean])

      assert enriched.id == candidate
      assert String.ends_with?(enriched.label, " bar.ex")
      assert String.first(enriched.label) != "b"
      assert enriched.description == "lib/foo"
      assert enriched.annotation == "M"
      assert enriched.two_line == false
      assert is_integer(enriched.icon_color)
    end

    test "uses an empty description for root-level files and no git annotation", %{
      tmp_dir: tmp_dir
    } do
      {:ok, root} = Root.directory(tmp_dir)

      lean = %Item{
        id: candidate!(root, "mix.exs"),
        label: "mix.exs",
        search_text: "mix.exs",
        meta: %{git: nil}
      }

      [enriched] = FileSource.enrich([lean])
      assert enriched.description == ""
      assert enriched.annotation == nil
    end
  end

  @spec candidate!(Root.t(), String.t(), Minga.Project.WorkspaceSnapshot.activation_id() | nil) ::
          ProjectFileCandidate.t()
  defp candidate!(root, path, activation_id \\ nil) do
    {:ok, candidate} = ProjectFileCandidate.new(root, path, activation_id)
    candidate
  end

  @spec activate_project!(Root.t()) :: Minga.Project.WorkspaceSnapshot.t()
  defp activate_project!(%Root{path: path} = root) do
    Minga.Events.subscribe(:project_rebuilt)
    assert {:ok, snapshot} = Project.activate(root)

    if snapshot.rebuilding? do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^path}},
                     5_000
    end

    _ = :sys.get_state(Project)
    Project.snapshot()
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

  @spec set_file_tree(MingaEditor.State.t(), FileTree.t()) :: MingaEditor.State.t()
  defp set_file_tree(state, file_tree) do
    %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree)}
  end

  defp stop_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
