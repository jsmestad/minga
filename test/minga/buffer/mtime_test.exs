defmodule Minga.Buffer.MtimeTest do
  @moduledoc """
  Save-conflict behavior for file-backed buffers.

  These tests avoid asserting on stored mtime fields directly. The contract is whether saves, force-saves, reloads, and dirty state behave correctly when the file changes on disk.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess

  @tag :tmp_dir
  test ":w returns :file_changed when file size differs on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "conflict.txt")
    File.write!(path, "original")
    buf = start_buffer(file_path: path)

    File.write!(path, "externally modified with longer content")
    BufferProcess.insert_char(buf, "x")

    assert BufferProcess.save(buf) == {:error, :file_changed}
    assert BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test ":w ignores metadata-only changes when file content still matches", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "touched.txt")
    File.write!(path, "original")
    %{mtime: original_mtime} = File.stat!(path, time: :posix)
    buf = start_buffer(file_path: path)
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
    buf = start_buffer(file_path: path)

    File.write!(path, "externally modified with longer content")
    BufferProcess.insert_char(buf, "forced")

    assert BufferProcess.force_save(buf) == :ok
    assert File.read!(path) == "forcedoriginal"
    refute BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test ":e! reloads buffer from disk and clears dirty state", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "reload.txt")
    File.write!(path, "line1\nline2\nline3")
    buf = start_buffer(file_path: path)
    BufferProcess.insert_char(buf, "x")
    assert BufferProcess.dirty?(buf)

    File.write!(path, "reloaded content")

    assert :ok = BufferProcess.reload(buf)
    assert BufferProcess.content(buf) == "reloaded content"
    refute BufferProcess.dirty?(buf)
  end

  @tag :tmp_dir
  test ":e! clears undo and redo history", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "undo.txt")
    File.write!(path, "original")
    buf = start_buffer(file_path: path)
    BufferProcess.insert_char(buf, "change1")
    BufferProcess.insert_char(buf, "change2")
    assert BufferProcess.last_undo_source(buf) != nil

    assert :ok = BufferProcess.reload(buf)

    assert BufferProcess.last_undo_source(buf) == nil
    assert BufferProcess.last_redo_source(buf) == nil
  end

  @tag :tmp_dir
  test ":e! preserves cursor position clamped to new content", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "clamp.txt")
    File.write!(path, "line1\nline2\nline3\nline4\nline5")
    buf = start_buffer(file_path: path)
    BufferProcess.move_to(buf, {4, 3})

    File.write!(path, "short\nfile")

    assert :ok = BufferProcess.reload(buf)
    {line, col} = BufferProcess.cursor(buf)
    assert line <= 1
    assert col <= 3
  end

  @tag :tmp_dir
  test ":w works when file was deleted on disk", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "deleted.txt")
    File.write!(path, "exists")
    buf = start_buffer(file_path: path)
    File.rm!(path)

    BufferProcess.insert_char(buf, "new content")

    assert BufferProcess.save(buf) == :ok
    assert File.read!(path) == "new contentexists"
  end

  test "reload and force_save on scratch buffers return errors" do
    buf = start_buffer(content: "scratch")

    assert BufferProcess.reload(buf) == {:error, :no_file_path}
    assert BufferProcess.force_save(buf) == {:error, :no_file_path}
  end

  @tag :tmp_dir
  test "save_as writes scratch content to a file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "saveas.txt")
    buf = start_buffer(content: "new file")

    assert :ok = BufferProcess.save_as(buf, path)
    assert File.read!(path) == "new file"
    assert BufferProcess.file_path(buf) == path
    refute BufferProcess.dirty?(buf)
  end

  defp start_buffer(opts) do
    start_supervised!({BufferProcess, opts}, id: {:buffer, make_ref()})
  end
end
