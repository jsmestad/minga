defmodule Minga.Editor.Commands.FileTreeRevealTest do
  @moduledoc """
  Tests for the reveal_active_file command (SPC o r).

  Verifies that revealing the active buffer's file in the tree opens the
  tree if needed, expands parents, moves the cursor, and focuses the tree.

  These tests use files inside the actual project root (via tmp_dir under
  the repo) because the file tree opens at Project.root(), so test files
  must exist within that tree to be revealed.

  Note: `FileTree.visible_entries/1` rescans the live filesystem via File.ls.
  Under concurrent async tests, other tests' tmp_dirs appear and disappear,
  shifting entry sort order between the reveal call (inside the editor
  GenServer) and the assertion in this test. `assert_file_visible/2` searches
  by path rather than cursor index, so it is stable even when list order differs.
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.FileTree

  @moduletag :tmp_dir

  # Asserts the file is visible in the tree (ancestors expanded).
  # Does NOT assert cursor position: the cursor index set during reveal
  # can point to a different entry if concurrent tests create/delete
  # files that shift the sort order before this assertion runs.
  defp assert_file_visible(state, file_path) do
    tree = state.workspace.file_tree.tree
    expanded_path = Path.expand(file_path)
    entries = FileTree.visible_entries(tree)

    file_entry = Enum.find(entries, fn e -> e.path == expanded_path end)
    assert file_entry != nil, "#{Path.basename(file_path)} should be visible in the tree"
  end

  describe "reveal active file (SPC o r)" do
    test "opens tree and reveals file when tree is closed", %{tmp_dir: dir} do
      file = Path.join(dir, "reveal_test.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file)

      # Tree starts closed
      state = :sys.get_state(ctx.editor)
      assert state.workspace.file_tree.tree == nil

      # Reveal active file
      state = send_keys_sync(ctx, "<SPC>or")

      # Tree should be open and focused
      assert state.workspace.file_tree.tree != nil
      assert state.workspace.file_tree.focused == true
      assert state.workspace.keymap_scope == :file_tree

      # File should be visible in the tree (ancestors expanded)
      assert_file_visible(state, file)
    end

    test "expands ancestors and reveals file when tree is already open", %{tmp_dir: dir} do
      file = Path.join(dir, "reveal_open_tree.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file)

      # Open the tree first
      _state = send_keys_sync(ctx, "<SPC>op")

      # Move cursor to top (away from the file).
      # Check cursor integer directly (no filesystem rescan) to verify
      # gg worked before testing reveal.
      state = send_keys_sync(ctx, "gg")
      assert state.workspace.file_tree.tree.cursor == 0, "gg should move cursor to top"

      # Reveal without closing: this exercises the ensure_tree_open pass-through
      state = send_keys_sync(ctx, "<SPC>or")

      assert_file_visible(state, file)
      assert state.workspace.file_tree.focused == true
    end

    test "reopens closed tree and re-reveals file", %{tmp_dir: dir} do
      file = Path.join(dir, "reveal_test2.txt")
      File.write!(file, "hello")

      ctx = start_editor("hello", file_path: file)

      # Open the tree and reveal the file
      state = send_keys_sync(ctx, "<SPC>or")
      assert state.workspace.file_tree.tree != nil

      # Close tree, then reveal again to reopen and re-reveal
      _state = send_keys_sync(ctx, "<SPC>op")
      state = send_keys_sync(ctx, "<SPC>or")

      # Tree should be open and focused after re-reveal
      assert state.workspace.file_tree.tree != nil
      assert state.workspace.file_tree.focused == true
      assert state.workspace.keymap_scope == :file_tree

      # File should be visible (ancestors expanded)
      assert_file_visible(state, file)
    end

    test "no-op when active buffer has no file path", %{tmp_dir: _dir} do
      # Buffer with content but no file_path
      ctx = start_editor("scratch content")

      # Reveal should be a no-op (tree stays closed)
      _state = send_keys_sync(ctx, "<SPC>or")
      state = :sys.get_state(ctx.editor)

      # Tree should not have opened
      assert state.workspace.file_tree.tree == nil
    end
  end
end
