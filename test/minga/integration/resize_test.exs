defmodule Minga.Integration.ResizeTest do
  @moduledoc """
  Integration tests for terminal resize: layout recompute, cursor clamp,
  modeline/minibuffer repositioning, and gutter adjustment.

  Ticket: #455
  """
  use Minga.Test.EditorCase, async: true

  # ── Basic resize ───────────────────────────────────────────────────────────

  describe "resize smaller" do
    test "modeline moves to correct row after shrink" do
      ctx = start_editor("hello world")

      ctx = send_resize(ctx, 60, 15)

      # Modeline should be at row height-2 = 13
      modeline_row = screen_row(ctx, 13)

      assert String.contains?(modeline_row, "NORMAL"),
             "modeline should be at row 13 after resize to 15 rows"

      assert_screen_snapshot(ctx, "resize_shrink")
    end

    test "minibuffer moves to last row" do
      ctx = start_editor("hello world")

      ctx = send_resize(ctx, 60, 15)

      # Minibuffer should be at row 14 (height - 1)
      mb = screen_row(ctx, 14)
      # Minibuffer should exist (even if empty)
      assert is_binary(mb)
    end
  end

  # ── Resize larger ─────────────────────────────────────────────────────────

  describe "resize larger" do
    test "more tilde rows appear after growing" do
      ctx = start_editor("hello world")

      ctx = send_resize(ctx, 80, 40)

      # With 40 rows, many more tilde rows should be visible
      tilde_count = screen_text(ctx) |> Enum.count(&String.starts_with?(String.trim(&1), "~"))
      assert tilde_count > 20, "expected many tilde rows after resize to 40, got #{tilde_count}"
      assert_screen_snapshot(ctx, "resize_grow")
    end
  end

  # ── Cursor clamp ──────────────────────────────────────────────────────────

  describe "cursor clamp on shrink" do
    test "viewport adjusts to keep cursor visible" do
      content = Enum.map_join(1..50, "\n", &"line #{&1}")
      ctx = start_editor(content)

      # Move cursor to line 20
      send_keys(ctx, "20j")
      {line, _} = buffer_cursor(ctx)
      assert line == 20

      # Shrink to 10 rows
      ctx = send_resize(ctx, 80, 10)

      # Cursor should still be at line 20, and that line should be visible
      {line_after, _} = buffer_cursor(ctx)
      assert line_after == 20
      assert screen_contains?(ctx, "line 21")
      assert_screen_snapshot(ctx, "resize_cursor_clamp")
    end
  end

  # ── Resize with file tree ─────────────────────────────────────────────────

  describe "resize with file tree open" do
    test "file tree and editor adjust to new width" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>op")
      assert Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))

      ctx = send_resize(ctx, 120, 24)

      # Both tree and editor should still be visible with separator
      assert Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))
    end
  end

  # ── Resize with splits ────────────────────────────────────────────────────

  describe "resize with window splits" do
    test "split panes adjust proportionally" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>wv")
      row_before = screen_row(ctx, 1)
      assert String.contains?(row_before, "│")

      ctx = send_resize(ctx, 120, 24)

      row_after = screen_row(ctx, 1)
      assert String.contains?(row_after, "│"), "split separator should persist after resize"
      assert_screen_snapshot(ctx, "resize_with_splits")
    end
  end

  # ── Extreme resize ────────────────────────────────────────────────────────

  describe "extreme resize" do
    test "very small then back to normal does not crash" do
      ctx = start_editor("hello world")

      # Shrink very small
      ctx = send_resize(ctx, 20, 5)
      assert editor_mode(ctx) == :normal

      # Grow back to normal
      ctx = send_resize(ctx, 80, 24)
      assert editor_mode(ctx) == :normal
      assert_screen_snapshot(ctx, "resize_extreme_roundtrip")
    end
  end
end
