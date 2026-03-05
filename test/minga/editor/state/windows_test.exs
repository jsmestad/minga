defmodule Minga.Editor.State.WindowsTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Windows
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_windows do
    tree = WindowTree.new(1)
    window = Window.new(1, self(), 24, 80)
    %Windows{tree: tree, map: %{1 => window}, active: 1, next_id: 2}
  end

  # ── split?/1 ─────────────────────────────────────────────────────────────────

  describe "split?/1" do
    test "false for nil tree" do
      refute Windows.split?(%Windows{})
    end

    test "false for single leaf" do
      refute Windows.split?(new_windows())
    end

    test "true after split" do
      ws = new_windows()
      {:ok, tree} = WindowTree.split(ws.tree, 1, :vertical, 2)
      win2 = Window.new(2, self(), 24, 40)
      ws = %{ws | tree: tree, map: Map.put(ws.map, 2, win2)}
      assert Windows.split?(ws)
    end
  end

  # ── active_struct/1 ──────────────────────────────────────────────────────────

  describe "active_struct/1" do
    test "returns the active window" do
      ws = new_windows()
      window = Windows.active_struct(ws)
      assert %Window{} = window
      assert window == Map.fetch!(ws.map, 1)
    end

    test "returns nil when no windows" do
      assert Windows.active_struct(%Windows{}) == nil
    end
  end

  # ── update/3 ─────────────────────────────────────────────────────────────────

  describe "update/3" do
    test "applies function to matching window" do
      ws = new_windows()
      ws = Windows.update(ws, 1, fn w -> %{w | cursor: {5, 10}} end)
      assert Map.fetch!(ws.map, 1).cursor == {5, 10}
    end

    test "no-op for unknown id" do
      ws = new_windows()
      assert Windows.update(ws, 999, fn w -> %{w | rows: 42} end) == ws
    end
  end
end
