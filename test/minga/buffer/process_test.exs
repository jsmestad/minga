defmodule Minga.Buffer.ProcessTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options

  @moduletag :tmp_dir

  defp consume_edit_deltas(buffer, consumer_id) do
    case BufferProcess.consume_edit_deltas(buffer, consumer_id) do
      {:ok, deltas} -> deltas
      :reset_required -> flunk("expected edit deltas, got reset_required")
    end
  end

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

    test "falls back to builtin defaults when a private options server dies" do
      options_server = start_supervised!({Options, name: nil})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :text, :cursor_animate, false)

      :ok = GenServer.stop(options_server)

      {:ok, pid} =
        BufferProcess.start_link(
          content: "hello",
          filetype: :text,
          options_server: options_server
        )

      assert BufferProcess.content(pid) == "hello"
      assert BufferProcess.get_option(pid, :cursor_animate) == Options.default(:cursor_animate)
    end

    test "accepts a missing named options_server and falls back to builtin defaults" do
      {:ok, pid} =
        BufferProcess.start_link(content: "hello", options_server: :missing_options_server)

      assert BufferProcess.content(pid) == "hello"
      assert BufferProcess.get_option(pid, :cursor_animate) == Options.default(:cursor_animate)
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

    test "re-seeds cached options from the opened filetype and preserves explicit options", %{
      tmp_dir: tmp_dir
    } do
      options_server = start_supervised!({Options, name: nil})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :text, :autopair_block, false)

      assert {:ok, true} = Options.set_for_filetype(options_server, :bash, :autopair_block, true)

      path = Path.join(tmp_dir, "open_script")
      File.write!(path, "#!/usr/bin/env bash\n")

      {:ok, pid} =
        BufferProcess.start_link(
          content: "hello",
          filetype: :text,
          options_server: options_server
        )

      BufferProcess.set_option(pid, :clipboard, :none)
      assert BufferProcess.get_option(pid, :autopair_block) == false

      :ok = BufferProcess.open(pid, path)

      assert BufferProcess.filetype(pid) == :bash
      assert BufferProcess.get_option(pid, :autopair_block) == true
      assert BufferProcess.get_option(pid, :clipboard) == :none
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

  describe "reload/1" do
    test "re-seeds cached options from the reloaded filetype and preserves explicit options", %{
      tmp_dir: tmp_dir
    } do
      options_server = start_supervised!({Options, name: nil})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :text, :autopair_block, false)

      assert {:ok, true} = Options.set_for_filetype(options_server, :bash, :autopair_block, true)

      path = Path.join(tmp_dir, "reload_script")
      File.write!(path, "hello")

      {:ok, pid} =
        BufferProcess.start_link(
          file_path: path,
          filetype: :text,
          options_server: options_server
        )

      BufferProcess.set_option(pid, :clipboard, :none)
      assert BufferProcess.get_option(pid, :autopair_block) == false

      File.write!(path, "#!/usr/bin/env bash\n")
      :ok = BufferProcess.reload(pid)

      assert BufferProcess.filetype(pid) == :bash
      assert BufferProcess.get_option(pid, :autopair_block) == true
      assert BufferProcess.get_option(pid, :clipboard) == :none
      assert BufferProcess.content(pid) == "#!/usr/bin/env bash\n"
    end
  end

  describe "document editing wrappers" do
    test "mutating wrappers update content and dirty state" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      refute BufferProcess.dirty?(pid)

      assert :ok = BufferProcess.insert_char(pid, "X")

      assert BufferProcess.content(pid) == "Xhello"
      assert BufferProcess.cursor(pid) == {0, 1}
      assert BufferProcess.dirty?(pid)
    end

    test "boundary edit no-ops leave a clean buffer clean" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")

      assert :ok = BufferProcess.delete_before(pid)
      BufferProcess.move_to(pid, {0, 5})
      assert :ok = BufferProcess.delete_at(pid)

      refute BufferProcess.dirty?(pid)
      assert BufferProcess.content(pid) == "hello"
    end

    test "movement wrappers update cursor without marking dirty" do
      {:ok, pid} = BufferProcess.start_link(content: "hello\nworld")

      BufferProcess.move(pid, :right)
      BufferProcess.move(pid, :down)
      BufferProcess.move_to(pid, {1, 3})

      assert BufferProcess.cursor(pid) == {1, 3}
      refute BufferProcess.dirty?(pid)
    end

    test "move_if_possible reports successful moves and boundaries" do
      pid = start_supervised!({BufferProcess, content: "ab"})

      assert {:ok, {0, 1}} = BufferProcess.move_if_possible(pid, :right)
      assert :at_boundary = BufferProcess.move_if_possible(pid, :right)
      assert {:ok, {0, 0}} = BufferProcess.move_if_possible(pid, :left)
      assert :at_boundary = BufferProcess.move_if_possible(pid, :left)
      refute BufferProcess.dirty?(pid)
    end

    test "query wrappers expose document lines" do
      {:ok, pid} = BufferProcess.start_link(content: "a\nb\nc\nd\ne")

      assert BufferProcess.lines(pid, 1, 3) == ["b", "c", "d"]
      assert BufferProcess.line_count(pid) == 5
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

  describe "retarget_path/2" do
    test "retargets a clean buffer without writing content", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "source.txt")
      target = Path.join(tmp_dir, "target.txt")
      File.write!(source, "alpha")

      {:ok, pid} = BufferProcess.start_link(file_path: source)

      assert :ok = BufferProcess.retarget_path(pid, target)
      assert BufferProcess.file_path(pid) == target
      refute BufferProcess.dirty?(pid)
      assert File.exists?(source)
      refute File.exists?(target)
      assert :not_found = BufferProcess.pid_for_path(source)
      assert {:ok, ^pid} = BufferProcess.pid_for_path(target)
    end

    test "retargets a dirty buffer and preserves dirty state until explicit save", %{
      tmp_dir: tmp_dir
    } do
      source = Path.join(tmp_dir, "source.txt")
      target = Path.join(tmp_dir, "target.txt")
      File.write!(source, "alpha")

      {:ok, pid} = BufferProcess.start_link(file_path: source)
      BufferProcess.replace_content(pid, "dirty", :user)
      assert BufferProcess.dirty?(pid)

      assert :ok = BufferProcess.retarget_path(pid, target)
      assert BufferProcess.file_path(pid) == target
      assert BufferProcess.dirty?(pid)
      assert File.read!(source) == "alpha"
      refute File.exists?(target)

      assert :ok = BufferProcess.save(pid)
      assert File.read!(target) == "dirty"
      assert File.exists?(source)
    end

    test "retarget_path/2 updates registry for nowrite buffers and still blocks save", %{
      tmp_dir: tmp_dir
    } do
      source = Path.join(tmp_dir, "source.txt")
      target = Path.join(tmp_dir, "target.txt")
      File.write!(source, "display only")

      {:ok, pid} = BufferProcess.start_link(file_path: source, buffer_type: :nowrite)
      assert BufferProcess.buffer_type(pid) == :nowrite
      assert {:ok, ^pid} = Buffer.pid_for_path(source)

      assert :ok = Buffer.retarget_path(pid, target)
      assert BufferProcess.file_path(pid) == target
      assert BufferProcess.buffer_type(pid) == :nowrite
      assert :not_found = Buffer.pid_for_path(source)
      assert {:ok, ^pid} = Buffer.pid_for_path(target)
      assert Buffer.save(pid) == {:error, :buffer_not_saveable}
    end
  end

  describe "special buffer properties" do
    test "metadata accessors expose configured flags" do
      {:ok, default} = BufferProcess.start_link(content: "hello")

      {:ok, configured} =
        BufferProcess.start_link(
          content: "",
          buffer_name: "*Messages*",
          unlisted: true,
          persistent: true
        )

      assert BufferProcess.buffer_name(default) == nil
      refute BufferProcess.read_only?(default)
      assert BufferProcess.buffer_name(configured) == "*Messages*"
      assert BufferProcess.unlisted?(configured)
      assert BufferProcess.persistent?(configured)
    end

    test "read-only buffers reject mutating APIs except append" do
      cases = [
        {"insert_char", "hello", fn pid -> BufferProcess.insert_char(pid, "x") end},
        {"delete_before", "hello",
         fn pid ->
           BufferProcess.move(pid, :right)
           BufferProcess.delete_before(pid)
         end},
        {"delete_at", "hello", fn pid -> BufferProcess.delete_at(pid) end},
        {"replace_content", "hello", fn pid -> BufferProcess.replace_content(pid, "new") end},
        {"delete_range", "hello", fn pid -> BufferProcess.delete_range(pid, {0, 0}, {0, 3}) end},
        {"delete_lines", "a\nb\nc", fn pid -> BufferProcess.delete_lines(pid, 0, 0) end},
        {"clear_line", "hello", fn pid -> BufferProcess.clear_line(pid, 0) end}
      ]

      for {name, content, operation} <- cases do
        {:ok, pid} = BufferProcess.start_link(content: content, read_only: true)
        assert operation.(pid) == {:error, :read_only}, name
        assert BufferProcess.content(pid) == content, name
      end

      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert BufferProcess.append(pid, "\nworld") == :ok
      assert BufferProcess.content(pid) == "hello\nworld"
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

  describe "commit_snapshot/2" do
    test "replaces buffer content and marks dirty" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      gb = BufferProcess.snapshot(pid)
      new_gb = Document.insert_text(gb, "X")

      assert :ok = BufferProcess.commit_snapshot(pid, new_gb)
      assert BufferProcess.content(pid) == "Xhello"
      assert BufferProcess.dirty?(pid)
    end

    test "pushes undo state so changes can be undone" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      gb = BufferProcess.snapshot(pid)
      new_gb = Document.insert_text(gb, "X")

      BufferProcess.commit_snapshot(pid, new_gb)
      assert BufferProcess.content(pid) == "Xhello"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "hello"
    end

    test "returns error on read-only buffer" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      gb = BufferProcess.snapshot(pid)
      new_gb = Document.insert_text(gb, "X")

      assert {:error, :read_only} = BufferProcess.commit_snapshot(pid, new_gb)
      assert BufferProcess.content(pid) == "hello"
    end

    test "round-trip preserves buffer identity" do
      {:ok, pid} = BufferProcess.start_link(content: "hello\nworld")
      BufferProcess.move_to(pid, {1, 2})
      gb = BufferProcess.snapshot(pid)

      BufferProcess.commit_snapshot(pid, gb)
      assert BufferProcess.content(pid) == "hello\nworld"
      assert BufferProcess.cursor(pid) == {1, 2}
    end
  end

  describe "apply_edits/2" do
    test "applies multiple edits in a single call" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa\nbbb\nccc")

      # Replace "aaa" with "AAA" and "ccc" with "CCC"
      edits = [
        {{0, 0}, {0, 2}, "AAA"},
        {{2, 0}, {2, 2}, "CCC"}
      ]

      assert :ok = BufferProcess.apply_edits(pid, edits)
      assert BufferProcess.content(pid) == "AAA\nbbb\nCCC"
    end

    test "produces a single undo entry for all edits" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa\nbbb\nccc")

      edits = [
        {{0, 0}, {0, 2}, "AAA"},
        {{2, 0}, {2, 2}, "CCC"}
      ]

      BufferProcess.apply_edits(pid, edits)
      assert BufferProcess.content(pid) == "AAA\nbbb\nCCC"

      # One undo reverts all edits
      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "aaa\nbbb\nccc"
    end

    test "empty edit list is a no-op" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.apply_edits(pid, [])
      assert BufferProcess.content(pid) == "hello"
      refute BufferProcess.dirty?(pid)
    end

    test "returns error on read-only buffer" do
      {:ok, pid} = BufferProcess.start_link(content: "hello", read_only: true)
      assert {:error, :read_only} = BufferProcess.apply_edits(pid, [{{0, 0}, {0, 0}, "X"}])
    end

    test "replays unsorted variable-length edits on the same line through undo and redo" do
      {:ok, pid} = BufferProcess.start_link(content: "abcdefghij")

      edits = [
        {{0, 1}, {0, 2}, "LMNOP"},
        {{0, 6}, {0, 8}, "W"}
      ]

      assert :ok = BufferProcess.apply_edits(pid, edits)
      assert BufferProcess.content(pid) == "aLMNOPdefWj"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "abcdefghij"

      BufferProcess.redo(pid)
      assert BufferProcess.content(pid) == "aLMNOPdefWj"
    end
  end

  describe "buffer_type" do
    test "buffer type controls read-only defaults" do
      {:ok, file} = BufferProcess.start_link()
      {:ok, nofile} = BufferProcess.start_link(buffer_type: :nofile, content: "read only content")

      {:ok, editable_nofile} =
        BufferProcess.start_link(buffer_type: :nofile, read_only: false, content: "editable")

      {:ok, nowrite} = BufferProcess.start_link(buffer_type: :nowrite, content: "display only")

      assert BufferProcess.buffer_type(file) == :file
      assert BufferProcess.buffer_type(nofile) == :nofile
      assert BufferProcess.read_only?(nofile)
      refute BufferProcess.read_only?(editable_nofile)
      assert BufferProcess.buffer_type(nowrite) == :nowrite
      refute BufferProcess.read_only?(nowrite)
    end

    test "unsaveable buffer types block save APIs" do
      for type <- [:nofile, :nowrite] do
        {:ok, pid} = BufferProcess.start_link(buffer_type: type, content: "no save")
        assert BufferProcess.save(pid) == {:error, :buffer_not_saveable}
        assert BufferProcess.force_save(pid) == {:error, :buffer_not_saveable}
      end
    end

    test "file buffers save normally", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "saveable.txt")
      File.write!(path, "original")
      {:ok, pid} = BufferProcess.start_link(file_path: path, buffer_type: :file)
      BufferProcess.insert_char(pid, "x")
      assert BufferProcess.save(pid) == :ok
    end

    test "render_snapshot exposes type, options, decorations, and version metadata" do
      {:ok, nofile} = BufferProcess.start_link(buffer_type: :nofile, content: "hello\nworld")

      assert %Minga.Buffer.RenderSnapshot{buffer_type: :nofile} =
               BufferProcess.render_snapshot(nofile, 0, 10)

      {:ok, editable} = BufferProcess.start_link(content: "hello")
      assert {:ok, true} = BufferProcess.set_option(editable, :wrap, true)

      _decoration_id =
        BufferProcess.add_block_decoration(editable, 0,
          placement: :below,
          render: fn _width -> [{"note", []}] end
        )

      snap1 = BufferProcess.render_snapshot(editable, 0, 10)
      BufferProcess.insert_char(editable, "x")
      snap2 = BufferProcess.render_snapshot(editable, 0, 10)

      assert snap1.options.wrap
      assert snap1.decorations.block_decorations != []
      assert snap2.version > snap1.version
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
    test "edits tag undo source by caller" do
      cases = [
        {:user, "hello", fn pid -> BufferProcess.insert_char(pid, "X") end},
        {:agent, "hello world",
         fn pid -> BufferProcess.find_and_replace(pid, "hello", "goodbye") end},
        {:agent, "hello world",
         fn pid -> BufferProcess.find_and_replace_batch(pid, [{"hello", "goodbye"}]) end},
        {:lsp, "hello",
         fn pid -> BufferProcess.apply_edits(pid, [{{0, 0}, {0, 5}, "goodbye"}]) end}
      ]

      for {source, content, operation} <- cases do
        pid =
          start_supervised!({BufferProcess, content: content},
            id: {:source_case, source, :erlang.unique_integer([:positive])}
          )

        assert BufferProcess.last_undo_source(pid) == nil
        assert BufferProcess.last_redo_source(pid) == nil

        operation.(pid)

        assert BufferProcess.last_undo_source(pid) == source
      end
    end

    test "source metadata survives undo/redo round-trip" do
      pid = start_supervised!({BufferProcess, content: "hello world"})
      BufferProcess.find_and_replace(pid, "hello", "goodbye")

      # Undo pops the agent entry and creates a redo entry carrying the source
      BufferProcess.undo(pid)
      assert BufferProcess.last_redo_source(pid) == :agent

      # Redo pushes it back to undo history
      BufferProcess.redo(pid)
      assert BufferProcess.last_undo_source(pid) == :agent
    end

    test "find_and_replace redo reapplies multiline replacements" do
      pid = start_supervised!({BufferProcess, content: "alpha\nbeta\ngamma"})

      assert {:ok, _} = BufferProcess.find_and_replace(pid, "beta", "one\ntwo")
      assert BufferProcess.content(pid) == "alpha\none\ntwo\ngamma"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "alpha\nbeta\ngamma"

      BufferProcess.redo(pid)
      assert BufferProcess.content(pid) == "alpha\none\ntwo\ngamma"
    end

    test "find_and_replace_batch redo reapplies unicode replacements" do
      pid = start_supervised!({BufferProcess, content: "hello café world"})

      assert {:ok, results} = BufferProcess.find_and_replace_batch(pid, [{"café", "茶"}])
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert BufferProcess.content(pid) == "hello 茶 world"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "hello café world"

      BufferProcess.redo(pid)
      assert BufferProcess.content(pid) == "hello 茶 world"
    end

    test "replace_content records explicit and default sources" do
      pid = start_supervised!({BufferProcess, content: "hello"})
      BufferProcess.replace_content(pid, "goodbye", :agent)
      assert BufferProcess.last_undo_source(pid) == :agent

      pid = start_supervised!({BufferProcess, content: "hello"}, id: :default_source_buffer)
      BufferProcess.replace_content(pid, "goodbye")
      assert BufferProcess.last_undo_source(pid) == :user
    end

    test "generated replacement APIs clear stale undo history" do
      cases = [
        {"generated", fn pid -> BufferProcess.replace_generated_content(pid, "generated") end},
        {"decorated",
         fn pid ->
           BufferProcess.replace_content_with_decorations(pid, "decorated", fn decs -> decs end)
         end}
      ]

      for {expected_content, operation} <- cases do
        pid =
          start_supervised!({BufferProcess, content: "hello"},
            id: {:generated_replace, expected_content}
          )

        BufferProcess.insert_char(pid, "X")
        assert BufferProcess.content(pid) == "Xhello"

        operation.(pid)

        assert BufferProcess.content(pid) == expected_content
        assert BufferProcess.last_undo_source(pid) == nil
        assert BufferProcess.last_redo_source(pid) == nil

        BufferProcess.undo(pid)
        assert BufferProcess.content(pid) == expected_content
      end
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

  describe "clear_line/2" do
    test "returns yanked text, changes content, and supports undo/redo" do
      pid = start_supervised!({BufferProcess, content: "one\ntwo\nthree"})

      assert {:ok, "two"} = BufferProcess.clear_line(pid, 1)
      assert BufferProcess.content(pid) == "one\n\nthree"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "one\ntwo\nthree"

      BufferProcess.redo(pid)
      assert BufferProcess.content(pid) == "one\n\nthree"
    end
  end

  describe "undo patch memory" do
    test "1000 small undo entries on a 1 MB file stay under 10 MB" do
      content = String.duplicate("a", 1_000_000)
      {:ok, pid} = BufferProcess.start_link(content: content)
      BufferProcess.move_to(pid, {0, byte_size(content)})

      for _ <- 1..1000 do
        BufferProcess.break_undo_coalescing(pid)
        BufferProcess.insert_char(pid, "x")
      end

      undo_bytes = :erlang.external_size(:sys.get_state(pid).undo_history)
      assert undo_bytes < 10 * 1024 * 1024
    end
  end

  describe "edit delta tracking" do
    test "insert_char records an insertion delta" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "!")
      edits = consume_edit_deltas(pid, :test)
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
      edits = consume_edit_deltas(pid, :test)
      assert [delta] = edits
      assert delta.start_byte == 4
      assert delta.old_end_byte == 5
      assert delta.new_end_byte == 4
      assert delta.inserted_text == ""
    end

    test "apply_edit records byte-accurate unicode replacement delta" do
      {:ok, pid} = BufferProcess.start_link(content: "aébc")
      BufferProcess.apply_edit(pid, 0, 1, 0, 1, "X")
      edits = consume_edit_deltas(pid, :test)
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

    test "multiple edits accumulate in order" do
      {:ok, pid} = BufferProcess.start_link(content: "ab")
      BufferProcess.move_to(pid, {0, 2})
      BufferProcess.insert_char(pid, "c")
      BufferProcess.insert_char(pid, "d")
      edits = consume_edit_deltas(pid, :test)
      assert length(edits) == 2
      assert [first, second] = edits
      assert first.inserted_text == "c"
      assert second.inserted_text == "d"
    end

    test "delete_range records a deletion delta" do
      {:ok, pid} = BufferProcess.start_link(content: "hello world")
      BufferProcess.delete_range(pid, {0, 5}, {0, 11})
      edits = consume_edit_deltas(pid, :test)
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
      assert [_] = consume_edit_deltas(pid, :test)
      # Make another edit then undo
      BufferProcess.insert_char(pid, "?")
      BufferProcess.undo(pid)
      # Undo clears edits to force full sync
      assert :reset_required = BufferProcess.consume_edit_deltas(pid, :test)
    end

    test "replace_content clears pending edits" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "!")
      BufferProcess.replace_content(pid, "goodbye")
      assert :reset_required = BufferProcess.consume_edit_deltas(pid, :test)
    end
  end

  # ── Per-consumer consume_edit_deltas ──────────────────────────────────────────────

  describe "per-consumer consume_edit_deltas" do
    test "two consumers independently receive the full set of deltas from the same edit" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "x")
      BufferProcess.insert_char(pid, "y")

      # Both consumers should see the same 2 deltas
      lsp_deltas = consume_edit_deltas(pid, :lsp)
      hl_deltas = consume_edit_deltas(pid, :highlight)

      assert length(lsp_deltas) == 2
      assert length(hl_deltas) == 2
      assert Enum.map(lsp_deltas, & &1.inserted_text) == ["x", "y"]
      assert Enum.map(hl_deltas, & &1.inserted_text) == ["x", "y"]
    end

    test "consume_edit_deltas with consumer_id returns deltas since that consumer's last read" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")

      # First flush gets both deltas
      assert [d1, d2] = consume_edit_deltas(pid, :lsp)
      assert d1.inserted_text == "a"
      assert d2.inserted_text == "b"

      # Insert more
      BufferProcess.insert_char(pid, "c")

      # Second flush gets only the new one
      assert [d3] = consume_edit_deltas(pid, :lsp)
      assert d3.inserted_text == "c"
    end

    test "consumers can read at different rates without losing deltas" do
      {:ok, pid} = BufferProcess.start_link(content: "")
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")
      BufferProcess.insert_char(pid, "c")

      # :lsp reads all 3
      lsp_first = consume_edit_deltas(pid, :lsp)
      assert length(lsp_first) == 3

      # More edits
      BufferProcess.insert_char(pid, "d")
      BufferProcess.insert_char(pid, "e")

      # :highlight hasn't read yet, should get all 5
      hl_all = consume_edit_deltas(pid, :highlight)
      assert length(hl_all) == 5
      assert Enum.map(hl_all, & &1.inserted_text) == ["a", "b", "c", "d", "e"]

      # :lsp should get only the 2 new ones
      lsp_second = consume_edit_deltas(pid, :lsp)
      assert length(lsp_second) == 2
      assert Enum.map(lsp_second, & &1.inserted_text) == ["d", "e"]
    end

    test "log is trimmed after all consumers have read" do
      {:ok, pid} = BufferProcess.start_link(content: "")
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")

      # Both consumers flush
      consume_edit_deltas(pid, :lsp)
      consume_edit_deltas(pid, :highlight)

      # Once both registered consumers have caught up, the log is trimmed.
      # A new consumer registering after the fact needs a full sync because
      # there is no retained history for its baseline.
      assert :reset_required = BufferProcess.consume_edit_deltas(pid, :late_arrival)
    end

    test "new consumer starts from sequence 0 and gets entire log" do
      {:ok, pid} = BufferProcess.start_link(content: "")
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")
      BufferProcess.insert_char(pid, "c")

      # :lsp reads all 3
      consume_edit_deltas(pid, :lsp)

      # More edits
      BufferProcess.insert_char(pid, "d")
      BufferProcess.insert_char(pid, "e")

      # New consumer never registered before, but the complete history is still retained.
      new_deltas = consume_edit_deltas(pid, :new_consumer)
      assert Enum.map(new_deltas, & &1.inserted_text) == ["a", "b", "c", "d", "e"]
    end

    test "undo clears the edit log for all consumers" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")

      # :lsp reads
      assert [_, _] = consume_edit_deltas(pid, :lsp)

      # More edits then undo
      BufferProcess.insert_char(pid, "c")
      BufferProcess.undo(pid)

      # Both consumers must full-sync after history is cleared.
      assert :reset_required = BufferProcess.consume_edit_deltas(pid, :lsp)
      assert :reset_required = BufferProcess.consume_edit_deltas(pid, :highlight)
    end

    test "replace_content clears the edit log for all consumers" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.move_to(pid, {0, 5})
      BufferProcess.insert_char(pid, "!")
      BufferProcess.replace_content(pid, "goodbye")

      assert :reset_required = BufferProcess.consume_edit_deltas(pid, :lsp)
      assert :reset_required = BufferProcess.consume_edit_deltas(pid, :highlight)
    end

    test "flush with no edits returns empty list" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      assert [] = consume_edit_deltas(pid, :lsp)
    end

    test "flush same consumer twice with no intervening edits returns empty" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      BufferProcess.insert_char(pid, "!")
      assert [_] = consume_edit_deltas(pid, :lsp)
      assert [] = consume_edit_deltas(pid, :lsp)
    end

    test "change log is capped at 1000 entries when only one consumer is registered" do
      {:ok, pid} = BufferProcess.start_link(content: "")

      # Insert more than 1000 chars with only :lsp reading periodically
      for _ <- 1..1100, do: BufferProcess.insert_char(pid, "x")

      # Only one consumer has ever called consume_edit_deltas
      _deltas = consume_edit_deltas(pid, :lsp)

      # A late-arriving consumer is behind compacted history, so it must full-sync.
      assert :reset_required = BufferProcess.consume_edit_deltas(pid, :late_arrival)
    end
  end

  # ── Buffer-local options ──────────────────────────────────────────────────

  describe "buffer-local options" do
    test "local overrides are isolated and visible through option APIs" do
      {:ok, a} = BufferProcess.start_link(content: "alpha")
      {:ok, b} = BufferProcess.start_link(content: "bravo")

      assert BufferProcess.get_option(a, :tab_width) == 2
      assert BufferProcess.local_options(a)[:wrap] == true
      assert BufferProcess.local_option_overrides(a) == %{}

      assert {:ok, 8} = BufferProcess.set_option(a, :tab_width, 8)

      assert BufferProcess.get_option(a, :tab_width) == 8
      assert BufferProcess.get_option(b, :tab_width) == 2
      assert BufferProcess.local_options(a)[:tab_width] == 8
      assert BufferProcess.local_option_overrides(a) == %{tab_width: 8}
    end

    test "set_option rejects invalid or unknown options without changing existing values" do
      {:ok, pid} = BufferProcess.start_link(content: "hello")

      assert {:error, _} = BufferProcess.set_option(pid, :tab_width, -1)
      assert {:error, _} = BufferProcess.set_option(pid, :nonexistent, true)
      assert BufferProcess.get_option(pid, :tab_width) == 2
    end

    test "filetype reseeding preserves explicit overrides and updates defaults" do
      Options.set_for_filetype(:go, :tab_width, 8)

      on_exit(fn ->
        try do
          Options.set_for_filetype(:go, :tab_width, 2)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, seeded} = BufferProcess.start_link(content: "package main", filetype: :go)
      assert BufferProcess.get_option(seeded, :tab_width) == 8
      BufferProcess.set_option(seeded, :tab_width, 3)
      assert BufferProcess.get_option(seeded, :tab_width) == 3

      {:ok, reseeded} = BufferProcess.start_link(content: "hello", filetype: :text)
      assert BufferProcess.get_option(reseeded, :tab_width) == 2
      BufferProcess.set_filetype(reseeded, :go)
      assert BufferProcess.get_option(reseeded, :tab_width) == 8

      {:ok, explicit} = BufferProcess.start_link(content: "hello")
      BufferProcess.set_option(explicit, :clipboard, :none)
      BufferProcess.set_filetype(explicit, :python)
      assert BufferProcess.get_option(explicit, :clipboard) == :none
    end

    test "get_option falls back to builtin defaults when a private options server dies" do
      options_server = start_supervised!({Options, name: nil})
      assert {:ok, 4} = Options.set_for_filetype(options_server, :text, :tab_width, 4)
      :ok = GenServer.stop(options_server)

      {:ok, pid} =
        BufferProcess.start_link(
          content: "hello",
          filetype: :text,
          options_server: options_server
        )

      assert BufferProcess.get_option(pid, :tab_width) == 2
    end

    test "set_filetype reseeds from the buffer's private options server" do
      options_server = start_supervised!({Options, name: nil})
      assert {:ok, 11} = Options.set_for_filetype(options_server, :go, :tab_width, 11)

      {:ok, pid} =
        BufferProcess.start_link(
          content: "hello",
          filetype: :text,
          options_server: options_server
        )

      assert BufferProcess.get_option(pid, :tab_width) == 2

      BufferProcess.set_filetype(pid, :go)

      assert BufferProcess.get_option(pid, :tab_width) == 11
    end
  end

  describe "face_overrides/1 and remap_face/3" do
    test "sets, clears, and preserves independent face overrides" do
      {:ok, pid} = BufferProcess.start_link()
      assert BufferProcess.face_overrides(pid) == %{}

      :ok = BufferProcess.remap_face(pid, "keyword", fg: 0xFF0000)
      :ok = BufferProcess.remap_face(pid, "comment", italic: false)

      assert BufferProcess.face_overrides(pid) == %{
               "keyword" => [fg: 0xFF0000],
               "comment" => [italic: false]
             }

      :ok = BufferProcess.clear_face_override(pid, "comment")
      assert BufferProcess.face_overrides(pid) == %{"keyword" => [fg: 0xFF0000]}
    end
  end

  describe "find_and_replace/3" do
    test "replacing text updates content and marks dirty" do
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

    test "replacement edge cases update exact content" do
      cases = [
        {"multi-line replacement", "line1\nline2\nline3\n", "line1\nline2",
         "replaced1\nreplaced2\nreplaced3", "replaced1\nreplaced2\nreplaced3\nline3\n"},
        {"start of buffer", "target rest of file", "target", "replaced", "replaced rest of file"},
        {"end of buffer", "start of file target", "target", "replaced", "start of file replaced"},
        {"whole buffer", "everything", "everything", "replaced", "replaced"},
        {"line count change", "before\nsingle line\nafter", "single line",
         "line A\nline B\nline C", "before\nline A\nline B\nline C\nafter"},
        {"unicode", "I like café and naïve", "café", "tea", "I like tea and naïve"}
      ]

      for {name, content, old_text, new_text, expected} <- cases do
        {:ok, pid} = BufferProcess.start_link(content: content)
        assert {:ok, _} = BufferProcess.find_and_replace(pid, old_text, new_text), name
        assert BufferProcess.content(pid) == expected, name
      end
    end

    test "replacement errors leave content unchanged" do
      cases = [
        {"not found", "hello world", [], "nonexistent", "replacement", "not found"},
        {"ambiguous", "foo\nbar\nfoo\n", [], "foo", "baz", "2 times"},
        {"read-only", "hello", [read_only: true], "hello", "world", "read-only"},
        {"empty old_text", "hello", [], "", "something", "empty"}
      ]

      for {name, content, opts, old_text, new_text, expected_message} <- cases do
        {:ok, pid} = BufferProcess.start_link(Keyword.merge([content: content], opts))
        assert {:error, msg} = BufferProcess.find_and_replace(pid, old_text, new_text), name
        assert msg =~ expected_message, name
        assert BufferProcess.content(pid) == content, name
      end
    end

    test "replacing text creates a single undo entry" do
      {:ok, pid} = BufferProcess.start_link(content: "aaa bbb ccc")
      BufferProcess.find_and_replace(pid, "bbb", "BBB")
      assert BufferProcess.content(pid) == "aaa BBB ccc"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "aaa bbb ccc"
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
    test "returns :not_found for unknown or pathless buffers" do
      _pid = start_supervised!({BufferProcess, content: "scratch"})

      assert :not_found = BufferProcess.pid_for_path("/no/such/file.ex")
      assert :not_found = BufferProcess.pid_for_path("/nonexistent")
    end

    test "registered buffers are findable by independent file paths", %{tmp_dir: dir} do
      path_a = Path.join(dir, "a.ex")
      path_b = Path.join(dir, "b.ex")
      File.write!(path_a, "aaa")
      File.write!(path_b, "bbb")

      pid_a = start_supervised!({BufferProcess, file_path: path_a}, id: :buf_a)
      pid_b = start_supervised!({BufferProcess, file_path: path_b}, id: :buf_b)

      assert {:ok, ^pid_a} = BufferProcess.pid_for_path(path_a)
      assert {:ok, ^pid_b} = BufferProcess.pid_for_path(path_b)
    end

    test "path-changing APIs unregister the old path and register the new path", %{tmp_dir: dir} do
      cases = [
        {:open, fn pid, path -> BufferProcess.open(pid, path) end},
        {:save_as, fn pid, path -> BufferProcess.save_as(pid, path) end}
      ]

      for {name, operation} <- cases do
        path_a = Path.join(dir, "#{name}_a.ex")
        path_b = Path.join(dir, "#{name}_b.ex")
        File.write!(path_a, "aaa")
        File.write!(path_b, "bbb")
        pid = start_supervised!({BufferProcess, file_path: path_a}, id: {:path_case, name})

        assert {:ok, ^pid} = BufferProcess.pid_for_path(path_a)

        operation.(pid, path_b)

        assert :not_found = BufferProcess.pid_for_path(path_a)
        assert {:ok, ^pid} = BufferProcess.pid_for_path(path_b)
      end
    end
  end

  describe "find_and_replace/4 with boundary" do
    test "allows edits within inclusive boundaries" do
      cases = [
        {"middle", "line0\nline1\nline2\nline3\nline4", "line2", "REPLACED", {1, 3}, "REPLACED"},
        {"boundary start", "line0\nline1\nline2\nline3\nline4", "line2", "OK", {2, 4}, "OK"},
        {"boundary end", "line0\nline1\nline2\nline3\nline4", "line4", "OK", {2, 4}, "OK"},
        {"nil boundary", "line0\nline1\nline2", "line0", "OK", nil, "OK"},
        {"multi-line", "aaa\nbbb\nccc\nddd\neee", "bbb\nccc\nddd", "OK", {1, 3}, "OK"},
        {"single-line zero", "only_line", "only_line", "replaced", {0, 0}, "replaced"},
        {"unicode", "café\n日本語\ntarget\nmore", "target", "hit", {2, 2}, "hit"}
      ]

      for {name, content, old_text, new_text, boundary, expected_fragment} <- cases do
        {:ok, pid} = BufferProcess.start_link(content: content)
        assert {:ok, _} = BufferProcess.find_and_replace(pid, old_text, new_text, boundary), name
        assert BufferProcess.content(pid) =~ expected_fragment, name
      end
    end

    test "rejects edits outside the allowed boundary" do
      cases = [
        {"line before boundary", "line0\nline1\nline2\nline3\nline4", "line0", "NOPE", {1, 3},
         ["outside boundary", "lines 0-0", "1-3"]},
        {"span crosses boundary", "aaa\nbbb\nccc\nddd", "bbb\nccc\nddd", "NOPE", {1, 2},
         ["outside boundary"]}
      ]

      for {name, content, old_text, new_text, boundary, messages} <- cases do
        {:ok, pid} = BufferProcess.start_link(content: content)

        assert {:error, msg} = BufferProcess.find_and_replace(pid, old_text, new_text, boundary),
               name

        assert Enum.all?(messages, &String.contains?(msg, &1)), name
        assert BufferProcess.content(pid) == content, name
      end
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
