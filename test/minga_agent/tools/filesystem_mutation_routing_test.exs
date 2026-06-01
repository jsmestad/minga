defmodule MingaAgent.Tools.FilesystemMutationRoutingTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Fork
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.BufferForkStore
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Executor
  alias MingaAgent.Tool.Registry

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "root")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/open.txt"), "original\n")
    File.write!(Path.join(root, "lib/existing.txt"), "existing\n")

    table = :"filesystem_routing_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: table, start: {Registry, :start_link, [[name: table]]}})

    %{root: root, table: table}
  end

  test "write_file routes open buffers through fork store and leaves buffer and disk unchanged",
       %{root: root, table: table} do
    path = Path.join(root, "lib/open.txt")

    {:ok, buffer} =
      start_supervised({Minga.Buffer.Process, content: File.read!(path), file_path: path})

    {:ok, fork_store} = start_supervised(BufferForkStore)
    context = Context.new(project_root: root, fork_store: fork_store)

    assert {:ok, result} = approved_write(table, context, "lib/open.txt", "forked\n")
    assert result =~ "via fork"

    fork = BufferForkStore.get(fork_store, path)
    assert Fork.content(fork) == "forked\n"
    assert BufferProcess.content(buffer) == "original\n"
    assert File.read!(path) == "original\n"
  end

  test "write_file with fork store but no open buffer falls through to filesystem passthrough", %{
    root: root,
    table: table
  } do
    {:ok, fork_store} = start_supervised(BufferForkStore)
    context = Context.new(project_root: root, fork_store: fork_store)

    assert {:ok, result} = approved_write(table, context, "lib/new.txt", "direct\n")
    assert result =~ "wrote"
    assert File.read!(Path.join(root, "lib/new.txt")) == "direct\n"
  end

  test "write_file routes through changeset and leaves the real project unchanged", %{
    root: root,
    table: table
  } do
    {:ok, changeset} = start_supervised({MingaAgent.Changeset.Server, project_root: root})
    context = Context.new(project_root: root, changeset: changeset)

    assert {:ok, result} = approved_write(table, context, "lib/changeset.txt", "overlay\n")
    assert result =~ "changeset"
    assert {:ok, "overlay\n"} = Changeset.read_file(changeset, "lib/changeset.txt")
    refute File.exists?(Path.join(root, "lib/changeset.txt"))
  end

  test "write_file routes through ProjectView before other routing layers", %{
    root: root,
    table: table,
    tmp_dir: dir
  } do
    working_dir = Path.join(dir, "view")
    File.mkdir_p!(Path.join(working_dir, "lib"))

    {:ok, view} =
      RecordingBackend.create(root,
        parent: self(),
        working_dir: working_dir,
        workspace_id: 99,
        env: []
      )

    {:ok, fork_store} = start_supervised(BufferForkStore)
    {:ok, changeset} = start_supervised({MingaAgent.Changeset.Server, project_root: root})

    context =
      Context.new(
        project_root: root,
        project_view: view,
        fork_store: fork_store,
        changeset: changeset
      )

    assert {:ok, result} = approved_write(table, context, "lib/view.txt", "view\n")
    assert result =~ "ProjectView"
    assert File.read!(Path.join(working_dir, "lib/view.txt")) == "view\n"
    refute File.exists?(Path.join(root, "lib/view.txt"))
    assert_receive {:project_view_call, {:write_file, "lib/view.txt", "view\n"}}
  end

  test "write_file rejects escaping paths before routing", %{
    root: root,
    table: table,
    tmp_dir: dir
  } do
    outside = Path.join(dir, "outside.txt")
    File.write!(outside, "outside\n")
    working_dir = Path.join(dir, "view")
    File.mkdir_p!(working_dir)

    {:ok, view} =
      RecordingBackend.create(root, parent: self(), working_dir: working_dir, workspace_id: 7)

    context = Context.new(project_root: root, project_view: view)

    assert {:error, {:raised, message}} =
             approved_write(table, context, "../outside.txt", "hacked\n")

    assert message =~ "escapes project root"
    refute_receive {:project_view_call, _}
    assert File.read!(outside) == "outside\n"
  end

  test "router errors do not fall back to direct filesystem writes", %{root: root, table: table} do
    path = Path.join(root, "lib/existing.txt")
    {:ok, changeset} = start_supervised({MingaAgent.Changeset.Server, project_root: root})
    context = Context.new(project_root: root, changeset: changeset)
    ref = Process.monitor(changeset)
    Process.exit(changeset, :kill)
    assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

    assert {:error, message} = approved_write(table, context, "lib/existing.txt", "changed\n")
    assert message =~ "changeset_unavailable"

    assert File.read!(path) == "existing\n"
  end

  defp approved_write(table, context, path, content) do
    {:ok, spec} = Registry.lookup(table, "write_file")

    Executor.execute_approved(spec, %{"path" => path, "content" => content},
      tool_context: context
    )
  end
end
