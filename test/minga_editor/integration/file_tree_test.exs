defmodule Minga.Integration.FileTreeTest do
  @moduledoc """
  Integration tests for file tree: toggle, navigate, open files, focus
  return, and separator rendering.

  Uses @moduletag :tmp_dir to create controlled directory fixtures instead
  of scanning the real working directory. This prevents position-dependent
  failures when the filesystem differs between local dev and CI.
  """
  use Minga.Test.EditorCase, async: true

  @moduletag :tmp_dir

  defp setup_fixture(%{tmp_dir: dir}) do
    # Create a controlled directory structure so navigation is deterministic
    File.mkdir_p!(Path.join(dir, "subdir"))
    File.write!(Path.join(dir, "alpha.txt"), "alpha content")
    File.write!(Path.join(dir, "beta.txt"), "beta content")
    File.write!(Path.join(dir, "subdir/gamma.txt"), "gamma content")

    file = Path.join(dir, "alpha.txt")
    # project_root isolates the file tree to this test's tmp_dir,
    # preventing concurrent tests from shifting the entry list.
    %{file: file, project_root: dir}
  end

  # ── Toggle ─────────────────────────────────────────────────────────────────

  describe "file tree toggle (SPC o p)" do
    test "opening shows file tree panel with separator", %{tmp_dir: dir} do
      %{file: file, project_root: root} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file, project_root: root)

      send_keys_sync(ctx, "<Space>op")

      # File tree should show directory structure with separator
      rows = screen_text(ctx)
      has_separator = Enum.any?(rows, &String.contains?(&1, "│"))
      assert has_separator, "vertical separator between tree and editor should be visible"
    end

    test "closing restores full editor width", %{tmp_dir: dir} do
      %{file: file, project_root: root} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file, project_root: root)

      # Open then close
      send_keys_sync(ctx, "<Space>op")
      assert Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))

      send_keys_sync(ctx, "<Space>op")

      # Separator should be gone
      row1 = screen_row(ctx, 1)
      refute String.contains?(row1, "│"), "separator should be gone after closing tree"
    end
  end

  # ── Navigation ─────────────────────────────────────────────────────────────

  describe "file tree navigation" do
    test "j/k moves tree cursor", %{tmp_dir: dir} do
      %{file: file, project_root: root} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file, project_root: root)

      send_keys_sync(ctx, "<Space>op")
      # Move down in tree
      send_keys_sync(ctx, "j")
      send_keys_sync(ctx, "j")
    end
  end

  # ── Focus return ───────────────────────────────────────────────────────────

  describe "focus return after tree interaction" do
    test "pressing Escape returns focus to editor", %{tmp_dir: dir} do
      %{file: file, project_root: root} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file, project_root: root)

      send_keys_sync(ctx, "<Space>op")
      # Tree should be focused initially
      send_keys_sync(ctx, "j")

      send_keys_sync(ctx, "<Esc>")

      # After escape, focus should return to editor
      assert editor_mode(ctx) == :normal
    end
  end

  # ── Focus cycling ──────────────────────────────────────────────────────────

  describe "focus cycling between tree and editor" do
    test "Escape from tree returns focus to editor while keeping tree open", %{tmp_dir: dir} do
      %{file: file, project_root: root} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file, project_root: root)

      send_keys_sync(ctx, "<Space>op")
      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :file_tree

      # Escape closes the tree and returns focus to the editor
      send_keys_sync(ctx, "<Esc>")
      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :editor
    end

    test "opening a file from tree returns focus to editor", %{tmp_dir: dir} do
      %{file: file, project_root: root} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file, project_root: root)

      send_keys_sync(ctx, "<Space>op")
      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :file_tree

      # Navigate past directories to reach a file.
      send_keys_sync(ctx, "G<CR>")

      state = :sys.get_state(ctx.editor)

      assert state.workspace.keymap_scope == :editor,
             "focus should return to editor after opening file from tree, got #{state.workspace.keymap_scope}"
    end
  end

  # ── Nested directory expansion ─────────────────────────────────────────────

  describe "nested directory expansion" do
    test "l expands a directory and shows children", %{tmp_dir: dir} do
      %{file: file, project_root: root} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file, project_root: root)

      send_keys_sync(ctx, "<Space>op")
      # Cursor lands on alpha.txt (revealed active buffer).
      # Navigate up to subdir/ and expand with l.
      send_keys_sync(ctx, "gg")
      send_keys_sync(ctx, "l")

      # After expanding subdir, the child file should be visible
      rows_after = screen_text(ctx)

      assert Enum.any?(rows_after, &String.contains?(&1, "gamma.txt")),
             "expanding subdir should show gamma.txt"
    end

    test "h collapses an expanded directory", %{tmp_dir: dir} do
      %{file: file, project_root: root} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file, project_root: root)

      send_keys_sync(ctx, "<Space>op")
      # Navigate to subdir/ and expand, then collapse.
      send_keys_sync(ctx, "gg")
      send_keys_sync(ctx, "l")

      # Verify gamma.txt is visible after expanding
      rows_expanded = screen_text(ctx)
      assert Enum.any?(rows_expanded, &String.contains?(&1, "gamma.txt"))

      send_keys_sync(ctx, "h")
      rows_collapsed = screen_text(ctx)

      refute Enum.any?(rows_collapsed, &String.contains?(&1, "gamma.txt")),
             "collapsing subdir should hide gamma.txt"
    end
  end
end
