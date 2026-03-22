defmodule Minga.Editor.Commands.FileTreeRevealTest do
  @moduledoc """
  Tests for the reveal_active_file command (SPC o r).

  Verifies that revealing the active buffer's file in the tree opens the
  tree if needed, expands parents, moves the cursor, and focuses the tree.

  These tests use files inside the actual project root (via tmp_dir under
  the repo) because the file tree opens at Project.root(), so test files
  must exist within that tree to be revealed.
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.FileTree

  @moduletag :tmp_dir

  describe "reveal active file (SPC o r)" do
    test "opens tree and reveals file when tree is closed", %{tmp_dir: dir} do
      file = Path.join(dir, "reveal_test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file)

      # Tree starts closed
      state = :sys.get_state(ctx.editor)
      assert state.file_tree.tree == nil

      # Reveal active file
      state = send_keys_sync(ctx, "<SPC>or")

      # Tree should be open and focused
      assert state.file_tree.tree != nil
      assert state.file_tree.focused == true
      assert state.keymap_scope == :file_tree

      # Cursor should be on the file
      selected = FileTree.selected_entry(state.file_tree.tree)
      assert selected != nil
      assert selected.name == "reveal_test.txt"
    end

    test "moves cursor to file when tree is already open", %{tmp_dir: dir} do
      file = Path.join(dir, "reveal_open_tree.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file)

      # Open the tree first
      _state = send_keys_sync(ctx, "<SPC>op")

      # Move cursor to top (away from the file)
      state = send_keys_sync(ctx, "gg")
      top_entry = FileTree.selected_entry(state.file_tree.tree)
      assert top_entry.name != "reveal_open_tree.txt"

      # Reveal without closing: this exercises the ensure_tree_open pass-through
      state = send_keys_sync(ctx, "<SPC>or")

      selected = FileTree.selected_entry(state.file_tree.tree)
      assert selected.name == "reveal_open_tree.txt"
      assert state.file_tree.focused == true
    end

    test "reopens closed tree and re-reveals file", %{tmp_dir: dir} do
      file = Path.join(dir, "reveal_test2.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file)

      # Open the tree and reveal the file
      state = send_keys_sync(ctx, "<SPC>or")
      assert state.file_tree.tree != nil

      # Close tree, then reveal again to reopen and re-reveal
      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "<SPC>or")

      # Tree should be open and focused after re-reveal
      assert state.file_tree.tree != nil
      assert state.file_tree.focused == true
      assert state.keymap_scope == :file_tree

      # The file should be visible in the tree and the cursor should
      # be on it. The tree root is Project.root() which may differ
      # between local and CI, so verify via visible_entries lookup.
      entries = FileTree.visible_entries(state.file_tree.tree)
      expanded_path = Path.expand(file)
      file_entry = Enum.find(entries, fn e -> e.path == expanded_path end)
      assert file_entry != nil, "reveal_test2.txt should be visible in the tree"

      assert state.file_tree.tree.cursor ==
               Enum.find_index(entries, fn e -> e.path == expanded_path end)
    end

    test "no-op when active buffer has no file path", %{tmp_dir: _dir} do
      # Buffer with content but no file_path
      ctx = start_editor("scratch content")

      # Reveal should be a no-op (tree stays closed)
      _state = send_keys_sync(ctx, "<SPC>or")
      state = :sys.get_state(ctx.editor)

      # Tree should not have opened
      assert state.file_tree.tree == nil
    end
  end
end
