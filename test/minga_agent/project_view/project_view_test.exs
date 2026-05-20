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

    test "rejects symlink escapes through linked directories", %{tmp_dir: dir} do
      seed_project(dir)
      outside_dir = Path.join(Path.dirname(dir), "outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(outside_dir, "nested"))
      File.write!(Path.join(outside_dir, "nested/secret.txt"), "secret\n")
      File.ln_s!(outside_dir, Path.join(dir, "linked"))

      {:ok, view} = ProjectView.direct(dir)

      assert {:error, :symlink_traversal} =
               ProjectView.read_file(view, "linked/nested/secret.txt")

      assert {:error, :symlink_traversal} = ProjectView.write_file(view, "linked/new.txt", "new")

      assert {:error, :symlink_traversal} =
               ProjectView.edit_file(view, "linked/nested/secret.txt", "secret", "public")

      assert {:error, :symlink_traversal} =
               ProjectView.delete_file(view, "linked/nested/secret.txt")

      assert {:error, :symlink_traversal} = ProjectView.list_directory(view, "linked")
      assert {:ok, "one\n"} = ProjectView.read_file(view, "lib/a.txt")
    end

    test "allows a final symlinked file when it resolves inside the project root", %{tmp_dir: dir} do
      seed_project(dir)
      File.ln_s!(Path.join(dir, "lib/a.txt"), Path.join(dir, "alias.txt"))

      {:ok, view} = ProjectView.direct(dir)

      assert {:ok, "one\n"} = ProjectView.read_file(view, "alias.txt")
      assert :ok = ProjectView.edit_file(view, "alias.txt", "one", "ONE")
      assert {:ok, "ONE\n"} = ProjectView.read_file(view, "alias.txt")
      assert {:ok, "ONE\n"} = File.read(Path.join(dir, "lib/a.txt"))
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

    test "rejects promote when a tracked project file becomes a symlink escape", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, view} = ProjectView.overlay(dir)

      assert :ok = ProjectView.edit_file(view, "lib/a.txt", "one", "ONE")

      outside_dir = Path.join(Path.dirname(dir), "outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside_dir)
      File.write!(Path.join(outside_dir, "secret.txt"), "secret\n")
      File.rm!(Path.join(dir, "lib/a.txt"))
      File.ln_s!(Path.join(outside_dir, "secret.txt"), Path.join(dir, "lib/a.txt"))

      assert {:error, :symlink_traversal} = ProjectView.promote(view, :project_root)
      assert {:ok, diff} = ProjectView.diff(view)
      assert Enum.any?(diff, &(&1.path == "lib/a.txt" and &1.kind == :modified))
      assert {:ok, "secret\n"} = File.read(Path.join(outside_dir, "secret.txt"))
    end

    test "rejects symlink escapes through linked directories", %{tmp_dir: dir} do
      seed_project(dir)
      outside_dir = Path.join(Path.dirname(dir), "outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(outside_dir, "nested"))
      File.write!(Path.join(outside_dir, "nested/secret.txt"), "secret\n")
      File.ln_s!(outside_dir, Path.join(dir, "linked"))

      {:ok, view} = ProjectView.overlay(dir)

      assert {:error, :symlink_traversal} =
               ProjectView.read_file(view, "linked/nested/secret.txt")

      assert {:error, :symlink_traversal} = ProjectView.write_file(view, "linked/new.txt", "new")

      assert {:error, :symlink_traversal} =
               ProjectView.edit_file(view, "linked/nested/secret.txt", "secret", "public")

      assert {:error, :symlink_traversal} =
               ProjectView.delete_file(view, "linked/nested/secret.txt")

      assert {:error, :symlink_traversal} = ProjectView.list_directory(view, "linked")
      assert {:ok, "one\n"} = File.read(Path.join(dir, "lib/a.txt"))
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

    test "promote returns fork merge failures without mutating project root", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, store} = start_supervised(MingaAgent.BufferForkStore)

      {:ok, parent} =
        start_supervised({Minga.Buffer.Process, content: "one\ntwo\nthree\n", name: nil},
          id: :overlay_parent
        )

      fork_path = Path.join(dir, "lib/a.txt")
      {:ok, fork_pid} = MingaAgent.BufferForkStore.get_or_create(store, fork_path, parent)
      Minga.Buffer.Fork.replace_content(fork_pid, "one\nfork two\nthree\n")
      Minga.Buffer.Process.replace_content(parent, "one\nparent two\nthree\n", :agent)

      {:ok, view} = ProjectView.overlay(dir, fork_store: store)
      assert :ok = ProjectView.write_file(view, "lib/new.txt", "new")
      assert :ok = ProjectView.edit_file(view, "lib/a.txt", "one", "ONE")

      assert {:error, {:fork_merge_failed, failures}} = ProjectView.promote(view, :project_root)
      assert [{^fork_path, {:conflict, _}}] = failures
      refute File.exists?(Path.join(dir, "lib/new.txt"))
      assert {:ok, "one\n"} = File.read(Path.join(dir, "lib/a.txt"))
      assert {:ok, "new"} = ProjectView.read_file(view, "lib/new.txt")
      assert {:ok, "ONE\n"} = ProjectView.read_file(view, "lib/a.txt")
      assert MingaAgent.BufferForkStore.get(store, fork_path) == fork_pid
      assert Minga.Buffer.Fork.dirty?(fork_pid)
    end

    test "diff omits forks outside the project root", %{tmp_dir: dir} do
      %{view: view, store: store, in_root_path: in_root_path, outside_path: outside_path} =
        seed_overlay_with_scoped_forks(dir)

      assert {:ok, diff} = ProjectView.diff(view)
      assert Enum.any?(diff, &(&1.path == Path.relative_to(in_root_path, dir)))
      refute Enum.any?(diff, &(&1.path == outside_path))
      assert MingaAgent.BufferForkStore.get(store, outside_path) != nil
    end

    test "promote only merges forks under the project root and leaves unrelated forks untouched",
         %{
           tmp_dir: dir
         } do
      %{
        view: view,
        store: store,
        in_root_path: in_root_path,
        outside_path: outside_path,
        outside_fork: outside_fork
      } = seed_overlay_with_scoped_forks(dir)

      assert :ok = ProjectView.promote(view, :project_root)
      assert {:ok, "in-root promoted\n"} = File.read(in_root_path)
      assert {:ok, "outside original\n"} = File.read(outside_path)
      assert nil == MingaAgent.BufferForkStore.get(store, in_root_path)
      assert MingaAgent.BufferForkStore.get(store, outside_path) == outside_fork
      assert Minga.Buffer.Fork.dirty?(outside_fork)
    end

    test "discard only removes forks under the project root and leaves unrelated forks untouched",
         %{
           tmp_dir: dir
         } do
      %{
        view: view,
        store: store,
        in_root_path: in_root_path,
        outside_path: outside_path,
        outside_fork: outside_fork
      } = seed_overlay_with_scoped_forks(dir)

      assert :ok = ProjectView.discard(view)
      assert {:ok, "one\n"} = File.read(in_root_path)
      assert {:ok, "outside original\n"} = File.read(outside_path)
      assert nil == MingaAgent.BufferForkStore.get(store, in_root_path)
      assert MingaAgent.BufferForkStore.get(store, outside_path) == outside_fork
      assert Minga.Buffer.Fork.dirty?(outside_fork)
    end

    test "rejects promoting fork paths that escape through a symlink", %{tmp_dir: dir} do
      seed_project(dir)
      outside_dir = Path.join(Path.dirname(dir), "outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside_dir)
      File.write!(Path.join(outside_dir, "secret.txt"), "secret\n")
      File.ln_s!(outside_dir, Path.join(dir, "linked"))

      {:ok, store} = start_supervised(MingaAgent.BufferForkStore)

      {:ok, parent} =
        start_supervised({Minga.Buffer.Process, content: "one\n", name: nil},
          id: :symlink_overlay_parent
        )

      fork_path = Path.join(dir, "linked/secret.txt")
      {:ok, fork_pid} = MingaAgent.BufferForkStore.get_or_create(store, fork_path, parent)
      Minga.Buffer.Fork.replace_content(fork_pid, "changed\n")

      {:ok, view} = ProjectView.overlay(dir, fork_store: store)

      assert {:error, {:fork_path_outside_project_root, ^fork_path, :symlink_traversal}} =
               ProjectView.promote(view, :project_root)

      assert MingaAgent.BufferForkStore.get(store, fork_path) == fork_pid
      assert Minga.Buffer.Fork.dirty?(fork_pid)
      assert {:ok, "secret\n"} = File.read(Path.join(outside_dir, "secret.txt"))
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

  defp seed_overlay_with_scoped_forks(dir) do
    seed_project(dir)

    {:ok, store} = start_supervised(MingaAgent.BufferForkStore)

    {:ok, parent} =
      start_supervised({Minga.Buffer.Process, content: "one\n", name: nil},
        id: :scoped_overlay_parent
      )

    in_root_path = Path.join(dir, "lib/a.txt")
    {:ok, in_root_fork} = MingaAgent.BufferForkStore.get_or_create(store, in_root_path, parent)
    Minga.Buffer.Fork.replace_content(in_root_fork, "in-root promoted\n")

    outside_dir = Path.join(Path.dirname(dir), "outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside_dir)
    outside_path = Path.join(outside_dir, "outside.txt")
    File.write!(outside_path, "outside original\n")

    {:ok, outside_fork} = MingaAgent.BufferForkStore.get_or_create(store, outside_path, parent)
    Minga.Buffer.Fork.replace_content(outside_fork, "outside changed\n")

    {:ok, view} = ProjectView.overlay(dir, fork_store: store)

    %{
      view: view,
      store: store,
      in_root_path: in_root_path,
      in_root_fork: in_root_fork,
      outside_path: outside_path,
      outside_fork: outside_fork
    }
  end
end
