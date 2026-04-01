defmodule MingaEditor.UI.Picker.AgentGroupIconSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.UI.Picker.AgentGroupIconSource
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
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

  describe "title/0" do
    test "returns a descriptive title" do
      assert AgentGroupIconSource.title() == "Set Workspace Icon"
    end
  end

  describe "candidates/1" do
    test "returns items for all curated icons" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      items = AgentGroupIconSource.candidates(fake_context(tb))
      assert length(items) > 40
      assert Enum.all?(items, &match?(%Item{}, &1))
    end

    test "marks current group icon with bullet" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_agent_group(tb, "Test")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      tb = TabBar.switch_to_group(tb, group.id)

      items = AgentGroupIconSource.candidates(fake_context(tb))
      cpu_item = Enum.find(items, &(&1.id == "cpu"))
      assert cpu_item.label =~ "\u{2022}"
      other = Enum.find(items, &(&1.id == "brain"))
      refute other.label =~ "\u{2022}"
    end

    test "items include category as description" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      items = AgentGroupIconSource.candidates(fake_context(tb))

      folder_item = Enum.find(items, &(&1.id == "folder"))
      assert folder_item.description == "General"
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

      assert AgentGroupIconSource.candidates(ctx) == []
    end
  end

  describe "on_select/2" do
    test "sets icon on the active agent group" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_agent_group(tb, "Test")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      tb = TabBar.switch_to_group(tb, group.id)

      state = %{shell_state: %{tab_bar: tb}}
      item = %Item{id: "brain", label: "brain"}
      new_state = AgentGroupIconSource.on_select(item, state)
      g = TabBar.active_group(new_state.shell_state.tab_bar)
      assert g.icon == "brain"
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{shell_state: %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex"))}}
      assert AgentGroupIconSource.on_cancel(state) == state
    end
  end
end
