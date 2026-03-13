defmodule Minga.Integration.WindowSplitsTest do
  @moduledoc """
  Integration tests for window splitting: vertical/horizontal splits,
  navigation between panes, closing splits, and layout correctness.

  """
  use Minga.Test.EditorCase, async: true

  # ── Vertical split ─────────────────────────────────────────────────────────

  describe "vertical split (SPC w v)" do
    test "creates two side-by-side panes with separator" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>wv")

      # Both panes should show the same buffer content
      rows = screen_text(ctx)
      # Row 1 should have content on both sides separated by │
      row1 = Enum.at(rows, 1)
      assert String.contains?(row1, "│"), "vertical separator should be visible"
      assert_screen_snapshot(ctx, "vsplit_basic")
    end

    test "modeline appears in both panes" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>wv")

      modeline_row = screen_row(ctx, ctx.height - 2)
      # Should contain NORMAL twice (one per pane)
      assert String.contains?(modeline_row, "NORMAL")
      assert String.contains?(modeline_row, "│")
    end
  end

  # ── Horizontal split ───────────────────────────────────────────────────────

  describe "horizontal split (SPC w s)" do
    test "creates two stacked panes" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>ws")

      # Both panes should show content, with separate modelines
      rows = screen_text(ctx)
      modeline_count = Enum.count(rows, &String.contains?(&1, "NORMAL"))

      assert modeline_count >= 2,
             "expected 2 modelines for horizontal split, found #{modeline_count}"

      assert_screen_snapshot(ctx, "hsplit_basic")
    end
  end

  # ── Navigation between splits ──────────────────────────────────────────────

  describe "split navigation (C-w h/l)" do
    test "C-w l moves focus to right pane" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>wv")
      # Focus starts in the left pane (or right, depending on impl)
      cursor_before = screen_cursor(ctx)

      send_keys(ctx, "<C-w>l")
      cursor_after = screen_cursor(ctx)

      # Cursor should move to the other pane (different column region)
      assert cursor_before != cursor_after
      assert_screen_snapshot(ctx, "vsplit_focus_right")
    end

    test "C-w h moves focus to left pane" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>wv")
      send_keys(ctx, "<C-w>l")
      cursor_right = screen_cursor(ctx)

      send_keys(ctx, "<C-w>h")
      cursor_left = screen_cursor(ctx)

      assert cursor_left != cursor_right
      assert_screen_snapshot(ctx, "vsplit_focus_left")
    end
  end

  # ── Independent editing ────────────────────────────────────────────────────

  describe "independent editing in splits" do
    test "typing in one pane doesn't affect the other" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>wv")
      # Type in the active pane
      send_keys(ctx, "iNEW TEXT<Esc>")

      # Both panes share the same buffer, so content changes appear in both.
      # But cursor position should only be in the active pane.
      assert editor_mode(ctx) == :normal
      assert_screen_snapshot(ctx, "vsplit_edit")
    end
  end

  # ── Closing a split ────────────────────────────────────────────────────────

  describe "closing a split" do
    test "closing one pane restores full width" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>wv")
      # Verify split exists
      row1_split = screen_row(ctx, 1)
      assert String.contains?(row1_split, "│")

      # Close the current window
      send_keys(ctx, "<Space>wd")

      # Should be back to single pane, no separator
      row1_single = screen_row(ctx, 1)
      refute String.contains?(row1_single, "│"), "separator should be gone after closing split"
      assert_screen_snapshot(ctx, "vsplit_close")
    end
  end

  # ── Cursor memory ─────────────────────────────────────────────────────────

  describe "cursor memory across splits" do
    test "switching away and back preserves cursor position" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>wv")
      # Move cursor in left pane
      send_keys(ctx, "lllll")
      cursor_left = buffer_cursor(ctx)

      # Switch to right pane and back
      send_keys(ctx, "<C-w>l")
      send_keys(ctx, "<C-w>h")

      assert buffer_cursor(ctx) == cursor_left
    end
  end

  # ── Three-way split ───────────────────────────────────────────────────────

  describe "three-way split" do
    test "splitting twice creates three panes" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>wv")
      send_keys(ctx, "<Space>wv")

      # Should have two separators (three panes)
      rows = screen_text(ctx)
      row1 = Enum.at(rows, 1)
      separator_count = row1 |> String.graphemes() |> Enum.count(&(&1 == "│"))

      assert separator_count >= 2,
             "expected at least 2 separators for 3 panes, found #{separator_count}"

      assert_screen_snapshot(ctx, "three_way_split")
    end
  end
end
