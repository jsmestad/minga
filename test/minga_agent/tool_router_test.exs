defmodule MingaAgent.ToolRouterTest do
  use ExUnit.Case, async: true

  alias MingaAgent.BufferForkStore
  alias MingaAgent.ProjectView
  alias MingaAgent.ToolRouter
  alias Minga.Buffer.Fork

  setup do
    path = "/tmp/tool-router-test-#{System.unique_integer([:positive])}/lib/foo.ex"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule Foo do\n  def hello, do: :world\nend\n")

    {:ok, parent} =
      start_supervised({Minga.Buffer.Process, content: File.read!(path), file_path: path})

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

      {:ok, fork_pid} = BufferForkStore.get_or_create(store, path, parent)
      Fork.replace_content(fork_pid, "modified via fork\n")

      assert {:ok, "modified via fork\n"} = ToolRouter.read_file(ctx, path)
    end

    test "returns a tagged error when the fork store dies before a read", %{
      store: store,
      parent: parent,
      path: path
    } do
      ctx = ToolRouter.context(store, nil)
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, path, parent)
      Fork.replace_content(fork_pid, "forked content\n")
      Process.exit(store, :kill)

      assert {:error, {:fork_unavailable, reason}} = ToolRouter.read_file(ctx, path)
      assert reason != nil
    end

    test "falls through to buffer when no fork exists", %{store: store, path: path} do
      ctx = ToolRouter.context(store, nil)

      {:ok, content} = ToolRouter.read_file(ctx, path)
      assert content =~ "defmodule Foo"
    end

    test "falls through to filesystem with no routing", %{path: path} do
      ctx = ToolRouter.context(nil, nil)

      assert {:ok, content} = ToolRouter.read_file(ctx, path)
      assert content =~ "defmodule Foo"
    end
  end

  describe "read_file/2 with changeset" do
    test "returns tagged errors when a dead changeset is asked to read", %{path: path} do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(nil, nil, changeset)
      ref = Process.monitor(changeset)
      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

      assert {:error, {:changeset_unavailable, reason}} = ToolRouter.read_file(ctx, path)
      assert reason != nil
    end
  end

  describe "read_file/2 with ProjectView" do
    test "surfaces backend errors without tagging them unavailable", %{path: path} do
      project_root = Path.dirname(Path.dirname(path))

      view =
        ProjectView.new(MingaAgent.Test.ProjectView.FailingBackend, project_root, %{ref: self()},
          workspace_id: 7
        )

      ctx = ToolRouter.context(view, nil, nil)
      assert {:error, :unsupported} = ToolRouter.read_file(ctx, path)
    end
  end

  describe "write_file/3 with fork store" do
    test "creates fork lazily on first write", %{store: store, parent: parent, path: path} do
      ctx = ToolRouter.context(store, nil)

      assert nil == BufferForkStore.get(store, path)

      assert :ok = ToolRouter.write_file(ctx, path, "new content\n")

      fork_pid = BufferForkStore.get(store, path)
      assert fork_pid != nil
      assert Fork.content(fork_pid) == "new content\n"

      assert Minga.Buffer.Process.content(parent) ==
               "defmodule Foo do\n  def hello, do: :world\nend\n"
    end

    test "returns a tagged error when the fork store dies before a write", %{
      store: store,
      parent: parent,
      path: path
    } do
      ctx = ToolRouter.context(store, nil)
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, path, parent)
      Fork.replace_content(fork_pid, "forked content\n")
      Process.exit(store, :kill)

      assert {:error, {:fork_unavailable, reason}} =
               ToolRouter.write_file(ctx, path, "new content\n")

      assert reason != nil

      assert Minga.Buffer.Process.content(parent) ==
               "defmodule Foo do\n  def hello, do: :world\nend\n"
    end

    test "falls through to passthrough when no buffer open", %{store: store} do
      ctx = ToolRouter.context(store, nil)
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

      assert :ok =
               ToolRouter.edit_file(ctx, path, "def hello, do: :world", "def hello, do: :cosmos")

      fork_pid = BufferForkStore.get(store, path)
      assert fork_pid != nil
      assert Fork.content(fork_pid) =~ "def hello, do: :cosmos"
    end

    test "returns a tagged error when the fork store dies before an edit", %{
      store: store,
      path: path
    } do
      ctx = ToolRouter.context(store, nil)
      Process.exit(store, :kill)

      assert {:error, {:fork_unavailable, reason}} =
               ToolRouter.edit_file(ctx, path, "def hello, do: :world", "def hello, do: :cosmos")

      assert reason != nil
      assert File.read!(path) =~ "def hello, do: :world"
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

    test "returns tagged errors when a dead changeset is asked to write, edit, or delete", %{
      path: path
    } do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(nil, nil, changeset)
      ref = Process.monitor(changeset)
      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

      for {fun, args} <- [
            {:write_file, [ctx, path, "new content\n"]},
            {:edit_file, [ctx, path, "defmodule Foo", "defmodule Bar"]},
            {:delete_file, [ctx, path]}
          ] do
        assert {:error, {:changeset_unavailable, reason}} = apply(ToolRouter, fun, args)
        assert reason != nil
      end

      assert File.read!(path) =~ "defmodule Foo"
    end
  end

  describe "working_dir/1" do
    test "returns nil with no changeset" do
      ctx = ToolRouter.context(nil, nil)
      assert nil == ToolRouter.working_dir(ctx)
    end

    test "returns an error when a configured ProjectView backend is dead", %{path: path} do
      project_dir = Path.dirname(path)
      {:ok, view} = ProjectView.overlay(project_dir)
      changeset = view.ref.changeset
      ref = Process.monitor(changeset)
      ctx = ToolRouter.context(view, nil, nil)

      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}
      assert {:error, :dead_project_view} = ToolRouter.working_dir(ctx)
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

    test "falls back to the filesystem when the ProjectView backend dies", %{path: path} do
      project_dir = Path.dirname(path)
      other_path = Path.join(project_dir, "README.md")
      File.write!(other_path, "filesystem content")

      {:ok, view} = ProjectView.overlay(project_dir)
      changeset = view.ref.changeset
      ref = Process.monitor(changeset)
      ctx = ToolRouter.context(view, nil, nil)

      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}
      assert {:ok, content} = ToolRouter.read_file(ctx, other_path)
      assert content == "filesystem content"
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
