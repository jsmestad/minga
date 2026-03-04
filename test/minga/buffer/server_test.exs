defmodule Minga.Buffer.ServerTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server

  @moduletag :tmp_dir

  describe "start_link/1" do
    test "starts with empty content by default" do
      {:ok, pid} = Server.start_link()
      assert Server.content(pid) == ""
      assert Server.cursor(pid) == {0, 0}
      refute Server.dirty?(pid)
      assert Server.file_path(pid) == nil
    end

    test "starts with initial content" do
      {:ok, pid} = Server.start_link(content: "hello\nworld")
      assert Server.content(pid) == "hello\nworld"
      assert Server.line_count(pid) == 2
    end

    test "starts by reading a file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "file content")

      {:ok, pid} = Server.start_link(file_path: path)
      assert Server.content(pid) == "file content"
      assert Server.file_path(pid) == path
      refute Server.dirty?(pid)
    end

    test "starts with empty content for non-existent file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "new_file.txt")

      {:ok, pid} = Server.start_link(file_path: path)
      assert Server.content(pid) == ""
      assert Server.file_path(pid) == path
    end

    test "starts with a registered name" do
      {:ok, _pid} = Server.start_link(name: :test_buffer, content: "named")
      assert Server.content(:test_buffer) == "named"
    end
  end

  describe "open/2" do
    test "opens a file and replaces buffer content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "open_test.txt")
      File.write!(path, "new content")

      {:ok, pid} = Server.start_link(content: "old content")
      assert Server.content(pid) == "old content"

      :ok = Server.open(pid, path)
      assert Server.content(pid) == "new content"
      assert Server.file_path(pid) == path
      refute Server.dirty?(pid)
    end

    test "returns error for unreadable file" do
      {:ok, pid} = Server.start_link()
      assert {:error, :enoent} = Server.open(pid, "/nonexistent/path/file.txt")
    end

    test "resets dirty flag after opening", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dirty_test.txt")
      File.write!(path, "content")

      {:ok, pid} = Server.start_link(content: "initial")
      Server.insert_char(pid, "x")
      assert Server.dirty?(pid)

      Server.open(pid, path)
      refute Server.dirty?(pid)
    end
  end

  describe "insert_char/2" do
    test "inserts at cursor and marks dirty" do
      {:ok, pid} = Server.start_link(content: "hello")
      refute Server.dirty?(pid)

      :ok = Server.insert_char(pid, "X")
      assert Server.content(pid) == "Xhello"
      assert Server.cursor(pid) == {0, 1}
      assert Server.dirty?(pid)
    end
  end

  describe "delete_before/1" do
    test "deletes character before cursor and marks dirty" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.move(pid, :right)
      Server.move(pid, :right)

      :ok = Server.delete_before(pid)
      assert Server.content(pid) == "hllo"
      assert Server.dirty?(pid)
    end

    test "does not mark dirty when nothing to delete" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.delete_before(pid)
      refute Server.dirty?(pid)
    end
  end

  describe "delete_at/1" do
    test "deletes character at cursor and marks dirty" do
      {:ok, pid} = Server.start_link(content: "hello")

      :ok = Server.delete_at(pid)
      assert Server.content(pid) == "ello"
      assert Server.dirty?(pid)
    end

    test "does not mark dirty when nothing to delete" do
      {:ok, pid} = Server.start_link(content: "hi")
      Server.move_to(pid, {0, 2})
      Server.delete_at(pid)
      refute Server.dirty?(pid)
    end
  end

  describe "move/2" do
    test "moves cursor without marking dirty" do
      {:ok, pid} = Server.start_link(content: "hello\nworld")
      refute Server.dirty?(pid)

      Server.move(pid, :right)
      assert Server.cursor(pid) == {0, 1}
      refute Server.dirty?(pid)

      Server.move(pid, :down)
      assert Server.cursor(pid) == {1, 1}
      refute Server.dirty?(pid)
    end
  end

  describe "move_to/2" do
    test "moves to exact position" do
      {:ok, pid} = Server.start_link(content: "abc\ndef\nghi")
      Server.move_to(pid, {2, 1})
      assert Server.cursor(pid) == {2, 1}
      refute Server.dirty?(pid)
    end
  end

  describe "save/1" do
    test "saves content to file and clears dirty flag", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "save_test.txt")
      File.write!(path, "original")

      {:ok, pid} = Server.start_link(file_path: path)
      Server.insert_char(pid, "X")
      assert Server.dirty?(pid)

      :ok = Server.save(pid)
      refute Server.dirty?(pid)
      assert File.read!(path) == "Xoriginal"
    end

    test "returns error when no file path is set" do
      {:ok, pid} = Server.start_link(content: "scratch")
      Server.insert_char(pid, "x")
      assert {:error, :no_file_path} = Server.save(pid)
    end

    test "creates parent directories if needed", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "dir", "file.txt"])

      {:ok, pid} = Server.start_link(file_path: path)
      Server.insert_char(pid, "hello")
      :ok = Server.save(pid)

      assert File.read!(path) == "hello"
    end
  end

  describe "save_as/2" do
    test "saves to a new path and updates file_path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "save_as_test.txt")

      {:ok, pid} = Server.start_link(content: "content")
      Server.insert_char(pid, "X")

      :ok = Server.save_as(pid, path)
      assert Server.file_path(pid) == path
      refute Server.dirty?(pid)
      assert File.read!(path) == "Xcontent"
    end
  end

  describe "get_lines/3" do
    test "returns requested line range" do
      {:ok, pid} = Server.start_link(content: "a\nb\nc\nd\ne")
      assert Server.get_lines(pid, 1, 3) == ["b", "c", "d"]
    end
  end

  describe "line_count/1" do
    test "returns the number of lines" do
      {:ok, pid} = Server.start_link(content: "a\nb\nc")
      assert Server.line_count(pid) == 3
    end
  end

  describe "special buffer properties" do
    test "buffer_name returns nil by default" do
      {:ok, pid} = Server.start_link(content: "hello")
      assert Server.buffer_name(pid) == nil
    end

    test "buffer_name returns the configured name" do
      {:ok, pid} = Server.start_link(content: "", buffer_name: "*Messages*")
      assert Server.buffer_name(pid) == "*Messages*"
    end

    test "read_only? returns false by default" do
      {:ok, pid} = Server.start_link(content: "hello")
      assert Server.read_only?(pid) == false
    end

    test "read-only buffer rejects insert_char" do
      {:ok, pid} = Server.start_link(content: "hello", read_only: true)
      assert Server.insert_char(pid, "x") == {:error, :read_only}
      assert Server.content(pid) == "hello"
    end

    test "read-only buffer rejects delete_before" do
      {:ok, pid} = Server.start_link(content: "hello", read_only: true)
      Server.move(pid, :right)
      assert Server.delete_before(pid) == {:error, :read_only}
      assert Server.content(pid) == "hello"
    end

    test "read-only buffer rejects delete_at" do
      {:ok, pid} = Server.start_link(content: "hello", read_only: true)
      assert Server.delete_at(pid) == {:error, :read_only}
      assert Server.content(pid) == "hello"
    end

    test "read-only buffer rejects replace_content" do
      {:ok, pid} = Server.start_link(content: "hello", read_only: true)
      assert Server.replace_content(pid, "new") == {:error, :read_only}
      assert Server.content(pid) == "hello"
    end

    test "read-only buffer rejects delete_range" do
      {:ok, pid} = Server.start_link(content: "hello", read_only: true)
      assert Server.delete_range(pid, {0, 0}, {0, 3}) == {:error, :read_only}
      assert Server.content(pid) == "hello"
    end

    test "read-only buffer rejects delete_lines" do
      {:ok, pid} = Server.start_link(content: "a\nb\nc", read_only: true)
      assert Server.delete_lines(pid, 0, 0) == {:error, :read_only}
      assert Server.content(pid) == "a\nb\nc"
    end

    test "read-only buffer rejects clear_line" do
      {:ok, pid} = Server.start_link(content: "hello", read_only: true)
      assert Server.clear_line(pid, 0) == {:error, :read_only}
      assert Server.content(pid) == "hello"
    end

    test "append bypasses read-only" do
      {:ok, pid} = Server.start_link(content: "hello", read_only: true)
      assert Server.append(pid, "\nworld") == :ok
      assert Server.content(pid) == "hello\nworld"
    end

    test "unlisted? returns configured value" do
      {:ok, pid} = Server.start_link(content: "", unlisted: true)
      assert Server.unlisted?(pid) == true
    end

    test "persistent? returns configured value" do
      {:ok, pid} = Server.start_link(content: "", persistent: true)
      assert Server.persistent?(pid) == true
    end

    test "render_snapshot includes name and read_only" do
      {:ok, pid} = Server.start_link(content: "hi", buffer_name: "*test*", read_only: true)
      snap = Server.render_snapshot(pid, 0, 10)
      assert snap.name == "*test*"
      assert snap.read_only == true
    end
  end

  describe "snapshot/1" do
    test "returns the underlying GapBuffer struct" do
      {:ok, pid} = Server.start_link(content: "hello\nworld")
      gb = Server.snapshot(pid)

      assert %Minga.Buffer.GapBuffer{} = gb
      assert Minga.Buffer.GapBuffer.content(gb) == "hello\nworld"
      assert Minga.Buffer.GapBuffer.cursor(gb) == {0, 0}
      assert Minga.Buffer.GapBuffer.line_count(gb) == 2
    end

    test "snapshot reflects cursor position" do
      {:ok, pid} = Server.start_link(content: "hello\nworld")
      Server.move_to(pid, {1, 3})
      gb = Server.snapshot(pid)

      assert Minga.Buffer.GapBuffer.cursor(gb) == {1, 3}
    end
  end

  describe "apply_snapshot/2" do
    test "replaces buffer content and marks dirty" do
      {:ok, pid} = Server.start_link(content: "hello")
      gb = Server.snapshot(pid)
      new_gb = Minga.Buffer.GapBuffer.insert_char(gb, "X")

      assert :ok = Server.apply_snapshot(pid, new_gb)
      assert Server.content(pid) == "Xhello"
      assert Server.dirty?(pid)
    end

    test "pushes undo state so changes can be undone" do
      {:ok, pid} = Server.start_link(content: "hello")
      gb = Server.snapshot(pid)
      new_gb = Minga.Buffer.GapBuffer.insert_char(gb, "X")

      Server.apply_snapshot(pid, new_gb)
      assert Server.content(pid) == "Xhello"

      Server.undo(pid)
      assert Server.content(pid) == "hello"
    end

    test "returns error on read-only buffer" do
      {:ok, pid} = Server.start_link(content: "hello", read_only: true)
      gb = Server.snapshot(pid)
      new_gb = Minga.Buffer.GapBuffer.insert_char(gb, "X")

      assert {:error, :read_only} = Server.apply_snapshot(pid, new_gb)
      assert Server.content(pid) == "hello"
    end

    test "round-trip preserves buffer identity" do
      {:ok, pid} = Server.start_link(content: "hello\nworld")
      Server.move_to(pid, {1, 2})
      gb = Server.snapshot(pid)

      Server.apply_snapshot(pid, gb)
      assert Server.content(pid) == "hello\nworld"
      assert Server.cursor(pid) == {1, 2}
    end
  end
end
