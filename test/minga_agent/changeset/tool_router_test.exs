defmodule MingaAgent.Changeset.ToolRouterTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Changeset
  alias MingaAgent.Changeset.ToolRouter

  setup do
    dir = Path.join(System.tmp_dir!(), "router-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "hello.txt"), "original content")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/foo.ex"), "defmodule Foo do\n  def hello, do: :world\nend\n")

    {:ok, cs} = start_changeset(dir)

    on_exit(fn ->
      if Process.alive?(cs), do: Changeset.discard(cs)
      File.rm_rf!(dir)
    end)

    %{project: dir, cs: cs}
  end

  defp start_changeset(dir) do
    # Start the changeset server directly (no DynamicSupervisor needed for tests)
    start_supervised({Changeset.Server, project_root: dir})
    |> case do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  describe "active?/1" do
    test "returns false for nil" do
      refute ToolRouter.active?(nil)
    end

    test "returns true for alive changeset", %{cs: cs} do
      assert ToolRouter.active?(cs)
    end
  end

  describe "read_file/2" do
    test "returns passthrough behavior with nil changeset" do
      # With nil, falls through to buffer/filesystem
      result = ToolRouter.read_file(nil, "/tmp/nonexistent-file-#{System.unique_integer()}")
      assert {:error, _} = result
    end

    test "reads modified content from changeset", %{cs: cs, project: project} do
      Changeset.write_file(cs, "hello.txt", "modified via changeset")

      result = ToolRouter.read_file(cs, Path.join(project, "hello.txt"))
      assert {:ok, "modified via changeset"} = result
    end

    test "reads original content from changeset for unmodified files", %{cs: cs, project: project} do
      result = ToolRouter.read_file(cs, Path.join(project, "hello.txt"))
      assert {:ok, "original content"} = result
    end
  end

  describe "write_file/3" do
    test "returns passthrough with nil changeset" do
      assert :passthrough = ToolRouter.write_file(nil, "any/path", "content")
    end

    test "writes to changeset overlay", %{cs: cs, project: project} do
      assert :ok = ToolRouter.write_file(cs, Path.join(project, "hello.txt"), "new content")

      # Changeset has the new content
      assert {:ok, "new content"} = Changeset.read_file(cs, "hello.txt")

      # Project is untouched
      assert File.read!(Path.join(project, "hello.txt")) == "original content"
    end
  end

  describe "edit_file/4" do
    test "returns passthrough with nil changeset" do
      assert :passthrough = ToolRouter.edit_file(nil, "path", "old", "new")
    end

    test "edits file in changeset", %{cs: cs, project: project} do
      assert :ok =
               ToolRouter.edit_file(
                 cs,
                 Path.join(project, "lib/foo.ex"),
                 "def hello, do: :world",
                 "def hello, do: :cosmos"
               )

      {:ok, content} = Changeset.read_file(cs, "lib/foo.ex")
      assert content =~ "def hello, do: :cosmos"
    end
  end

  describe "delete_file/2" do
    test "returns passthrough with nil changeset" do
      assert :passthrough = ToolRouter.delete_file(nil, "path")
    end

    test "deletes file in changeset", %{cs: cs, project: project} do
      assert :ok = ToolRouter.delete_file(cs, Path.join(project, "hello.txt"))
      assert {:error, :deleted} = Changeset.read_file(cs, "hello.txt")
    end
  end

  describe "working_dir/1" do
    test "returns nil with nil changeset" do
      assert nil == ToolRouter.working_dir(nil)
    end

    test "returns overlay directory with active changeset", %{cs: cs} do
      dir = ToolRouter.working_dir(cs)
      assert is_binary(dir)
      assert File.dir?(dir)
    end
  end
end
