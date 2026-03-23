defmodule Minga.Picker.AgentGroupSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Picker.AgentGroupSource

  describe "candidates/1" do
    test "returns one item per agent group with tabs" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_agent_group(tb, "Research")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      state = %{tab_bar: tb}

      items = AgentGroupSource.candidates(state)
      assert length(items) == 1
      assert hd(items).id == group.id
    end

    test "filters out groups with no tabs" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add_agent_group(tb, "Empty")
      state = %{tab_bar: tb}

      items = AgentGroupSource.candidates(state)
      assert items == []
    end

    test "shows file names in description" do
      tb = TabBar.new(Tab.new_file(1, "editor.ex"))
      {tb, _} = TabBar.add(tb, :file, "main.ex")
      {tb, group} = TabBar.add_agent_group(tb, "Work")
      tb = TabBar.move_tab_to_group(tb, 1, group.id)
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      state = %{tab_bar: tb}

      [item] = AgentGroupSource.candidates(state)
      assert item.description =~ "editor.ex"
      assert item.description =~ "main.ex"
    end

    test "returns empty for state without tab_bar" do
      assert AgentGroupSource.candidates(%{}) == []
    end
  end

  describe "on_select/2" do
    test "switches active tab to first tab in selected group" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, group} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      tb = TabBar.switch_to(tb, 1)

      tb = TabBar.switch_to_group(tb, group.id)
      assert TabBar.active_group_id(tb) == group.id
      assert tb.active_id == 2
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex"))}
      assert AgentGroupSource.on_cancel(state) == state
    end
  end
end
