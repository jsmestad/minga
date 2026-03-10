defmodule Minga.Editor.State.TabBarTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar

  defp file_tab(id, label \\ ""), do: Tab.new_file(id, label)

  describe "new/1" do
    test "creates a tab bar with one tab" do
      tab = file_tab(1, "main.ex")
      tb = TabBar.new(tab)
      assert TabBar.count(tb) == 1
      assert TabBar.active(tb) == tab
      assert tb.next_id == 2
    end
  end

  describe "active/1 and active_index/1" do
    test "returns the active tab" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.active(tb).label == "a.ex"
      assert TabBar.active_index(tb) == 0
    end
  end

  describe "add/3" do
    test "adds a file tab after the active tab" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, new_tab} = TabBar.add(tb, :file, "b.ex")
      assert new_tab.kind == :file
      assert new_tab.label == "b.ex"
      assert TabBar.count(tb) == 2
      assert TabBar.active(tb).id == new_tab.id
    end

    test "adds an agent tab" do
      tb = TabBar.new(file_tab(1))
      {tb, new_tab} = TabBar.add(tb, :agent, "Agent")
      assert new_tab.kind == :agent
      assert TabBar.active(tb).id == new_tab.id
    end

    test "inserts after active, not at end" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _b} = TabBar.add(tb, :file, "b")
      # Switch back to tab 1
      tb = TabBar.switch_to(tb, 1)
      {tb, c} = TabBar.add(tb, :file, "c")
      # Order should be: a, c, b
      labels = Enum.map(tb.tabs, & &1.label)
      assert labels == ["a", "c", "b"]
      assert TabBar.active(tb).id == c.id
    end

    test "assigns monotonically increasing ids" do
      tb = TabBar.new(file_tab(1))
      {tb, t2} = TabBar.add(tb, :file, "b")
      {_tb, t3} = TabBar.add(tb, :file, "c")
      assert t2.id == 2
      assert t3.id == 3
    end
  end

  describe "remove/2" do
    test "cannot remove the last tab" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.remove(tb, 1) == :last_tab
    end

    test "removes a non-active tab" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _b} = TabBar.add(tb, :file, "b")
      # Active is tab 2 (b). Remove tab 1 (a).
      {:ok, tb} = TabBar.remove(tb, 1)
      assert TabBar.count(tb) == 1
      assert TabBar.active(tb).label == "b"
    end

    test "removing active tab switches to right neighbor" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, b} = TabBar.add(tb, :file, "b")
      {tb, _c} = TabBar.add(tb, :file, "c")
      # Active is c (last added). Switch to b.
      tb = TabBar.switch_to(tb, b.id)
      {:ok, tb} = TabBar.remove(tb, b.id)
      # Should switch to c (right neighbor)
      assert TabBar.active(tb).label == "c"
    end

    test "removing last tab switches to left neighbor" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _b} = TabBar.add(tb, :file, "b")
      # Active is b (index 1). Remove b.
      {:ok, tb} = TabBar.remove(tb, TabBar.active(tb).id)
      assert TabBar.active(tb).label == "a"
    end

    test "removing nonexistent tab is a no-op" do
      tb = TabBar.new(file_tab(1))
      {tb, _} = TabBar.add(tb, :file, "b")
      {:ok, tb2} = TabBar.remove(tb, 999)
      assert tb2 == tb
    end
  end

  describe "switch_to/2" do
    test "switches to the given tab" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, b} = TabBar.add(tb, :file, "b")
      assert TabBar.active(tb).id == b.id
      tb = TabBar.switch_to(tb, 1)
      assert TabBar.active(tb).label == "a"
    end

    test "switching to nonexistent id is a no-op" do
      tb = TabBar.new(file_tab(1))
      tb2 = TabBar.switch_to(tb, 999)
      assert tb2 == tb
    end
  end

  describe "next/1 and prev/1" do
    test "next wraps around" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :file, "b")
      {tb, _} = TabBar.add(tb, :file, "c")
      # Active is c (index 2). Next wraps to a (index 0).
      tb = TabBar.next(tb)
      assert TabBar.active(tb).label == "a"
    end

    test "prev wraps around" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :file, "b")
      # Active is b. Switch to a.
      tb = TabBar.switch_to(tb, 1)
      # Prev from a wraps to b.
      tb = TabBar.prev(tb)
      assert TabBar.active(tb).label == "b"
    end

    test "next on single tab is a no-op" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.next(tb) == tb
    end

    test "prev on single tab is a no-op" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.prev(tb) == tb
    end
  end

  describe "update_context/3" do
    test "stores context on the given tab" do
      tb = TabBar.new(file_tab(1))
      ctx = %{mode: :insert}
      tb = TabBar.update_context(tb, 1, ctx)
      assert TabBar.get(tb, 1).context == ctx
    end
  end

  describe "update_label/3" do
    test "updates the label of the given tab" do
      tb = TabBar.new(file_tab(1, "old"))
      tb = TabBar.update_label(tb, 1, "new")
      assert TabBar.get(tb, 1).label == "new"
    end
  end

  describe "find_by_kind/2 and filter_by_kind/2" do
    test "finds first tab of a kind" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :agent, "Agent 1")
      assert TabBar.find_by_kind(tb, :agent).label == "Agent 1"
      assert TabBar.find_by_kind(tb, :file).label == "a"
    end

    test "returns nil when no tab of that kind exists" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.find_by_kind(tb, :agent) == nil
    end

    test "filters all tabs of a kind" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :file, "b")
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      assert length(TabBar.filter_by_kind(tb, :file)) == 2
      assert length(TabBar.filter_by_kind(tb, :agent)) == 1
    end
  end

  describe "most_recent_of_kind/2" do
    test "returns the last non-active tab of the given kind" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :file, "b")
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      # Active is agent tab. Most recent file tab is b.
      assert TabBar.most_recent_of_kind(tb, :file).label == "b"
    end

    test "returns nil when no other tab of that kind exists" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.most_recent_of_kind(tb, :file) == nil
    end

    test "skips the active tab" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :file, "b")
      tb = TabBar.switch_to(tb, 1)
      # Active is a. Most recent file is b (not a).
      result = TabBar.most_recent_of_kind(tb, :file)
      assert result.label == "b"
    end
  end

  describe "get/2" do
    test "returns the tab by id" do
      tb = TabBar.new(file_tab(1, "x"))
      assert TabBar.get(tb, 1).label == "x"
    end

    test "returns nil for missing id" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.get(tb, 99) == nil
    end
  end
end
