defmodule MingaEditor.UI.Picker.GitStashSourceTest do
  @moduledoc "Tests for the git stash picker source."
  use ExUnit.Case, async: true

  alias Minga.Git.StashEntry
  alias Minga.Git.Stub, as: GitStub
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.GitStashSource
  alias MingaEditor.UI.Picker.Item

  @moduletag :tmp_dir

  describe "candidates/1" do
    test "formats stash entries from context git root", %{tmp_dir: dir} do
      GitStub.set_stashes(dir, [
        %StashEntry{index: 0, ref: "stash@{0}", date: "2 minutes ago", message: "WIP on main"}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      assert [item] = GitStashSource.candidates(context(dir))
      assert item.id == {:stash, dir, 0, :list}
      assert item.label == "WIP on main"
      assert item.description == "2 minutes ago"
      assert item.annotation == "stash@{0}"
    end

    test "marks entries for default drop when opened in drop mode", %{tmp_dir: dir} do
      GitStub.set_stashes(dir, [
        %StashEntry{index: 1, ref: "stash@{1}", date: "1 hour ago", message: "work in progress"}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      assert [%Item{id: {:stash, ^dir, 1, :drop}}] =
               GitStashSource.candidates(context(dir, :drop))
    end
  end

  describe "selection" do
    test "list mode reports the selected stash message", %{tmp_dir: dir} do
      state = test_state()
      item = %Item{id: {:stash, dir, 0, :list}, label: "WIP on main"}

      assert %{shell_state: %{status_msg: "Stash: WIP on main"}} =
               GitStashSource.on_select(item, state)
    end

    test "drop mode drops the selected stash", %{tmp_dir: dir} do
      state = test_state()
      item = %Item{id: {:stash, dir, 1, :drop}, label: "WIP on feature"}

      assert %{shell_state: %{status_msg: "Dropped stash@{1}"}} =
               GitStashSource.on_select(item, state)
    end

    test "drop action is available from list mode", %{tmp_dir: dir} do
      item = %Item{id: {:stash, dir, 0, :list}, label: "WIP on main"}

      assert GitStashSource.actions(item) == [{"Drop", :drop}]

      assert %{shell_state: %{status_msg: "Dropped stash@{0}"}} =
               GitStashSource.on_action(:drop, item, test_state())
    end
  end

  defp context(git_root, action \\ :list) do
    %Context{
      buffers: nil,
      editing: nil,
      search: nil,
      viewport: nil,
      tab_bar: nil,
      picker_ui: %{context: %{git_root: git_root, action: action}},
      capabilities: %{},
      theme: nil
    }
  end

  defp test_state do
    %{shell_state: %{status_msg: nil}}
  end
end
