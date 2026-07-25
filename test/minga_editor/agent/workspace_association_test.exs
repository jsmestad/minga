defmodule MingaEditor.Agent.WorkspaceAssociationTest do
  @moduledoc """
  Tests for agent workspace association logic.

  Tests the TabBar-level operations for workspace file association
  and lifecycle (creation, migration, removal).
  """
  use ExUnit.Case, async: true

  alias MingaEditor.State.Tab
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.State.TabBar

  defp fake_session_pid do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end

  defp build_agent_scenario do
    fake_session = fake_session_pid()

    tab1 = Tab.new_file(1, "editor.ex")
    tab2 = Tab.new_file(2, "main.ex")
    tab3 = Tab.new_agent(3, "Agent")
    tab3 = Tab.set_session(tab3, fake_session)

    tb = %TabBar{tabs: [tab1, tab2, tab3], active_id: 3, next_id: 4}

    # Create workspace and assign agent tab
    {tb, ws} = TabBar.add_workspace(tb, "Agent", fake_session)
    tb = TabBar.move_tab_to_workspace(tb, 3, ws.id)

    {tb, fake_session, ws}
  end

  describe "agent file association" do
    test "move_tab_to_workspace associates file with agent workspace" do
      {tb, _session, ws} = build_agent_scenario()

      # Simulate what file_changed handler does: move the file tab to agent workspace
      tb = TabBar.move_tab_to_workspace(tb, 1, ws.id)

      assert TabBar.get(tb, 1).group_id == ws.id
      assert TabBar.get(tb, 2).group_id == 0
      assert Enum.count(TabBar.tabs_in_workspace(tb, ws.id)) == 2
    end

    test "tabs_in_workspace returns correct split after association" do
      {tb, _session, ws} = build_agent_scenario()

      tb = TabBar.move_tab_to_workspace(tb, 1, ws.id)

      manual_tabs = TabBar.tabs_in_workspace(tb, 0)
      agent_tabs = TabBar.tabs_in_workspace(tb, ws.id)

      assert Enum.count(manual_tabs) == 1
      assert hd(manual_tabs).label == "main.ex"
      assert Enum.count(agent_tabs) == 2
      assert Enum.any?(agent_tabs, &(&1.label == "editor.ex"))
      assert Enum.any?(agent_tabs, &(&1.label == "Agent"))
    end
  end

  describe "workspace lifecycle" do
    test "creating agent workspace assigns session" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      fake_session = fake_session_pid()

      {tb, ws} = TabBar.add_workspace(tb, "Research", fake_session)
      assert %WorkspaceAgent{session: ^fake_session} = ws.payload
      assert TabBar.find_workspace_by_session(tb, fake_session) == ws
    end

    test "removing workspace migrates all associated tabs to manual" do
      {tb, _session, ws} = build_agent_scenario()

      # Associate two files with agent workspace
      tb = TabBar.move_tab_to_workspace(tb, 1, ws.id)
      tb = TabBar.move_tab_to_workspace(tb, 2, ws.id)

      # All three tabs in agent workspace
      assert Enum.count(TabBar.tabs_in_workspace(tb, ws.id)) == 3

      # Remove workspace
      tb = TabBar.remove_workspace(tb, ws.id)

      # All tabs back in manual
      assert Enum.all?(tb.tabs, &(&1.group_id == 0))
      assert Enum.count(TabBar.tabs_in_workspace(tb, 0)) == 3
    end

    test "workspace status tracks agent activity" do
      {tb, _session, ws} = build_agent_scenario()

      tb = TabBar.set_workspace_agent_status(tb, ws.id, :thinking)
      assert %WorkspaceAgent{agent_status: :thinking} = TabBar.get_workspace(tb, ws.id).payload

      tb = TabBar.set_workspace_agent_status(tb, ws.id, :idle)
      assert %WorkspaceAgent{agent_status: :idle} = TabBar.get_workspace(tb, ws.id).payload
    end

    test "disclosure tier progresses with agent count" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      assert TabBar.disclosure_tier(tb) == 0

      {tb, _ws1} = TabBar.add_workspace(tb, "Agent 1")
      assert TabBar.disclosure_tier(tb) == 1

      {tb, _ws2} = TabBar.add_workspace(tb, "Agent 2")
      assert TabBar.disclosure_tier(tb) == 2
    end

    test "multiple agent workspaces have distinct colors" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, ws1} = TabBar.add_workspace(tb, "Agent 1")
      {tb, ws2} = TabBar.add_workspace(tb, "Agent 2")
      {_tb, ws3} = TabBar.add_workspace(tb, "Agent 3")

      assert ws1.color != ws2.color
      assert ws2.color != ws3.color
      assert ws1.color != ws3.color
    end
  end
end
