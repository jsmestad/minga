defmodule MingaEditor.UI.Picker.AgentGroupSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.UI.Picker.AgentGroupSource
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Theme

  defp fake_context(tab_bar) do
    %Context{
      buffers: %Buffers{list: [], active: nil, active_index: 0},
      editing: VimState.new(),
      file_tree: nil,
      search: %Search{},
      viewport: Viewport.new(80, 24),
      tab_bar: tab_bar,
      agent_session: nil,
      picker_ui: %{},
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end

  describe "candidates/1" do
    test "returns one item per agent group with tabs" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_agent_group(tb, "Research")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)

      items = AgentGroupSource.candidates(fake_context(tb))
      assert length(items) == 1
      assert hd(items).id == group.id
    end

    test "filters out groups with no tabs" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add_agent_group(tb, "Empty")

      items = AgentGroupSource.candidates(fake_context(tb))
      assert items == []
    end

    test "shows file names in description" do
      tb = TabBar.new(Tab.new_file(1, "editor.ex"))
      {tb, _} = TabBar.add(tb, :file, "main.ex")
      {tb, group} = TabBar.add_agent_group(tb, "Work")
      tb = TabBar.move_tab_to_group(tb, 1, group.id)
      tb = TabBar.move_tab_to_group(tb, 2, group.id)

      [item] = AgentGroupSource.candidates(fake_context(tb))
      assert item.description =~ "editor.ex"
      assert item.description =~ "main.ex"
    end

    test "returns empty for context without TabBar struct" do
      ctx = %Context{
        buffers: %Buffers{list: [], active: nil, active_index: 0},
        editing: VimState.new(),
        file_tree: nil,
        search: %Search{},
        viewport: Viewport.new(80, 24),
        tab_bar: %{},
        agent_session: nil,
        picker_ui: %{},
        capabilities: %{},
        theme: Theme.get!(:doom_one)
      }

      assert AgentGroupSource.candidates(ctx) == []
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
      state = %{shell_state: %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex"))}}
      assert AgentGroupSource.on_cancel(state) == state
    end
  end
end
