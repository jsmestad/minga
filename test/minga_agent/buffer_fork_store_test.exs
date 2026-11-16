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

  describe "claim_owner/4" do
    test "keeps a changeset claim when its file later opens in a buffer", ctx do
      changeset = self()
      path = "/claimed/changeset"

      assert {:ok, {:changeset, ^changeset}} =
               BufferForkStore.claim_owner(ctx.store, path, nil, changeset)

      assert {:ok, {:changeset, ^changeset}} =
               BufferForkStore.claim_owner(ctx.store, path, ctx.parent, nil)

      assert {:error, :owner_claimed_by_changeset} =
               BufferForkStore.get_or_create(ctx.store, path, ctx.parent)

      assert BufferForkStore.all(ctx.store) == %{}
    end

    test "keeps the original fork when routing candidates change", ctx do
      path = "/claimed/fork"

      assert {:ok, {:fork, fork}} =
               BufferForkStore.claim_owner(ctx.store, path, ctx.parent, self())

      assert {:ok, {:fork, ^fork}} =
               BufferForkStore.claim_owner(ctx.store, path, nil, self())

      assert BufferForkStore.get(ctx.store, path) == fork
    end

    test "no candidates leave the path unclaimed", ctx do
      path = "/claimed/later"
      assert :not_found = BufferForkStore.claim_owner(ctx.store, path, nil, nil)

      assert {:ok, {:fork, _fork}} =
               BufferForkStore.claim_owner(ctx.store, path, ctx.parent, self())
    end

    test "concurrent first claims converge on exactly one writer", ctx do
      path = "/claimed/concurrent"
      changeset = self()

      tasks = [
        Task.async(fn -> BufferForkStore.claim_owner(ctx.store, path, nil, changeset) end),
        Task.async(fn -> BufferForkStore.claim_owner(ctx.store, path, ctx.parent, changeset) end)
      ]

      [first, second] = Enum.map(tasks, &Task.await/1)
      assert {:ok, owner} = first
      assert second == {:ok, owner}
      assert BufferForkStore.claim_owner(ctx.store, path, ctx.parent, changeset) == {:ok, owner}
    end

    test "dead changeset claims do not fall back to a newly opened buffer", ctx do
      changeset = start_supervised!({Agent, fn -> :ready end})
      path = "/claimed/dead-changeset"

      assert {:ok, {:changeset, ^changeset}} =
               BufferForkStore.claim_owner(ctx.store, path, nil, changeset)

      GenServer.stop(changeset)

      assert {:error, :owner_unavailable} =
               BufferForkStore.claim_owner(ctx.store, path, ctx.parent, self())

      assert BufferForkStore.all(ctx.store) == %{}
    end

    test "discard releases only its path and discard_all releases every claim", ctx do
      changeset = self()
      first = "/claimed/first"
      second = "/claimed/second"

      assert {:ok, {:changeset, ^changeset}} =
               BufferForkStore.claim_owner(ctx.store, first, nil, changeset)

      assert {:ok, {:changeset, ^changeset}} =
               BufferForkStore.claim_owner(ctx.store, second, nil, changeset)

      assert :ok = BufferForkStore.discard(ctx.store, first)

      assert {:ok, {:fork, _fork}} =
               BufferForkStore.claim_owner(ctx.store, first, ctx.parent, nil)

      assert {:ok, {:changeset, ^changeset}} =
               BufferForkStore.claim_owner(ctx.store, second, ctx.parent, nil)

      assert :ok = BufferForkStore.discard_all(ctx.store)

      assert {:ok, {:fork, _fork}} =
               BufferForkStore.claim_owner(ctx.store, second, ctx.parent, nil)
    end
  end

  describe "transfer_to_changeset/4" do
    test "requires the exact sealed fork and atomically preserves the new claim", ctx do
      changeset = self()
      path = "/claimed/transfer"

      assert {:ok, {:fork, fork}} =
               BufferForkStore.claim_owner(ctx.store, path, ctx.parent, changeset)

      assert {:error, :owner_mismatch} =
               BufferForkStore.transfer_to_changeset(ctx.store, path, self(), changeset)

      assert {:error, :fork_not_published} =
               BufferForkStore.transfer_to_changeset(ctx.store, path, fork, changeset)

      Fork.replace_content(fork, "published")
      assert {:ok, "published"} = Fork.publish(fork)
      ref = Process.monitor(fork)
      assert :ok = BufferForkStore.transfer_to_changeset(ctx.store, path, fork, changeset)
      assert_receive {:DOWN, ^ref, :process, ^fork, :normal}

      assert BufferForkStore.get(ctx.store, path) == nil

      assert {:ok, {:changeset, ^changeset}} =
               BufferForkStore.claim_owner(ctx.store, path, ctx.parent, nil)

      assert {:error, :owner_claimed_by_changeset} =
               BufferForkStore.get_or_create(ctx.store, path, ctx.parent)
    end

    test "dead sealed fork transfer remains fail closed", ctx do
      path = "/claimed/dead-transfer"
      changeset = self()

      assert {:ok, {:fork, fork}} =
               BufferForkStore.claim_owner(ctx.store, path, ctx.parent, changeset)

      assert {:ok, _unchanged} = Fork.publish(fork)
      GenServer.stop(fork)

      assert {:error, :owner_unavailable} =
               BufferForkStore.transfer_to_changeset(ctx.store, path, fork, changeset)

      assert {:error, :owner_unavailable} =
               BufferForkStore.claim_owner(ctx.store, path, ctx.parent, changeset)
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
      assert Minga.Buffer.content(parent) == "modified content\n"
      Minga.Buffer.undo(parent)
      assert Minga.Buffer.content(parent) == "line one\n"
      assert File.read!(path) == "line one\n"
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

    test "keeps closed-parent forks without publishing to disk", %{
      tmp_dir: dir,
      store: store,
      parent: parent
    } do
      path = Path.join(dir, "closed-parent.ex")
      File.write!(path, "human disk content\n")

      {:ok, fork_pid} = BufferForkStore.get_or_create(store, path, parent)
      Fork.replace_content(fork_pid, "merged\n")
      GenServer.stop(parent)

      results = BufferForkStore.merge_all_keep_failed(store)
      assert [{^path, {:error, :parent_dead}}] = results
      assert File.read!(path) == "human disk content\n"
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
    test "dead fork claims remain unavailable until explicitly discarded", %{
      store: store,
      parent: parent
    } do
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, "/test/foo.ex", parent)

      ref = Process.monitor(fork_pid)
      Process.exit(fork_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^fork_pid, :killed}
      :sys.get_state(store)

      assert nil == BufferForkStore.get(store, "/test/foo.ex")
      assert %{} == BufferForkStore.all(store)

      assert {:error, :owner_unavailable} =
               BufferForkStore.claim_owner(store, "/test/foo.ex", parent, self())

      assert {:error, :owner_unavailable} =
               BufferForkStore.get_or_create(store, "/test/foo.ex", parent)

      assert :ok = BufferForkStore.discard(store, "/test/foo.ex")

      assert {:ok, {:fork, replacement}} =
               BufferForkStore.claim_owner(store, "/test/foo.ex", parent, nil)

      refute replacement == fork_pid
    end
  end
end
