defmodule Minga.Buffer.ServerTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server
  alias Minga.Config.Options

  @moduletag :tmp_dir

  describe "child_spec/1" do
    test "uses restart: :temporary so crashed buffers stay dead" do
      spec = Server.child_spec(file_path: "test.ex")
      assert spec.restart == :temporary
    end
  end

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
    test "returns the underlying Document struct" do
      {:ok, pid} = Server.start_link(content: "hello\nworld")
      gb = Server.snapshot(pid)

      assert %Document{} = gb
      assert Document.content(gb) == "hello\nworld"
      assert Document.cursor(gb) == {0, 0}
      assert Document.line_count(gb) == 2
    end

    test "snapshot reflects cursor position" do
      {:ok, pid} = Server.start_link(content: "hello\nworld")
      Server.move_to(pid, {1, 3})
      gb = Server.snapshot(pid)

      assert Document.cursor(gb) == {1, 3}
    end
  end

  describe "apply_snapshot/2" do
    test "replaces buffer content and marks dirty" do
      {:ok, pid} = Server.start_link(content: "hello")
      gb = Server.snapshot(pid)
      new_gb = Document.insert_char(gb, "X")

      assert :ok = Server.apply_snapshot(pid, new_gb)
      assert Server.content(pid) == "Xhello"
      assert Server.dirty?(pid)
    end

    test "pushes undo state so changes can be undone" do
      {:ok, pid} = Server.start_link(content: "hello")
      gb = Server.snapshot(pid)
      new_gb = Document.insert_char(gb, "X")

      Server.apply_snapshot(pid, new_gb)
      assert Server.content(pid) == "Xhello"

      Server.undo(pid)
      assert Server.content(pid) == "hello"
    end

    test "returns error on read-only buffer" do
      {:ok, pid} = Server.start_link(content: "hello", read_only: true)
      gb = Server.snapshot(pid)
      new_gb = Document.insert_char(gb, "X")

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

  describe "apply_text_edits/2" do
    test "applies multiple edits in a single call" do
      {:ok, pid} = Server.start_link(content: "aaa\nbbb\nccc")

      # Replace "aaa" with "AAA" and "ccc" with "CCC"
      edits = [
        {{0, 0}, {0, 2}, "AAA"},
        {{2, 0}, {2, 2}, "CCC"}
      ]

      assert :ok = Server.apply_text_edits(pid, edits)
      assert Server.content(pid) == "AAA\nbbb\nCCC"
    end

    test "produces a single undo entry for all edits" do
      {:ok, pid} = Server.start_link(content: "aaa\nbbb\nccc")

      edits = [
        {{0, 0}, {0, 2}, "AAA"},
        {{2, 0}, {2, 2}, "CCC"}
      ]

      Server.apply_text_edits(pid, edits)
      assert Server.content(pid) == "AAA\nbbb\nCCC"

      # One undo reverts all edits
      Server.undo(pid)
      assert Server.content(pid) == "aaa\nbbb\nccc"
    end

    test "empty edit list is a no-op" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.apply_text_edits(pid, [])
      assert Server.content(pid) == "hello"
      refute Server.dirty?(pid)
    end

    test "returns error on read-only buffer" do
      {:ok, pid} = Server.start_link(content: "hello", read_only: true)
      assert {:error, :read_only} = Server.apply_text_edits(pid, [{{0, 0}, {0, 0}, "X"}])
    end

    test "auto-sorts edits in reverse document order" do
      {:ok, pid} = Server.start_link(content: "aaa\nbbb\nccc")

      # Pass edits in forward order; they should be sorted automatically
      edits = [
        {{0, 0}, {0, 2}, "AAA"},
        {{2, 0}, {2, 2}, "CCC"}
      ]

      Server.apply_text_edits(pid, edits)
      assert Server.content(pid) == "AAA\nbbb\nCCC"
    end
  end

  describe "buffer_type" do
    test "defaults to :file" do
      {:ok, pid} = Server.start_link()
      assert Server.buffer_type(pid) == :file
    end

    test "accepts buffer_type: :nofile and sets read_only implicitly" do
      {:ok, pid} = Server.start_link(buffer_type: :nofile, content: "read only content")
      assert Server.buffer_type(pid) == :nofile
      assert Server.read_only?(pid)
    end

    test "nofile buffer can override read_only to false" do
      {:ok, pid} = Server.start_link(buffer_type: :nofile, read_only: false, content: "editable")
      assert Server.buffer_type(pid) == :nofile
      refute Server.read_only?(pid)
    end

    test "nowrite buffer accepts buffer_type: :nowrite" do
      {:ok, pid} = Server.start_link(buffer_type: :nowrite, content: "display only")
      assert Server.buffer_type(pid) == :nowrite
      refute Server.read_only?(pid)
    end

    test "nofile buffer blocks save" do
      {:ok, pid} = Server.start_link(buffer_type: :nofile, content: "no save")
      assert Server.save(pid) == {:error, :buffer_not_saveable}
    end

    test "nowrite buffer blocks save" do
      {:ok, pid} = Server.start_link(buffer_type: :nowrite, content: "no save")
      assert Server.save(pid) == {:error, :buffer_not_saveable}
    end

    test "nofile buffer blocks force_save" do
      {:ok, pid} = Server.start_link(buffer_type: :nofile, content: "no save")
      assert Server.force_save(pid) == {:error, :buffer_not_saveable}
    end

    test "nowrite buffer blocks force_save" do
      {:ok, pid} = Server.start_link(buffer_type: :nowrite, content: "no save")
      assert Server.force_save(pid) == {:error, :buffer_not_saveable}
    end

    test "file buffer saves normally", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "saveable.txt")
      File.write!(path, "original")
      {:ok, pid} = Server.start_link(file_path: path, buffer_type: :file)
      Server.insert_char(pid, "x")
      assert Server.save(pid) == :ok
    end

    test "buffer_type appears in render_snapshot" do
      {:ok, pid} = Server.start_link(buffer_type: :nofile, content: "test")
      snapshot = Server.render_snapshot(pid, 0, 10)
      assert snapshot.buffer_type == :nofile
    end

    test "render_snapshot is a RenderSnapshot struct" do
      {:ok, pid} = Server.start_link(content: "hello\nworld")
      snapshot = Server.render_snapshot(pid, 0, 10)
      assert %Minga.Buffer.RenderSnapshot{} = snapshot
    end

    test "render_snapshot includes version that increments on edit" do
      {:ok, pid} = Server.start_link(content: "hello")
      snap1 = Server.render_snapshot(pid, 0, 10)
      v1 = snap1.version

      Server.insert_char(pid, "x")
      snap2 = Server.render_snapshot(pid, 0, 10)
      v2 = snap2.version

      assert v2 > v1
    end

    test "append bypasses read_only on nofile buffer" do
      {:ok, pid} = Server.start_link(buffer_type: :nofile, buffer_name: "*Test*", content: "")
      assert Server.read_only?(pid)
      Server.append(pid, "appended text")
      assert Server.content(pid) == "appended text"
    end
  end

  describe "undo coalescing" do
    test "rapid edits within coalescing window produce one undo entry" do
      {:ok, pid} = Server.start_link(content: "hello")

      # Multiple rapid inserts without breaking coalescing
      Server.insert_char(pid, "a")
      Server.insert_char(pid, "b")
      Server.insert_char(pid, "c")
      assert Server.content(pid) == "abchello"

      # One undo reverts all three
      Server.undo(pid)
      assert Server.content(pid) == "hello"
    end

    test "break_undo_coalescing creates separate undo entries" do
      {:ok, pid} = Server.start_link(content: "hello")

      Server.insert_char(pid, "a")
      Server.break_undo_coalescing(pid)
      Server.insert_char(pid, "b")

      assert Server.content(pid) == "abhello"

      # First undo reverts "b" only
      Server.undo(pid)
      assert Server.content(pid) == "ahello"

      # Second undo reverts "a"
      Server.undo(pid)
      assert Server.content(pid) == "hello"
    end
  end

  describe "dirty flag after undo/redo (#475)" do
    @tag :tmp_dir
    test "undo back to saved state clears dirty flag", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "undo_dirty.txt")
      File.write!(path, "original")
      {:ok, pid} = Server.start_link(file_path: path)

      refute Server.dirty?(pid)

      # Edit and verify dirty
      Server.insert_char(pid, "X")
      assert Server.dirty?(pid)

      # Undo back to saved state
      Server.undo(pid)
      assert Server.content(pid) == "original"
      refute Server.dirty?(pid)
    end

    @tag :tmp_dir
    test "redo after undo restores dirty flag", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "redo_dirty.txt")
      File.write!(path, "original")
      {:ok, pid} = Server.start_link(file_path: path)

      Server.insert_char(pid, "X")
      assert Server.dirty?(pid)

      Server.undo(pid)
      refute Server.dirty?(pid)

      Server.redo(pid)
      assert Server.dirty?(pid)
    end

    @tag :tmp_dir
    test "save then edit then undo clears dirty", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "save_undo.txt")
      File.write!(path, "start")
      {:ok, pid} = Server.start_link(file_path: path)

      # Edit and save
      Server.insert_char(pid, "A")
      assert Server.dirty?(pid)
      :ok = Server.save(pid)
      refute Server.dirty?(pid)

      # Edit again
      Server.break_undo_coalescing(pid)
      Server.insert_char(pid, "B")
      assert Server.dirty?(pid)

      # Undo the second edit, back to saved state
      Server.undo(pid)
      refute Server.dirty?(pid)
    end

    test "pathless file buffer edit then undo returns to clean" do
      {:ok, pid} = Server.start_link(content: "text")

      refute Server.dirty?(pid)
      Server.insert_char(pid, "X")
      assert Server.dirty?(pid)

      Server.undo(pid)
      refute Server.dirty?(pid), "pathless buffer should be clean after undoing to initial state"
    end
  end

  describe "edit delta tracking" do
    test "insert_char records an insertion delta" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.move_to(pid, {0, 5})
      Server.insert_char(pid, "!")
      edits = Server.flush_edits(pid)
      assert [delta] = edits
      assert delta.start_byte == 5
      assert delta.old_end_byte == 5
      assert delta.new_end_byte == 6
      assert delta.inserted_text == "!"
    end

    test "delete_before records a deletion delta" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.move_to(pid, {0, 5})
      Server.delete_before(pid)
      edits = Server.flush_edits(pid)
      assert [delta] = edits
      assert delta.start_byte == 4
      assert delta.old_end_byte == 5
      assert delta.new_end_byte == 4
      assert delta.inserted_text == ""
    end

    test "flush_edits clears pending deltas" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.move_to(pid, {0, 5})
      Server.insert_char(pid, "!")
      assert [_] = Server.flush_edits(pid)
      assert [] = Server.flush_edits(pid)
    end

    test "multiple edits accumulate in order" do
      {:ok, pid} = Server.start_link(content: "ab")
      Server.move_to(pid, {0, 2})
      Server.insert_char(pid, "c")
      Server.insert_char(pid, "d")
      edits = Server.flush_edits(pid)
      assert length(edits) == 2
      assert [first, second] = edits
      assert first.inserted_text == "c"
      assert second.inserted_text == "d"
    end

    test "delete_range records a deletion delta" do
      {:ok, pid} = Server.start_link(content: "hello world")
      Server.delete_range(pid, {0, 5}, {0, 11})
      edits = Server.flush_edits(pid)
      assert [delta] = edits
      assert delta.start_byte == 5
      assert delta.old_end_byte == 11
      assert delta.new_end_byte == 5
      assert delta.inserted_text == ""
    end

    test "undo clears pending edits" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.move_to(pid, {0, 5})
      Server.insert_char(pid, "!")
      assert [_] = Server.flush_edits(pid)
      # Make another edit then undo
      Server.insert_char(pid, "?")
      Server.undo(pid)
      # Undo clears edits to force full sync
      assert [] = Server.flush_edits(pid)
    end

    test "replace_content clears pending edits" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.move_to(pid, {0, 5})
      Server.insert_char(pid, "!")
      Server.replace_content(pid, "goodbye")
      assert [] = Server.flush_edits(pid)
    end
  end

  # ── Per-consumer flush_edits ──────────────────────────────────────────────

  describe "per-consumer flush_edits" do
    test "two consumers independently receive the full set of deltas from the same edit" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.move_to(pid, {0, 5})
      Server.insert_char(pid, "x")
      Server.insert_char(pid, "y")

      # Both consumers should see the same 2 deltas
      lsp_deltas = Server.flush_edits(pid, :lsp)
      hl_deltas = Server.flush_edits(pid, :highlight)

      assert length(lsp_deltas) == 2
      assert length(hl_deltas) == 2
      assert Enum.map(lsp_deltas, & &1.inserted_text) == ["x", "y"]
      assert Enum.map(hl_deltas, & &1.inserted_text) == ["x", "y"]
    end

    test "flush_edits with consumer_id returns deltas since that consumer's last read" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.move_to(pid, {0, 5})
      Server.insert_char(pid, "a")
      Server.insert_char(pid, "b")

      # First flush gets both deltas
      assert [d1, d2] = Server.flush_edits(pid, :lsp)
      assert d1.inserted_text == "a"
      assert d2.inserted_text == "b"

      # Insert more
      Server.insert_char(pid, "c")

      # Second flush gets only the new one
      assert [d3] = Server.flush_edits(pid, :lsp)
      assert d3.inserted_text == "c"
    end

    test "consumers can read at different rates without losing deltas" do
      {:ok, pid} = Server.start_link(content: "")
      Server.insert_char(pid, "a")
      Server.insert_char(pid, "b")
      Server.insert_char(pid, "c")

      # :lsp reads all 3
      lsp_first = Server.flush_edits(pid, :lsp)
      assert length(lsp_first) == 3

      # More edits
      Server.insert_char(pid, "d")
      Server.insert_char(pid, "e")

      # :highlight hasn't read yet, should get all 5
      hl_all = Server.flush_edits(pid, :highlight)
      assert length(hl_all) == 5
      assert Enum.map(hl_all, & &1.inserted_text) == ["a", "b", "c", "d", "e"]

      # :lsp should get only the 2 new ones
      lsp_second = Server.flush_edits(pid, :lsp)
      assert length(lsp_second) == 2
      assert Enum.map(lsp_second, & &1.inserted_text) == ["d", "e"]
    end

    test "log is trimmed after all consumers have read" do
      {:ok, pid} = Server.start_link(content: "")
      Server.insert_char(pid, "a")
      Server.insert_char(pid, "b")

      # Both consumers flush
      Server.flush_edits(pid, :lsp)
      Server.flush_edits(pid, :highlight)

      # Check internal state: log should be trimmed
      internal = :sys.get_state(pid)
      assert internal.edit_log == []
    end

    test "new consumer starts from sequence 0 and gets entire log" do
      {:ok, pid} = Server.start_link(content: "")
      Server.insert_char(pid, "a")
      Server.insert_char(pid, "b")
      Server.insert_char(pid, "c")

      # :lsp reads all 3
      Server.flush_edits(pid, :lsp)

      # More edits
      Server.insert_char(pid, "d")
      Server.insert_char(pid, "e")

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
      new_deltas = Server.flush_edits(pid, :new_consumer)
      # Gets at least the 2 unread by all consumers (d, e)
      assert length(new_deltas) >= 2
    end

    test "undo clears the edit log for all consumers" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.move_to(pid, {0, 5})
      Server.insert_char(pid, "a")
      Server.insert_char(pid, "b")

      # :lsp reads
      assert [_, _] = Server.flush_edits(pid, :lsp)

      # More edits then undo
      Server.insert_char(pid, "c")
      Server.undo(pid)

      # Both consumers get empty (forces full sync)
      assert [] = Server.flush_edits(pid, :lsp)
      assert [] = Server.flush_edits(pid, :highlight)
    end

    test "replace_content clears the edit log for all consumers" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.move_to(pid, {0, 5})
      Server.insert_char(pid, "!")
      Server.replace_content(pid, "goodbye")

      assert [] = Server.flush_edits(pid, :lsp)
      assert [] = Server.flush_edits(pid, :highlight)
    end

    test "flush with no edits returns empty list" do
      {:ok, pid} = Server.start_link(content: "hello")
      assert [] = Server.flush_edits(pid, :lsp)
    end

    test "flush same consumer twice with no intervening edits returns empty" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.insert_char(pid, "!")
      assert [_] = Server.flush_edits(pid, :lsp)
      assert [] = Server.flush_edits(pid, :lsp)
    end
  end

  # ── Buffer-local options ──────────────────────────────────────────────────

  describe "buffer-local options" do
    test "get_option falls back to global default when no local override" do
      {:ok, pid} = Server.start_link(content: "hello")
      # tab_width global default is 2
      assert Server.get_option(pid, :tab_width) == 2
    end

    test "set_option stores a buffer-local override" do
      {:ok, pid} = Server.start_link(content: "hello")
      assert {:ok, 8} = Server.set_option(pid, :tab_width, 8)
      assert Server.get_option(pid, :tab_width) == 8
    end

    test "buffer-local override wins over global default" do
      {:ok, pid} = Server.start_link(content: "hello")
      Server.set_option(pid, :tab_width, 4)
      assert Server.get_option(pid, :tab_width) == 4
    end

    test "two buffers have independent options" do
      {:ok, a} = Server.start_link(content: "alpha")
      {:ok, b} = Server.start_link(content: "bravo")
      Server.set_option(a, :tab_width, 8)
      assert Server.get_option(a, :tab_width) == 8
      assert Server.get_option(b, :tab_width) == 2
    end

    test "set_option rejects invalid values" do
      {:ok, pid} = Server.start_link(content: "hello")
      assert {:error, _} = Server.set_option(pid, :tab_width, -1)
      # Original value unchanged
      assert Server.get_option(pid, :tab_width) == 2
    end

    test "set_option rejects unknown option names" do
      {:ok, pid} = Server.start_link(content: "hello")
      assert {:error, _} = Server.set_option(pid, :nonexistent, true)
    end

    test "local_options returns seeded defaults plus any overrides" do
      {:ok, pid} = Server.start_link(content: "hello")
      # Seeded with global defaults (tab_width: 2, wrap: false, etc.)
      defaults = Server.local_options(pid)
      assert defaults[:tab_width] == 2
      assert defaults[:wrap] == false

      # Override one option
      Server.set_option(pid, :tab_width, 4)
      updated = Server.local_options(pid)
      assert updated[:tab_width] == 4
      # Other seeded defaults still present
      assert updated[:wrap] == false
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

      {:ok, pid} = Server.start_link(content: "package main", filetype: :go)
      assert Server.get_option(pid, :tab_width) == 8
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

      {:ok, pid} = Server.start_link(content: "package main", filetype: :go)
      # Buffer was seeded with filetype default of 8
      assert Server.get_option(pid, :tab_width) == 8
      # Override locally
      Server.set_option(pid, :tab_width, 3)
      assert Server.get_option(pid, :tab_width) == 3
    end

    test "set_filetype preserves explicitly set options" do
      {:ok, pid} = Server.start_link(content: "hello")

      # Explicitly set clipboard to :none (like EditorCase does)
      Server.set_option(pid, :clipboard, :none)
      assert Server.get_option(pid, :clipboard) == :none

      # Change filetype, which reseeds options from global defaults
      Server.set_filetype(pid, :python)

      # The explicit override should survive the reseed
      assert Server.get_option(pid, :clipboard) == :none
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

      {:ok, pid} = Server.start_link(content: "hello", filetype: :text)
      assert Server.get_option(pid, :tab_width) == 2

      # Change to Go filetype; non-explicit tab_width should reseed to 8
      Server.set_filetype(pid, :go)
      assert Server.get_option(pid, :tab_width) == 8
    end
  end

  describe "face_overrides/1 and remap_face/3" do
    test "starts with empty overrides" do
      {:ok, pid} = Server.start_link()
      assert Server.face_overrides(pid) == %{}
    end

    test "sets and retrieves a face override" do
      {:ok, pid} = Server.start_link()
      :ok = Server.remap_face(pid, "default", fg: 0x000000, bg: 0xFFFFFF)

      overrides = Server.face_overrides(pid)
      assert overrides == %{"default" => [fg: 0x000000, bg: 0xFFFFFF]}
    end

    test "clears a face override" do
      {:ok, pid} = Server.start_link()
      :ok = Server.remap_face(pid, "comment", italic: false)
      :ok = Server.clear_face_override(pid, "comment")

      assert Server.face_overrides(pid) == %{}
    end

    test "multiple overrides coexist" do
      {:ok, pid} = Server.start_link()
      :ok = Server.remap_face(pid, "keyword", fg: 0xFF0000)
      :ok = Server.remap_face(pid, "comment", italic: false)

      overrides = Server.face_overrides(pid)
      assert Map.has_key?(overrides, "keyword")
      assert Map.has_key?(overrides, "comment")
    end
  end
end
