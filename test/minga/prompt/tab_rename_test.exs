defmodule Minga.Prompt.TabRenameTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Prompt.TabRename

  describe "label/0" do
    test "returns the prompt label" do
      assert TabRename.label() == "Rename tab: "
    end
  end

  describe "on_submit/2" do
    test "renames the active tab" do
      tb = TabBar.new(Tab.new_file(1, "editor.ex"))
      state = %{tab_bar: tb, status_msg: ""}

      new_state = TabRename.on_submit("My Editor", state)
      assert TabBar.active(new_state.tab_bar).label == "My Editor"
      assert new_state.status_msg =~ "Renamed"
    end

    test "trims whitespace" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      state = %{tab_bar: tb, status_msg: ""}
      new_state = TabRename.on_submit("  neat  ", state)
      assert TabBar.active(new_state.tab_bar).label == "neat"
    end

    test "rejects empty name" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      state = %{tab_bar: tb, status_msg: ""}
      new_state = TabRename.on_submit("", state)
      assert new_state.status_msg =~ "cannot be empty"
      assert TabBar.active(new_state.tab_bar).label == "a.ex"
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex"))}
      assert TabRename.on_cancel(state) == state
    end
  end
end
