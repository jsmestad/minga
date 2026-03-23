defmodule Minga.Prompt.AgentGroupRenameTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Prompt.AgentGroupRename

  describe "label/0" do
    test "returns the prompt label" do
      assert AgentGroupRename.label() == "Rename workspace: "
    end
  end

  describe "on_submit/2" do
    test "renames the active agent group" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      tb = TabBar.switch_to_group(tb, group.id)
      state = %{tab_bar: tb, status_msg: ""}

      new_state = AgentGroupRename.on_submit("Research Bot", state)
      assert TabBar.active_group(new_state.tab_bar).label == "Research Bot"
      assert TabBar.active_group(new_state.tab_bar).custom_name == true
      assert new_state.status_msg =~ "Renamed"
    end

    test "trims whitespace from name" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      tb = TabBar.switch_to_group(tb, group.id)
      state = %{tab_bar: tb, status_msg: ""}

      new_state = AgentGroupRename.on_submit("  My Space  ", state)
      assert TabBar.active_group(new_state.tab_bar).label == "My Space"
    end

    test "rejects empty name with error message" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      state = %{tab_bar: tb, status_msg: ""}
      new_state = AgentGroupRename.on_submit("", state)
      assert new_state.status_msg =~ "cannot be empty"
    end

    test "rejects whitespace-only name" do
      state = %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex")), status_msg: ""}
      new_state = AgentGroupRename.on_submit("   ", state)
      assert new_state.status_msg =~ "cannot be empty"
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex"))}
      assert AgentGroupRename.on_cancel(state) == state
    end
  end
end
