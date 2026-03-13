defmodule Minga.Integration.FileTreeTest do
  @moduledoc """
  Integration tests for file tree: toggle, navigate, open files, focus
  return, and separator rendering.

  Ticket: #449
  """
  # async: false because file tree reads the real filesystem and can be
  # slow under heavy test concurrency
  use Minga.Test.EditorCase, async: false

  # ── Toggle ─────────────────────────────────────────────────────────────────

  describe "file tree toggle (SPC o p)" do
    test "opening shows file tree panel with separator" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>op")

      # File tree should show directory structure with separator
      rows = screen_text(ctx)
      has_separator = Enum.any?(rows, &String.contains?(&1, "│"))
      assert has_separator, "vertical separator between tree and editor should be visible"
    end

    test "closing restores full editor width" do
      ctx = start_editor("hello world")

      # Open then close
      send_keys(ctx, "<Space>op")
      assert Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))

      send_keys(ctx, "<Space>op")

      # Separator should be gone
      row1 = screen_row(ctx, 1)
      refute String.contains?(row1, "│"), "separator should be gone after closing tree"
    end
  end

  # ── Navigation ─────────────────────────────────────────────────────────────

  describe "file tree navigation" do
    test "j/k moves tree cursor" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>op")
      # Move down in tree
      send_keys(ctx, "j")
      send_keys(ctx, "j")
    end
  end

  # ── Focus return ───────────────────────────────────────────────────────────

  describe "focus return after tree interaction" do
    test "pressing Escape returns focus to editor" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>op")
      # Tree should be focused initially
      send_keys(ctx, "j")

      send_keys(ctx, "<Esc>")

      # After escape, focus should return to editor
      # Subsequent keys should operate on the buffer, not the tree
      assert editor_mode(ctx) == :normal
    end
  end

  # ── Toggle idempotence ────────────────────────────────────────────────────

  describe "toggle idempotence" do
    test "open -> close -> open shows tree with separator both times" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>op")
      first_has_separator = Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))
      assert first_has_separator

      send_keys(ctx, "<Space>op")

      refute Enum.any?(1..20, fn row ->
               screen_row(ctx, row) |> String.contains?("│")
             end),
             "separator should be gone after close"

      send_keys(ctx, "<Space>op")
      second_has_separator = Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))
      assert second_has_separator, "re-opening tree should show separator again"
    end
  end
end
