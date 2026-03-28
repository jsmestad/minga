defmodule Minga.Editing.TextObject.StructuralTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.TextObject

  describe "structural_inner/1" do
    test "returns nil when tree_data is nil" do
      assert TextObject.structural_inner(nil) == nil
    end

    test "converts tree-sitter range to inclusive Vim range" do
      # Tree-sitter returns exclusive end: row 3, col 5 means "up to but not including col 5"
      tree_data = {1, 4, 3, 5}
      assert TextObject.structural_inner(tree_data) == {{1, 4}, {3, 4}}
    end

    test "adjusts end position at column 0 to previous line" do
      # End at col 0 of row 3 means the range ends at the end of row 2
      tree_data = {0, 0, 3, 0}
      assert TextObject.structural_inner(tree_data) == {{0, 0}, {2, 0}}
    end

    test "handles zero-width range at origin" do
      tree_data = {0, 0, 0, 0}
      assert TextObject.structural_inner(tree_data) == {{0, 0}, {0, 0}}
    end
  end

  describe "structural_around/1" do
    test "returns nil when tree_data is nil" do
      assert TextObject.structural_around(nil) == nil
    end

    test "converts tree-sitter range to inclusive Vim range" do
      tree_data = {0, 0, 5, 10}
      assert TextObject.structural_around(tree_data) == {{0, 0}, {5, 9}}
    end
  end

  describe "adjust_end_position edge cases" do
    test "single-character range" do
      tree_data = {2, 3, 2, 4}
      assert TextObject.structural_inner(tree_data) == {{2, 3}, {2, 3}}
    end

    test "multi-line range ending at line start" do
      tree_data = {10, 2, 15, 0}
      assert TextObject.structural_inner(tree_data) == {{10, 2}, {14, 0}}
    end
  end
end
