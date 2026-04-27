defmodule MingaAgent.Changeset.ServerTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Changeset.Server

  setup do
    dir = Path.join(System.tmp_dir!(), "changeset-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "hello.txt"), "original content")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/foo.ex"), "defmodule Foo do\n  def hello, do: :world\nend\n")

    on_exit(fn -> File.rm_rf!(dir) end)
    %{project: dir}
  end

  defp start_server(project, opts \\ []) do
    start_supervised!({Server, Keyword.merge([project_root: project], opts)})
  end

  describe "write_file" do
    test "writes content to the overlay without modifying the project", %{project: project} do
      server = start_server(project)

      assert :ok = GenServer.call(server, {:write_file, "hello.txt", "new content"})

      # Overlay has new content
      overlay = GenServer.call(server, :overlay_path)
      assert File.read!(Path.join(overlay, "hello.txt")) == "new content"

      # Project is untouched
      assert File.read!(Path.join(project, "hello.txt")) == "original content"
    end

    test "creates new files in the overlay", %{project: project} do
      server = start_server(project)

      assert :ok = GenServer.call(server, {:write_file, "lib/new.ex", "defmodule New do\nend"})

      overlay = GenServer.call(server, :overlay_path)
      assert File.read!(Path.join(overlay, "lib/new.ex")) == "defmodule New do\nend"
      refute File.exists?(Path.join(project, "lib/new.ex"))
    end

    test "rejects traversal before capturing or writing files", %{project: project} do
      server = start_server(project)
      escaped = Path.join(Path.dirname(project), "escape.txt")

      assert {:error, :path_traversal} =
               GenServer.call(server, {:write_file, "../escape.txt", "pwned"})

      refute File.exists?(escaped)
    end

    test "failed overlay writes do not create undo history", %{project: project} do
      dep_file = Path.join(project, "deps/some_dep/lib/real.ex")
      File.mkdir_p!(Path.dirname(dep_file))
      File.write!(dep_file, "original_dep")
      server = start_server(project)

      assert {:error, :symlink_traversal} =
               GenServer.call(server, {:write_file, "deps/some_dep/lib/real.ex", "mutated"})

      assert {:error, :nothing_to_undo} =
               GenServer.call(server, {:undo, "deps/some_dep/lib/real.ex"})

      assert File.read!(dep_file) == "original_dep"
    end
  end

  describe "edit_file" do
    test "replaces text in an existing file", %{project: project} do
      server = start_server(project)

      assert :ok =
               GenServer.call(
                 server,
                 {:edit_file, "lib/foo.ex", "def hello, do: :world", "def hello, do: :cosmos"}
               )

      {:ok, content} = GenServer.call(server, {:read_file, "lib/foo.ex"})
      assert content =~ "def hello, do: :cosmos"
    end

    test "returns error when text not found", %{project: project} do
      server = start_server(project)

      assert {:error, :text_not_found} =
               GenServer.call(
                 server,
                 {:edit_file, "lib/foo.ex", "nonexistent text", "replacement"}
               )
    end

    test "rejects traversal before reading files", %{project: project} do
      server = start_server(project)
      escaped = Path.join(Path.dirname(project), "escape.txt")
      File.write!(escaped, "outside")

      assert {:error, :path_traversal} =
               GenServer.call(server, {:edit_file, "../escape.txt", "outside", "mutated"})

      assert File.read!(escaped) == "outside"
      File.rm!(escaped)
    end
  end

  describe "delete_file" do
    test "removes file from overlay view", %{project: project} do
      server = start_server(project)

      assert :ok = GenServer.call(server, {:delete_file, "hello.txt"})
      assert {:error, :deleted} = GenServer.call(server, {:read_file, "hello.txt"})
    end

    test "returns error for non-existent file", %{project: project} do
      server = start_server(project)

      assert {:error, :file_not_found} = GenServer.call(server, {:delete_file, "nope.txt"})
      assert {:error, :nothing_to_undo} = GenServer.call(server, {:undo, "nope.txt"})
    end

    test "rejects traversal before capturing or deleting files", %{project: project} do
      server = start_server(project)
      escaped = Path.join(Path.dirname(project), "escape.txt")
      File.write!(escaped, "outside")

      assert {:error, :path_traversal} = GenServer.call(server, {:delete_file, "../escape.txt"})
      assert File.exists?(escaped)
      File.rm!(escaped)
    end
  end

  describe "read_file" do
    test "returns modified content when available", %{project: project} do
      server = start_server(project)

      GenServer.call(server, {:write_file, "hello.txt", "modified"})
      assert {:ok, "modified"} = GenServer.call(server, {:read_file, "hello.txt"})
    end

    test "falls back to project file for unmodified files", %{project: project} do
      server = start_server(project)

      assert {:ok, "original content"} = GenServer.call(server, {:read_file, "hello.txt"})
    end

    test "rejects traversal before reading project files", %{project: project} do
      server = start_server(project)
      escaped = Path.join(Path.dirname(project), "escape.txt")
      File.write!(escaped, "outside")

      assert {:error, :path_traversal} = GenServer.call(server, {:read_file, "../escape.txt"})
      File.rm!(escaped)
    end
  end

  describe "undo" do
    test "reverts to previous content", %{project: project} do
      server = start_server(project)

      GenServer.call(server, {:write_file, "hello.txt", "version 1"})
      GenServer.call(server, {:write_file, "hello.txt", "version 2"})

      assert :ok = GenServer.call(server, {:undo, "hello.txt"})
      assert {:ok, "version 1"} = GenServer.call(server, {:read_file, "hello.txt"})
    end

    test "reverts back to unmodified state", %{project: project} do
      server = start_server(project)

      GenServer.call(server, {:write_file, "hello.txt", "modified"})
      assert :ok = GenServer.call(server, {:undo, "hello.txt"})
      assert {:ok, "original content"} = GenServer.call(server, {:read_file, "hello.txt"})
    end

    test "returns error when nothing to undo", %{project: project} do
      server = start_server(project)

      assert {:error, :nothing_to_undo} = GenServer.call(server, {:undo, "hello.txt"})
    end

    test "rejects traversal", %{project: project} do
      server = start_server(project)

      assert {:error, :path_traversal} = GenServer.call(server, {:undo, "../escape.txt"})
    end
  end

  describe "modified_files" do
    test "tracks modified and deleted files", %{project: project} do
      server = start_server(project)

      GenServer.call(server, {:write_file, "hello.txt", "changed"})
      GenServer.call(server, {:write_file, "lib/new.ex", "new file"})
      GenServer.call(server, {:delete_file, "lib/foo.ex"})

      result = GenServer.call(server, :modified_files)
      assert "hello.txt" in result.modified
      assert "lib/new.ex" in result.modified
      assert "lib/foo.ex" in result.deleted
    end
  end

  describe "summary" do
    test "returns per-file change summaries", %{project: project} do
      server = start_server(project)

      GenServer.call(server, {:write_file, "hello.txt", "changed"})
      GenServer.call(server, {:write_file, "lib/brand_new.ex", "new file"})

      summary = GenServer.call(server, :summary)
      assert length(summary) == 2

      hello_entry = Enum.find(summary, &(&1.path == "hello.txt"))
      assert hello_entry.kind == :modified

      new_entry = Enum.find(summary, &(&1.path == "lib/brand_new.ex"))
      assert new_entry.kind == :new
    end
  end

  describe "budget" do
    test "tracks attempts and reports exhaustion", %{project: project} do
      server = start_server(project, budget: 2)

      assert {:ok, 1} = GenServer.call(server, :record_attempt)
      assert {:ok, 2} = GenServer.call(server, :record_attempt)
      assert {:budget_exhausted, 3, 2} = GenServer.call(server, :record_attempt)
    end

    test "unlimited budget never exhausts", %{project: project} do
      server = start_server(project)

      for i <- 1..100 do
        assert {:ok, ^i} = GenServer.call(server, :record_attempt)
      end
    end

    test "reports attempt info", %{project: project} do
      server = start_server(project, budget: 5)

      GenServer.call(server, :record_attempt)
      GenServer.call(server, :record_attempt)

      info = GenServer.call(server, :attempt_info)
      assert info.attempts == 2
      assert info.budget == 5
    end
  end

  describe "reset" do
    test "clears all modifications and history", %{project: project} do
      server = start_server(project)

      GenServer.call(server, {:write_file, "hello.txt", "changed"})
      GenServer.call(server, {:delete_file, "lib/foo.ex"})
      GenServer.call(server, :reset)

      result = GenServer.call(server, :modified_files)
      assert result.modified == []
      assert result.deleted == []

      # Original content is readable again
      assert {:ok, "original content"} = GenServer.call(server, {:read_file, "hello.txt"})
    end
  end

  describe "merge" do
    test "applies changes to the real project and stops the server", %{project: project} do
      server = start_server(project)
      ref = Process.monitor(server)

      GenServer.call(server, {:write_file, "hello.txt", "merged content"})
      assert :ok = GenServer.call(server, :merge)

      # Server stopped
      assert_receive {:DOWN, ^ref, :process, ^server, :normal}

      # Project has the merged content
      assert File.read!(Path.join(project, "hello.txt")) == "merged content"
    end

    test "creates new files in the project", %{project: project} do
      server = start_server(project)

      GenServer.call(server, {:write_file, "lib/new.ex", "defmodule New do\nend"})
      assert :ok = GenServer.call(server, :merge)

      assert File.read!(Path.join(project, "lib/new.ex")) == "defmodule New do\nend"
    end

    test "deletes files from the project when unmodified", %{project: project} do
      server = start_server(project)

      GenServer.call(server, {:delete_file, "hello.txt"})
      assert :ok = GenServer.call(server, :merge)

      refute File.exists?(Path.join(project, "hello.txt"))
    end

    test "detects conflicts when project file was modified concurrently", %{project: project} do
      server = start_server(project)

      # Agent modifies the file through changeset
      GenServer.call(server, {:write_file, "hello.txt", "agent version"})

      # Simulate concurrent edit to the real project
      File.write!(Path.join(project, "hello.txt"), "human version")

      # Merge should detect the conflict and attempt three-way merge
      result = GenServer.call(server, :merge)
      # Both sides completely replaced the content, so it's a conflict
      assert {:ok, :merged_with_conflicts, _details} = result
    end

    test "three-way merges non-overlapping concurrent edits", %{project: project} do
      # Write a file with distinct lines that can be independently edited
      original = "line1\nline2\nline3\nline4\nline5\n"
      File.write!(Path.join(project, "multi.txt"), original)

      server = start_server(project)

      # Agent edits line 2
      agent_version = "line1\nagent_line2\nline3\nline4\nline5\n"
      GenServer.call(server, {:write_file, "multi.txt", agent_version})

      # Human edits line 4 concurrently
      human_version = "line1\nline2\nline3\nhuman_line4\nline5\n"
      File.write!(Path.join(project, "multi.txt"), human_version)

      assert :ok = GenServer.call(server, :merge)

      merged = File.read!(Path.join(project, "multi.txt"))
      assert merged =~ "agent_line2"
      assert merged =~ "human_line4"
    end
  end

  describe "discard" do
    test "cleans up overlay and stops the server", %{project: project} do
      server = start_server(project)
      ref = Process.monitor(server)

      overlay = GenServer.call(server, :overlay_path)
      GenServer.call(server, {:write_file, "hello.txt", "temporary"})

      assert :ok = GenServer.call(server, :discard)
      assert_receive {:DOWN, ^ref, :process, ^server, :normal}

      # Overlay is cleaned up
      refute File.dir?(overlay)

      # Project is untouched
      assert File.read!(Path.join(project, "hello.txt")) == "original content"
    end
  end
end
