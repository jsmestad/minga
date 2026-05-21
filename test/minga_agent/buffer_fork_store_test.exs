defmodule MingaAgent.BufferForkStoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.BufferForkStore
  alias Minga.Buffer.Fork

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
    test "merges dirty forks back", %{store: store, parent: parent} do
      merge_root =
        Path.join(System.tmp_dir!(), "fork-merge-success-#{System.unique_integer([:positive])}")

      File.mkdir_p!(merge_root)
      fork_path = Path.join(merge_root, "foo.ex")
      File.write!(fork_path, "line one\nline two\nline three\n")

      {:ok, fork_pid} = BufferForkStore.get_or_create(store, fork_path, parent)

      # Edit the fork
      Fork.replace_content(fork_pid, "modified content\n")
      assert Fork.dirty?(fork_pid)

      results = BufferForkStore.merge_all(store)
      assert [{^fork_path, :ok}] = results
      assert File.read!(fork_path) == "modified content\n"

      # Store is empty after merge
      assert %{} == BufferForkStore.all(store)
    end

    test "skips clean forks", %{store: store, parent: parent} do
      BufferForkStore.get_or_create(store, "/test/foo.ex", parent)

      results = BufferForkStore.merge_all(store)
      assert [{"/test/foo.ex", :ok}] = results
    end
  end

  describe "merge_all_keep_failed/1" do
    test "removes successful forks and preserves forks whose fallback write fails", %{
      store: store,
      parent: parent
    } do
      {:ok, _success_fork} = BufferForkStore.get_or_create(store, "/test/success.ex", parent)
      {:ok, conflict_fork} = BufferForkStore.get_or_create(store, "/test/conflict.ex", parent)

      error_root =
        Path.join(System.tmp_dir!(), "fork-merge-error-#{System.unique_integer([:positive])}")

      File.mkdir_p!(error_root)
      error_path = Path.join(error_root, "error.ex")
      File.write!(error_path, "line one\nline two\nline three\n")

      {:ok, error_parent} =
        start_supervised(
          {Minga.Buffer.Process, content: "line one\nline two\nline three\n", name: nil},
          id: :error_parent
        )

      {:ok, error_fork} = BufferForkStore.get_or_create(store, error_path, error_parent)

      Fork.replace_content(conflict_fork, "line one\nfork change\nline three\n")
      Fork.replace_content(error_fork, "line one\nerror change\nline three\n")

      Minga.Buffer.Process.replace_content(
        parent,
        "line one\nparent change\nline three\n",
        :agent
      )

      File.rm_rf!(error_root)

      results = BufferForkStore.merge_all_keep_failed(store)
      result_map = Map.new(results)

      assert result_map["/test/success.ex"] == :ok
      assert match?({:conflict, _}, result_map["/test/conflict.ex"])
      assert result_map[error_path] == {:error, :enoent}

      assert nil == BufferForkStore.get(store, "/test/success.ex")

      assert %{
               "/test/conflict.ex" => conflict_pid,
               ^error_path => error_pid
             } = BufferForkStore.all(store)

      assert Fork.dirty?(conflict_pid)
      assert Fork.dirty?(error_pid)
      assert is_binary(Fork.content(conflict_pid))
      assert is_binary(Fork.content(error_pid))
    end
  end

  describe "merge_paths_keep_failed/2" do
    test "removes only the selected forks and preserves the rest", %{store: store, parent: parent} do
      merge_root =
        Path.join(System.tmp_dir!(), "fork-merge-selected-#{System.unique_integer([:positive])}")

      File.mkdir_p!(merge_root)
      selected_path = Path.join(merge_root, "selected.ex")
      untouched_path = Path.join(merge_root, "untouched.ex")
      File.write!(selected_path, "selected original\n")
      File.write!(untouched_path, "untouched original\n")

      {:ok, selected_fork} = BufferForkStore.get_or_create(store, selected_path, parent)
      {:ok, untouched_fork} = BufferForkStore.get_or_create(store, untouched_path, parent)

      Fork.replace_content(selected_fork, "selected change\n")
      Fork.replace_content(untouched_fork, "untouched change\n")

      results = BufferForkStore.merge_paths_keep_failed(store, [selected_path])
      assert [{^selected_path, :ok}] = results
      assert {:ok, "selected change\n"} = File.read(selected_path)
      assert nil == BufferForkStore.get(store, selected_path)
      assert BufferForkStore.get(store, untouched_path) == untouched_fork
      assert Fork.dirty?(untouched_fork)
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

  describe "discard_paths/2" do
    test "removes only the selected forks", %{store: store, parent: parent} do
      {:ok, selected_fork} = BufferForkStore.get_or_create(store, "/test/selected.ex", parent)
      {:ok, untouched_fork} = BufferForkStore.get_or_create(store, "/test/untouched.ex", parent)

      Fork.replace_content(selected_fork, "selected change\n")
      Fork.replace_content(untouched_fork, "untouched change\n")

      assert :ok = BufferForkStore.discard_paths(store, ["/test/selected.ex"])
      assert nil == BufferForkStore.get(store, "/test/selected.ex")
      assert BufferForkStore.get(store, "/test/untouched.ex") == untouched_fork
      assert Fork.dirty?(untouched_fork)
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
