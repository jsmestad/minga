defmodule Minga.Keymap.Scope.FileTreeScopeTest do
  @moduledoc """
  Trie-level unit tests for file tree keymap scope.

  Verifies the new a/A/R bindings for inline editing, and regression
  checks that existing bindings (Enter, q, h, l, etc.) still work.
  """
  use ExUnit.Case, async: true

  alias Minga.Keymap.Scope

  @enter 13
  @escape 27
  @tab 9

  describe "normal mode: file operation bindings" do
    test "a resolves to tree_new_file" do
      assert {:command, :tree_new_file} = Scope.resolve_key(:file_tree, :normal, {?a, 0})
    end

    test "A resolves to tree_new_folder" do
      assert {:command, :tree_new_folder} = Scope.resolve_key(:file_tree, :normal, {?A, 0})
    end

    test "R resolves to tree_rename" do
      assert {:command, :tree_rename} = Scope.resolve_key(:file_tree, :normal, {?R, 0})
    end
  end

  describe "CUA mode: file operation bindings not present" do
    test "a is not bound in CUA mode" do
      assert :not_found = Scope.resolve_key(:file_tree, :cua, {?a, 0})
    end

    test "A is not bound in CUA mode" do
      assert :not_found = Scope.resolve_key(:file_tree, :cua, {?A, 0})
    end

    test "R is not bound in CUA mode" do
      assert :not_found = Scope.resolve_key(:file_tree, :cua, {?R, 0})
    end
  end

  describe "normal mode: existing bindings still work (regression)" do
    test "Enter opens file or toggles directory" do
      assert {:command, :tree_open_or_toggle} =
               Scope.resolve_key(:file_tree, :normal, {@enter, 0})
    end

    test "q closes file tree" do
      assert {:command, :tree_close} = Scope.resolve_key(:file_tree, :normal, {?q, 0})
    end

    test "Escape closes file tree" do
      assert {:command, :tree_close} = Scope.resolve_key(:file_tree, :normal, {@escape, 0})
    end

    test "Tab toggles directory" do
      assert {:command, :tree_toggle_directory} =
               Scope.resolve_key(:file_tree, :normal, {@tab, 0})
    end

    test "l expands directory" do
      assert {:command, :tree_expand} = Scope.resolve_key(:file_tree, :normal, {?l, 0})
    end

    test "h collapses directory" do
      assert {:command, :tree_collapse} = Scope.resolve_key(:file_tree, :normal, {?h, 0})
    end

    test "H toggles hidden files" do
      assert {:command, :tree_toggle_hidden} = Scope.resolve_key(:file_tree, :normal, {?H, 0})
    end

    test "r refreshes tree" do
      assert {:command, :tree_refresh} = Scope.resolve_key(:file_tree, :normal, {?r, 0})
    end
  end

  describe "help_groups includes File Operations" do
    test "File Operations group contains a, A, R bindings" do
      groups = Minga.Keymap.Scope.FileTree.help_groups(:default)

      {_name, bindings} =
        Enum.find(groups, fn {name, _} -> name == "File Operations" end)

      assert Enum.any?(bindings, fn {key, _desc} -> key == "a" end)
      assert Enum.any?(bindings, fn {key, _desc} -> key == "A" end)
      assert Enum.any?(bindings, fn {key, _desc} -> key == "R" end)
    end
  end
end
