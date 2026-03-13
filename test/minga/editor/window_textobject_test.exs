defmodule Minga.Editor.WindowTextobjectTest do
  @moduledoc """
  Tests for `Window.next_textobject/3` and `Window.prev_textobject/3`.
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content

  defp window_with_positions(positions) do
    pid = self()

    %Window{
      id: 1,
      content: Content.buffer(pid),
      buffer: pid,
      viewport: Viewport.new(24, 80),
      textobject_positions: positions
    }
  end

  # ── next_textobject/3 ──────────────────────────────────────────────────────

  describe "next_textobject/3" do
    test "returns nil for empty positions" do
      win = window_with_positions(%{})
      assert Window.next_textobject(win, :function, {0, 0}) == nil
    end

    test "returns nil when type has no entries" do
      win = window_with_positions(%{class: [{5, 0}]})
      assert Window.next_textobject(win, :function, {0, 0}) == nil
    end

    test "returns the first position after cursor on same line" do
      win = window_with_positions(%{function: [{0, 0}, {0, 10}, {5, 0}]})
      assert Window.next_textobject(win, :function, {0, 0}) == {0, 10}
    end

    test "returns position on a later line" do
      win = window_with_positions(%{function: [{0, 0}, {5, 0}, {10, 0}]})
      assert Window.next_textobject(win, :function, {0, 0}) == {5, 0}
    end

    test "returns nil when cursor is at or past all positions" do
      win = window_with_positions(%{function: [{0, 0}, {5, 0}]})
      assert Window.next_textobject(win, :function, {5, 0}) == nil
    end

    test "returns nil when cursor is past all positions" do
      win = window_with_positions(%{function: [{0, 0}, {5, 0}]})
      assert Window.next_textobject(win, :function, {10, 0}) == nil
    end

    test "handles single entry after cursor" do
      win = window_with_positions(%{function: [{3, 5}]})
      assert Window.next_textobject(win, :function, {0, 0}) == {3, 5}
    end

    test "skips entries before cursor" do
      win = window_with_positions(%{function: [{1, 0}, {2, 0}, {3, 0}]})
      assert Window.next_textobject(win, :function, {2, 0}) == {3, 0}
    end

    test "handles same-row comparison correctly" do
      win = window_with_positions(%{function: [{5, 0}, {5, 10}, {5, 20}]})
      assert Window.next_textobject(win, :function, {5, 10}) == {5, 20}
    end
  end

  # ── prev_textobject/3 ──────────────────────────────────────────────────────

  describe "prev_textobject/3" do
    test "returns nil for empty positions" do
      win = window_with_positions(%{})
      assert Window.prev_textobject(win, :function, {10, 0}) == nil
    end

    test "returns nil when type has no entries" do
      win = window_with_positions(%{class: [{5, 0}]})
      assert Window.prev_textobject(win, :function, {10, 0}) == nil
    end

    test "returns the last position before cursor on same line" do
      win = window_with_positions(%{function: [{5, 0}, {5, 10}, {5, 20}]})
      assert Window.prev_textobject(win, :function, {5, 20}) == {5, 10}
    end

    test "returns position on an earlier line" do
      win = window_with_positions(%{function: [{0, 0}, {5, 0}, {10, 0}]})
      assert Window.prev_textobject(win, :function, {10, 0}) == {5, 0}
    end

    test "returns nil when cursor is at or before all positions" do
      win = window_with_positions(%{function: [{5, 0}, {10, 0}]})
      assert Window.prev_textobject(win, :function, {5, 0}) == nil
    end

    test "returns nil when cursor is before all positions" do
      win = window_with_positions(%{function: [{5, 0}, {10, 0}]})
      assert Window.prev_textobject(win, :function, {0, 0}) == nil
    end

    test "handles single entry before cursor" do
      win = window_with_positions(%{function: [{3, 5}]})
      assert Window.prev_textobject(win, :function, {10, 0}) == {3, 5}
    end

    test "skips entries after cursor" do
      win = window_with_positions(%{function: [{1, 0}, {2, 0}, {3, 0}]})
      assert Window.prev_textobject(win, :function, {2, 0}) == {1, 0}
    end

    test "handles same-row comparison correctly" do
      win = window_with_positions(%{function: [{5, 0}, {5, 10}, {5, 20}]})
      assert Window.prev_textobject(win, :function, {5, 10}) == {5, 0}
    end
  end

  # ── Cross-type independence ────────────────────────────────────────────────

  describe "cross-type independence" do
    test "different types have independent position lists" do
      win =
        window_with_positions(%{
          function: [{1, 0}, {10, 0}],
          class: [{5, 0}, {20, 0}],
          parameter: [{3, 5}]
        })

      assert Window.next_textobject(win, :function, {0, 0}) == {1, 0}
      assert Window.next_textobject(win, :class, {0, 0}) == {5, 0}
      assert Window.next_textobject(win, :parameter, {0, 0}) == {3, 5}
    end
  end
end
