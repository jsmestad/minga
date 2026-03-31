defmodule MingaEditor.UI.Picker.TabSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.UI.Picker.TabSource
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

      candidates = TabSource.candidates(fake_context(tb))
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

      candidates = TabSource.candidates(fake_context(tb))

      %Item{label: active_label} = Enum.find(candidates, fn %Item{id: id} -> id == 1 end)
      assert String.contains?(active_label, "\u{2022}")

      %Item{label: inactive_label} = Enum.find(candidates, fn %Item{id: id} -> id == 2 end)
      refute String.contains?(inactive_label, "\u{2022}")
    end

    test "agent tabs show agent icon" do
      tab = Tab.new_agent(1, "My Session")
      tb = TabBar.new(tab)

      [%Item{label: label, description: desc}] =
        TabSource.candidates(fake_context(tb))

      assert String.contains?(label, "My Session")
      assert desc == "agent"
    end

    test "returns empty list when tab_bar is not a TabBar struct" do
      # When tab_bar is not a TabBar struct, candidates/1 returns []
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

      assert TabSource.candidates(ctx) == []
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{shell_state: %{tab_bar: TabBar.new(Tab.new_file(1, "x.ex"))}}
      assert TabSource.on_cancel(state) == state
    end
  end
end
