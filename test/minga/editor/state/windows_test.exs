defmodule Minga.Editor.State.WindowsTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Windows
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.UI.Popup.Active, as: PopupActive
  alias Minga.UI.Popup.Rule

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_windows do
    tree = WindowTree.new(1)
    window = Window.new(1, self(), 24, 80)
    %Windows{tree: tree, map: %{1 => window}, active: 1, next_id: 2}
  end

  defp split_windows do
    {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
    win1 = Window.new(1, self(), 24, 40)
    win2 = Window.new(2, self(), 24, 40)

    %Windows{
      tree: tree,
      map: %{1 => win1, 2 => win2},
      active: 1,
      next_id: 3
    }
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
      assert Windows.split?(split_windows())
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

    test "returns the correct window after focus change" do
      ws = %{split_windows() | active: 2}
      window = Windows.active_struct(ws)
      assert window.id == 2
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
      assert Windows.update(ws, 999, fn w -> %{w | cursor: {42, 0}} end) == ws
    end

    test "updates only the targeted window in a split" do
      ws = split_windows()
      ws = Windows.update(ws, 2, fn w -> %{w | cursor: {10, 5}} end)
      assert Map.fetch!(ws.map, 2).cursor == {10, 5}
      assert Map.fetch!(ws.map, 1).cursor == {0, 0}
    end
  end

  # ── popup_windows/1 ─────────────────────────────────────────────────────────

  describe "popup_windows/1" do
    test "returns empty list when no popups" do
      ws = new_windows()
      assert Windows.popup_windows(ws) == []
    end

    test "returns empty list for split with no popups" do
      ws = split_windows()
      assert Windows.popup_windows(ws) == []
    end

    test "returns windows with popup_meta" do
      rule = Rule.new("*Warnings*")
      popup_meta = PopupActive.new(rule, 3, 1)
      popup_win = %{Window.new(3, self(), 10, 80) | popup_meta: popup_meta}

      ws = %{new_windows() | map: Map.put(new_windows().map, 3, popup_win)}
      popups = Windows.popup_windows(ws)

      assert length(popups) == 1
      assert [{3, %Window{popup_meta: %PopupActive{}}}] = popups
    end

    test "filters only popup windows among mixed windows" do
      rule = Rule.new("*Messages*")
      popup_meta = PopupActive.new(rule, 3, 1)
      popup_win = %{Window.new(3, self(), 10, 80) | popup_meta: popup_meta}

      ws = split_windows()
      ws = %{ws | map: Map.put(ws.map, 3, popup_win)}

      popups = Windows.popup_windows(ws)
      assert length(popups) == 1
      assert [{3, _}] = popups
    end
  end

  # ── Focus switching lifecycle ───────────────────────────────────────────────

  describe "focus switching" do
    test "switching active updates active_struct result" do
      ws = split_windows()
      assert Windows.active_struct(ws).id == 1

      ws = %{ws | active: 2}
      assert Windows.active_struct(ws).id == 2
    end

    test "update on new active window works after focus switch" do
      ws = %{split_windows() | active: 2}
      ws = Windows.update(ws, 2, fn w -> %{w | cursor: {7, 3}} end)
      assert Windows.active_struct(ws).cursor == {7, 3}
    end
  end

  # ── Split and close lifecycle ───────────────────────────────────────────────

  describe "split and close lifecycle" do
    test "split -> verify split? -> close -> back to single" do
      ws = new_windows()
      refute Windows.split?(ws)

      # Split
      {:ok, tree} = WindowTree.split(ws.tree, 1, :vertical, 2)
      win2 = Window.new(2, self(), 24, 40)
      ws = %{ws | tree: tree, map: Map.put(ws.map, 2, win2), next_id: 3}
      assert Windows.split?(ws)

      # Close window 2
      {:ok, tree} = WindowTree.close(ws.tree, 2)
      ws = %{ws | tree: tree, map: Map.delete(ws.map, 2)}
      refute Windows.split?(ws)
    end

    test "close active returns to sibling" do
      ws = split_windows()

      # Close active window (1), sibling (2) remains
      {:ok, tree} = WindowTree.close(ws.tree, 1)
      ws = %{ws | tree: tree, map: Map.delete(ws.map, 1), active: 2}

      refute Windows.split?(ws)
      assert Windows.active_struct(ws).id == 2
    end
  end
end
