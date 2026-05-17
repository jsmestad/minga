defmodule Minga.Buffer.UndoTest do
  @moduledoc """
  Buffer-level undo tests. Migrated from integration_test.exs to test
  at the correct layer (single GenServer, no Editor or HeadlessPort).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Buffer.Process, as: BufferProcess

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content}, id: {BufferProcess, make_ref()})
  end

  defp position_for(content, offset) do
    content |> Document.new() |> Document.offset_to_position(offset)
  end

  defp apply_random_op(pid, {:insert, seed, text}) do
    content = BufferProcess.content(pid)
    offset = rem(seed, byte_size(content) + 1)
    BufferProcess.move_to(pid, position_for(content, offset))
    BufferProcess.insert_text(pid, text)
    BufferProcess.break_undo_coalescing(pid)
  end

  defp apply_random_op(pid, {:delete, seed}) do
    content = BufferProcess.content(pid)
    delete_at_offset(pid, content, byte_size(content), seed)
  end

  defp delete_at_offset(_pid, _content, 0, _seed), do: :ok

  defp delete_at_offset(pid, content, content_size, seed) do
    position = position_for(content, rem(seed, content_size))
    BufferProcess.move_to(pid, position)
    BufferProcess.delete_at(pid)
    BufferProcess.break_undo_coalescing(pid)
  end

  defp random_op_generator do
    StreamData.frequency([
      {3,
       StreamData.tuple({
         StreamData.constant(:insert),
         StreamData.positive_integer(),
         StreamData.string(:alphanumeric, min_length: 1, max_length: 5)
       })},
      {2, StreamData.tuple({StreamData.constant(:delete), StreamData.positive_integer()})}
    ])
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

    test "reverts a coalesced final-line delete and linewise paste" do
      pid = start_buffer("alpha\nbeta")
      BufferProcess.delete_lines(pid, 1, 1)
      BufferProcess.insert_text(pid, "beta\n")
      assert BufferProcess.content(pid) == "beta\nalpha"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "alpha\nbeta"
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

  describe "cursor restoration" do
    test "undo and redo restore cursor positions for multi-byte multiline edits" do
      pid = start_buffer("héllo\nworld")
      BufferProcess.move_to(pid, {0, 3})
      BufferProcess.insert_text(pid, "\nΩ")
      edited_cursor = BufferProcess.cursor(pid)

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "héllo\nworld"
      assert BufferProcess.cursor(pid) == {0, 3}

      BufferProcess.redo(pid)
      assert BufferProcess.content(pid) == "hé\nΩllo\nworld"
      assert BufferProcess.cursor(pid) == edited_cursor
    end
  end

  describe "batch edits" do
    test "one undo reverts the full batch and one redo reapplies it" do
      pid = start_buffer("aaa\nbbb\nccc")

      edits = [
        {{0, 0}, {0, 2}, "AAA"},
        {{2, 0}, {2, 2}, "CCC"}
      ]

      BufferProcess.apply_edits(pid, edits)
      assert BufferProcess.content(pid) == "AAA\nbbb\nCCC"

      BufferProcess.undo(pid)
      assert BufferProcess.content(pid) == "aaa\nbbb\nccc"

      BufferProcess.redo(pid)
      assert BufferProcess.content(pid) == "AAA\nbbb\nCCC"
    end

    test "undo and redo restore the cursor after a batch edit" do
      pid = start_buffer("aaa\nbbb\nccc")
      BufferProcess.move_to(pid, {1, 1})

      edits = [
        {{0, 0}, {0, 2}, "AAA"},
        {{2, 0}, {2, 2}, "CCC"}
      ]

      BufferProcess.apply_edits(pid, edits)
      edited_cursor = BufferProcess.cursor(pid)

      BufferProcess.undo(pid)
      assert BufferProcess.cursor(pid) == {1, 1}

      BufferProcess.redo(pid)
      assert BufferProcess.cursor(pid) == edited_cursor
    end
  end

  describe "property-based undo round trips" do
    property "undoing random insert and delete edits restores the original content" do
      check all(
              original <- StreamData.string(:alphanumeric, min_length: 0, max_length: 40),
              ops <- StreamData.list_of(random_op_generator(), min_length: 50, max_length: 100),
              max_runs: 50
            ) do
        pid = start_buffer(original)

        Enum.each(ops, &apply_random_op(pid, &1))
        Enum.each(ops, fn _ -> BufferProcess.undo(pid) end)

        assert BufferProcess.content(pid) == original
      end
    end

    property "undo then redo returns to the edited content" do
      check all(
              original <- StreamData.string(:alphanumeric, min_length: 0, max_length: 40),
              ops <- StreamData.list_of(random_op_generator(), min_length: 50, max_length: 100),
              max_runs: 50
            ) do
        pid = start_buffer(original)

        Enum.each(ops, &apply_random_op(pid, &1))
        edited = BufferProcess.content(pid)
        Enum.each(ops, fn _ -> BufferProcess.undo(pid) end)
        Enum.each(ops, fn _ -> BufferProcess.redo(pid) end)

        assert BufferProcess.content(pid) == edited
      end
    end
  end
end
