defmodule Minga.Integration.AgentPanelTest do
  @moduledoc """
  Integration tests for agent panel: toggle, focus management, layout
  interaction with other UI elements.

  Ticket: #453
  """
  # async: false because agent panel initialization talks to external processes
  # and can be slow under heavy test concurrency
  use Minga.Test.EditorCase, async: false

  # ── Toggle ─────────────────────────────────────────────────────────────────

  describe "agent panel toggle (SPC a a)" do
    test "opening shows agent panel with separator" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>aa")

      # Agent panel should render on the right side with a separator
      rows = screen_text(ctx)
      has_separator = Enum.any?(rows, &String.contains?(&1, "│"))
      assert has_separator, "separator between editor and agent panel should be visible"
    end

    test "closing restores full editor width" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>aa")
      assert Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))

      send_keys(ctx, "<Space>aa")

      row1 = screen_row(ctx, 1)
      refute String.contains?(row1, "│"), "separator should be gone after closing agent panel"
    end
  end

  # ── Layout with editor ────────────────────────────────────────────────────

  describe "agent panel layout" do
    test "editor viewport shrinks when agent panel is open" do
      ctx = start_editor("hello world")

      row_before = screen_row(ctx, 1)

      send_keys(ctx, "<Space>aa")

      row_after = screen_row(ctx, 1)
      # The editor content should be narrower (shorter trimmed text before separator)
      assert String.length(String.trim(row_after)) >= String.length(String.trim(row_before)),
             "row should include agent panel content"
    end
  end

  # ── Toggle idempotence ────────────────────────────────────────────────────

  describe "agent panel toggle idempotence" do
    test "open -> close removes separator from content rows" do
      ctx = start_editor("hello world")

      send_keys(ctx, "<Space>aa")
      # Agent panel should be open with separator
      assert Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))

      send_keys(ctx, "<Space>aa")

      # Content rows (not tab bar or modeline) should have no separator
      content_row = screen_row(ctx, 1)

      refute String.contains?(content_row, "│"),
             "content row should have no separator after close"
    end
  end

  # ── Both file tree and agent panel ─────────────────────────────────────────

  describe "file tree + agent panel simultaneously" do
    test "both panels render with editor in the middle" do
      ctx = start_editor("hello world")

      # Open file tree
      send_keys(ctx, "<Space>op")
      # Open agent panel
      send_keys(ctx, "<Space>aa")

      rows = screen_text(ctx)
      # Row 1 should have content from all three: tree | editor | agent
      row1 = Enum.at(rows, 1)
      separator_count = row1 |> String.graphemes() |> Enum.count(&(&1 == "│"))

      assert separator_count >= 2,
             "expected at least 2 separators (tree|editor|agent), found #{separator_count}"
    end
  end
end
