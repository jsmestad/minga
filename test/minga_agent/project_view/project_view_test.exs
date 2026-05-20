defmodule MingaAgent.ProjectViewTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProjectView

  @moduletag :tmp_dir

  describe "shared backend contract" do
    test "runs the same file contract against direct and overlay backends", %{tmp_dir: dir} do
      for {name, create_view} <- backend_factories() do
        backend_dir = Path.join(dir, Atom.to_string(name))
        seed_project(backend_dir)
        {:ok, view} = create_view.(backend_dir)
        assert_shared_file_contract(view)
        ProjectView.discard(view)
      end
    end
  end

  describe "direct backend contract" do
    test "read/write/edit/delete/list/diff/discard use logical relative paths", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, view} = ProjectView.direct(dir, workspace_id: 7)

      assert view.workspace_id == 7
      assert view.project_root == Path.expand(dir)
      assert ProjectView.working_dir(view) == Path.expand(dir)
      assert ProjectView.command_env(view) == []
      assert %{isolation: :none, mutates_project_root: true} = ProjectView.capabilities(view)

      assert {:ok, "one\n"} = ProjectView.read_file(view, "lib/a.txt")
      assert :ok = ProjectView.write_file(view, "lib/new.txt", "new")
      assert {:ok, "new"} = File.read(Path.join(dir, "lib/new.txt"))
      assert :ok = ProjectView.edit_file(view, "lib/a.txt", "one", "ONE")
      assert {:ok, "ONE\n"} = ProjectView.read_file(view, "lib/a.txt")

      assert {:ok, entries} = ProjectView.list_directory(view, "lib")
      assert %{name: "a.txt", type: :file} in entries
      assert %{name: "new.txt", type: :file} in entries

      assert :ok = ProjectView.delete_file(view, "lib/a.txt")
      assert {:error, :enoent} = ProjectView.read_file(view, "lib/a.txt")
      refute File.exists?(Path.join(dir, "lib/a.txt"))

      assert {:ok, diff} = ProjectView.diff(view)
      assert %{path: "lib/new.txt", kind: :modified} in diff
      assert %{path: "lib/a.txt", kind: :deleted} in diff

      assert :ok = ProjectView.promote(view, :project_root)
      assert :ok = ProjectView.discard(view)
      assert {:ok, []} = ProjectView.diff(view)
    end
  end

  describe "overlay backend contract" do
    test "read/write/edit/delete/list/diff/promote/discard stay isolated until promote", %{
      tmp_dir: dir
    } do
      seed_project(dir)
      {:ok, view} = ProjectView.overlay(dir, workspace_id: 9)

      assert view.workspace_id == 9
      assert view.project_root == Path.expand(dir)
      assert ProjectView.working_dir(view) != Path.expand(dir)
      assert File.dir?(ProjectView.working_dir(view))

      assert {"MIX_BUILD_PATH", _} =
               List.keyfind(ProjectView.command_env(view), "MIX_BUILD_PATH", 0)

      assert %{isolation: :overlay, mutates_project_root: false} = ProjectView.capabilities(view)

      assert {:ok, "one\n"} = ProjectView.read_file(view, "lib/a.txt")
      assert :ok = ProjectView.write_file(view, "lib/new.txt", "new")
      assert :ok = ProjectView.edit_file(view, "lib/a.txt", "one", "ONE")
      assert {:ok, "ONE\n"} = ProjectView.read_file(view, "lib/a.txt")
      assert {:ok, "one\n"} = File.read(Path.join(dir, "lib/a.txt"))
      refute File.exists?(Path.join(dir, "lib/new.txt"))

      assert {:ok, entries} = ProjectView.list_directory(view, "lib")
      assert %{name: "new.txt", type: :file} in entries

      assert :ok = ProjectView.delete_file(view, "lib/a.txt")
      assert {:error, :deleted} = ProjectView.read_file(view, "lib/a.txt")
      assert {:ok, entries_after_delete} = ProjectView.list_directory(view, "lib")
      refute Enum.any?(entries_after_delete, &(&1.name == "a.txt"))
      assert File.exists?(Path.join(dir, "lib/a.txt"))

      assert {:ok, diff} = ProjectView.diff(view)
      assert Enum.any?(diff, &(&1.path == "lib/new.txt" and &1.kind in [:new, :modified]))
      assert %{path: "lib/a.txt", kind: :deleted, size: 0} in diff

      assert :ok = ProjectView.promote(view, :project_root)
      assert {:ok, "new"} = File.read(Path.join(dir, "lib/new.txt"))
      refute File.exists?(Path.join(dir, "lib/a.txt"))
    end

    test "promote returns structured conflicts without stopping the overlay", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, view} = ProjectView.overlay(dir)

      assert :ok = ProjectView.write_file(view, "lib/a.txt", "agent version")
      File.write!(Path.join(dir, "lib/a.txt"), "current file version")

      assert {:conflict, %{conflicts: [{:conflict, "lib/a.txt", :concurrent_edit}]}} =
               ProjectView.promote(view, :project_root)

      assert {:ok, "agent version"} = ProjectView.read_file(view, "lib/a.txt")
    end

    test "discard removes overlay changes without mutating project root", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, view} = ProjectView.overlay(dir)

      assert :ok = ProjectView.write_file(view, "lib/new.txt", "new")
      assert :ok = ProjectView.edit_file(view, "lib/a.txt", "one", "ONE")
      assert :ok = ProjectView.discard(view)

      refute File.exists?(Path.join(dir, "lib/new.txt"))
      assert {:ok, "one\n"} = File.read(Path.join(dir, "lib/a.txt"))
    end
  end

  describe "path validation" do
    test "rejects absolute paths and traversal", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, view} = ProjectView.direct(dir)

      assert {:error, :path_traversal} = ProjectView.read_file(view, "/etc/passwd")
      assert {:error, :path_traversal} = ProjectView.read_file(view, "../outside")
      assert {:error, :invalid_path} = ProjectView.read_file(view, "")
      assert {:ok, _entries} = ProjectView.list_directory(view, ".")
    end
  end

  defp backend_factories do
    [
      direct: &ProjectView.direct/1,
      overlay: &ProjectView.overlay/1
    ]
  end

  defp assert_shared_file_contract(view) do
    assert {:ok, "one\n"} = ProjectView.read_file(view, "lib/a.txt")
    assert :ok = ProjectView.write_file(view, "lib/shared.txt", "shared")
    assert {:ok, "shared"} = ProjectView.read_file(view, "lib/shared.txt")
    assert :ok = ProjectView.edit_file(view, "lib/shared.txt", "shared", "changed")
    assert {:ok, "changed"} = ProjectView.read_file(view, "lib/shared.txt")
    assert :ok = ProjectView.delete_file(view, "lib/shared.txt")
    assert {:error, _reason} = ProjectView.read_file(view, "lib/shared.txt")
    assert {:ok, entries} = ProjectView.list_directory(view, "lib")
    assert %{name: "a.txt", type: :file} in entries
    assert is_binary(ProjectView.working_dir(view))
    assert is_list(ProjectView.command_env(view))
    assert %{mutates_project_root: _} = ProjectView.capabilities(view)
    assert {:ok, diff} = ProjectView.diff(view)
    assert is_list(diff)
  end

  defp seed_project(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.txt"), "one\n")
    File.write!(Path.join(dir, "README.md"), "readme\n")
  end
end
