defmodule Minga.Picker.WorkspaceIconSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Picker.Item
  alias Minga.Picker.WorkspaceIconSource

  describe "title/0" do
    test "returns a descriptive title" do
      assert WorkspaceIconSource.title() == "Set Workspace Icon"
    end
  end

  describe "candidates/1" do
    test "returns items for all curated icons" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      items = WorkspaceIconSource.candidates(%{tab_bar: tb})
      assert length(items) > 40
      assert Enum.all?(items, &match?(%Item{}, &1))
    end

    test "marks current workspace icon with bullet" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      items = WorkspaceIconSource.candidates(%{tab_bar: tb})
      doc_item = Enum.find(items, &(&1.id == "doc.on.doc"))
      assert doc_item.label =~ "\u{2022}"
      other = Enum.find(items, &(&1.id == "brain"))
      refute other.label =~ "\u{2022}"
    end

    test "items include category as description" do
      items = WorkspaceIconSource.candidates(%{tab_bar: TabBar.new(Tab.new_file(1, "a.ex"))})
      folder_item = Enum.find(items, &(&1.id == "folder"))
      assert folder_item.description == "General"
      cpu_item = Enum.find(items, &(&1.id == "cpu"))
      assert cpu_item.description == "Code"
    end

    test "returns empty for state without tab_bar" do
      assert WorkspaceIconSource.candidates(%{}) == []
    end
  end

  describe "on_select/2" do
    test "sets icon on the active workspace" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      state = %{tab_bar: tb}
      item = %Item{id: "brain", label: "brain"}
      new_state = WorkspaceIconSource.on_select(item, state)
      ws = TabBar.active_workspace(new_state.tab_bar)
      assert ws.icon == "brain"
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex"))}
      assert WorkspaceIconSource.on_cancel(state) == state
    end
  end
end
