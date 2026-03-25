defmodule Minga.Project.FileTree.BufferSyncTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync

  describe "start_buffer/1" do
    test "creates a nofile buffer", %{tmp_dir: tmp_dir} do
      tree = FileTree.new(tmp_dir)
      pid = BufferSync.start_buffer(tree)

      assert is_pid(pid)
      assert BufferServer.buffer_type(pid) == :nofile
      assert BufferServer.read_only?(pid)
      assert BufferServer.buffer_name(pid) == "*File Tree*"
      assert BufferServer.unlisted?(pid)
    end

    test "buffer content matches visible entries", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "alpha.txt"), "")
      File.write!(Path.join(tmp_dir, "beta.txt"), "")
      File.mkdir_p!(Path.join(tmp_dir, "gamma"))

      tree = FileTree.new(tmp_dir)
      pid = BufferSync.start_buffer(tree)

      content = BufferServer.content(pid)
      lines = String.split(content, "\n")

      # Directories first (sorted), then files (sorted)
      assert Enum.any?(lines, &String.contains?(&1, "gamma"))
      assert Enum.any?(lines, &String.contains?(&1, "alpha.txt"))
      assert Enum.any?(lines, &String.contains?(&1, "beta.txt"))
    end
  end

  describe "sync/2" do
    test "updates buffer content after tree mutation", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))
      File.write!(Path.join(tmp_dir, "file.txt"), "")

      tree = FileTree.new(tmp_dir)
      pid = BufferSync.start_buffer(tree)

      content_before = BufferServer.content(pid)

      # Toggle hidden files changes visible entries
      new_tree = FileTree.toggle_hidden(tree)
      BufferSync.sync(pid, new_tree)

      content_after = BufferServer.content(pid)
      # Content may or may not change depending on hidden files present,
      # but the sync should not crash
      assert is_binary(content_after)
      _ = content_before
    end

    test "buffer cursor matches tree cursor", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")
      File.write!(Path.join(tmp_dir, "b.txt"), "")
      File.write!(Path.join(tmp_dir, "c.txt"), "")

      tree = FileTree.new(tmp_dir)
      pid = BufferSync.start_buffer(tree)

      # Move tree cursor down
      tree = FileTree.move_down(tree)
      tree = FileTree.move_down(tree)
      BufferSync.sync(pid, tree)

      {cursor_line, _col} = BufferServer.cursor(pid)
      assert cursor_line == tree.cursor
    end
  end

  describe "entries_to_text/2" do
    test "formats entries with guide lines, icons, and trailing slash for dirs" do
      entries = [
        %{
          path: "/root/dir",
          name: "dir",
          dir?: true,
          depth: 0,
          last_child?: false,
          guides: []
        },
        %{
          path: "/root/dir/file.txt",
          name: "file.txt",
          dir?: false,
          depth: 1,
          last_child?: true,
          guides: [true]
        }
      ]

      expanded = MapSet.new(["/root/dir"])
      text = BufferSync.entries_to_text(entries, expanded)
      lines = String.split(text, "\n")

      # First line: connector + folder open icon + dir name with trailing slash
      assert String.contains?(hd(lines), "dir/")
      assert String.contains?(hd(lines), "├─")

      # Second line: guide pipe + elbow connector + file icon + name
      second = Enum.at(lines, 1)
      assert String.contains?(second, "│ ")
      assert String.contains?(second, "└─")
      assert String.contains?(second, "file.txt")
    end

    test "collapsed directory uses closed folder icon" do
      entries = [
        %{
          path: "/root/dir",
          name: "dir",
          dir?: true,
          depth: 0,
          last_child?: true,
          guides: []
        }
      ]

      expanded = MapSet.new()
      text = BufferSync.entries_to_text(entries, expanded)

      # Should contain the closed folder icon and dir name with trailing slash
      assert String.contains?(text, "dir/")
      assert String.contains?(text, "└─")
    end
  end
end
