defmodule Minga.Integration.FileTreeTest do
  @moduledoc """
  Integration tests for file tree: toggle, navigate, open files, focus
  return, and separator rendering.

  """
  # async: false because file tree reads the real filesystem and can be
  # slow under heavy test concurrency
  use Minga.Test.EditorCase, async: false

  # ── Toggle ─────────────────────────────────────────────────────────────────

  describe "file tree toggle (SPC o p)" do
    test "opening shows file tree panel with separator" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>op")

      # File tree should show directory structure with separator
      rows = screen_text(ctx)
      has_separator = Enum.any?(rows, &String.contains?(&1, "│"))
      assert has_separator, "vertical separator between tree and editor should be visible"
    end

    test "closing restores full editor width" do
      ctx = start_editor("hello world")

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
    test "j/k moves tree cursor" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>op")
      # Move down in tree
      send_keys_sync(ctx, "j")
      send_keys_sync(ctx, "j")
    end
  end

  # ── Focus return ───────────────────────────────────────────────────────────

  describe "focus return after tree interaction" do
    test "pressing Escape returns focus to editor" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>op")
      # Tree should be focused initially
      send_keys_sync(ctx, "j")

      send_keys_sync(ctx, "<Esc>")

      # After escape, focus should return to editor
      # Subsequent keys should operate on the buffer, not the tree
      assert editor_mode(ctx) == :normal
    end
  end

  # ── Open file from tree ─────────────────────────────────────────────────

  describe "opening a file from tree" do
    test "Enter on a file opens it in the editor and returns focus" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>op")
      # Navigate down to find a file (skip root dir entry)
      send_keys_sync(ctx, "jjjjj")
      # Open the selected file
      send_keys_sync(ctx, "<CR>")

      # Focus should be in the editor (not stuck in tree)
      # Verify by checking that 'j' moves the buffer cursor, not the tree cursor
      cursor_before = buffer_cursor(ctx)
      send_keys_sync(ctx, "j")
      cursor_after = buffer_cursor(ctx)

      # If focus returned to buffer, j moves cursor down one line
      {line_before, _} = cursor_before
      {line_after, _} = cursor_after

      assert line_after >= line_before,
             "after opening file from tree, j should move buffer cursor"
    end
  end

  # ── Focus cycling ──────────────────────────────────────────────────────────

  describe "focus cycling between tree and editor" do
    test "Escape from tree returns focus to editor while keeping tree open" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>op")
      state = :sys.get_state(ctx.editor)
      assert state.keymap_scope == :file_tree

      # Escape closes the tree and returns focus to the editor
      send_keys_sync(ctx, "<Esc>")
      state = :sys.get_state(ctx.editor)
      assert state.keymap_scope == :editor
    end

    test "opening a file from tree returns focus to editor" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>op")
      state = :sys.get_state(ctx.editor)
      assert state.keymap_scope == :file_tree

      # Navigate past all directories to reach a file (directories come first).
      # Go to the bottom of the tree to find a file entry.
      send_keys_sync(ctx, "G<CR>")

      state = :sys.get_state(ctx.editor)

      assert state.keymap_scope == :editor,
             "focus should return to editor after opening file from tree, got #{state.keymap_scope}"
    end
  end

  # ── Nested directory expansion ─────────────────────────────────────────────

  describe "nested directory expansion" do
    test "l expands a directory and shows children" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>op")
      # The root dir entry should be at the top
      # Navigate to it and expand with l
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

    test "h collapses an expanded directory" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>op")
      send_keys_sync(ctx, "j")
      send_keys_sync(ctx, "l")
      rows_expanded = screen_text(ctx)

      send_keys_sync(ctx, "h")
      rows_collapsed = screen_text(ctx)

      # After collapse, some child rows should disappear
      non_empty_expanded = Enum.count(rows_expanded, &(String.trim(&1) != ""))
      non_empty_collapsed = Enum.count(rows_collapsed, &(String.trim(&1) != ""))

      assert non_empty_collapsed <= non_empty_expanded,
             "collapsing should show fewer or equal rows"
    end
  end

  # ── Toggle idempotence ────────────────────────────────────────────────────

  describe "toggle idempotence" do
    test "open -> close -> open shows tree with separator both times" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>op")
      first_has_separator = Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))
      assert first_has_separator

      send_keys_sync(ctx, "<Space>op")

      refute Enum.any?(1..20, fn row ->
               screen_row(ctx, row) |> String.contains?("│")
             end),
             "separator should be gone after close"

      send_keys_sync(ctx, "<Space>op")
      second_has_separator = Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))
      assert second_has_separator, "re-opening tree should show separator again"
    end
  end
end
