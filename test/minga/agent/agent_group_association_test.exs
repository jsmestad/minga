defmodule Minga.Agent.AgentGroupAssociationTest do
  @moduledoc """
  Tests for agent workspace association logic.

  Tests the TabBar-level operations for workspace file association
  and lifecycle (creation, migration, removal).
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.State.AgentGroup
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar

  defp build_agent_scenario do
    fake_session = spawn(fn -> Process.sleep(:infinity) end)

    tab1 = %Tab{id: 1, kind: :file, label: "editor.ex", group_id: 0}
    tab2 = %Tab{id: 2, kind: :file, label: "main.ex", group_id: 0}
    tab3 = %Tab{id: 3, kind: :agent, label: "Agent", group_id: 0}
    tab3 = Tab.set_session(tab3, fake_session)

    tb = %TabBar{tabs: [tab1, tab2, tab3], active_id: 3, next_id: 4}

    # Create workspace and assign agent tab
    {tb, ws} = TabBar.add_agent_group(tb, "Agent", fake_session)
    tb = TabBar.move_tab_to_group(tb, 3, ws.id)

    {tb, fake_session, ws}
  end

  describe "agent file association" do
    test "move_tab_to_group associates file with agent workspace" do
      {tb, _session, ws} = build_agent_scenario()

      # Simulate what file_changed handler does: move the file tab to agent workspace
      tb = TabBar.move_tab_to_group(tb, 1, ws.id)

      assert TabBar.get(tb, 1).group_id == ws.id
      assert TabBar.get(tb, 2).group_id == 0
      assert length(TabBar.tabs_in_group(tb, ws.id)) == 2
    end

    test "tabs_in_group returns correct split after association" do
      {tb, _session, ws} = build_agent_scenario()

      tb = TabBar.move_tab_to_group(tb, 1, ws.id)

      manual_tabs = TabBar.tabs_in_group(tb, 0)
      agent_tabs = TabBar.tabs_in_group(tb, ws.id)

      assert length(manual_tabs) == 1
      assert hd(manual_tabs).label == "main.ex"
      assert length(agent_tabs) == 2
      assert Enum.any?(agent_tabs, &(&1.label == "editor.ex"))
      assert Enum.any?(agent_tabs, &(&1.label == "Agent"))
    end
  end

  describe "workspace lifecycle" do
    test "creating agent workspace assigns session" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      fake_session = spawn(fn -> Process.sleep(:infinity) end)

      {tb, ws} = TabBar.add_agent_group(tb, "Research", fake_session)
      assert ws.session == fake_session
      assert TabBar.find_group_by_session(tb, fake_session) == ws
    end

    test "removing workspace migrates all associated tabs to manual" do
      {tb, _session, ws} = build_agent_scenario()

      # Associate two files with agent workspace
      tb = TabBar.move_tab_to_group(tb, 1, ws.id)
      tb = TabBar.move_tab_to_group(tb, 2, ws.id)

      # All three tabs in agent workspace
      assert length(TabBar.tabs_in_group(tb, ws.id)) == 3

      # Remove workspace
      tb = TabBar.remove_group(tb, ws.id)

      # All tabs back in manual
      assert Enum.all?(tb.tabs, &(&1.group_id == 0))
      assert length(TabBar.tabs_in_group(tb, 0)) == 3
    end

    test "workspace status tracks agent activity" do
      {tb, _session, ws} = build_agent_scenario()

      tb = TabBar.update_group(tb, ws.id, &AgentGroup.set_agent_status(&1, :thinking))
      assert TabBar.get_group(tb, ws.id).agent_status == :thinking

      tb = TabBar.update_group(tb, ws.id, &AgentGroup.set_agent_status(&1, :idle))
      assert TabBar.get_group(tb, ws.id).agent_status == :idle
    end

    test "disclosure tier progresses with agent count" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      assert TabBar.disclosure_tier(tb) == 0

      {tb, _ws1} = TabBar.add_agent_group(tb, "Agent 1")
      assert TabBar.disclosure_tier(tb) == 1

      {tb, _ws2} = TabBar.add_agent_group(tb, "Agent 2")
      assert TabBar.disclosure_tier(tb) == 2
    end

    test "multiple agent workspaces have distinct colors" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, ws1} = TabBar.add_agent_group(tb, "Agent 1")
      {tb, ws2} = TabBar.add_agent_group(tb, "Agent 2")
      {_tb, ws3} = TabBar.add_agent_group(tb, "Agent 3")

      assert ws1.color != ws2.color
      assert ws2.color != ws3.color
      assert ws1.color != ws3.color
    end
  end
end
