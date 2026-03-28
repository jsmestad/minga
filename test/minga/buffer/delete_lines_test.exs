defmodule Minga.Buffer.DeleteLinesTest do
  @moduledoc """
  Buffer-level tests for line deletion (dd equivalent).
  Migrated from integration_test.exs to test at the correct layer.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server

  defp start_buffer(content) do
    start_supervised!({Server, content: content})
  end

  describe "delete_lines/3 (dd equivalent)" do
    test "deletes the first line" do
      pid = start_buffer("hello\nworld\nfoo")
      Server.delete_lines(pid, 0, 0)

      content = Server.content(pid)
      refute String.contains?(content, "hello")
      assert String.contains?(content, "world")
    end

    test "on a single-line buffer leaves it empty" do
      pid = start_buffer("only line")
      Server.delete_lines(pid, 0, 0)

      refute String.contains?(Server.content(pid), "only")
    end

    test "deletes a middle line" do
      pid = start_buffer("aaa\nbbb\nccc")
      Server.delete_lines(pid, 1, 1)

      content = Server.content(pid)
      assert String.contains?(content, "aaa")
      refute String.contains?(content, "bbb")
      assert String.contains?(content, "ccc")
    end
  end
end
