defmodule Minga.UI.Picker.TabSourceTest do
  use ExUnit.Case, async: true

  alias Minga.UI.Picker.Item

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.UI.Picker.TabSource

  describe "title/0" do
    test "returns Switch Tab" do
      assert TabSource.title() == "Switch Tab"
    end
  end

  describe "candidates/1" do
    test "returns candidates for all tabs" do
      tab = Tab.new_file(1, "main.ex")
      tb = TabBar.new(tab)
      {tb, _} = TabBar.add(tb, :file, "lib.ex")
      {tb, _} = TabBar.add(tb, :agent, "Agent")

      candidates = TabSource.candidates(%{tab_bar: tb})
      assert length(candidates) == 3

      %Item{id: id1, label: label1} = Enum.find(candidates, fn %Item{id: id} -> id == 1 end)
      assert id1 == 1
      assert String.contains?(label1, "main.ex")
    end

    test "active tab has bullet marker" do
      tab = Tab.new_file(1, "one.ex")
      tb = TabBar.new(tab)
      {tb, _} = TabBar.add(tb, :file, "two.ex")
      tb = TabBar.switch_to(tb, 1)

      candidates = TabSource.candidates(%{tab_bar: tb})

      %Item{label: active_label} = Enum.find(candidates, fn %Item{id: id} -> id == 1 end)
      assert String.contains?(active_label, "\u{2022}")

      %Item{label: inactive_label} = Enum.find(candidates, fn %Item{id: id} -> id == 2 end)
      refute String.contains?(inactive_label, "\u{2022}")
    end

    test "agent tabs show agent icon" do
      tab = Tab.new_agent(1, "My Session")
      tb = TabBar.new(tab)

      [%Item{label: label, description: desc}] = TabSource.candidates(%{tab_bar: tb})
      assert String.contains?(label, "My Session")
      assert desc == "agent"
    end

    test "returns empty list for non-tab-bar context" do
      assert TabSource.candidates(%{}) == []
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{tab_bar: TabBar.new(Tab.new_file(1, "x.ex"))}
      assert TabSource.on_cancel(state) == state
    end
  end
end
