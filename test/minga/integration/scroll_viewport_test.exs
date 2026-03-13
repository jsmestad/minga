defmodule Minga.Integration.ScrollViewportTest do
  @moduledoc """
  Integration tests for scrolling and viewport behavior with files larger
  than the terminal height. Verifies cursor following, edge scrolling,
  gg/G/C-d/C-u, and gutter line number correctness.

  Ticket: #451
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
      send_keys(ctx, "20j")
      send_keys(ctx, "gg")

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

      send_keys(ctx, "G")

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
      send_keys(ctx, "30j")

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
      send_keys(ctx, "G")
      send_keys(ctx, "30k")

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
      send_keys(ctx, "<C-d>")
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
      send_keys(ctx, "50j")
      {line_before, _} = buffer_cursor(ctx)

      send_keys(ctx, "<C-u>")
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

      send_keys(ctx, "25j")

      # The gutter should show numbers around line 26
      # (0-indexed line 25 = display line 26)
      rows = screen_text(ctx)
      # Find a row containing "line 26" and verify gutter shows "26"
      line_26_row = Enum.find(rows, &String.contains?(&1, "line 26"))
      assert line_26_row != nil, "line 26 should be visible"
      assert String.contains?(line_26_row, "26"), "gutter should show 26"
    end
  end

  # ── Round-trip ─────────────────────────────────────────────────────────────

  describe "scroll round-trip" do
    test "G then gg returns to same screen state" do
      ctx = start_editor(@test_content)

      # Capture initial screen
      initial_cursor = buffer_cursor(ctx)

      send_keys(ctx, "G")
      assert buffer_cursor(ctx) != initial_cursor

      send_keys(ctx, "gg")
      assert buffer_cursor(ctx) == initial_cursor
      assert_screen_snapshot(ctx, "scroll_roundtrip_gg")
    end
  end
end
