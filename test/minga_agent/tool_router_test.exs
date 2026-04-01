defmodule MingaAgent.ToolRouterTest do
  use ExUnit.Case, async: true

  alias MingaAgent.BufferForkStore
  alias MingaAgent.ToolRouter
  alias Minga.Buffer.Fork

  setup do
    # Start a parent buffer with known content, registered by path
    path = "/tmp/tool-router-test-#{System.unique_integer([:positive])}/lib/foo.ex"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule Foo do\n  def hello, do: :world\nend\n")

    {:ok, parent} =
      start_supervised({Minga.Buffer.Server, content: File.read!(path), file_path: path})

    {:ok, store} = start_supervised(BufferForkStore)

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)

    %{
      parent: parent,
      store: store,
      path: path
    }
  end

  describe "context/2" do
    test "builds a context map" do
      ctx = ToolRouter.context(self(), nil)
      assert ctx.fork_store == self()
      assert ctx.changeset == nil
    end
  end

  describe "read_file/2 with fork store" do
    test "reads from fork when one exists", %{store: store, parent: parent, path: path} do
      ctx = ToolRouter.context(store, nil)

      # Create a fork and modify it
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, path, parent)
      Fork.replace_content(fork_pid, "modified via fork\n")

      assert {:ok, "modified via fork\n"} = ToolRouter.read_file(ctx, path)
    end

    test "falls through to buffer when no fork exists", %{store: store, path: path} do
      ctx = ToolRouter.context(store, nil)

      # No fork created yet, should read from the buffer
      {:ok, content} = ToolRouter.read_file(ctx, path)
      assert content =~ "defmodule Foo"
    end

    test "falls through to filesystem with no routing", %{path: path} do
      ctx = ToolRouter.context(nil, nil)

      result = ToolRouter.read_file(ctx, path)
      assert {:ok, content} = result
      assert content =~ "defmodule Foo"
    end
  end

  describe "write_file/3 with fork store" do
    test "creates fork lazily on first write", %{store: store, parent: parent, path: path} do
      ctx = ToolRouter.context(store, nil)

      # No fork yet
      assert nil == BufferForkStore.get(store, path)

      # Write creates a fork
      assert :ok = ToolRouter.write_file(ctx, path, "new content\n")

      # Fork was created
      fork_pid = BufferForkStore.get(store, path)
      assert fork_pid != nil
      assert Fork.content(fork_pid) == "new content\n"

      # Parent buffer untouched
      assert Minga.Buffer.Server.content(parent) ==
               "defmodule Foo do\n  def hello, do: :world\nend\n"
    end

    test "falls through to passthrough when no buffer open", %{store: store} do
      ctx = ToolRouter.context(store, nil)
      # Path with no open buffer
      assert :passthrough = ToolRouter.write_file(ctx, "/nonexistent/file.ex", "content")
    end

    test "returns passthrough with no routing active" do
      ctx = ToolRouter.context(nil, nil)
      assert :passthrough = ToolRouter.write_file(ctx, "/any/path.ex", "content")
    end
  end

  describe "edit_file/4 with fork store" do
    test "edits via fork when buffer is open", %{store: store, path: path} do
      ctx = ToolRouter.context(store, nil)

      # Edit creates fork lazily and applies
      assert :ok =
               ToolRouter.edit_file(ctx, path, "def hello, do: :world", "def hello, do: :cosmos")

      fork_pid = BufferForkStore.get(store, path)
      assert fork_pid != nil
      assert Fork.content(fork_pid) =~ "def hello, do: :cosmos"
    end

    test "returns error when old_text not found", %{store: store, path: path} do
      ctx = ToolRouter.context(store, nil)
      assert {:error, _} = ToolRouter.edit_file(ctx, path, "nonexistent text", "replacement")
    end

    test "falls through to passthrough when no buffer open", %{store: store} do
      ctx = ToolRouter.context(store, nil)
      assert :passthrough = ToolRouter.edit_file(ctx, "/nonexistent.ex", "old", "new")
    end
  end

  describe "delete_file/2" do
    test "returns passthrough when no changeset" do
      ctx = ToolRouter.context(nil, nil)
      assert :passthrough = ToolRouter.delete_file(ctx, "/any/path.ex")
    end
  end

  describe "working_dir/1" do
    test "returns nil with no changeset" do
      ctx = ToolRouter.context(nil, nil)
      assert nil == ToolRouter.working_dir(ctx)
    end
  end

  describe "active?/1" do
    test "returns false with nil context" do
      ctx = ToolRouter.context(nil, nil)
      refute ToolRouter.active?(ctx)
    end

    test "returns true with active fork store", %{store: store} do
      ctx = ToolRouter.context(store, nil)
      assert ToolRouter.active?(ctx)
    end
  end

  describe "has_forks?/1" do
    test "returns false with no fork store" do
      ctx = ToolRouter.context(nil, nil)
      refute ToolRouter.has_forks?(ctx)
    end

    test "returns false when fork store is empty", %{store: store} do
      ctx = ToolRouter.context(store, nil)
      refute ToolRouter.has_forks?(ctx)
    end

    test "returns true when forks exist", %{store: store, parent: parent, path: path} do
      ctx = ToolRouter.context(store, nil)
      BufferForkStore.get_or_create(store, path, parent)
      assert ToolRouter.has_forks?(ctx)
    end
  end
end
