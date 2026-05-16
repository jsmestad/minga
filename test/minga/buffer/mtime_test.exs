defmodule Minga.Buffer.MtimeTest do
  @moduledoc """
  Tests for file mtime tracking and save-conflict detection in BufferProcess.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Buffer.State, as: BufState

  @tag :tmp_dir
  test "opening a file records its mtime", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "hello.txt")
    File.write!(path, "hello")
    %{mtime: disk_mtime} = File.stat!(path, time: :posix)

    {:ok, buf} = BufferProcess.start_link(file_path: path)
    state = :sys.get_state(buf)

    assert BufState.mtime(state) == disk_mtime
  end

  test "scratch buffer has nil mtime" do
    {:ok, buf} = BufferProcess.start_link(content: "scratch")
    state = :sys.get_state(buf)

    assert BufState.mtime(state) == nil
  end

  @tag :tmp_dir
  test "saving updates stored mtime", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "save.txt")
    File.write!(path, "original")

    {:ok, buf} = BufferProcess.start_link(file_path: path)
    old_state = :sys.get_state(buf)

    # Modify buffer so there's something to save
    BufferProcess.insert_char(buf, "x")
    :ok = BufferProcess.save(buf)

    new_state = :sys.get_state(buf)
    assert BufState.mtime(new_state) >= BufState.mtime(old_state)
    assert BufState.dirty?(new_state) == false
  end

  @tag :tmp_dir
  test ":w returns :file_changed when file size differs on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "conflict.txt")
    File.write!(path, "original")

    {:ok, buf} = BufferProcess.start_link(file_path: path)

    # Simulate external modification, different size triggers detection even within the same second.
    File.write!(path, "externally modified with longer content")

    BufferProcess.insert_char(buf, "x")
    result = BufferProcess.save(buf)

    assert result == {:error, :file_changed}
    state = :sys.get_state(buf)
    assert BufState.dirty?(state) == true
  end

  @tag :tmp_dir
  test ":w ignores metadata-only changes when file content still matches", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "touched.txt")
    File.write!(path, "original")

    {:ok, buf} = BufferProcess.start_link(file_path: path)
    original_mtime = buf |> :sys.get_state() |> BufState.mtime()
    File.touch!(path, original_mtime + 10)

    BufferProcess.insert_char(buf, "x")

    assert BufferProcess.save(buf) == :ok
    assert File.read!(path) == "xoriginal"
    refute BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test ":w! force-saves despite file change on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "force.txt")
    File.write!(path, "original")

    {:ok, buf} = BufferProcess.start_link(file_path: path)

    # Simulate external modification with a different size.
    File.write!(path, "externally modified with longer content")

    BufferProcess.insert_char(buf, "forced")
    result = BufferProcess.force_save(buf)

    assert result == :ok
    assert File.read!(path) == "forcedoriginal"

    state = :sys.get_state(buf)
    assert BufState.dirty?(state) == false
  end

  @tag :tmp_dir
  test ":e! reloads buffer from disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "reload.txt")
    File.write!(path, "line1\nline2\nline3")

    {:ok, buf} = BufferProcess.start_link(file_path: path)

    # Modify buffer locally
    BufferProcess.insert_char(buf, "x")
    assert BufferProcess.dirty?(buf) == true

    # Modify on disk
    File.write!(path, "reloaded content")

    :ok = BufferProcess.reload(buf)

    assert BufferProcess.content(buf) == "reloaded content"
    assert BufferProcess.dirty?(buf) == false
  end

  @tag :tmp_dir
  test ":e! clears undo/redo history", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "undo.txt")
    File.write!(path, "original")

    {:ok, buf} = BufferProcess.start_link(file_path: path)
    BufferProcess.insert_char(buf, "change1")
    BufferProcess.insert_char(buf, "change2")

    assert BufferProcess.last_undo_source(buf) != nil

    :ok = BufferProcess.reload(buf)

    assert BufferProcess.last_undo_source(buf) == nil
    assert BufferProcess.last_redo_source(buf) == nil
  end

  @tag :tmp_dir
  test ":e! preserves cursor position clamped to new content", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "clamp.txt")
    File.write!(path, "line1\nline2\nline3\nline4\nline5")

    {:ok, buf} = BufferProcess.start_link(file_path: path)
    # Move cursor to line 4
    BufferProcess.move_to(buf, {4, 3})

    # Reload with shorter content
    File.write!(path, "short\nfile")
    :ok = BufferProcess.reload(buf)

    {line, col} = BufferProcess.cursor(buf)
    # Should clamp to last line (1), col clamped to line length
    assert line <= 1
    assert col <= 3
  end

  @tag :tmp_dir
  test ":w works when file was deleted on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "deleted.txt")
    File.write!(path, "exists")

    {:ok, buf} = BufferProcess.start_link(file_path: path)

    # Delete the file
    File.rm!(path)

    BufferProcess.insert_char(buf, "new content")
    result = BufferProcess.save(buf)

    assert result == :ok
    assert File.read!(path) == "new contentexists"
  end

  test "reload on scratch buffer returns error" do
    {:ok, buf} = BufferProcess.start_link(content: "scratch")
    assert BufferProcess.reload(buf) == {:error, :no_file_path}
  end

  test "force_save on scratch buffer returns error" do
    {:ok, buf} = BufferProcess.start_link(content: "scratch")
    assert BufferProcess.force_save(buf) == {:error, :no_file_path}
  end

  @tag :tmp_dir
  test "save_as updates mtime", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "saveas.txt")

    {:ok, buf} = BufferProcess.start_link(content: "new file")
    :ok = BufferProcess.save_as(buf, path)

    state = :sys.get_state(buf)
    assert BufState.mtime(state) != nil
    assert File.exists?(path)
  end

  @tag :tmp_dir
  test "opening a file records its size", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "sized.txt")
    File.write!(path, "hello")

    {:ok, buf} = BufferProcess.start_link(file_path: path)
    state = :sys.get_state(buf)

    assert BufState.file_size(state) == 5
  end

  @tag :tmp_dir
  test "open updates mtime", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "opened.txt")
    File.write!(path, "content")

    {:ok, buf} = BufferProcess.start_link(content: "scratch")
    :ok = BufferProcess.open(buf, path)

    state = :sys.get_state(buf)
    assert BufState.mtime(state) != nil
  end
end
