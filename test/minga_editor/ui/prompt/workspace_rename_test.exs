defmodule MingaEditor.UI.Prompt.WorkspaceRenameTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Prompt.WorkspaceRename
  alias MingaEditor.Viewport

  describe "label/0" do
    test "returns the prompt label" do
      assert WorkspaceRename.label() == "Rename workspace: "
    end
  end

  describe "on_submit/2" do
    test "renames the active workspace" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_workspace(tb, "Agent")
      tb = TabBar.move_tab_to_workspace(tb, 2, group.id)
      tb = TabBar.switch_to_workspace(tb, group.id)
      state = state_with_tab_bar(tb)

      new_state = WorkspaceRename.on_submit("Research Bot", state)

      assert TabBar.active_workspace(new_state.shell_runtime.state.tab_bar).label ==
               "Research Bot"

      assert TabBar.active_workspace(new_state.shell_runtime.state.tab_bar).custom_name ==
               "Research Bot"

      assert new_state.shell_runtime.state.status_msg =~ "Renamed"
    end

    test "trims whitespace from name" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_workspace(tb, "Agent")
      tb = TabBar.move_tab_to_workspace(tb, 2, group.id)
      tb = TabBar.switch_to_workspace(tb, group.id)
      state = state_with_tab_bar(tb)

      new_state = WorkspaceRename.on_submit("  My Space  ", state)
      assert TabBar.active_workspace(new_state.shell_runtime.state.tab_bar).label == "My Space"
    end

    test "rejects empty name with error message" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      state = state_with_tab_bar(tb)
      new_state = WorkspaceRename.on_submit("", state)
      assert new_state.shell_runtime.state.status_msg =~ "cannot be empty"
    end

    test "rejects whitespace-only name" do
      state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "a.ex")))

      new_state = WorkspaceRename.on_submit("   ", state)
      assert new_state.shell_runtime.state.status_msg =~ "cannot be empty"
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "a.ex")))

      assert WorkspaceRename.on_cancel(state) == state
    end
  end

  defp state_with_tab_bar(tab_bar) do
    %EditorState{
      port_manager: self(),
      workspace: %SessionState{viewport: Viewport.new(24, 80)},
      shell_runtime:
        Runtime.new(Runtime.default_entry(), %TraditionalState{tab_bar: tab_bar, status_msg: ""})
    }
  end
end
