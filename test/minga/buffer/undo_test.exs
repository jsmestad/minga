defmodule Minga.Buffer.UndoTest do
  @moduledoc """
  Buffer-level undo tests. Migrated from integration_test.exs to test
  at the correct layer (single GenServer, no Editor or HeadlessPort).
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content})
  end

  describe "undo after insert" do
    test "reverts inserted text" do
      pid = start_buffer("hello")
      BufferProcess.insert_char(pid, "x")
      assert BufferProcess.content(pid) == "xhello"

      # Break coalescing so the insert becomes its own undo entry
      BufferProcess.break_undo_coalescing(pid)
      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "hello"
    end
  end

  describe "undo after delete_lines" do
    test "reverts the deletion" do
      pid = start_buffer("hello\nworld\nfoo")
      BufferProcess.delete_lines(pid, 0, 0)
      refute String.contains?(BufferProcess.content(pid), "hello")

      BufferProcess.undo(pid)
      assert String.contains?(BufferProcess.content(pid), "hello")
    end
  end

  describe "undo on unchanged buffer" do
    test "is a no-op" do
      pid = start_buffer("hello")
      original = BufferProcess.content(pid)

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == original
    end
  end

  describe "multiple undo steps" do
    test "revert in order" do
      pid = start_buffer("aaa\nbbb\nccc")

      BufferProcess.delete_lines(pid, 0, 0)
      assert BufferProcess.content(pid) == "bbb\nccc"

      # Break coalescing between the two deletes
      BufferProcess.break_undo_coalescing(pid)

      # After deleting first line, "bbb" is now line 0
      BufferProcess.delete_lines(pid, 0, 0)
      assert BufferProcess.content(pid) == "ccc"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "bbb\nccc"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "aaa\nbbb\nccc"
    end
  end
end
