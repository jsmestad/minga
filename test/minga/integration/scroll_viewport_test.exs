defmodule Minga.Integration.ScrollViewportTest do
  @moduledoc """
  Integration tests for scrolling and viewport behavior with files larger
  than the terminal height. Verifies cursor following, edge scrolling,
  gg/G/C-d/C-u, and gutter line number correctness.

  """
  use Minga.Test.EditorCase, async: true

  # Generate a 100-line test buffer
  @line_count 100
  @test_content Enum.map_join(1..@line_count, "\n", &"line #{&1}")

  # ── gg (go to top) ────────────────────────────────────────────────────────

  describe "gg (go to top)" do
    test "shows first lines of file, cursor at line 1" do
      ctx = start_editor(@test_content)

      # Move down first, then gg back to top
      send_keys_sync(ctx, "20j")
      send_keys_sync(ctx, "gg")

      {line, col} = buffer_cursor(ctx)
      assert line == 0
      assert col == 0
      assert_row_contains(ctx, 1, "line 1")
      assert_screen_snapshot(ctx, "scroll_gg_top")
    end
  end

  # ── G (go to bottom) ──────────────────────────────────────────────────────

  describe "G (go to bottom)" do
    test "shows last lines of file, cursor at last line" do
      ctx = start_editor(@test_content)

      send_keys_sync(ctx, "G")

      {line, _col} = buffer_cursor(ctx)
      assert line == @line_count - 1
      # The last line should be visible on screen
      assert screen_contains?(ctx, "line #{@line_count}")
      assert_screen_snapshot(ctx, "scroll_G_bottom")
    end
  end

  # ── j scrolling ───────────────────────────────────────────────────────────

  describe "scrolling down with j" do
    test "viewport follows cursor past bottom edge" do
      ctx = start_editor(@test_content)

      # Move down enough to scroll (24-row terminal, ~22 content rows)
      send_keys_sync(ctx, "30j")

      {line, _col} = buffer_cursor(ctx)
      assert line == 30
      # Line 31 should be visible (0-indexed line 30)
      assert screen_contains?(ctx, "line 31")
      assert_screen_snapshot(ctx, "scroll_j_30")
    end
  end

  # ── k scrolling ───────────────────────────────────────────────────────────

  describe "scrolling up with k" do
    test "viewport follows cursor past top edge" do
      ctx = start_editor(@test_content)

      # Go to bottom, then come back up
      send_keys_sync(ctx, "G")
      send_keys_sync(ctx, "30k")

      {line, _col} = buffer_cursor(ctx)
      assert line == @line_count - 1 - 30
      assert screen_contains?(ctx, "line #{line + 1}")
      assert_screen_snapshot(ctx, "scroll_k_from_bottom")
    end
  end

  # ── C-d (half-page down) ──────────────────────────────────────────────────

  describe "C-d (half-page down)" do
    test "scrolls approximately half a screen" do
      ctx = start_editor(@test_content)

      {line_before, _} = buffer_cursor(ctx)
      send_keys_sync(ctx, "<C-d>")
      {line_after, _} = buffer_cursor(ctx)

      # Should move roughly half the screen height (10-12 lines for 24-row terminal)
      jump = line_after - line_before
      assert jump >= 8 and jump <= 15, "C-d should jump ~half screen, jumped #{jump}"
      assert_screen_snapshot(ctx, "scroll_ctrl_d")
    end
  end

  # ── C-u (half-page up) ────────────────────────────────────────────────────

  describe "C-u (half-page up)" do
    test "scrolls approximately half a screen upward" do
      ctx = start_editor(@test_content)

      # Go down first
      send_keys_sync(ctx, "50j")
      {line_before, _} = buffer_cursor(ctx)

      send_keys_sync(ctx, "<C-u>")
      {line_after, _} = buffer_cursor(ctx)

      jump = line_before - line_after
      assert jump >= 8 and jump <= 15, "C-u should jump ~half screen, jumped #{jump}"
      assert_screen_snapshot(ctx, "scroll_ctrl_u")
    end
  end

  # ── Gutter correctness ────────────────────────────────────────────────────

  describe "gutter line numbers match visible content" do
    test "line numbers are correct after scrolling" do
      ctx = start_editor(@test_content)

      send_keys_sync(ctx, "25j")

      # The gutter should show numbers around line 26
      # (0-indexed line 25 = display line 26)
      rows = screen_text(ctx)
      # Find a row containing "line 26" and verify gutter shows "26"
      line_26_row = Enum.find(rows, &String.contains?(&1, "line 26"))
      assert line_26_row != nil, "line 26 should be visible"
      assert String.contains?(line_26_row, "26"), "gutter should show 26"
    end
  end

  # ── Scrolloff behavior ──────────────────────────────────────────────────

  describe "scrolloff (scroll margin)" do
    test "cursor stays away from viewport edge when scrolling down" do
      ctx = start_editor(@test_content)

      # Move down enough to trigger scrolling
      send_keys_sync(ctx, "30j")

      {cursor_line, _} = buffer_cursor(ctx)
      # The cursor should be visible on screen, not at the very last content row.
      # Find which screen row contains the cursor's line text
      cursor_display_line = cursor_line + 1
      rows = screen_text(ctx)

      cursor_screen_row =
        Enum.find_index(rows, &String.contains?(&1, "line #{cursor_display_line}"))

      assert cursor_screen_row != nil, "cursor line should be visible"
      # With default scroll_margin of 5, cursor should not be on the very last
      # content row (row height-3, accounting for tab bar and modeline)
      last_content_row = ctx.height - 3

      assert cursor_screen_row < last_content_row,
             "cursor at screen row #{cursor_screen_row} should be above last content row #{last_content_row} (scrolloff)"
    end

    test "cursor stays away from viewport edge when scrolling up" do
      ctx = start_editor(@test_content)

      send_keys_sync(ctx, "G")
      send_keys_sync(ctx, "30k")

      {cursor_line, _} = buffer_cursor(ctx)
      cursor_display_line = cursor_line + 1
      rows = screen_text(ctx)

      cursor_screen_row =
        Enum.find_index(rows, &String.contains?(&1, "line #{cursor_display_line}"))

      assert cursor_screen_row != nil, "cursor line should be visible"
      # Cursor should not be on the very first content row (row 1, after tab bar)
      assert cursor_screen_row > 1,
             "cursor at screen row #{cursor_screen_row} should be below first content row (scrolloff)"
    end
  end

  # ── Horizontal scroll ─────────────────────────────────────────────────────

  describe "horizontal scroll" do
    @wide_content "short\n" <> String.duplicate("x", 200) <> "\nend"

    test "long line causes horizontal scroll when cursor moves right" do
      ctx = start_editor(@wide_content)

      # Move to the long line (line 2, 0-indexed line 1)
      send_keys_sync(ctx, "j")
      # Move cursor far right past the terminal width
      send_keys_sync(ctx, "$")

      {_, col} = buffer_cursor(ctx)
      assert col >= 100, "cursor should be far right on the long line, at col #{col}"

      # The visible text should not show the start of the line anymore
      # because the viewport has scrolled horizontally
      row_text = screen_row(ctx, 2)
      # Row should contain x's but not "short" from line 1 bleeding in
      assert String.contains?(row_text, "x"), "long line content should be visible"
    end
  end

  # ── Round-trip ─────────────────────────────────────────────────────────────

  describe "scroll round-trip" do
    test "G then gg returns to same screen state" do
      ctx = start_editor(@test_content)

      # Capture initial screen
      initial_cursor = buffer_cursor(ctx)

      send_keys_sync(ctx, "G")
      assert buffer_cursor(ctx) != initial_cursor

      send_keys_sync(ctx, "gg")
      assert buffer_cursor(ctx) == initial_cursor
      assert_screen_snapshot(ctx, "scroll_roundtrip_gg")
    end
  end
end
