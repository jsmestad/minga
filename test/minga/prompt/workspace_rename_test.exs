defmodule Minga.Prompt.WorkspaceRenameTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Prompt.WorkspaceRename

  describe "label/0" do
    test "returns the prompt label" do
      assert WorkspaceRename.label() == "Rename workspace: "
    end
  end

  describe "on_submit/2" do
    test "renames the active workspace and sets status message" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, ws} = TabBar.add_agent_workspace(tb, "Agent")
      # Put a tab in the agent workspace so switch works
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      tb = TabBar.move_tab_to_workspace(tb, 2, ws.id)
      tb = TabBar.switch_workspace(tb, ws.id)
      state = %{tab_bar: tb, status_msg: ""}

      new_state = WorkspaceRename.on_submit("Research Bot", state)
      assert TabBar.active_workspace(new_state.tab_bar).label == "Research Bot"
      assert TabBar.active_workspace(new_state.tab_bar).custom_name == true
      assert new_state.status_msg =~ "Renamed"
    end

    test "trims whitespace from name" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      state = %{tab_bar: tb, status_msg: ""}
      new_state = WorkspaceRename.on_submit("  My Space  ", state)
      assert TabBar.active_workspace(new_state.tab_bar).label == "My Space"
    end

    test "rejects empty name with error message" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      state = %{tab_bar: tb, status_msg: ""}
      new_state = WorkspaceRename.on_submit("", state)
      assert new_state.status_msg =~ "cannot be empty"
    end

    test "rejects whitespace-only name" do
      state = %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex")), status_msg: ""}
      new_state = WorkspaceRename.on_submit("   ", state)
      assert new_state.status_msg =~ "cannot be empty"
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex"))}
      assert WorkspaceRename.on_cancel(state) == state
    end
  end
end
