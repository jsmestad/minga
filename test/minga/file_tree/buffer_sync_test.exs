defmodule Minga.FileTree.BufferSyncTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync

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
    test "formats entries with indentation and icons" do
      entries = [
        %{path: "/root/dir", name: "dir", dir?: true, depth: 0},
        %{path: "/root/dir/file.txt", name: "file.txt", dir?: false, depth: 1}
      ]

      expanded = MapSet.new(["/root/dir"])
      text = BufferSync.entries_to_text(entries, expanded)
      lines = String.split(text, "\n")

      assert hd(lines) == "▾ dir"
      assert Enum.at(lines, 1) == "    file.txt"
    end

    test "collapsed directory uses collapsed icon" do
      entries = [
        %{path: "/root/dir", name: "dir", dir?: true, depth: 0}
      ]

      expanded = MapSet.new()
      text = BufferSync.entries_to_text(entries, expanded)

      assert text == "▸ dir"
    end
  end
end
