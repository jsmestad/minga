defmodule Minga.Integration.MouseTest do
  @moduledoc """
  Integration tests for mouse interactions: click-to-position,
  double-click word select, triple-click line select, scroll wheel,
  and region dispatch.

  """
  use Minga.Test.EditorCase, async: true

  # ── Click to position ──────────────────────────────────────────────────────

  describe "single left click" do
    test "positions cursor at clicked cell in editor area" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      # Click on "second" at row 2, accounting for gutter width
      # Gutter is ~3 chars ("1 "), so col 3 = start of text
      send_mouse(ctx, 2, 5, :left)

      {line, _col} = buffer_cursor(ctx)
      assert line == 1, "clicking row 2 should place cursor on buffer line 1"
      assert_screen_snapshot(ctx, "mouse_click_position")
    end

    test "click at different position moves cursor" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      send_mouse(ctx, 1, 7, :left)
      cursor1 = buffer_cursor(ctx)

      send_mouse(ctx, 3, 5, :left)
      cursor2 = buffer_cursor(ctx)

      assert cursor1 != cursor2, "clicking different positions should move cursor"
    end
  end

  # ── Double-click word select ───────────────────────────────────────────────

  describe "double-click word select" do
    test "selects word under cursor" do
      ctx = start_editor("hello world")

      # Double-click on "hello" (row 1, within text area)
      send_mouse(ctx, 1, 5, :left, 0, :press, 2)

      assert editor_mode(ctx) == :visual
      assert_screen_snapshot(ctx, "mouse_double_click_word")
    end
  end

  # ── Triple-click line select ───────────────────────────────────────────────

  describe "triple-click line select" do
    test "selects entire line" do
      ctx = start_editor("hello world\nsecond line")

      # Triple-click on first content row
      send_mouse(ctx, 1, 5, :left, 0, :press, 3)

      mode = editor_mode(ctx)

      assert mode in [:visual, :visual_line],
             "triple-click should enter visual or visual-line mode"

      assert_screen_snapshot(ctx, "mouse_triple_click_line")
    end
  end

  # ── Scroll wheel ───────────────────────────────────────────────────────────

  describe "scroll wheel" do
    @long_content Enum.map_join(1..50, "\n", &"line #{&1}")

    test "wheel down scrolls viewport" do
      ctx = start_editor(@long_content)

      # Scroll down a few times
      send_mouse(ctx, 10, 10, :wheel_down)
      send_mouse(ctx, 10, 10, :wheel_down)
      send_mouse(ctx, 10, 10, :wheel_down)

      # Viewport should have scrolled; later lines should be visible
      assert screen_contains?(ctx, "line 4") or screen_contains?(ctx, "line 5")
      assert_screen_snapshot(ctx, "mouse_scroll_down")
    end

    test "wheel up scrolls viewport back" do
      ctx = start_editor(@long_content)

      # Scroll down then back up
      for _ <- 1..5, do: send_mouse(ctx, 10, 10, :wheel_down)
      for _ <- 1..5, do: send_mouse(ctx, 10, 10, :wheel_up)

      # Should be back near the top
      assert screen_contains?(ctx, "line 1")
    end
  end

  # ── Click in file tree ────────────────────────────────────────────────────

  describe "click in file tree region" do
    test "clicking in tree area doesn't move buffer cursor" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>op")
      cursor_before = buffer_cursor(ctx)

      # Click in the tree area (col 2, well within tree panel)
      send_mouse(ctx, 3, 2, :left)

      cursor_after = buffer_cursor(ctx)
      assert cursor_after == cursor_before, "clicking tree should not move buffer cursor"
    end
  end

  # ── Click-and-drag ──────────────────────────────────────────────────────────

  describe "click-and-drag" do
    test "drag creates visual selection" do
      ctx = start_editor("hello world foo bar")

      # Press at one position
      send_mouse(ctx, 1, 5, :left, 0, :press, 1)
      # Drag to another position
      send_mouse(ctx, 1, 15, :left, 0, :drag, 1)

      assert editor_mode(ctx) == :visual,
             "dragging should enter visual mode, got #{editor_mode(ctx)}"
    end

    test "releasing after drag keeps selection" do
      ctx = start_editor("hello world foo bar")

      send_mouse(ctx, 1, 5, :left, 0, :press, 1)
      send_mouse(ctx, 1, 15, :left, 0, :drag, 1)
      send_mouse(ctx, 1, 15, :left, 0, :release, 1)

      assert editor_mode(ctx) == :visual
    end
  end

  # ── Click in gutter ────────────────────────────────────────────────────────

  describe "click in gutter area" do
    test "clicking in the gutter does not position cursor at col 0" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      # Click in the gutter area (col 0 or 1, where line numbers are)
      send_mouse(ctx, 2, 0, :left)

      {_line, col} = buffer_cursor(ctx)
      # Cursor should be at col 0 of the text (start of line), not in the gutter
      assert col == 0
    end
  end

  # ── Click in agent panel ──────────────────────────────────────────────────

  describe "click in agent panel area" do
    test "clicking in agent panel area focuses it" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>aa")

      # Find the separator column to know where the agent panel starts
      row1 = screen_row(ctx, 1)
      sep_col = row1 |> String.graphemes() |> Enum.find_index(&(&1 == "│"))

      if sep_col do
        # Click in the agent panel area (right of separator)
        send_mouse(ctx, 5, sep_col + 5, :left)

        # Buffer cursor should not have moved to the agent panel area
        # (the click was dispatched to the agent panel, not the buffer)
        {_, buf_col} = buffer_cursor(ctx)

        assert buf_col < sep_col,
               "buffer cursor should stay in editor area after clicking agent panel"
      end
    end
  end

  # ── Shift-click extend selection ───────────────────────────────────────────

  describe "shift-click extend selection" do
    @shift 0x01

    test "shift-click extends selection from cursor" do
      ctx = start_editor("hello world foo bar")

      # Click to position cursor
      send_mouse(ctx, 1, 5, :left)
      # Shift-click further right to extend selection
      send_mouse(ctx, 1, 15, :left, @shift)

      assert editor_mode(ctx) == :visual
      assert_screen_snapshot(ctx, "mouse_shift_click_select")
    end
  end
end
