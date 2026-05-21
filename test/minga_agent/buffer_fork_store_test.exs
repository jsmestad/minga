defmodule MingaAgent.BufferForkStoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.BufferForkStore
  alias Minga.Buffer.Fork

  @moduletag :tmp_dir

  setup do
    # Start a parent buffer with known content
    {:ok, parent} =
      start_supervised(
        {Minga.Buffer.Process, content: "line one\nline two\nline three\n", name: nil}
      )

    {:ok, store} = start_supervised(BufferForkStore)

    %{parent: parent, store: store}
  end

  describe "get_or_create/3" do
    test "creates a fork on first call", %{store: store, parent: parent} do
      assert {:ok, fork_pid} = BufferForkStore.get_or_create(store, "/test/foo.ex", parent)
      assert is_pid(fork_pid)
      assert Fork.content(fork_pid) == "line one\nline two\nline three\n"
    end

    test "returns the same fork on subsequent calls", %{store: store, parent: parent} do
      {:ok, fork1} = BufferForkStore.get_or_create(store, "/test/foo.ex", parent)
      {:ok, fork2} = BufferForkStore.get_or_create(store, "/test/foo.ex", parent)
      assert fork1 == fork2
    end

    test "creates separate forks for different paths", %{store: store, parent: parent} do
      {:ok, fork1} = BufferForkStore.get_or_create(store, "/test/a.ex", parent)
      {:ok, fork2} = BufferForkStore.get_or_create(store, "/test/b.ex", parent)
      refute fork1 == fork2
    end
  end

  describe "get/2" do
    test "returns nil for unknown path", %{store: store} do
      assert nil == BufferForkStore.get(store, "/nonexistent.ex")
    end

    test "returns the fork pid for a known path", %{store: store, parent: parent} do
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, "/test/foo.ex", parent)
      assert BufferForkStore.get(store, "/test/foo.ex") == fork_pid
    end
  end

  describe "all/1" do
    test "returns empty map when no forks", %{store: store} do
      assert %{} == BufferForkStore.all(store)
    end

    test "returns all forks", %{store: store, parent: parent} do
      BufferForkStore.get_or_create(store, "/test/a.ex", parent)
      BufferForkStore.get_or_create(store, "/test/b.ex", parent)
      forks = BufferForkStore.all(store)
      assert map_size(forks) == 2
      assert Map.has_key?(forks, "/test/a.ex")
      assert Map.has_key?(forks, "/test/b.ex")
    end
  end

  describe "merge_all/1" do
    test "merges dirty forks back", %{tmp_dir: dir, store: store, parent: parent} do
      path = Path.join(dir, "merge-success/lib/foo.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "line one\n")
      assert :ok = Minga.Buffer.open(parent, path)

      {:ok, fork_pid} = BufferForkStore.get_or_create(store, path, parent)

      Fork.replace_content(fork_pid, "modified content\n")
      assert Fork.dirty?(fork_pid)

      results = BufferForkStore.merge_all(store)
      assert [{^path, :ok}] = results

      assert %{} == BufferForkStore.all(store)
    end

    test "skips clean forks", %{tmp_dir: dir, store: store, parent: parent} do
      path = Path.join(dir, "merge-clean/lib/foo.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "line one\n")
      assert :ok = Minga.Buffer.open(parent, path)

      {:ok, _fork_pid} = BufferForkStore.get_or_create(store, path, parent)

      results = BufferForkStore.merge_all(store)
      assert [{^path, :ok}] = results
      assert %{} == BufferForkStore.all(store)
    end

    test "keeps failed forks when the parent write fails", %{
      tmp_dir: dir,
      store: store,
      parent: parent
    } do
      path = Path.join(dir, "missing/project/lib/foo.ex")

      {:ok, fork_pid} = BufferForkStore.get_or_create(store, path, parent)
      Fork.replace_content(fork_pid, "merged\n")

      results = BufferForkStore.merge_all_keep_failed(store)
      assert [{^path, {:error, reason}}] = results
      assert reason != nil
      assert BufferForkStore.get(store, path) == fork_pid
      assert %{^path => ^fork_pid} = BufferForkStore.all(store)
    end

    test "keeps failed forks when replace_content is rejected by a read-only parent",
         %{tmp_dir: dir, store: store} do
      failed_path = Path.join(dir, "readonly/lib/foo.ex")
      ok_path = Path.join(dir, "merge-ok/lib/bar.ex")
      File.mkdir_p!(Path.dirname(failed_path))
      File.mkdir_p!(Path.dirname(ok_path))
      File.write!(failed_path, "original\n")
      File.write!(ok_path, "base\n")

      {:ok, read_only_parent} =
        start_supervised(
          {Minga.Buffer.Process, content: "original\n", file_path: failed_path, read_only: true},
          id: :read_only_parent
        )

      {:ok, ok_parent} =
        start_supervised(
          {Minga.Buffer.Process, content: "base\n", file_path: ok_path},
          id: :ok_parent
        )

      {:ok, failed_fork} = BufferForkStore.get_or_create(store, failed_path, read_only_parent)
      {:ok, ok_fork} = BufferForkStore.get_or_create(store, ok_path, ok_parent)

      Fork.replace_content(failed_fork, "failed merge\n")
      Fork.replace_content(ok_fork, "merged ok\n")

      results = BufferForkStore.merge_all_keep_failed(store)
      result_map = Map.new(results)

      assert result_map[failed_path] == {:error, :read_only}
      assert result_map[ok_path] == :ok
      assert BufferForkStore.get(store, failed_path) == failed_fork
      assert nil == BufferForkStore.get(store, ok_path)
      assert File.read!(failed_path) == "original\n"
      assert Minga.Buffer.Process.content(ok_parent) == "merged ok\n"
    end

    test "keeps failed forks when the parent process dies during merge",
         %{tmp_dir: dir, store: store} do
      path = Path.join(dir, "dying/lib/foo.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "original\n")

      {:ok, parent} =
        start_supervised({Minga.Buffer.Process, content: "original\n", file_path: path},
          id: :dying_parent
        )

      {:ok, fork_pid} = BufferForkStore.get_or_create(store, path, parent)
      Fork.replace_content(fork_pid, "merged\n")

      Process.exit(parent, :kill)

      results = BufferForkStore.merge_all_keep_failed(store)
      result_map = Map.new(results)

      assert match?({:error, _reason}, result_map[path])
      assert BufferForkStore.get(store, path) == fork_pid
      assert %{^path => ^fork_pid} = BufferForkStore.all(store)
    end
  end

  describe "discard_all/1" do
    test "removes all forks without merging", %{store: store, parent: parent} do
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, "/test/foo.ex", parent)
      Fork.replace_content(fork_pid, "modified\n")

      assert :ok = BufferForkStore.discard_all(store)
      assert %{} == BufferForkStore.all(store)

      # Original buffer is untouched
      assert Minga.Buffer.Process.content(parent) == "line one\nline two\nline three\n"
    end
  end

  describe "monitor cleanup" do
    test "removes fork from store when fork process dies", %{store: store, parent: parent} do
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, "/test/foo.ex", parent)

      # Kill the fork
      GenServer.stop(fork_pid, :normal)

      # Give the DOWN message time to be processed
      :sys.get_state(store)

      assert nil == BufferForkStore.get(store, "/test/foo.ex")
      assert %{} == BufferForkStore.all(store)
    end
  end
end
