defmodule Minga.Buffer.InsertOperationsTest do
  @moduledoc """
  Buffer-level tests for insert-mode operations (insert_char, delete_before,
  newline insertion, append position). Migrated from integration_test.exs to
  test at the correct layer.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content})
  end

  describe "insert_char" do
    test "inserts characters at cursor position" do
      pid = start_buffer("hello")
      BufferProcess.insert_char(pid, "a")
      BufferProcess.insert_char(pid, "b")
      BufferProcess.insert_char(pid, "c")

      assert BufferProcess.content(pid) == "abchello"
    end

    test "inserts after moving right (append equivalent)" do
      pid = start_buffer("hi")
      # Move right one position (simulates 'a' entering insert after cursor)
      BufferProcess.move(pid, :right)
      BufferProcess.insert_char(pid, "!")

      assert String.contains?(BufferProcess.content(pid), "!")
    end
  end

  describe "delete_before (backspace)" do
    test "deletes the previous character" do
      pid = start_buffer("hello")
      BufferProcess.insert_char(pid, "a")
      BufferProcess.delete_before(pid)

      assert BufferProcess.content(pid) == "hello"
    end

    test "is a no-op at start of buffer" do
      pid = start_buffer("hello")
      BufferProcess.delete_before(pid)

      assert BufferProcess.content(pid) == "hello"
    end
  end

  describe "newline insertion" do
    test "insert_char with newline splits the line" do
      pid = start_buffer("hello")
      BufferProcess.insert_char(pid, "\n")

      assert String.contains?(BufferProcess.content(pid), "\n")
    end
  end
end
