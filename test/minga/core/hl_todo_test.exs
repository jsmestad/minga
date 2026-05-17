defmodule Minga.Core.HlTodoTest do
  use ExUnit.Case, async: true

  alias Minga.Core.HlTodo

  describe "scan_line/1" do
    test "matches supported keywords after comment delimiters" do
      assert HlTodo.scan_line("# TODO write test") == [{2, 6, :todo}]
      assert HlTodo.scan_line("// FIXME broken") == [{3, 8, :fixme}]
      assert HlTodo.scan_line("/* NOTE explain") == [{3, 7, :note}]
      assert HlTodo.scan_line("% HACK temporary") == [{2, 6, :hack}]
      assert HlTodo.scan_line("-- REVIEW this") == [{3, 9, :review}]
      assert HlTodo.scan_line("# DEPRECATED old") == [{2, 12, :deprecated}]
    end

    test "matches inline comments when the delimiter starts a comment token" do
      assert HlTodo.scan_line("value = 1 # TODO revisit") == [{12, 16, :todo}]
    end

    test "does not match keywords in regular code" do
      assert HlTodo.scan_line("TODO = :not_a_comment") == []
      assert HlTodo.scan_line("prefixTODO # nope") == []
      assert HlTodo.scan_line("value// TODO needs whitespace before delimiter") == []
    end

    test "returns keyword-only byte offsets" do
      line = "  # FIXME align"
      assert HlTodo.scan_line(line) == [{4, 9, :fixme}]
      assert binary_part(line, 4, 5) == "FIXME"
    end
  end
end
