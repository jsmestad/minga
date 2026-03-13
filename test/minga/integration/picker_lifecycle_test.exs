defmodule Minga.Integration.PickerLifecycleTest do
  @moduledoc """
  Integration tests for picker lifecycle: open, filter, select, cancel.
  Covers the buffer picker (SPC b b), command palette (SPC :), and
  general picker interactions.

  Ticket: #447
  """
  use Minga.Test.EditorCase, async: true

  # ── Buffer picker: open ────────────────────────────────────────────────────

  describe "buffer picker open (SPC b b)" do
    test "shows picker overlay with title and prompt" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>bb")

      # Picker renders at the bottom: title row, item rows, prompt row
      assert_minibuffer_contains(ctx, ">")
      # The title row should contain "Switch buffer"
      assert screen_contains?(ctx, "Switch buffer")
      assert_screen_snapshot(ctx, "buffer_picker_open")
    end

    test "shows current scratch buffer in item list" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>bb")

      assert screen_contains?(ctx, "[scratch]")
    end
  end

  # ── Buffer picker: cancel ──────────────────────────────────────────────────

  describe "buffer picker cancel (Escape)" do
    test "closes picker and restores normal mode screen" do
      ctx = start_editor("hello world")

      # Record state before picker
      cursor_before = buffer_cursor(ctx)

      send_keys(ctx, "<Space>bb")
      assert screen_contains?(ctx, "Switch buffer")

      send_keys(ctx, "<Esc>")

      assert editor_mode(ctx) == :normal
      assert_modeline_contains(ctx, "NORMAL")
      assert buffer_cursor(ctx) == cursor_before
      refute screen_contains?(ctx, "Switch buffer")
      assert_screen_snapshot(ctx, "buffer_picker_cancel")
    end

    test "cursor returns to previous position after cancel" do
      ctx = start_editor("hello world")

      # Move cursor to col 5
      send_keys(ctx, "lllll")
      cursor_before = buffer_cursor(ctx)
      {_line, col} = cursor_before
      assert col == 5

      send_keys(ctx, "<Space>bb<Esc>")

      assert buffer_cursor(ctx) == cursor_before
    end
  end

  # ── Buffer picker: filter ──────────────────────────────────────────────────

  describe "buffer picker filtering" do
    test "typing in prompt filters visible items" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>bb")
      assert screen_contains?(ctx, "[scratch]")

      # Type something that won't match "[scratch]"
      send_keys(ctx, "zzz")

      # The item should be filtered out (no match)
      assert_screen_snapshot(ctx, "buffer_picker_filter_no_match")
    end

    test "backspace in filter restores previous results" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>bb")
      send_keys(ctx, "zzz")
      # Filter should show no matches

      send_keys(ctx, "<BS><BS><BS>")
      # Cleared filter, should show items again
      assert screen_contains?(ctx, "[scratch]")
    end
  end

  # ── Buffer picker: select ──────────────────────────────────────────────────

  describe "buffer picker select (Enter)" do
    test "selecting the only buffer closes picker" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>bb<CR>")

      assert editor_mode(ctx) == :normal
      refute screen_contains?(ctx, "Switch buffer")
      assert_screen_snapshot(ctx, "buffer_picker_select")
    end
  end

  # ── Command palette: open ──────────────────────────────────────────────────

  describe "command palette open (SPC :)" do
    test "shows picker overlay with Commands title" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>:")

      assert screen_contains?(ctx, "Commands")
      assert_screen_snapshot(ctx, "command_palette_open")
    end
  end

  # ── Command palette: filter ────────────────────────────────────────────────

  describe "command palette filtering" do
    test "typing filters the command list" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>:")
      assert screen_contains?(ctx, "Commands")

      # Type "save" to filter to save-related commands
      send_keys(ctx, "save")

      assert_screen_snapshot(ctx, "command_palette_filter_save")
    end
  end

  # ── Command palette: cancel ────────────────────────────────────────────────

  describe "command palette cancel" do
    test "escape closes picker and returns to normal" do
      ctx = start_editor("hello world")

      cursor_before = buffer_cursor(ctx)

      send_keys(ctx, "<Space>:")
      assert screen_contains?(ctx, "Commands")

      send_keys(ctx, "<Esc>")

      assert editor_mode(ctx) == :normal
      refute screen_contains?(ctx, "Commands")
      assert buffer_cursor(ctx) == cursor_before
      assert_screen_snapshot(ctx, "command_palette_cancel")
    end
  end

  # ── Command palette: select ────────────────────────────────────────────────

  describe "command palette select" do
    test "selecting a command executes it and closes picker" do
      ctx = start_editor("hello world")

      # Open command palette and filter to "new_buffer"
      send_keys(ctx, "<Space>:")
      send_keys(ctx, "new_buffer")

      # Select the first match
      send_keys(ctx, "<CR>")

      assert editor_mode(ctx) == :normal
      refute screen_contains?(ctx, "Commands")
      assert_screen_snapshot(ctx, "command_palette_execute")
    end
  end

  # ── Round-trip: open picker from visual mode ───────────────────────────────

  describe "picker from visual mode" do
    test "opening and cancelling buffer picker preserves visual mode" do
      ctx = start_editor("hello world")

      # Enter visual mode and start selection
      send_keys(ctx, "llv")
      assert editor_mode(ctx) == :visual

      send_keys(ctx, "<Space>bb")
      send_keys(ctx, "<Esc>")

      # After picker cancel, should return to visual mode
      # (The picker restores the mode it was opened from)
      assert_screen_snapshot(ctx, "picker_cancel_visual")
    end
  end
end
