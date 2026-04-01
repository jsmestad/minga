defmodule MingaAgent.BufferForkStoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.BufferForkStore
  alias Minga.Buffer.Fork

  setup do
    # Start a parent buffer with known content
    {:ok, parent} =
      start_supervised(
        {Minga.Buffer.Server, content: "line one\nline two\nline three\n", name: nil}
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
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, "/test/foo.ex", parent)

      # Edit the fork
      Fork.replace_content(fork_pid, "modified content\n")
      assert Fork.dirty?(fork_pid)

      results = BufferForkStore.merge_all(store)
      assert [{"/test/foo.ex", :ok}] = results

      # Store is empty after merge
      assert %{} == BufferForkStore.all(store)
    end

    test "skips clean forks", %{store: store, parent: parent} do
      BufferForkStore.get_or_create(store, "/test/foo.ex", parent)

      results = BufferForkStore.merge_all(store)
      assert [{"/test/foo.ex", :ok}] = results
    end
  end

  describe "discard_all/1" do
    test "removes all forks without merging", %{store: store, parent: parent} do
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, "/test/foo.ex", parent)
      Fork.replace_content(fork_pid, "modified\n")

      assert :ok = BufferForkStore.discard_all(store)
      assert %{} == BufferForkStore.all(store)

      # Original buffer is untouched
      assert Minga.Buffer.Server.content(parent) == "line one\nline two\nline three\n"
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
