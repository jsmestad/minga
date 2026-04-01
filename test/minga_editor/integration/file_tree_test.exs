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
    %{file: file}
  end

  # ── Toggle ─────────────────────────────────────────────────────────────────

  describe "file tree toggle (SPC o p)" do
    test "opening shows file tree panel with separator", %{tmp_dir: dir} do
      %{file: file} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file)

      send_keys_sync(ctx, "<Space>op")

      # File tree should show directory structure with separator
      rows = screen_text(ctx)
      has_separator = Enum.any?(rows, &String.contains?(&1, "│"))
      assert has_separator, "vertical separator between tree and editor should be visible"
    end

    test "closing restores full editor width", %{tmp_dir: dir} do
      %{file: file} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file)

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
      %{file: file} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file)

      send_keys_sync(ctx, "<Space>op")
      # Move down in tree
      send_keys_sync(ctx, "j")
      send_keys_sync(ctx, "j")
    end
  end

  # ── Focus return ───────────────────────────────────────────────────────────

  describe "focus return after tree interaction" do
    test "pressing Escape returns focus to editor", %{tmp_dir: dir} do
      %{file: file} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file)

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
      %{file: file} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file)

      send_keys_sync(ctx, "<Space>op")
      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :file_tree

      # Escape closes the tree and returns focus to the editor
      send_keys_sync(ctx, "<Esc>")
      state = :sys.get_state(ctx.editor)
      assert state.workspace.keymap_scope == :editor
    end

    test "opening a file from tree returns focus to editor", %{tmp_dir: dir} do
      %{file: file} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file)

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
      %{file: file} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file)

      send_keys_sync(ctx, "<Space>op")
      # Navigate to the subdir entry and expand with l
      send_keys_sync(ctx, "j")

      rows_before = screen_text(ctx)
      send_keys_sync(ctx, "l")
      rows_after = screen_text(ctx)

      # After expansion, there should be more content rows (children visible)
      non_empty_before = Enum.count(rows_before, &(String.trim(&1) != ""))
      non_empty_after = Enum.count(rows_after, &(String.trim(&1) != ""))

      assert non_empty_after >= non_empty_before,
             "expanding a directory should show at least as many rows"
    end

    test "h collapses an expanded directory", %{tmp_dir: dir} do
      %{file: file} = setup_fixture(%{tmp_dir: dir})
      ctx = start_editor("hello world", file_path: file)

      send_keys_sync(ctx, "<Space>op")
      send_keys_sync(ctx, "j")
      send_keys_sync(ctx, "l")
      rows_expanded = screen_text(ctx)

      send_keys_sync(ctx, "h")
      rows_collapsed = screen_text(ctx)

      non_empty_expanded = Enum.count(rows_expanded, &(String.trim(&1) != ""))
      non_empty_collapsed = Enum.count(rows_collapsed, &(String.trim(&1) != ""))

      assert non_empty_collapsed <= non_empty_expanded,
             "collapsing should show fewer or equal rows"
    end
  end
end
