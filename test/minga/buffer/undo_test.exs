defmodule Minga.Buffer.UndoTest do
  @moduledoc """
  Buffer-level undo tests. Migrated from integration_test.exs to test
  at the correct layer (single GenServer, no Editor or HeadlessPort).
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server

  defp start_buffer(content) do
    start_supervised!({Server, content: content})
  end

  describe "undo after insert" do
    test "reverts inserted text" do
      pid = start_buffer("hello")
      Server.insert_char(pid, "x")
      assert Server.content(pid) == "xhello"

      # Break coalescing so the insert becomes its own undo entry
      Server.break_undo_coalescing(pid)
      Server.undo(pid)
      assert Server.content(pid) == "hello"
    end
  end

  describe "undo after delete_lines" do
    test "reverts the deletion" do
      pid = start_buffer("hello\nworld\nfoo")
      Server.delete_lines(pid, 0, 0)
      refute String.contains?(Server.content(pid), "hello")

      Server.undo(pid)
      assert String.contains?(Server.content(pid), "hello")
    end
  end

  describe "undo on unchanged buffer" do
    test "is a no-op" do
      pid = start_buffer("hello")
      original = Server.content(pid)

      Server.undo(pid)
      assert Server.content(pid) == original
    end
  end

  describe "multiple undo steps" do
    test "revert in order" do
      pid = start_buffer("aaa\nbbb\nccc")

      Server.delete_lines(pid, 0, 0)
      assert Server.content(pid) == "bbb\nccc"

      # Break coalescing between the two deletes
      Server.break_undo_coalescing(pid)

      # After deleting first line, "bbb" is now line 0
      Server.delete_lines(pid, 0, 0)
      assert Server.content(pid) == "ccc"

      Server.undo(pid)
      assert Server.content(pid) == "bbb\nccc"

      Server.undo(pid)
      assert Server.content(pid) == "aaa\nbbb\nccc"
    end
  end
end
