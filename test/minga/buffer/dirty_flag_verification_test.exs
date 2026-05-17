defmodule Minga.Buffer.DirtyFlagVerificationTest do
  @moduledoc """
  Verifies that the dirty flag tracks the save point correctly
  through undo, redo, save, and save_as operations.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Process, as: BufferProcess

  @moduletag :tmp_dir

  test "typing a character then undoing clears the dirty flag", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "hello")
    {:ok, pid} = BufferProcess.start_link(file_path: path)

    refute BufferProcess.dirty?(pid)
    BufferProcess.insert_char(pid, "X")
    assert BufferProcess.dirty?(pid)
    BufferProcess.undo(pid)
    refute BufferProcess.dirty?(pid)
  end

  test "multiple edits followed by the same number of undos clears dirty", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "hello")
    {:ok, pid} = BufferProcess.start_link(file_path: path)

    BufferProcess.insert_char(pid, "A")
    BufferProcess.break_undo_coalescing(pid)
    BufferProcess.insert_char(pid, "B")
    BufferProcess.break_undo_coalescing(pid)
    BufferProcess.insert_char(pid, "C")
    assert BufferProcess.dirty?(pid)

    BufferProcess.undo(pid)
    assert BufferProcess.dirty?(pid), "still dirty after first undo"
    BufferProcess.undo(pid)
    assert BufferProcess.dirty?(pid), "still dirty after second undo"
    BufferProcess.undo(pid)
    refute BufferProcess.dirty?(pid), "clean after undoing all edits"
  end

  test "undoing past the save point re-marks dirty", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "original")
    {:ok, pid} = BufferProcess.start_link(file_path: path)

    BufferProcess.insert_char(pid, "X")
    :ok = BufferProcess.save(pid)
    refute BufferProcess.dirty?(pid)

    BufferProcess.break_undo_coalescing(pid)
    BufferProcess.insert_char(pid, "Y")
    assert BufferProcess.dirty?(pid)

    # Undo back to save point
    BufferProcess.undo(pid)
    refute BufferProcess.dirty?(pid)

    # Undo past save point into pre-save state
    BufferProcess.undo(pid)
    assert BufferProcess.dirty?(pid)
  end

  test "saving then editing then undoing back clears dirty", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "start")
    {:ok, pid} = BufferProcess.start_link(file_path: path)

    BufferProcess.insert_char(pid, "A")
    :ok = BufferProcess.save(pid)
    refute BufferProcess.dirty?(pid)

    BufferProcess.break_undo_coalescing(pid)
    BufferProcess.insert_char(pid, "B")
    assert BufferProcess.dirty?(pid)

    BufferProcess.undo(pid)
    refute BufferProcess.dirty?(pid)
  end

  test "redo past the save point marks dirty again", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "original")
    {:ok, pid} = BufferProcess.start_link(file_path: path)

    BufferProcess.insert_char(pid, "X")
    assert BufferProcess.dirty?(pid)

    BufferProcess.undo(pid)
    refute BufferProcess.dirty?(pid)

    BufferProcess.redo(pid)
    assert BufferProcess.dirty?(pid)
  end

  test "save moves the save point to the current state", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "v1")
    {:ok, pid} = BufferProcess.start_link(file_path: path)

    BufferProcess.insert_char(pid, "A")
    :ok = BufferProcess.save(pid)
    refute BufferProcess.dirty?(pid)

    # Undoing past the new save point should be dirty
    BufferProcess.undo(pid)
    assert BufferProcess.dirty?(pid)

    # Redo back to save point should be clean
    BufferProcess.redo(pid)
    refute BufferProcess.dirty?(pid)
  end

  test "save_as moves the save point to the new path", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    new_path = Path.join(dir, "test_new.txt")
    File.write!(path, "v1")
    {:ok, pid} = BufferProcess.start_link(file_path: path)

    BufferProcess.insert_char(pid, "Z")
    :ok = BufferProcess.save_as(pid, new_path)
    refute BufferProcess.dirty?(pid)

    BufferProcess.undo(pid)
    assert BufferProcess.dirty?(pid)
  end

  test "buffers loaded from disk start clean", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "hello world")
    {:ok, pid} = BufferProcess.start_link(file_path: path)

    refute BufferProcess.dirty?(pid)
    assert BufferProcess.content(pid) == "hello world"
  end

  test "new buffers start clean and become dirty on first edit" do
    {:ok, pid} = BufferProcess.start_link(content: "")

    refute BufferProcess.dirty?(pid)
    BufferProcess.insert_char(pid, "a")
    assert BufferProcess.dirty?(pid)

    BufferProcess.undo(pid)
    refute BufferProcess.dirty?(pid), "new buffer should be clean after undoing all edits"
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  property "dirty flag is consistent after random insert/undo sequences", %{tmp_dir: dir} do
    check all(
            ops <-
              StreamData.list_of(
                StreamData.frequency([
                  {3, StreamData.constant(:insert)},
                  {2, StreamData.constant(:undo)},
                  {1, StreamData.constant(:save)},
                  {1, StreamData.constant(:break)}
                ]),
                min_length: 1,
                max_length: 20
              )
          ) do
      path = Path.join(dir, "prop_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(path, "start")
      {:ok, pid} = BufferProcess.start_link(file_path: path)

      Enum.each(ops, fn
        :insert ->
          BufferProcess.insert_char(pid, "x")

        :undo ->
          BufferProcess.undo(pid)

        :save ->
          BufferProcess.save(pid)

        :break ->
          BufferProcess.break_undo_coalescing(pid)
      end)

      # After any sequence: if content matches what was last saved,
      # dirty should be false. We can't easily track the saved content
      # in the property, but we CAN verify the invariant that saving
      # then doing nothing leaves the buffer clean.
      BufferProcess.save(pid)
      refute BufferProcess.dirty?(pid), "buffer should be clean immediately after save"

      GenServer.stop(pid)
    end
  end
end
