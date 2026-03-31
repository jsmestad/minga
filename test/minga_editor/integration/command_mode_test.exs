defmodule Minga.Integration.CommandModeTest do
  @moduledoc """
  Integration tests for command mode (:) covering entry, typing, execution,
  error handling, and clean focus return. Uses HeadlessPort screen capture
  with snapshot assertions.

  """
  use Minga.Test.EditorCase, async: true

  # ── Entry ──────────────────────────────────────────────────────────────────

  describe "entering command mode" do
    test "colon shows in minibuffer with cursor positioned after it" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, ":")

      assert editor_mode(ctx) == :command
      assert_minibuffer_contains(ctx, ":")
      {cursor_row, cursor_col} = screen_cursor(ctx)
      assert cursor_row == ctx.height - 1, "cursor should be on minibuffer row"
      assert cursor_col == 1, "cursor should be right after the colon"
      assert_screen_snapshot(ctx, "command_entry")
    end
  end

  # ── Typing ─────────────────────────────────────────────────────────────────

  describe "typing in command mode" do
    test "typed text appears in minibuffer after colon" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, ":set nu")

      assert editor_mode(ctx) == :command
      assert_minibuffer_contains(ctx, ":set nu")
      assert_screen_snapshot(ctx, "command_typing_set_nu")
    end

    test "partial command shows incrementally" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, ":se")

      assert_minibuffer_contains(ctx, ":se")
      {cursor_row, cursor_col} = screen_cursor(ctx)
      assert cursor_row == ctx.height - 1
      assert cursor_col == 3, "cursor after ':se' should be at col 3"
      assert_screen_snapshot(ctx, "command_typing_partial")
    end
  end

  # ── Backspace ──────────────────────────────────────────────────────────────

  describe "backspace in command mode" do
    test "removes last character from minibuffer" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, ":set")
      assert_minibuffer_contains(ctx, ":set")

      send_keys_sync(ctx, "<BS>")

      assert editor_mode(ctx) == :command
      assert_minibuffer_contains(ctx, ":se")
      assert_screen_snapshot(ctx, "command_backspace")
    end

    test "backspacing to empty exits command mode" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, ":a<BS>")

      assert editor_mode(ctx) == :normal
      assert_modeline_contains(ctx, "NORMAL")
      assert_screen_snapshot(ctx, "command_backspace_exit")
    end
  end

  # ── Escape ─────────────────────────────────────────────────────────────────

  describe "escape from command mode" do
    test "clears minibuffer and returns to normal mode" do
      ctx = start_editor("hello world")

      # Record buffer cursor before command mode
      cursor_before = buffer_cursor(ctx)

      send_keys_sync(ctx, ":set nu<Esc>")

      assert editor_mode(ctx) == :normal
      assert_modeline_contains(ctx, "NORMAL")
      assert buffer_cursor(ctx) == cursor_before
      assert_screen_snapshot(ctx, "command_escape")
    end

    test "cursor returns to buffer at previous position" do
      ctx = start_editor("hello world")

      # Move cursor to col 5 before entering command mode
      send_keys_sync(ctx, "lllll")
      cursor_before = buffer_cursor(ctx)
      {_line, col} = cursor_before
      assert col == 5

      send_keys_sync(ctx, ":w<Esc>")

      assert buffer_cursor(ctx) == cursor_before
    end
  end

  # ── Execution: :set nu ─────────────────────────────────────────────────────

  describe "executing :set nu" do
    test "toggles line numbers and returns to normal mode" do
      ctx = start_editor("hello\nworld\nfoo")

      send_keys_sync(ctx, ":set nu<CR>")

      assert editor_mode(ctx) == :normal
      assert_modeline_contains(ctx, "NORMAL")
      assert_screen_snapshot(ctx, "command_exec_set_nu")
    end
  end

  # ── Execution: :set rnu ────────────────────────────────────────────────────

  describe "executing :set rnu" do
    test "toggles relative line numbers and returns to normal mode" do
      ctx = start_editor("line one\nline two\nline three\nline four\nline five")

      send_keys_sync(ctx, ":set rnu<CR>")

      assert editor_mode(ctx) == :normal
      assert_screen_snapshot(ctx, "command_exec_set_rnu")
    end
  end

  # ── Execution: goto line ───────────────────────────────────────────────────

  describe "executing :<number> to goto line" do
    test "jumps cursor to the specified line" do
      ctx =
        start_editor("line one\nline two\nline three\nline four\nline five")

      send_keys_sync(ctx, ":3<CR>")

      assert editor_mode(ctx) == :normal
      {line, col} = buffer_cursor(ctx)
      assert line == 2, "expected buffer line 2 (0-indexed for line 3), got #{line}"
      assert col == 0
      assert_screen_snapshot(ctx, "command_goto_line_3")
    end

    test "goto line 1 moves to top" do
      ctx =
        start_editor("line one\nline two\nline three\nline four\nline five")

      # Move to line 3 first, then :1 to go back to top
      send_keys_sync(ctx, ":3<CR>")
      send_keys_sync(ctx, ":1<CR>")

      {line, _col} = buffer_cursor(ctx)
      assert line == 0
      assert_screen_snapshot(ctx, "command_goto_line_1")
    end
  end

  # ── Execution: :w on unnamed buffer ────────────────────────────────────────

  describe "executing :w on unnamed buffer" do
    test "shows no file name error in status" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, ":w<CR>")

      assert editor_mode(ctx) == :normal
      assert_screen_snapshot(ctx, "command_save_unnamed")
    end
  end

  # ── Execution: unknown command ─────────────────────────────────────────────

  describe "executing unknown command" do
    test "returns to normal mode silently" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, ":nonexistent<CR>")

      assert editor_mode(ctx) == :normal
      assert_modeline_contains(ctx, "NORMAL")
      assert_screen_snapshot(ctx, "command_unknown")
    end
  end

  # ── Round-trip workflow ────────────────────────────────────────────────────

  describe "full command mode round-trip" do
    test "normal -> : -> type -> execute -> back to normal with result" do
      ctx = start_editor("alpha\nbeta\ngamma\ndelta\nepsilon")

      # Verify starting state
      assert editor_mode(ctx) == :normal
      {start_line, _} = buffer_cursor(ctx)
      assert start_line == 0

      # Enter command mode and jump to line 4
      send_keys_sync(ctx, ":4<CR>")

      assert editor_mode(ctx) == :normal
      {line, _} = buffer_cursor(ctx)
      assert line == 3, "expected line 3 (0-indexed for :4), got #{line}"
      assert_screen_snapshot(ctx, "command_roundtrip_goto")
    end

    test "multiple commands in sequence" do
      ctx =
        start_editor("first\nsecond\nthird\nfourth\nfifth")

      # Toggle line numbers
      send_keys_sync(ctx, ":set nu<CR>")
      assert editor_mode(ctx) == :normal

      # Jump to line 3
      send_keys_sync(ctx, ":3<CR>")
      assert editor_mode(ctx) == :normal
      {line, _} = buffer_cursor(ctx)
      assert line == 2

      # Enter and escape without executing
      send_keys_sync(ctx, ":w<Esc>")
      assert editor_mode(ctx) == :normal
      # Cursor stays where it was after :3
      {line2, _} = buffer_cursor(ctx)
      assert line2 == 2

      assert_screen_snapshot(ctx, "command_multi_sequence")
    end
  end
end
