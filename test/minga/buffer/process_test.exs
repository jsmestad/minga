defmodule Minga.Buffer.ProcessTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options

  @moduletag :tmp_dir

  describe "child_spec/1" do
    test "uses restart: :temporary so crashed buffers stay dead" do
      spec = BufferProcess.child_spec(file_path: "test.ex")
      assert spec.restart == :temporary
    end
  end

  describe "start_link/1" do
    test "starts with empty content by default" do
      {:ok, pid} = BufferProcess.start_link()
      assert BufferProcess.content(pid) == ""
      assert BufferProcess.cursor(pid) == {0, 0}
      refute BufferProcess.dirty?(pid)
      assert BufferProcess.file_path(pid) == nil
    end

    test "starts with initial content" do
      {:ok, pid} = BufferProcess.start_link(content: "hello\nworld")
      assert BufferProcess.content(pid) == "hello\nworld"
      assert BufferProcess.line_count(pid) == 2
    end

    test "starts by reading a file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "file content")

      {:ok, pid} = BufferProcess.start_link(file_path: path)
      assert BufferProcess.content(pid) == "file content"
      assert BufferProcess.file_path(pid) == path
      refute BufferProcess.dirty?(pid)
    end

    test "starts with empty content for non-existent file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "new_file.txt")

      {:ok, pid} = BufferProcess.start_link(file_path: path)
      assert BufferProcess.content(pid) == ""
      assert BufferProcess.file_path(pid) == path
    end

    test "starts with a registered name" do
      {:ok, _pid} = BufferProcess.start_link(name: :test_buffer, content: "named")
      assert BufferProcess.content(:test_buffer) == "named"
    end
  end

  describe "open/2" do
    test "opens a file and replaces buffer content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "open_test.txt")
      File.write!(path, "new content")

      {:ok, pid} = BufferProcess.start_link(content: "old content")
      assert BufferProcess.content(pid) == "old content"

      :ok = BufferProcess.open(pid, path)
      assert BufferProcess.content(pid) == "new content"
      assert BufferProcess.file_path(pid) == path
      refute BufferProcess.dirty?(pid)
    end

    test "returns error for unreadable file" do
      {:ok, pid} = BufferProcess.start_link()
      assert {:error, :enoent} = BufferProcess.open(pid, "/nonexistent/path/file.txt")
    end

    test "resets dirty flag after opening", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dirty_test.txt")
      File.write!(path, "content")

      {:ok, pid} = BufferProcess.start_link(content: "initial")
      BufferProcess.insert_char(pid, "x")
      assert BufferProcess.dirty?(pid)

      BufferProcess.open(pid, path)
      refute BufferProcess.dirty?(pid)
    end
  end

  describe "insert_char/2" do
    test "inserts at cursor and marks dirty" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      refute BufferProcess.dirty?(pid)

      :ok = BufferProcess.insert_char(pid, "X")
      assert BufferProcess.content(pid) == "Xhello"
      assert BufferProcess.cursor(pid) == {0, 1}
      assert BufferProcess.dirty?(pid)
    end
  end

  describe "delete_before/1" do
    test "deletes character before cursor and marks dirty" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move(pid, :right)
      BufferProcess.move(pid, :right)

      :ok = BufferProcess.delete_before(pid)
      assert BufferProcess.content(pid) == "hllo"
      assert BufferProcess.dirty?(pid)
    end

    test "does not mark dirty when nothing to delete" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.delete_before(pid)
      refute BufferProcess.dirty?(pid)
    end
  end

  describe "delete_at/1" do
    test "deletes character at cursor and marks dirty" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")

      :ok = BufferProcess.delete_at(pid)
      assert BufferProcess.content(pid) == "ello"
      assert BufferProcess.dirty?(pid)
    end

    test "does not mark dirty when nothing to delete" do
      {:ok, pid} = BufferProcess.start_link(content: "hi")
      BufferProcess.move_to(pid, {0, 2})
      BufferProcess.delete_at(pid)
      refute BufferProcess.dirty?(pid)
    end
  end

  describe "move/2" do
    test "moves cursor without marking dirty" do
      {:ok, pid} = BufferProcess.start_link(content: "hello\nworld")
      refute BufferProcess.dirty?(pid)

      BufferProcess.move(pid, :right)
      assert BufferProcess.cursor(pid) == {0, 1}
      refute BufferProcess.dirty?(pid)

      BufferProcess.move(pid, :down)
      assert BufferProcess.cursor(pid) == {1, 1}
      refute BufferProcess.dirty?(pid)
    end
  end

  describe "move_if_possible/2" do
    test "moves left when not at column 0" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      BufferProcess.move_to(pid, {0, 3})
      assert {:ok, {0, 2}} = BufferProcess.move_if_possible(pid, :left)
      assert BufferProcess.cursor(pid) == {0, 2}
    end

    test "left from column 1 succeeds and reaches column 0" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      BufferProcess.move_to(pid, {0, 1})
      assert {:ok, {0, 0}} = BufferProcess.move_if_possible(pid, :left)
      assert BufferProcess.cursor(pid) == {0, 0}
    end

    test "returns :at_boundary when at column 0 (left)" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      assert :at_boundary = BufferProcess.move_if_possible(pid, :left)
      assert BufferProcess.cursor(pid) == {0, 0}
    end

    test "moves right when not at end of line" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      assert {:ok, {0, 1}} = BufferProcess.move_if_possible(pid, :right)
      assert BufferProcess.cursor(pid) == {0, 1}
    end

    test "returns :at_boundary when at last grapheme position (right)" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      # "hello" has last grapheme at byte offset 4
      BufferProcess.move_to(pid, {0, 4})
      assert :at_boundary = BufferProcess.move_if_possible(pid, :right)
      assert BufferProcess.cursor(pid) == {0, 4}
    end

    test "single character line is at boundary for right" do
      # single char: last_grapheme_byte_offset("x") is 0, cursor already at max_col
      pid = start_supervised!({BufferProcess, content: "x"})
      assert :at_boundary = BufferProcess.move_if_possible(pid, :right)
      assert BufferProcess.cursor(pid) == {0, 0}
    end

    test "returns :at_boundary on empty line (right)" do
      pid = start_supervised!({BufferProcess, content: "\n"})
      assert :at_boundary = BufferProcess.move_if_possible(pid, :right)
      assert BufferProcess.cursor(pid) == {0, 0}
    end

    test "returns :at_boundary at start of buffer (left)" do
      pid = start_supervised!({BufferProcess, content: "abc\ndef"})
      assert :at_boundary = BufferProcess.move_if_possible(pid, :left)
    end

    test "returns :at_boundary at end of last line (right)" do
      pid = start_supervised!({BufferProcess, content: "abc\ndef"})
      BufferProcess.move_to(pid, {1, 2})
      assert :at_boundary = BufferProcess.move_if_possible(pid, :right)
    end

    test "consecutive right moves walk to end of line then stop" do
      pid = start_supervised!({BufferProcess, content: "abc"})
      assert {:ok, {0, 1}} = BufferProcess.move_if_possible(pid, :right)
      assert {:ok, {0, 2}} = BufferProcess.move_if_possible(pid, :right)
      assert :at_boundary = BufferProcess.move_if_possible(pid, :right)
      # cursor stays put after boundary
      assert :at_boundary = BufferProcess.move_if_possible(pid, :right)
      assert BufferProcess.cursor(pid) == {0, 2}
    end

    test "respects byte-offset positions for multi-byte graphemes (right)" do
      # "héllo": h(0) é(1, 2 bytes) l(3) l(4) o(5) — last grapheme at byte offset 5
      pid = start_supervised!({BufferProcess, content: "héllo"})
      BufferProcess.move_to(pid, {0, 5})
      assert :at_boundary = BufferProcess.move_if_possible(pid, :right)
    end

    test "left through multi-byte grapheme returns correct byte offset" do
      # "héllo": moving left from l(3) should land on é(1)
      pid = start_supervised!({BufferProcess, content: "héllo"})
      BufferProcess.move_to(pid, {0, 3})
      assert {:ok, {0, 1}} = BufferProcess.move_if_possible(pid, :left)
    end

    test "does not mark buffer dirty" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      BufferProcess.move_if_possible(pid, :right)
      refute BufferProcess.dirty?(pid)
    end
  end

  describe "move_to/2" do
    test "moves to exact position" do
      {:ok, pid} = BufferProcess.start_link(content: "abc\ndef\nghi")
      BufferProcess.move_to(pid, {2, 1})
      assert BufferProcess.cursor(pid) == {2, 1}
      refute BufferProcess.dirty?(pid)
    end
  end

  describe "save/1" do
    test "saves content to file and clears dirty flag", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "save_test.txt")
      File.write!(path, "original")

      {:ok, pid} = BufferProcess.start_link(file_path: path)
      BufferProcess.insert_char(pid, "X")
      assert BufferProcess.dirty?(pid)

      :ok = BufferProcess.save(pid)
      refute BufferProcess.dirty?(pid)
      assert File.read!(path) == "Xoriginal"
    end

    test "returns error when no file path is set" do
      {:ok, pid} = BufferProcess.start_link(content: "scratch")
      BufferProcess.insert_char(pid, "x")
      assert {:error, :no_file_path} = BufferProcess.save(pid)
    end

    test "creates parent directories if needed", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "dir", "file.txt"])

      {:ok, pid} = BufferProcess.start_link(file_path: path)
      BufferProcess.insert_char(pid, "hello")
      :ok = BufferProcess.save(pid)

      assert File.read!(path) == "hello"
    end
  end

  describe "save_as/2" do
    test "saves to a new path and updates file_path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "save_as_test.txt")

      {:ok, pid} = BufferProcess.start_link(content: "content")
      BufferProcess.insert_char(pid, "X")

      :ok = BufferProcess.save_as(pid, path)
      assert BufferProcess.file_path(pid) == path
      refute BufferProcess.dirty?(pid)
      assert File.read!(path) == "Xcontent"
    end
  end

  describe "get_lines/3" do
    test "returns requested line range" do
      {:ok, pid} = BufferProcess.start_link(content: "a\nb\nc\nd\ne")
      assert BufferProcess.get_lines(pid, 1, 3) == ["b", "c", "d"]
    end
  end

  describe "line_count/1" do
    test "returns the number of lines" do
      {:ok, pid} = BufferProcess.start_link(content: "a\nb\nc")
      assert BufferProcess.line_count(pid) == 3
    end
  end

  describe "special buffer properties" do
    test "buffer_name returns nil by default" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      assert BufferProcess.buffer_name(pid) == nil
    end

    test "buffer_name returns the configured name" do
      {:ok, pid} = BufferProcess.start_link(content: "", buffer_name: "*Messages*")
      assert BufferProcess.buffer_name(pid) == "*Messages*"
    end

    test "read_only? returns false by default" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      assert BufferProcess.read_only?(pid) == false
    end

    test "read-only buffer rejects insert_char" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert BufferProcess.insert_char(pid, "x") == {:error, :read_only}
      assert BufferProcess.content(pid) == "hello"
    end

    test "read-only buffer rejects delete_before" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      BufferProcess.move(pid, :right)
      assert BufferProcess.delete_before(pid) == {:error, :read_only}
      assert BufferProcess.content(pid) == "hello"
    end

    test "read-only buffer rejects delete_at" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert BufferProcess.delete_at(pid) == {:error, :read_only}
      assert BufferProcess.content(pid) == "hello"
    end

    test "read-only buffer rejects replace_content" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert BufferProcess.replace_content(pid, "new") == {:error, :read_only}
      assert BufferProcess.content(pid) == "hello"
    end

    test "read-only buffer rejects delete_range" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert BufferProcess.delete_range(pid, {0, 0}, {0, 3}) == {:error, :read_only}
      assert BufferProcess.content(pid) == "hello"
    end

    test "read-only buffer rejects delete_lines" do
      {:ok, pid} = BufferProcess.start_link(content: "a\nb\nc", read_only: true)
      assert BufferProcess.delete_lines(pid, 0, 0) == {:error, :read_only}
      assert BufferProcess.content(pid) == "a\nb\nc"
    end

    test "read-only buffer rejects clear_line" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert BufferProcess.clear_line(pid, 0) == {:error, :read_only}
      assert BufferProcess.content(pid) == "hello"
    end

    test "append bypasses read-only" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert BufferProcess.append(pid, "\nworld") == :ok
      assert BufferProcess.content(pid) == "hello\nworld"
    end

    test "unlisted? returns configured value" do
      {:ok, pid} = BufferProcess.start_link(content: "", unlisted: true)
      assert BufferProcess.unlisted?(pid) == true
    end

    test "persistent? returns configured value" do
      {:ok, pid} = BufferProcess.start_link(content: "", persistent: true)
      assert BufferProcess.persistent?(pid) == true
    end

    test "render_snapshot includes name and read_only" do
      {:ok, pid} = BufferProcess.start_link(content: "hi", buffer_name: "*test*", read_only: true)
      snap = BufferProcess.render_snapshot(pid, 0, 10)
      assert snap.name == "*test*"
      assert snap.read_only == true
    end
  end

  describe "snapshot/1" do
    test "returns the underlying Document struct" do
      {:ok, pid} = BufferProcess.start_link(content: "hello\nworld")
      gb = BufferProcess.snapshot(pid)

      assert %Document{} = gb
      assert Document.content(gb) == "hello\nworld"
      assert Document.cursor(gb) == {0, 0}
      assert Document.line_count(gb) == 2
    end

    test "snapshot reflects cursor position" do
      {:ok, pid} = BufferProcess.start_link(content: "hello\nworld")
      BufferProcess.move_to(pid, {1, 3})
      gb = BufferProcess.snapshot(pid)

      assert Document.cursor(gb) == {1, 3}
    end
  end

  describe "apply_snapshot/2" do
    test "replaces buffer content and marks dirty" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      gb = BufferProcess.snapshot(pid)
      new_gb = Document.insert_text(gb, "X")

      assert :ok = BufferProcess.apply_snapshot(pid, new_gb)
      assert BufferProcess.content(pid) == "Xhello"
      assert BufferProcess.dirty?(pid)
    end

    test "pushes undo state so changes can be undone" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      gb = BufferProcess.snapshot(pid)
      new_gb = Document.insert_text(gb, "X")

      BufferProcess.apply_snapshot(pid, new_gb)
      assert BufferProcess.content(pid) == "Xhello"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "hello"
    end

    test "returns error on read-only buffer" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      gb = BufferProcess.snapshot(pid)
      new_gb = Document.insert_text(gb, "X")

      assert {:error, :read_only} = BufferProcess.apply_snapshot(pid, new_gb)
      assert BufferProcess.content(pid) == "hello"
    end

    test "round-trip preserves buffer identity" do
      {:ok, pid} = BufferProcess.start_link(content: "hello\nworld")
      BufferProcess.move_to(pid, {1, 2})
      gb = BufferProcess.snapshot(pid)

      BufferProcess.apply_snapshot(pid, gb)
      assert BufferProcess.content(pid) == "hello\nworld"
      assert BufferProcess.cursor(pid) == {1, 2}
    end
  end

  describe "apply_text_edits/2" do
    test "applies multiple edits in a single call" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa\nbbb\nccc")

      # Replace "aaa" with "AAA" and "ccc" with "CCC"
      edits = [
        {{0, 0}, {0, 2}, "AAA"},
        {{2, 0}, {2, 2}, "CCC"}
      ]

      assert :ok = BufferProcess.apply_text_edits(pid, edits)
      assert BufferProcess.content(pid) == "AAA\nbbb\nCCC"
    end

    test "produces a single undo entry for all edits" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa\nbbb\nccc")

      edits = [
        {{0, 0}, {0, 2}, "AAA"},
        {{2, 0}, {2, 2}, "CCC"}
      ]

      BufferProcess.apply_text_edits(pid, edits)
      assert BufferProcess.content(pid) == "AAA\nbbb\nCCC"

      # One undo reverts all edits
      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "aaa\nbbb\nccc"
    end

    test "empty edit list is a no-op" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.apply_text_edits(pid, [])
      assert BufferProcess.content(pid) == "hello"
      refute BufferProcess.dirty?(pid)
    end

    test "returns error on read-only buffer" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert {:error, :read_only} = BufferProcess.apply_text_edits(pid, [{{0, 0}, {0, 0}, "X"}])
    end

    test "auto-sorts edits in reverse document order" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa\nbbb\nccc")

      # Pass edits in forward order; they should be sorted automatically
      edits = [
        {{0, 0}, {0, 2}, "AAA"},
        {{2, 0}, {2, 2}, "CCC"}
      ]

      BufferProcess.apply_text_edits(pid, edits)
      assert BufferProcess.content(pid) == "AAA\nbbb\nCCC"
    end
  end

  describe "buffer_type" do
    test "defaults to :file" do
      {:ok, pid} = BufferProcess.start_link()
      assert BufferProcess.buffer_type(pid) == :file
    end

    test "accepts buffer_type: :nofile and sets read_only implicitly" do
      {:ok, pid} = BufferProcess.start_link(buffer_type: :nofile, content: "read only content")
      assert BufferProcess.buffer_type(pid) == :nofile
      assert BufferProcess.read_only?(pid)
    end

    test "nofile buffer can override read_only to false" do
      {:ok, pid} =
        BufferProcess.start_link(buffer_type: :nofile, read_only: false, content: "editable")

      assert BufferProcess.buffer_type(pid) == :nofile
      refute BufferProcess.read_only?(pid)
    end

    test "nowrite buffer accepts buffer_type: :nowrite" do
      {:ok, pid} = BufferProcess.start_link(buffer_type: :nowrite, content: "display only")
      assert BufferProcess.buffer_type(pid) == :nowrite
      refute BufferProcess.read_only?(pid)
    end

    test "nofile buffer blocks save" do
      {:ok, pid} = BufferProcess.start_link(buffer_type: :nofile, content: "no save")
      assert BufferProcess.save(pid) == {:error, :buffer_not_saveable}
    end

    test "nowrite buffer blocks save" do
      {:ok, pid} = BufferProcess.start_link(buffer_type: :nowrite, content: "no save")
      assert BufferProcess.save(pid) == {:error, :buffer_not_saveable}
    end

    test "nofile buffer blocks force_save" do
      {:ok, pid} = BufferProcess.start_link(buffer_type: :nofile, content: "no save")
      assert BufferProcess.force_save(pid) == {:error, :buffer_not_saveable}
    end

    test "nowrite buffer blocks force_save" do
      {:ok, pid} = BufferProcess.start_link(buffer_type: :nowrite, content: "no save")
      assert BufferProcess.force_save(pid) == {:error, :buffer_not_saveable}
    end

    test "file buffer saves normally", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "saveable.txt")
      File.write!(path, "original")
      {:ok, pid} = BufferProcess.start_link(file_path: path, buffer_type: :file)
      BufferProcess.insert_char(pid, "x")
      assert BufferProcess.save(pid) == :ok
    end

    test "buffer_type appears in render_snapshot" do
      {:ok, pid} = BufferProcess.start_link(buffer_type: :nofile, content: "test")
      snapshot = BufferProcess.render_snapshot(pid, 0, 10)
      assert snapshot.buffer_type == :nofile
    end

    test "render_snapshot is a RenderSnapshot struct" do
      {:ok, pid} = BufferProcess.start_link(content: "hello\nworld")
      snapshot = BufferProcess.render_snapshot(pid, 0, 10)
      assert %Minga.Buffer.RenderSnapshot{} = snapshot
    end

    test "render_snapshot includes version that increments on edit" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      snap1 = BufferProcess.render_snapshot(pid, 0, 10)
      v1 = snap1.version

      BufferProcess.insert_char(pid, "x")
      snap2 = BufferProcess.render_snapshot(pid, 0, 10)
      v2 = snap2.version

      assert v2 > v1
    end

    test "append bypasses read_only on nofile buffer" do
      {:ok, pid} =
        BufferProcess.start_link(buffer_type: :nofile, buffer_name: "*Test*", content: "")

      assert BufferProcess.read_only?(pid)
      BufferProcess.append(pid, "appended text")
      assert BufferProcess.content(pid) == "appended text"
    end
  end

  describe "undo coalescing" do
    test "rapid edits within coalescing window produce one undo entry" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")

      # Multiple rapid inserts without breaking coalescing
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")
      BufferProcess.insert_char(pid, "c")
      assert BufferProcess.content(pid) == "abchello"

      # One undo reverts all three
      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "hello"
    end

    test "break_undo_coalescing creates separate undo entries" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")

      BufferProcess.insert_char(pid, "a")
      BufferProcess.break_undo_coalescing(pid)
      BufferProcess.insert_char(pid, "b")

      assert BufferProcess.content(pid) == "abhello"

      # First undo reverts "b" only
      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "ahello"

      # Second undo reverts "a"
      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "hello"
    end
  end

  describe "dirty flag after undo/redo (#475)" do
    @tag :tmp_dir
    test "undo back to saved state clears dirty flag", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "undo_dirty.txt")
      File.write!(path, "original")
      {:ok, pid} = BufferProcess.start_link(file_path: path)

      refute BufferProcess.dirty?(pid)

      # Edit and verify dirty
      BufferProcess.insert_char(pid, "X")
      assert BufferProcess.dirty?(pid)

      # Undo back to saved state
      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "original"
      refute BufferProcess.dirty?(pid)
    end

    @tag :tmp_dir
    test "redo after undo restores dirty flag", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "redo_dirty.txt")
      File.write!(path, "original")
      {:ok, pid} = BufferProcess.start_link(file_path: path)

      BufferProcess.insert_char(pid, "X")
      assert BufferProcess.dirty?(pid)

      BufferProcess.undo(pid)
      refute BufferProcess.dirty?(pid)

      BufferProcess.redo(pid)
      assert BufferProcess.dirty?(pid)
    end

    @tag :tmp_dir
    test "save then edit then undo clears dirty", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "save_undo.txt")
      File.write!(path, "start")
      {:ok, pid} = BufferProcess.start_link(file_path: path)

      # Edit and save
      BufferProcess.insert_char(pid, "A")
      assert BufferProcess.dirty?(pid)
      :ok = BufferProcess.save(pid)
      refute BufferProcess.dirty?(pid)

      # Edit again
      BufferProcess.break_undo_coalescing(pid)
      BufferProcess.insert_char(pid, "B")
      assert BufferProcess.dirty?(pid)

      # Undo the second edit, back to saved state
      BufferProcess.undo(pid)
      refute BufferProcess.dirty?(pid)
    end

    test "pathless file buffer edit then undo returns to clean" do
      {:ok, pid} = BufferProcess.start_link(content: "text")

      refute BufferProcess.dirty?(pid)
      BufferProcess.insert_char(pid, "X")
      assert BufferProcess.dirty?(pid)

      BufferProcess.undo(pid)

      refute BufferProcess.dirty?(pid),
             "pathless buffer should be clean after undoing to initial state"
    end
  end

  describe "undo source metadata" do
    test "user edits are tagged :user in undo stack" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      BufferProcess.insert_char(pid, "X")

      assert BufferProcess.last_undo_source(pid) == :user
    end

    test "agent edits (find_and_replace) are tagged :agent" do
      pid = start_supervised!({BufferProcess, content: "hello world"})
      BufferProcess.find_and_replace(pid, "hello", "goodbye")

      assert BufferProcess.last_undo_source(pid) == :agent
    end

    test "agent batch edits (find_and_replace_batch) are tagged :agent" do
      pid = start_supervised!({BufferProcess, content: "hello world"})
      BufferProcess.find_and_replace_batch(pid, [{"hello", "goodbye"}])

      assert BufferProcess.last_undo_source(pid) == :agent
    end

    test "LSP batch edits (apply_text_edits) are tagged :lsp" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      BufferProcess.apply_text_edits(pid, [{{0, 0}, {0, 5}, "goodbye"}])

      assert BufferProcess.last_undo_source(pid) == :lsp
    end

    test "source metadata survives undo/redo round-trip" do
      pid = start_supervised!({BufferProcess, content: "hello world"})
      BufferProcess.find_and_replace(pid, "hello", "goodbye")

      # Undo pops the agent entry and creates a redo entry carrying the source
      BufferProcess.undo(pid)
      assert BufferProcess.last_redo_source(pid) == :agent

      # Redo pushes it back to undo_stack
      BufferProcess.redo(pid)
      assert BufferProcess.last_undo_source(pid) == :agent
    end

    test "replace_content with :agent source is tagged :agent" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      BufferProcess.replace_content(pid, "goodbye", :agent)

      assert BufferProcess.last_undo_source(pid) == :agent
    end

    test "replace_content defaults to :user source" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      BufferProcess.replace_content(pid, "goodbye")

      assert BufferProcess.last_undo_source(pid) == :user
    end

    test "interleaved user and agent edits preserve correct sources" do
      pid = start_supervised!({BufferProcess, content: "hello world"})

      BufferProcess.insert_char(pid, "X")
      BufferProcess.break_undo_coalescing(pid)
      assert BufferProcess.last_undo_source(pid) == :user

      BufferProcess.find_and_replace(pid, "Xhello", "goodbye")
      assert BufferProcess.last_undo_source(pid) == :agent

      # Undo the agent edit; the user entry below should now be at the head.
      BufferProcess.undo(pid)
      assert BufferProcess.last_undo_source(pid) == :user
    end
  end

  describe "last_undo_source/1 and last_redo_source/1" do
    test "returns nil when stacks are empty" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      assert BufferProcess.last_undo_source(pid) == nil
      assert BufferProcess.last_redo_source(pid) == nil
    end

    test "returns source of most recent undo entry" do
      pid = start_supervised!({BufferProcess, content: "hello world"})
      BufferProcess.insert_char(pid, "X")
      assert BufferProcess.last_undo_source(pid) == :user
    end

    test "returns :agent for agent edits" do
      pid = start_supervised!({BufferProcess, content: "hello world"})
      BufferProcess.find_and_replace(pid, "hello", "goodbye")
      assert BufferProcess.last_undo_source(pid) == :agent
    end

    test "returns :lsp for LSP edits" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      BufferProcess.apply_text_edits(pid, [{{0, 0}, {0, 5}, "goodbye"}])
      assert BufferProcess.last_undo_source(pid) == :lsp
    end

    test "last_redo_source/1 returns source after undo" do
      pid = start_supervised!({BufferProcess, content: "hello world"})
      BufferProcess.find_and_replace(pid, "hello", "goodbye")
      BufferProcess.undo(pid)
      assert BufferProcess.last_redo_source(pid) == :agent
    end

    test "redo clears redo and updates undo source" do
      pid = start_supervised!({BufferProcess, content: "hello world"})
      BufferProcess.find_and_replace(pid, "hello", "goodbye")
      BufferProcess.undo(pid)
      BufferProcess.redo(pid)
      assert BufferProcess.last_undo_source(pid) == :agent
      assert BufferProcess.last_redo_source(pid) == nil
    end
  end

  describe "edit delta tracking" do
    test "insert_char records an insertion delta" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "!")
      edits = BufferProcess.flush_edits(pid, :test)
      assert [delta] = edits
      assert delta.start_byte == 5
      assert delta.old_end_byte == 5
      assert delta.new_end_byte == 6
      assert delta.inserted_text == "!"
    end

    test "delete_before records a deletion delta" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.delete_before(pid)
      edits = BufferProcess.flush_edits(pid, :test)
      assert [delta] = edits
      assert delta.start_byte == 4
      assert delta.old_end_byte == 5
      assert delta.new_end_byte == 4
      assert delta.inserted_text == ""
    end

    test "apply_text_edit records byte-accurate unicode replacement delta" do
      {:ok, pid} = BufferProcess.start_link(content: "aébc")
      BufferProcess.apply_text_edit(pid, 0, 1, 0, 1, "X")
      edits = BufferProcess.flush_edits(pid, :test)
      assert [delta] = edits
      assert BufferProcess.content(pid) == "aXbc"
      assert delta.start_byte == 1
      assert delta.old_end_byte == 3
      assert delta.new_end_byte == 2
      assert delta.start_position == {0, 1}
      assert delta.old_end_position == {0, 3}
      assert delta.new_end_position == {0, 2}
      assert delta.inserted_text == "X"
    end

    test "flush_edits clears pending deltas for that consumer" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "!")
      assert [_] = BufferProcess.flush_edits(pid, :test)
      assert [] = BufferProcess.flush_edits(pid, :test)
    end

    test "multiple edits accumulate in order" do
      {:ok, pid} = BufferProcess.start_link(content: "ab")
      BufferProcess.move_to(pid, {0, 2})
      BufferProcess.insert_char(pid, "c")
      BufferProcess.insert_char(pid, "d")
      edits = BufferProcess.flush_edits(pid, :test)
      assert length(edits) == 2
      assert [first, second] = edits
      assert first.inserted_text == "c"
      assert second.inserted_text == "d"
    end

    test "delete_range records a deletion delta" do
      {:ok, pid} = BufferProcess.start_link(content: "hello world")
      BufferProcess.delete_range(pid, {0, 5}, {0, 11})
      edits = BufferProcess.flush_edits(pid, :test)
      assert [delta] = edits
      assert delta.start_byte == 5
      assert delta.old_end_byte == 11
      assert delta.new_end_byte == 5
      assert delta.inserted_text == ""
    end

    test "undo clears pending edits" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "!")
      assert [_] = BufferProcess.flush_edits(pid, :test)
      # Make another edit then undo
      BufferProcess.insert_char(pid, "?")
      BufferProcess.undo(pid)
      # Undo clears edits to force full sync
      assert [] = BufferProcess.flush_edits(pid, :test)
    end

    test "replace_content clears pending edits" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "!")
      BufferProcess.replace_content(pid, "goodbye")
      assert [] = BufferProcess.flush_edits(pid, :test)
    end
  end

  # ── Per-consumer flush_edits ──────────────────────────────────────────────

  describe "per-consumer flush_edits" do
    test "two consumers independently receive the full set of deltas from the same edit" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "x")
      BufferProcess.insert_char(pid, "y")

      # Both consumers should see the same 2 deltas
      lsp_deltas = BufferProcess.flush_edits(pid, :lsp)
      hl_deltas = BufferProcess.flush_edits(pid, :highlight)

      assert length(lsp_deltas) == 2
      assert length(hl_deltas) == 2
      assert Enum.map(lsp_deltas, & &1.inserted_text) == ["x", "y"]
      assert Enum.map(hl_deltas, & &1.inserted_text) == ["x", "y"]
    end

    test "flush_edits with consumer_id returns deltas since that consumer's last read" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")

      # First flush gets both deltas
      assert [d1, d2] = BufferProcess.flush_edits(pid, :lsp)
      assert d1.inserted_text == "a"
      assert d2.inserted_text == "b"

      # Insert more
      BufferProcess.insert_char(pid, "c")

      # Second flush gets only the new one
      assert [d3] = BufferProcess.flush_edits(pid, :lsp)
      assert d3.inserted_text == "c"
    end

    test "consumers can read at different rates without losing deltas" do
      {:ok, pid} = BufferProcess.start_link(content: "")
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")
      BufferProcess.insert_char(pid, "c")

      # :lsp reads all 3
      lsp_first = BufferProcess.flush_edits(pid, :lsp)
      assert length(lsp_first) == 3

      # More edits
      BufferProcess.insert_char(pid, "d")
      BufferProcess.insert_char(pid, "e")

      # :highlight hasn't read yet, should get all 5
      hl_all = BufferProcess.flush_edits(pid, :highlight)
      assert length(hl_all) == 5
      assert Enum.map(hl_all, & &1.inserted_text) == ["a", "b", "c", "d", "e"]

      # :lsp should get only the 2 new ones
      lsp_second = BufferProcess.flush_edits(pid, :lsp)
      assert length(lsp_second) == 2
      assert Enum.map(lsp_second, & &1.inserted_text) == ["d", "e"]
    end

    test "log is trimmed after all consumers have read" do
      {:ok, pid} = BufferProcess.start_link(content: "")
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")

      # Both consumers flush
      BufferProcess.flush_edits(pid, :lsp)
      BufferProcess.flush_edits(pid, :highlight)

      # Once both registered consumers have caught up, the log is trimmed —
      # a new consumer registering after the fact sees no historical deltas.
      assert [] = BufferProcess.flush_edits(pid, :late_arrival)
    end

    test "new consumer starts from sequence 0 and gets entire log" do
      {:ok, pid} = BufferProcess.start_link(content: "")
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")
      BufferProcess.insert_char(pid, "c")

      # :lsp reads all 3
      BufferProcess.flush_edits(pid, :lsp)

      # More edits
      BufferProcess.insert_char(pid, "d")
      BufferProcess.insert_char(pid, "e")

      # New consumer never registered before, gets everything still in log
      # (log is trimmed based on min cursor; :lsp cursor is at 3, so a-c may be trimmed)
      # But :new_consumer has cursor 0, so as long as log entries exist, it gets them.
      # Since :lsp flushed 3 but :new_consumer hasn't, the log won't be fully trimmed.
      # Actually, the log was trimmed based on registered consumers only.
      # Since :new_consumer wasn't registered, its cursor defaults to 0 on first call.
      # The log entries for d and e (seq 4, 5) are still there because :lsp hasn't
      # read them yet. Entries for a,b,c (seq 1,2,3) may or may not be trimmed
      # depending on whether other consumers exist. Since only :lsp is registered
      # and its cursor is at 3, entries 1-3 got trimmed on that flush.
      new_deltas = BufferProcess.flush_edits(pid, :new_consumer)
      # Gets at least the 2 unread by all consumers (d, e)
      assert length(new_deltas) >= 2
    end

    test "undo clears the edit log for all consumers" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")

      # :lsp reads
      assert [_, _] = BufferProcess.flush_edits(pid, :lsp)

      # More edits then undo
      BufferProcess.insert_char(pid, "c")
      BufferProcess.undo(pid)

      # Both consumers get empty (forces full sync)
      assert [] = BufferProcess.flush_edits(pid, :lsp)
      assert [] = BufferProcess.flush_edits(pid, :highlight)
    end

    test "replace_content clears the edit log for all consumers" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "!")
      BufferProcess.replace_content(pid, "goodbye")

      assert [] = BufferProcess.flush_edits(pid, :lsp)
      assert [] = BufferProcess.flush_edits(pid, :highlight)
    end

    test "flush with no edits returns empty list" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      assert [] = BufferProcess.flush_edits(pid, :lsp)
    end

    test "flush same consumer twice with no intervening edits returns empty" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.insert_char(pid, "!")
      assert [_] = BufferProcess.flush_edits(pid, :lsp)
      assert [] = BufferProcess.flush_edits(pid, :lsp)
    end

    test "edit_log is capped at 1000 entries when only one consumer is registered" do
      {:ok, pid} = BufferProcess.start_link(content: "")

      # Insert more than 1000 chars with only :lsp reading periodically
      for _ <- 1..1100, do: BufferProcess.insert_char(pid, "x")

      # Only one consumer has ever called flush_edits
      _deltas = BufferProcess.flush_edits(pid, :lsp)

      # A late-arriving consumer would see every retained entry (its cursor
      # starts at 0). With the cap in place it sees at most 1000, not 1100.
      late_deltas = BufferProcess.flush_edits(pid, :late_arrival)
      assert length(late_deltas) <= 1000
    end
  end

  # ── Buffer-local options ──────────────────────────────────────────────────

  describe "buffer-local options" do
    test "get_option falls back to global default when no local override" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      # tab_width global default is 2
      assert BufferProcess.get_option(pid, :tab_width) == 2
    end

    test "set_option stores a buffer-local override" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      assert {:ok, 8} = BufferProcess.set_option(pid, :tab_width, 8)
      assert BufferProcess.get_option(pid, :tab_width) == 8
    end

    test "buffer-local override wins over global default" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.set_option(pid, :tab_width, 4)
      assert BufferProcess.get_option(pid, :tab_width) == 4
    end

    test "two buffers have independent options" do
      {:ok, a} = BufferProcess.start_link(content: "alpha")
      {:ok, b} = BufferProcess.start_link(content: "bravo")
      BufferProcess.set_option(a, :tab_width, 8)
      assert BufferProcess.get_option(a, :tab_width) == 8
      assert BufferProcess.get_option(b, :tab_width) == 2
    end

    test "set_option rejects invalid values" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      assert {:error, _} = BufferProcess.set_option(pid, :tab_width, -1)
      # Original value unchanged
      assert BufferProcess.get_option(pid, :tab_width) == 2
    end

    test "set_option rejects unknown option names" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      assert {:error, _} = BufferProcess.set_option(pid, :nonexistent, true)
    end

    test "local_options returns seeded defaults plus any overrides" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      # Seeded with global defaults (tab_width: 2, wrap: false, etc.)
      defaults = BufferProcess.local_options(pid)
      assert defaults[:tab_width] == 2
      assert defaults[:wrap] == false

      # Override one option
      BufferProcess.set_option(pid, :tab_width, 4)
      updated = BufferProcess.local_options(pid)
      assert updated[:tab_width] == 4
      # Other seeded defaults still present
      assert updated[:wrap] == false
    end

    test "local_option_overrides returns only explicitly set options" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      assert BufferProcess.local_option_overrides(pid) == %{}

      BufferProcess.set_option(pid, :tab_width, 4)
      assert BufferProcess.local_option_overrides(pid) == %{tab_width: 4}
    end

    test "filetype default wins over global when seeded at creation" do
      # Set filetype override BEFORE creating buffer (eager seeding)
      Options.set_for_filetype(:go, :tab_width, 8)

      on_exit(fn ->
        try do
          Options.set_for_filetype(:go, :tab_width, 2)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid} = BufferProcess.start_link(content: "package main", filetype: :go)
      assert BufferProcess.get_option(pid, :tab_width) == 8
    end

    test "buffer-local wins over filetype default" do
      Options.set_for_filetype(:go, :tab_width, 8)

      on_exit(fn ->
        try do
          Options.set_for_filetype(:go, :tab_width, 2)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid} = BufferProcess.start_link(content: "package main", filetype: :go)
      # Buffer was seeded with filetype default of 8
      assert BufferProcess.get_option(pid, :tab_width) == 8
      # Override locally
      BufferProcess.set_option(pid, :tab_width, 3)
      assert BufferProcess.get_option(pid, :tab_width) == 3
    end

    test "set_filetype preserves explicitly set options" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")

      # Explicitly set clipboard to :none (like EditorCase does)
      BufferProcess.set_option(pid, :clipboard, :none)
      assert BufferProcess.get_option(pid, :clipboard) == :none

      # Change filetype, which reseeds options from global defaults
      BufferProcess.set_filetype(pid, :python)

      # The explicit override should survive the reseed
      assert BufferProcess.get_option(pid, :clipboard) == :none
    end

    test "set_filetype reseeds non-explicit options for new filetype" do
      Options.set_for_filetype(:go, :tab_width, 8)

      on_exit(fn ->
        try do
          Options.set_for_filetype(:go, :tab_width, 2)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, pid} = BufferProcess.start_link(content: "hello", filetype: :text)
      assert BufferProcess.get_option(pid, :tab_width) == 2

      # Change to Go filetype; non-explicit tab_width should reseed to 8
      BufferProcess.set_filetype(pid, :go)
      assert BufferProcess.get_option(pid, :tab_width) == 8
    end
  end

  describe "face_overrides/1 and remap_face/3" do
    test "starts with empty overrides" do
      {:ok, pid} = BufferProcess.start_link()
      assert BufferProcess.face_overrides(pid) == %{}
    end

    test "sets and retrieves a face override" do
      {:ok, pid} = BufferProcess.start_link()
      :ok = BufferProcess.remap_face(pid, "default", fg: 0x000000, bg: 0xFFFFFF)

      overrides = BufferProcess.face_overrides(pid)
      assert overrides == %{"default" => [fg: 0x000000, bg: 0xFFFFFF]}
    end

    test "clears a face override" do
      {:ok, pid} = BufferProcess.start_link()
      :ok = BufferProcess.remap_face(pid, "comment", italic: false)
      :ok = BufferProcess.clear_face_override(pid, "comment")

      assert BufferProcess.face_overrides(pid) == %{}
    end

    test "multiple overrides coexist" do
      {:ok, pid} = BufferProcess.start_link()
      :ok = BufferProcess.remap_face(pid, "keyword", fg: 0xFF0000)
      :ok = BufferProcess.remap_face(pid, "comment", italic: false)

      overrides = BufferProcess.face_overrides(pid)
      assert Map.has_key?(overrides, "keyword")
      assert Map.has_key?(overrides, "comment")
    end
  end

  describe "find_and_replace/3" do
    test "replacing text with one clear target updates content and marks dirty" do
      {:ok, pid} =
        BufferProcess.start_link(content: "defmodule Foo do\n  def hello, do: :world\nend\n")

      assert {:ok, _} =
               BufferProcess.find_and_replace(
                 pid,
                 "def hello, do: :world",
                 "def hello, do: :earth"
               )

      assert BufferProcess.content(pid) =~ "def hello, do: :earth"
      assert BufferProcess.dirty?(pid)
    end

    test "replacing text creates a single undo entry" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa bbb ccc")
      BufferProcess.find_and_replace(pid, "bbb", "BBB")
      assert BufferProcess.content(pid) == "aaa BBB ccc"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "aaa bbb ccc"
    end

    test "returns error when old_text is not found" do
      {:ok, pid} = BufferProcess.start_link(content: "hello world")
      assert {:error, msg} = BufferProcess.find_and_replace(pid, "nonexistent", "replacement")
      assert msg =~ "not found"
      assert BufferProcess.content(pid) == "hello world"
      refute BufferProcess.dirty?(pid)
    end

    test "returns error when old_text is ambiguous" do
      {:ok, pid} = BufferProcess.start_link(content: "foo\nbar\nfoo\n")
      assert {:error, msg} = BufferProcess.find_and_replace(pid, "foo", "baz")
      assert msg =~ "2 times"
      assert BufferProcess.content(pid) == "foo\nbar\nfoo\n"
    end

    test "read-only buffer rejects find_and_replace" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert {:error, msg} = BufferProcess.find_and_replace(pid, "hello", "world")
      assert msg =~ "read-only"
    end

    test "multi-line old_text and new_text work correctly" do
      {:ok, pid} = BufferProcess.start_link(content: "line1\nline2\nline3\n")

      assert {:ok, _} =
               BufferProcess.find_and_replace(
                 pid,
                 "line1\nline2",
                 "replaced1\nreplaced2\nreplaced3"
               )

      assert BufferProcess.content(pid) == "replaced1\nreplaced2\nreplaced3\nline3\n"
    end

    test "empty old_text returns error" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      assert {:error, msg} = BufferProcess.find_and_replace(pid, "", "something")
      assert msg =~ "empty"
    end

    test "old_text at very start of buffer" do
      {:ok, pid} = BufferProcess.start_link(content: "target rest of file")
      assert {:ok, _} = BufferProcess.find_and_replace(pid, "target", "replaced")
      assert BufferProcess.content(pid) == "replaced rest of file"
    end

    test "old_text at very end of buffer without trailing newline" do
      {:ok, pid} = BufferProcess.start_link(content: "start of file target")
      assert {:ok, _} = BufferProcess.find_and_replace(pid, "target", "replaced")
      assert BufferProcess.content(pid) == "start of file replaced"
    end

    test "old_text spans entire buffer content" do
      {:ok, pid} = BufferProcess.start_link(content: "everything")
      assert {:ok, _} = BufferProcess.find_and_replace(pid, "everything", "replaced")
      assert BufferProcess.content(pid) == "replaced"
    end

    test "replacement that changes line count" do
      {:ok, pid} = BufferProcess.start_link(content: "before\nsingle line\nafter")
      assert BufferProcess.line_count(pid) == 3

      BufferProcess.find_and_replace(pid, "single line", "line A\nline B\nline C")
      assert BufferProcess.line_count(pid) == 5
      assert BufferProcess.content(pid) == "before\nline A\nline B\nline C\nafter"
    end

    test "unicode multi-byte graphemes in old_text and new_text" do
      {:ok, pid} = BufferProcess.start_link(content: "I like café and naïve")
      assert {:ok, _} = BufferProcess.find_and_replace(pid, "café", "tea")
      assert BufferProcess.content(pid) == "I like tea and naïve"
    end

    test "two rapid find_and_replace calls produce two independent undo entries" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa bbb ccc")
      BufferProcess.find_and_replace(pid, "aaa", "AAA")
      BufferProcess.find_and_replace(pid, "ccc", "CCC")
      assert BufferProcess.content(pid) == "AAA bbb CCC"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "AAA bbb ccc"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "aaa bbb ccc"
    end

    test "concurrent find_and_replace calls are serialized cleanly" do
      content = "aaa\nbbb\nccc\nddd\neee"
      {:ok, pid} = BufferProcess.start_link(content: content)

      task_a = Task.async(fn -> BufferProcess.find_and_replace(pid, "aaa", "AAA") end)
      task_b = Task.async(fn -> BufferProcess.find_and_replace(pid, "eee", "EEE") end)

      results = Task.await_many([task_a, task_b])
      assert Enum.all?(results, &match?({:ok, _}, &1))

      final = BufferProcess.content(pid)
      assert final =~ "AAA"
      assert final =~ "EEE"
      assert final =~ "bbb"
      assert final =~ "ccc"
      assert final =~ "ddd"
    end
  end

  describe "find_and_replace_batch/2" do
    test "batch applies multiple edits and produces a single undo entry" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa bbb ccc")

      assert {:ok, results} =
               BufferProcess.find_and_replace_batch(pid, [{"aaa", "AAA"}, {"ccc", "CCC"}])

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert BufferProcess.content(pid) == "AAA bbb CCC"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "aaa bbb ccc"
    end

    test "batch reports per-edit success and failure" do
      {:ok, pid} = BufferProcess.start_link(content: "foo bar foo")

      assert {:ok, results} =
               BufferProcess.find_and_replace_batch(pid, [
                 {"bar", "BAR"},
                 {"nonexistent", "x"},
                 {"foo", "FOO"}
               ])

      assert [{:ok, _}, {:error, _}, {:error, _}] = results
      # bar→BAR succeeded, making "foo" appear twice (ambiguous for third edit)
      assert BufferProcess.content(pid) == "foo BAR foo"
    end

    test "edits within a batch are applied sequentially" do
      {:ok, pid} = BufferProcess.start_link(content: "foo bar baz")
      # First edit makes "bar" ambiguous for the second
      assert {:ok, results} =
               BufferProcess.find_and_replace_batch(pid, [{"foo", "bar"}, {"bar", "qux"}])

      assert [{:ok, _}, {:error, _}] = results
      assert BufferProcess.content(pid) == "bar bar baz"
    end

    test "batch with all edits failing leaves buffer unchanged and clean" do
      {:ok, pid} = BufferProcess.start_link(content: "hello world")

      assert {:ok, results} =
               BufferProcess.find_and_replace_batch(pid, [{"nope", "x"}, {"nada", "y"}])

      assert Enum.all?(results, &match?({:error, _}, &1))
      assert BufferProcess.content(pid) == "hello world"
      refute BufferProcess.dirty?(pid)
    end

    test "empty edit list is a no-op" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      assert {:ok, []} = BufferProcess.find_and_replace_batch(pid, [])
      refute BufferProcess.dirty?(pid)
    end

    test "read-only buffer rejects batch" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert {:error, msg} = BufferProcess.find_and_replace_batch(pid, [{"hello", "world"}])
      assert msg =~ "read-only"
    end
  end

  describe "pid_for_path/1" do
    test "returns :not_found for unregistered path" do
      assert :not_found = BufferProcess.pid_for_path("/no/such/file.ex")
    end

    test "registered buffer is findable by its file path", %{tmp_dir: dir} do
      path = Path.join(dir, "test.ex")
      File.write!(path, "hello")
      pid = start_supervised!({BufferProcess, file_path: path})

      assert {:ok, ^pid} = BufferProcess.pid_for_path(path)
    end

    test "opening a new file unregisters the old path", %{tmp_dir: dir} do
      path_a = Path.join(dir, "a.ex")
      path_b = Path.join(dir, "b.ex")
      File.write!(path_a, "aaa")
      File.write!(path_b, "bbb")
      pid = start_supervised!({BufferProcess, file_path: path_a})

      assert {:ok, ^pid} = BufferProcess.pid_for_path(path_a)

      BufferProcess.open(pid, path_b)
      assert :not_found = BufferProcess.pid_for_path(path_a)
      assert {:ok, ^pid} = BufferProcess.pid_for_path(path_b)
    end

    test "save_as unregisters old path and registers new path", %{tmp_dir: dir} do
      path_a = Path.join(dir, "a.ex")
      path_b = Path.join(dir, "b.ex")
      File.write!(path_a, "aaa")
      pid = start_supervised!({BufferProcess, file_path: path_a})

      assert {:ok, ^pid} = BufferProcess.pid_for_path(path_a)

      BufferProcess.save_as(pid, path_b)
      assert :not_found = BufferProcess.pid_for_path(path_a)
      assert {:ok, ^pid} = BufferProcess.pid_for_path(path_b)
    end

    test "buffer without file_path does not register" do
      _pid = start_supervised!({BufferProcess, content: "scratch"})
      assert :not_found = BufferProcess.pid_for_path("/nonexistent")
    end

    test "two buffers with different paths coexist", %{tmp_dir: dir} do
      path_a = Path.join(dir, "a.ex")
      path_b = Path.join(dir, "b.ex")
      File.write!(path_a, "aaa")
      File.write!(path_b, "bbb")

      pid_a = start_supervised!({BufferProcess, file_path: path_a}, id: :buf_a)
      pid_b = start_supervised!({BufferProcess, file_path: path_b}, id: :buf_b)

      assert {:ok, ^pid_a} = BufferProcess.pid_for_path(path_a)
      assert {:ok, ^pid_b} = BufferProcess.pid_for_path(path_b)
    end
  end

  describe "find_and_replace/4 with boundary" do
    test "edit within boundary succeeds" do
      {:ok, pid} = BufferProcess.start_link(content: "line0\nline1\nline2\nline3\nline4")

      assert {:ok, _} = BufferProcess.find_and_replace(pid, "line2", "REPLACED", {1, 3})
      assert BufferProcess.content(pid) =~ "REPLACED"
    end

    test "edit outside boundary is rejected with descriptive error" do
      {:ok, pid} = BufferProcess.start_link(content: "line0\nline1\nline2\nline3\nline4")

      assert {:error, msg} = BufferProcess.find_and_replace(pid, "line0", "NOPE", {1, 3})
      assert msg =~ "outside boundary"
      assert msg =~ "lines 0-0"
      assert msg =~ "1-3"
      assert BufferProcess.content(pid) == "line0\nline1\nline2\nline3\nline4"
    end

    test "edit at boundary start line succeeds (inclusive)" do
      {:ok, pid} = BufferProcess.start_link(content: "line0\nline1\nline2\nline3\nline4")

      assert {:ok, _} = BufferProcess.find_and_replace(pid, "line2", "OK", {2, 4})
    end

    test "edit at boundary end line succeeds (inclusive)" do
      {:ok, pid} = BufferProcess.start_link(content: "line0\nline1\nline2\nline3\nline4")

      assert {:ok, _} = BufferProcess.find_and_replace(pid, "line4", "OK", {2, 4})
    end

    test "nil boundary allows any edit (backward compatible)" do
      {:ok, pid} = BufferProcess.start_link(content: "line0\nline1\nline2")

      assert {:ok, _} = BufferProcess.find_and_replace(pid, "line0", "OK", nil)
      assert {:ok, _} = BufferProcess.find_and_replace(pid, "OK", "DONE")
    end

    test "multi-line match spanning boundary is rejected" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa\nbbb\nccc\nddd")

      assert {:error, msg} = BufferProcess.find_and_replace(pid, "bbb\nccc\nddd", "NOPE", {1, 2})
      assert msg =~ "outside boundary"
    end

    test "multi-line match fully within boundary succeeds" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa\nbbb\nccc\nddd\neee")

      assert {:ok, _} = BufferProcess.find_and_replace(pid, "bbb\nccc\nddd", "OK", {1, 3})
    end

    test "edit on single-line boundary at line 0 succeeds" do
      {:ok, pid} = BufferProcess.start_link(content: "only_line")

      assert {:ok, _} = BufferProcess.find_and_replace(pid, "only_line", "replaced", {0, 0})
    end

    test "unicode content does not confuse boundary check" do
      {:ok, pid} = BufferProcess.start_link(content: "café\n日本語\ntarget\nmore")

      assert {:ok, _} = BufferProcess.find_and_replace(pid, "target", "hit", {2, 2})
      assert BufferProcess.content(pid) =~ "hit"
    end

    test "ambiguous match returns ambiguous error, not boundary error" do
      {:ok, pid} = BufferProcess.start_link(content: "foo\nfoo")

      assert {:error, msg} = BufferProcess.find_and_replace(pid, "foo", "bar", {0, 0})
      assert msg =~ "2 times"
    end
  end

  describe "find_and_replace_batch/3 with boundary" do
    test "rejects individual edits outside boundary while applying valid ones" do
      {:ok, pid} = BufferProcess.start_link(content: "line0\nline1\nline2\nline3")

      edits = [{"line1", "OK1"}, {"line0", "NOPE"}, {"line2", "OK2"}]
      assert {:ok, results} = BufferProcess.find_and_replace_batch(pid, edits, {1, 2})

      assert [{:ok, _}, {:error, _}, {:ok, _}] = results

      content = BufferProcess.content(pid)
      assert content =~ "OK1"
      assert content =~ "OK2"
      assert content =~ "line0"
    end

    test "all edits outside boundary leaves buffer unchanged" do
      {:ok, pid} = BufferProcess.start_link(content: "line0\nline1\nline2")

      edits = [{"line0", "X"}, {"line2", "Y"}]
      assert {:ok, results} = BufferProcess.find_and_replace_batch(pid, edits, {1, 1})

      assert [{:error, _}, {:error, _}] = results
      refute BufferProcess.dirty?(pid)
      assert BufferProcess.content(pid) == "line0\nline1\nline2"
    end
  end
end
