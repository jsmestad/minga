defmodule Minga.Buffer.MtimeTest do
  @moduledoc """
  Tests for file mtime tracking and save-conflict detection in BufferServer.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer

  @tag :tmp_dir
  test "opening a file records its mtime", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "hello.txt")
    File.write!(path, "hello")
    %{mtime: disk_mtime} = File.stat!(path, time: :posix)

    {:ok, buf} = BufferServer.start_link(file_path: path)
    state = :sys.get_state(buf)

    assert state.mtime == disk_mtime
  end

  test "scratch buffer has nil mtime" do
    {:ok, buf} = BufferServer.start_link(content: "scratch")
    state = :sys.get_state(buf)

    assert state.mtime == nil
  end

  @tag :tmp_dir
  test "saving updates stored mtime", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "save.txt")
    File.write!(path, "original")

    {:ok, buf} = BufferServer.start_link(file_path: path)
    old_state = :sys.get_state(buf)

    # Modify buffer so there's something to save
    BufferServer.insert_char(buf, "x")
    :ok = BufferServer.save(buf)

    new_state = :sys.get_state(buf)
    assert new_state.mtime >= old_state.mtime
    assert new_state.dirty == false
  end

  @tag :tmp_dir
  test ":w returns :file_changed when file size differs on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "conflict.txt")
    File.write!(path, "original")

    {:ok, buf} = BufferServer.start_link(file_path: path)

    # Simulate external modification — different size triggers detection
    # even within the same second
    File.write!(path, "externally modified with longer content")

    BufferServer.insert_char(buf, "x")
    result = BufferServer.save(buf)

    assert result == {:error, :file_changed}
    # Buffer should still be dirty — save was rejected
    state = :sys.get_state(buf)
    assert state.dirty == true
  end

  @tag :tmp_dir
  test ":w! force-saves despite file change on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "force.txt")
    File.write!(path, "original")

    {:ok, buf} = BufferServer.start_link(file_path: path)

    # Simulate external modification — different size
    File.write!(path, "externally modified with longer content")

    BufferServer.insert_char(buf, "forced")
    result = BufferServer.force_save(buf)

    assert result == :ok
    assert File.read!(path) == "forcedoriginal"

    state = :sys.get_state(buf)
    assert state.dirty == false
  end

  @tag :tmp_dir
  test ":e! reloads buffer from disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "reload.txt")
    File.write!(path, "line1\nline2\nline3")

    {:ok, buf} = BufferServer.start_link(file_path: path)

    # Modify buffer locally
    BufferServer.insert_char(buf, "x")
    assert BufferServer.dirty?(buf) == true

    # Modify on disk
    File.write!(path, "reloaded content")

    :ok = BufferServer.reload(buf)

    assert BufferServer.content(buf) == "reloaded content"
    assert BufferServer.dirty?(buf) == false
  end

  @tag :tmp_dir
  test ":e! clears undo/redo stacks", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "undo.txt")
    File.write!(path, "original")

    {:ok, buf} = BufferServer.start_link(file_path: path)
    BufferServer.insert_char(buf, "change1")
    BufferServer.insert_char(buf, "change2")

    state_before = :sys.get_state(buf)
    assert state_before.undo_stack != []

    :ok = BufferServer.reload(buf)

    state_after = :sys.get_state(buf)
    assert state_after.undo_stack == []
    assert state_after.redo_stack == []
  end

  @tag :tmp_dir
  test ":e! preserves cursor position clamped to new content", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "clamp.txt")
    File.write!(path, "line1\nline2\nline3\nline4\nline5")

    {:ok, buf} = BufferServer.start_link(file_path: path)
    # Move cursor to line 4
    BufferServer.move_to(buf, {4, 3})

    # Reload with shorter content
    File.write!(path, "short\nfile")
    :ok = BufferServer.reload(buf)

    {line, col} = BufferServer.cursor(buf)
    # Should clamp to last line (1), col clamped to line length
    assert line <= 1
    assert col <= 3
  end

  @tag :tmp_dir
  test ":w works when file was deleted on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "deleted.txt")
    File.write!(path, "exists")

    {:ok, buf} = BufferServer.start_link(file_path: path)

    # Delete the file
    File.rm!(path)

    BufferServer.insert_char(buf, "new content")
    result = BufferServer.save(buf)

    assert result == :ok
    assert File.read!(path) == "new contentexists"
  end

  test "reload on scratch buffer returns error" do
    {:ok, buf} = BufferServer.start_link(content: "scratch")
    assert BufferServer.reload(buf) == {:error, :no_file_path}
  end

  test "force_save on scratch buffer returns error" do
    {:ok, buf} = BufferServer.start_link(content: "scratch")
    assert BufferServer.force_save(buf) == {:error, :no_file_path}
  end

  @tag :tmp_dir
  test "save_as updates mtime", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "saveas.txt")

    {:ok, buf} = BufferServer.start_link(content: "new file")
    :ok = BufferServer.save_as(buf, path)

    state = :sys.get_state(buf)
    assert state.mtime != nil
    assert File.exists?(path)
  end

  @tag :tmp_dir
  test "opening a file records its size", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "sized.txt")
    File.write!(path, "hello")

    {:ok, buf} = BufferServer.start_link(file_path: path)
    state = :sys.get_state(buf)

    assert state.file_size == 5
  end

  @tag :tmp_dir
  test "open updates mtime", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "opened.txt")
    File.write!(path, "content")

    {:ok, buf} = BufferServer.start_link(content: "scratch")
    :ok = BufferServer.open(buf, path)

    state = :sys.get_state(buf)
    assert state.mtime != nil
  end
end
