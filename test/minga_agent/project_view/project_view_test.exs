defmodule MingaAgent.ProjectViewTest do
  use ExUnit.Case, async: true

  alias MingaAgent.BufferForkStore
  alias MingaAgent.ProjectView

  @moduletag :tmp_dir

  describe "shared backend contract" do
    test "runs the same file contract against direct and overlay backends", %{tmp_dir: dir} do
      for {name, create_view} <- backend_factories() do
        backend_dir = Path.join(dir, Atom.to_string(name))
        seed_project(backend_dir)
        {:ok, view} = create_view.(backend_dir)
        assert_shared_file_contract(view)

        if ProjectView.capabilities(view).supports_discard do
          assert :ok = ProjectView.discard(view)
        else
          assert {:error, :discard_not_supported} = ProjectView.discard(view)
        end

        assert :ok = ProjectView.close(view)
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

      assert %{isolation: :none, mutates_project_root: true, supports_discard: false} =
               ProjectView.capabilities(view)

      assert {:ok, "one\n"} = ProjectView.read_file(view, "lib/a.txt")
      assert :ok = ProjectView.write_file(view, "lib/new.txt", "new")
      assert {:ok, "new"} = File.read(Path.join(dir, "lib/new.txt"))
      assert :ok = ProjectView.edit_file(view, "lib/a.txt", "one", "ONE")
      assert {:ok, "ONE\n"} = ProjectView.read_file(view, "lib/a.txt")

      File.write!(Path.join(dir, "lib/ambiguous.txt"), "hello world hello world\n")

      assert {:error, "old_text is empty"} =
               ProjectView.edit_file(view, "lib/a.txt", "", "ignored")

      assert {:error, "old_text found 2 times (ambiguous)"} =
               ProjectView.edit_file(view, "lib/ambiguous.txt", "hello world", "goodbye")

      assert {:ok, "hello world hello world\n"} = File.read(Path.join(dir, "lib/ambiguous.txt"))

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
      assert {:error, :discard_not_supported} = ProjectView.discard(view)
      assert {:ok, diff_after_discard} = ProjectView.diff(view)
      assert %{path: "lib/new.txt", kind: :modified} in diff_after_discard
      assert %{path: "lib/a.txt", kind: :deleted} in diff_after_discard
    end

    test "direct backend discard_file and discard are not supported", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, view} = ProjectView.direct(dir)

      assert {:error, :discard_not_supported} = ProjectView.discard_file(view, "lib/a.txt")
      assert {:error, :discard_not_supported} = ProjectView.discard(view)
    end

    test "dead direct backend write/edit/delete leave the real project unchanged", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, view} = ProjectView.direct(dir)
      old_trap_exit = Process.flag(:trap_exit, true)
      view_ref = view.ref
      Process.exit(view_ref, :kill)
      assert_receive {:EXIT, ^view_ref, :killed}
      Process.flag(:trap_exit, old_trap_exit)

      assert {:error, {:direct_view_unavailable, _}} =
               ProjectView.write_file(view, "lib/new.txt", "new")

      assert {:error, {:direct_view_unavailable, _}} =
               ProjectView.edit_file(view, "lib/a.txt", "one", "ONE")

      assert {:error, {:direct_view_unavailable, _}} =
               ProjectView.delete_file(view, "lib/a.txt")

      assert {:ok, "one\n"} = File.read(Path.join(dir, "lib/a.txt"))
      refute File.exists?(Path.join(dir, "lib/new.txt"))
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

    test "open-buffer edits route through the view-owned fork store and show up in diff", %{
      tmp_dir: dir
    } do
      seed_project(dir)
      path = Path.join(dir, "lib/a.txt")

      {:ok, _buffer} =
        start_supervised({Minga.Buffer.Process, content: File.read!(path), file_path: path})

      {:ok, view} = ProjectView.overlay(dir)

      assert is_pid(view.ref.fork_store)
      assert {:ok, "one\n"} = ProjectView.read_file(view, "lib/a.txt")
      assert :ok = ProjectView.write_file(view, "lib/a.txt", "forked\n")
      assert :ok = ProjectView.edit_file(view, "lib/a.txt", "forked", "edited")
      assert {:ok, "edited\n"} = ProjectView.read_file(view, "lib/a.txt")
      assert File.read!(path) == "one\n"

      assert {:ok, diff} = ProjectView.diff(view)
      assert %{path: "lib/a.txt", kind: :modified} in diff
    end

    test "dead fork stores fail diff without losing overlay state", %{tmp_dir: dir} do
      seed_project(dir)
      {dead_store, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_store, :normal}
      {:ok, view} = ProjectView.overlay(dir, fork_store: dead_store)

      assert :ok = ProjectView.write_file(view, "lib/new.txt", "new")
      assert {:error, {:fork_diff_failed, reason}} = ProjectView.diff(view)
      assert is_tuple(reason)
      assert {:ok, "new"} = ProjectView.read_file(view, "lib/new.txt")
    end

    test "dead fork stores fail promote without losing overlay state", %{tmp_dir: dir} do
      seed_project(dir)
      {dead_store, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_store, :normal}
      {:ok, view} = ProjectView.overlay(dir, fork_store: dead_store)

      assert :ok = ProjectView.write_file(view, "lib/new.txt", "new")
      assert {:error, {:fork_promote_failed, reason}} = ProjectView.promote(view, :project_root)
      assert is_tuple(reason)
      assert {:ok, "new"} = ProjectView.read_file(view, "lib/new.txt")
      refute File.exists?(Path.join(dir, "lib/new.txt"))
    end

    test "dead fork stores fail discard without changing unrelated overlay state", %{tmp_dir: dir} do
      seed_project(dir)
      {dead_store, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_store, :normal}
      {:ok, view} = ProjectView.overlay(dir, fork_store: dead_store)

      assert :ok = ProjectView.write_file(view, "lib/new.txt", "new")

      assert {:error, {:fork_discard_failed, reason}} =
               ProjectView.discard_file(view, "lib/untracked.txt")

      assert is_tuple(reason)
      assert {:ok, "new"} = ProjectView.read_file(view, "lib/new.txt")
      assert {:error, :enoent} = ProjectView.read_file(view, "lib/untracked.txt")
    end

    test "dead fork stores fail tracked discard without erasing overlay state", %{tmp_dir: dir} do
      seed_project(dir)
      {dead_store, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_store, :normal}
      {:ok, view} = ProjectView.overlay(dir, fork_store: dead_store)

      assert :ok = ProjectView.write_file(view, "lib/new.txt", "new")

      assert {:error, {:fork_discard_failed, reason}} =
               ProjectView.discard_file(view, "lib/new.txt")

      assert is_tuple(reason)
      assert {:ok, "new"} = ProjectView.read_file(view, "lib/new.txt")
    end

    test "dead fork stores fail full discard without losing overlay state", %{tmp_dir: dir} do
      seed_project(dir)
      {dead_store, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_store, :normal}
      {:ok, view} = ProjectView.overlay(dir, fork_store: dead_store)

      assert :ok = ProjectView.write_file(view, "lib/new.txt", "new")
      assert {:error, {:fork_discard_failed, reason}} = ProjectView.discard(view)

      assert is_tuple(reason)
      assert {:ok, "new"} = ProjectView.read_file(view, "lib/new.txt")
    end

    test "dead fork stores fail tracked discard without losing overlay state", %{tmp_dir: dir} do
      seed_project(dir)
      {dead_store, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_store, :normal}
      {:ok, view} = ProjectView.overlay(dir, fork_store: dead_store)

      assert :ok = ProjectView.write_file(view, "lib/a.txt", "draft")

      assert {:error, {:fork_discard_failed, reason}} =
               ProjectView.discard_file(view, "lib/a.txt")

      assert is_tuple(reason)
      assert {:ok, "draft"} = ProjectView.read_file(view, "lib/a.txt")
    end

    test "dead changesets return tagged working directory and listing errors", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, view} = ProjectView.overlay(dir)
      ref = Process.monitor(view.ref.changeset)
      Process.exit(view.ref.changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert {:error, {:changeset_unavailable, _}} = ProjectView.working_dir(view)
      assert {:error, {:changeset_unavailable, _}} = ProjectView.command_env(view)
      assert {:error, {:changeset_unavailable, _}} = ProjectView.list_directory(view, "lib")
    end
  end

  describe "close lifecycle" do
    test "stops owned fork store after successful discard", %{tmp_dir: dir} do
      %{view: view, store: store, parent: parent} = seed_overlay_with_open_fork(dir)
      store_ref = Process.monitor(store)
      changeset_ref = Process.monitor(view.ref.changeset)

      assert :ok = ProjectView.discard(view)
      assert_receive {:DOWN, ^changeset_ref, :process, _, _}
      assert BufferForkStore.all(store) == %{}
      assert "one\n" = Minga.Buffer.content(parent)

      assert :ok = ProjectView.close(view)
      assert_receive {:DOWN, ^store_ref, :process, ^store, _}
    end

    test "stops owned fork store after successful promote", %{tmp_dir: dir} do
      %{view: view, store: store, parent: parent} = seed_overlay_with_open_fork(dir)
      store_ref = Process.monitor(store)
      changeset_ref = Process.monitor(view.ref.changeset)

      assert :ok = ProjectView.promote(view, :project_root)
      assert_receive {:DOWN, ^changeset_ref, :process, _, _}
      assert BufferForkStore.all(store) == %{}
      assert "draft\n" = Minga.Buffer.content(parent)

      assert :ok = ProjectView.close(view)
      assert_receive {:DOWN, ^store_ref, :process, ^store, _}
    end

    test "keeps owned fork store alive when promote fails and drafts remain", %{tmp_dir: dir} do
      %{view: view, store: store, path: path} = seed_overlay_with_open_fork(dir)
      changeset_ref = Process.monitor(view.ref.changeset)

      Process.exit(view.ref.changeset, :kill)
      assert_receive {:DOWN, ^changeset_ref, :process, _, _}

      assert {:error, {:changeset_unavailable, _}} = ProjectView.promote(view, :project_root)
      assert {:error, {:close_blocked, :fork_store_dirty}} = ProjectView.close(view)
      assert Map.has_key?(BufferForkStore.all(store), path)
    end

    test "keeps owned fork store alive when discard fails and drafts remain", %{tmp_dir: dir} do
      %{view: view, store: store, path: path} = seed_overlay_with_open_fork(dir)
      changeset_ref = Process.monitor(view.ref.changeset)

      Process.exit(view.ref.changeset, :kill)
      assert_receive {:DOWN, ^changeset_ref, :process, _, _}

      assert {:error, {:changeset_unavailable, _}} = ProjectView.discard(view)
      assert {:error, {:close_blocked, :fork_store_dirty}} = ProjectView.close(view)
      assert Map.has_key?(BufferForkStore.all(store), path)
    end

    test "does not stop injected fork stores", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, store} = start_supervised(BufferForkStore)
      path = Path.join(dir, "lib/a.txt")

      {:ok, parent} =
        start_supervised({Minga.Buffer.Process, content: File.read!(path), file_path: path},
          id: :injected_project_view_parent
        )

      {:ok, view} = ProjectView.overlay(dir, fork_store: store)
      assert :ok = ProjectView.write_file(view, "lib/a.txt", "draft\n")
      assert :ok = ProjectView.close(view)

      fork_pid = BufferForkStore.get(store, path)
      assert is_pid(fork_pid)
      assert "draft\n" = Minga.Buffer.Fork.content(fork_pid)
      assert "one\n" = Minga.Buffer.content(parent)
    end

    test "clears injected fork stores after promote without stopping them", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, store} = start_supervised(BufferForkStore)
      path = Path.join(dir, "lib/a.txt")

      {:ok, parent} =
        start_supervised({Minga.Buffer.Process, content: File.read!(path), file_path: path},
          id: :injected_project_view_parent_promote
        )

      {:ok, view} = ProjectView.overlay(dir, fork_store: store)
      assert :ok = ProjectView.write_file(view, "lib/a.txt", "draft\n")
      store_ref = Process.monitor(store)

      assert :ok = ProjectView.promote(view, :project_root)
      assert BufferForkStore.all(store) == %{}
      assert "draft\n" = Minga.Buffer.content(parent)
      refute_receive {:DOWN, ^store_ref, :process, ^store, _}
    end

    test "clears injected fork stores after discard without stopping them", %{tmp_dir: dir} do
      seed_project(dir)
      {:ok, store} = start_supervised(BufferForkStore)
      path = Path.join(dir, "lib/a.txt")

      {:ok, parent} =
        start_supervised({Minga.Buffer.Process, content: File.read!(path), file_path: path},
          id: :injected_project_view_parent_discard
        )

      {:ok, view} = ProjectView.overlay(dir, fork_store: store)
      assert :ok = ProjectView.write_file(view, "lib/a.txt", "draft\n")
      store_ref = Process.monitor(store)

      assert :ok = ProjectView.discard(view)
      assert BufferForkStore.all(store) == %{}
      assert "one\n" = Minga.Buffer.content(parent)
      refute_receive {:DOWN, ^store_ref, :process, ^store, _}
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

  defp seed_overlay_with_open_fork(dir, opts \\ []) do
    seed_project(dir)
    path = Path.join(dir, "lib/a.txt")

    {:ok, parent} =
      start_supervised({Minga.Buffer.Process, content: File.read!(path), file_path: path})

    {:ok, view} = ProjectView.overlay(dir, opts)
    :ok = ProjectView.write_file(view, "lib/a.txt", "draft\n")

    %{view: view, store: view.ref.fork_store, parent: parent, path: path}
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
