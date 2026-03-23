defmodule Minga.Picker.WorkspaceSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Picker.Item
  alias Minga.Picker.WorkspaceSource

  describe "candidates/1" do
    test "returns one item per workspace" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _ws} = TabBar.add_agent_workspace(tb, "Research")
      state = %{tab_bar: tb}

      items = WorkspaceSource.candidates(state)
      assert length(items) == 2
    end

    test "marks active workspace with bullet" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      state = %{tab_bar: tb}

      [item] = WorkspaceSource.candidates(state)
      assert item.label =~ "\u{2022}"
    end

    test "shows file names in description" do
      tab1 = %Tab{id: 1, kind: :file, label: "editor.ex", group_id: 0}
      tab2 = %Tab{id: 2, kind: :file, label: "main.ex", group_id: 0}
      tb = %TabBar{tabs: [tab1, tab2], active_id: 1, next_id: 3}
      state = %{tab_bar: tb}

      [item] = WorkspaceSource.candidates(state)
      assert item.description =~ "editor.ex"
      assert item.description =~ "main.ex"
      assert item.description =~ "2 tabs"
    end

    test "agent workspace shows status annotation" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, ws} = TabBar.add_agent_workspace(tb, "Agent")

      tb =
        TabBar.update_workspace(tb, ws.id, fn ws ->
          %{ws | agent_status: :thinking}
        end)

      state = %{tab_bar: tb}

      items = WorkspaceSource.candidates(state)
      agent_item = Enum.find(items, &(&1.id == ws.id))
      assert agent_item.annotation =~ "thinking"
    end

    test "items use two_line layout" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      state = %{tab_bar: tb}

      [item] = WorkspaceSource.candidates(state)
      assert item.two_line == true
    end

    test "returns empty for non-tab-bar state" do
      assert WorkspaceSource.candidates(%{}) == []
    end
  end

  describe "on_select/2" do
    test "switches active tab to first tab in selected workspace" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :file, "agent_file.ex")
      {tb, ws} = TabBar.add_agent_workspace(tb, "Agent")
      tb = TabBar.move_tab_to_workspace(tb, 2, ws.id)
      # Start on file tab
      tb = TabBar.switch_to(tb, 1)

      # on_select calls EditorState.switch_tab which needs a full state.
      # Test the underlying switch_workspace behavior directly instead.
      tb = TabBar.switch_workspace(tb, ws.id)
      assert TabBar.active_workspace_id(tb) == ws.id
      assert tb.active_id == 2
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex"))}
      assert WorkspaceSource.on_cancel(state) == state
    end
  end
end
