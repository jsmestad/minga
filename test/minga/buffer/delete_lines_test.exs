defmodule Minga.Buffer.DeleteLinesTest do
  @moduledoc """
  Buffer-level tests for line deletion (dd equivalent).
  Migrated from integration_test.exs to test at the correct layer.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content})
  end

  describe "delete_lines/3 (dd equivalent)" do
    test "deletes the first line" do
      pid = start_buffer("hello\nworld\nfoo")
      BufferProcess.delete_lines(pid, 0, 0)

      content = BufferProcess.content(pid)
      refute String.contains?(content, "hello")
      assert String.contains?(content, "world")
    end

    test "on a single-line buffer leaves it empty" do
      pid = start_buffer("only line")
      BufferProcess.delete_lines(pid, 0, 0)

      refute String.contains?(BufferProcess.content(pid), "only")
    end

    test "deletes a middle line" do
      pid = start_buffer("aaa\nbbb\nccc")
      BufferProcess.delete_lines(pid, 1, 1)

      content = BufferProcess.content(pid)
      assert String.contains?(content, "aaa")
      refute String.contains?(content, "bbb")
      assert String.contains?(content, "ccc")
    end
  end
end
