defmodule Minga.Buffer.DirtyFlagVerificationTest do
  @moduledoc """
  Verifies that the dirty flag tracks the save point correctly
  through undo, redo, save, and save_as operations.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Server

  @moduletag :tmp_dir

  test "typing a character then undoing clears the dirty flag", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "hello")
    {:ok, pid} = Server.start_link(file_path: path)

    refute Server.dirty?(pid)
    Server.insert_char(pid, "X")
    assert Server.dirty?(pid)
    Server.undo(pid)
    refute Server.dirty?(pid)
  end

  test "multiple edits followed by the same number of undos clears dirty", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "hello")
    {:ok, pid} = Server.start_link(file_path: path)

    Server.insert_char(pid, "A")
    Server.break_undo_coalescing(pid)
    Server.insert_char(pid, "B")
    Server.break_undo_coalescing(pid)
    Server.insert_char(pid, "C")
    assert Server.dirty?(pid)

    Server.undo(pid)
    assert Server.dirty?(pid), "still dirty after first undo"
    Server.undo(pid)
    assert Server.dirty?(pid), "still dirty after second undo"
    Server.undo(pid)
    refute Server.dirty?(pid), "clean after undoing all edits"
  end

  test "undoing past the save point re-marks dirty", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "original")
    {:ok, pid} = Server.start_link(file_path: path)

    Server.insert_char(pid, "X")
    :ok = Server.save(pid)
    refute Server.dirty?(pid)

    Server.break_undo_coalescing(pid)
    Server.insert_char(pid, "Y")
    assert Server.dirty?(pid)

    # Undo back to save point
    Server.undo(pid)
    refute Server.dirty?(pid)

    # Undo past save point into pre-save state
    Server.undo(pid)
    assert Server.dirty?(pid)
  end

  test "saving then editing then undoing back clears dirty", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "start")
    {:ok, pid} = Server.start_link(file_path: path)

    Server.insert_char(pid, "A")
    :ok = Server.save(pid)
    refute Server.dirty?(pid)

    Server.break_undo_coalescing(pid)
    Server.insert_char(pid, "B")
    assert Server.dirty?(pid)

    Server.undo(pid)
    refute Server.dirty?(pid)
  end

  test "redo past the save point marks dirty again", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "original")
    {:ok, pid} = Server.start_link(file_path: path)

    Server.insert_char(pid, "X")
    assert Server.dirty?(pid)

    Server.undo(pid)
    refute Server.dirty?(pid)

    Server.redo(pid)
    assert Server.dirty?(pid)
  end

  test "save moves the save point to the current state", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "v1")
    {:ok, pid} = Server.start_link(file_path: path)

    Server.insert_char(pid, "A")
    :ok = Server.save(pid)
    refute Server.dirty?(pid)

    # Undoing past the new save point should be dirty
    Server.undo(pid)
    assert Server.dirty?(pid)

    # Redo back to save point should be clean
    Server.redo(pid)
    refute Server.dirty?(pid)
  end

  test "save_as moves the save point to the new path", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    new_path = Path.join(dir, "test_new.txt")
    File.write!(path, "v1")
    {:ok, pid} = Server.start_link(file_path: path)

    Server.insert_char(pid, "Z")
    :ok = Server.save_as(pid, new_path)
    refute Server.dirty?(pid)

    Server.undo(pid)
    assert Server.dirty?(pid)
  end

  test "buffers loaded from disk start clean", %{tmp_dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "hello world")
    {:ok, pid} = Server.start_link(file_path: path)

    refute Server.dirty?(pid)
    assert Server.content(pid) == "hello world"
  end

  test "new buffers start clean and become dirty on first edit" do
    {:ok, pid} = Server.start_link(content: "")

    refute Server.dirty?(pid)
    Server.insert_char(pid, "a")
    assert Server.dirty?(pid)

    Server.undo(pid)
    refute Server.dirty?(pid), "new buffer should be clean after undoing all edits"
  end

  @tag :tmp_dir
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
      {:ok, pid} = Server.start_link(file_path: path)

      Enum.each(ops, fn
        :insert ->
          Server.insert_char(pid, "x")

        :undo ->
          Server.undo(pid)

        :save ->
          Server.save(pid)

        :break ->
          Server.break_undo_coalescing(pid)
      end)

      # After any sequence: if content matches what was last saved,
      # dirty should be false. We can't easily track the saved content
      # in the property, but we CAN verify the invariant that saving
      # then doing nothing leaves the buffer clean.
      Server.save(pid)
      refute Server.dirty?(pid), "buffer should be clean immediately after save"

      GenServer.stop(pid)
    end
  end
end
