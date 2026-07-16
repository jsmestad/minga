defmodule MingaEditor.UI.Picker.FileSourceAsyncTest do
  @moduledoc "Tests FileSource behavior that does not mutate the global project singleton."

  use ExUnit.Case, async: true

  alias Minga.Project.Root
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.FileTree
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ProjectFileCandidate

  @moduletag :tmp_dir

  test "on_bulk_select opens all marked project-relative files", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "bulk_project_#{:erlang.unique_integer([:positive])}")
    lib = Path.join(project, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(lib, "one.ex"), "one")
    File.write!(Path.join(lib, "two.ex"), "two")

    {:ok, root} = Root.directory(project)

    state =
      TestHelpers.base_state(content: "initial")
      |> set_file_tree(%FileTree{project_root: project})

    initial_pids = state.workspace.buffers.list

    state =
      FileSource.on_bulk_select(
        [
          %Item{id: candidate!(root, "lib/one.ex"), label: "one.ex"},
          %Item{id: candidate!(root, "lib/two.ex"), label: "two.ex"}
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

  test "selection uses the candidate root after the file tree changes", %{tmp_dir: tmp_dir} do
    original_root = Path.join(tmp_dir, "original")
    current_tree_root = Path.join(tmp_dir, "current")
    File.mkdir_p!(original_root)
    File.mkdir_p!(current_tree_root)
    File.write!(Path.join(original_root, "same.txt"), "original")
    File.write!(Path.join(current_tree_root, "same.txt"), "current")
    {:ok, root} = Root.directory(original_root)

    state =
      TestHelpers.base_state(content: "initial")
      |> set_file_tree(%FileTree{project_root: current_tree_root})

    initial_pids = state.workspace.buffers.list
    item = %Item{id: candidate!(root, "same.txt"), label: "same.txt"}
    state = FileSource.on_select(item, state)
    new_pids = Enum.reject(state.workspace.buffers.list, &Enum.member?(initial_pids, &1))
    on_exit(fn -> Enum.each(new_pids, &stop_pid/1) end)

    assert Minga.Buffer.file_path(state.workspace.buffers.active) ==
             Path.join(original_root, "same.txt")
  end

  test "delete unlinks an authorized symlink without deleting its target", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "symlink-delete")
    target = Path.join(project, "target.txt")
    link = Path.join(project, "link.txt")
    File.mkdir_p!(project)
    File.write!(target, "keep me")
    File.ln_s!("target.txt", link)
    {:ok, root} = Root.directory(project)

    state = TestHelpers.base_state(content: "initial")
    item = %Item{id: candidate!(root, "link.txt"), label: "link.txt"}

    assert FileSource.on_action(:delete, item, state) == state
    assert {:error, :enoent} = File.lstat(link)
    assert File.read!(target) == "keep me"
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

  @spec candidate!(Root.t(), String.t()) :: ProjectFileCandidate.t()
  defp candidate!(root, path) do
    {:ok, candidate} = ProjectFileCandidate.new(root, path)
    candidate
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
