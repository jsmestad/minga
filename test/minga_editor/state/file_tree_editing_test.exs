defmodule MingaEditor.State.FileTreeEditingTest do
  @moduledoc """
  Pure unit tests for the inline editing state on FileTree sub-state.

  Tests start_editing/4, update_editing_text/2, cancel_editing/1, and
  editing?/1. No GenServer, no processes, just struct manipulation.
  """
  use ExUnit.Case, async: true

  alias MingaEditor.State.FileTree, as: FileTreeState

  alias Minga.Project.FileTree

  describe "visibility" do
    test "default state is hidden browse" do
      ft = %FileTreeState{}

      assert ft.visibility == :hidden
      assert ft.interaction == :browse
      refute FileTreeState.focused?(ft)
      refute FileTreeState.editing?(ft)
      assert FileTreeState.editing(ft) == nil
    end

    test "open, focus, unfocus, hide, and show keep loaded data coherent" do
      tree = FileTree.new("/tmp") |> FileTree.put_entries([])
      opened = FileTreeState.open(%FileTreeState{}, tree, self())

      assert opened.visibility == :focused
      assert opened |> FileTreeState.unfocus() |> then(& &1.visibility) == :visible

      assert opened |> FileTreeState.unfocus() |> FileTreeState.focus() |> then(& &1.visibility) ==
               :focused

      hidden = FileTreeState.hide(opened)

      assert hidden.visibility == :hidden
      assert hidden.interaction == :browse
      assert FileTreeState.status(hidden) == :hidden
      assert FileTreeState.loaded?(hidden)
      assert hidden.tree == opened.tree
      assert hidden.buffer == opened.buffer
      assert hidden.watchers == opened.watchers

      shown = FileTreeState.show(hidden)
      assert shown.visibility == :focused
      assert shown.tree == opened.tree
      assert shown.buffer == opened.buffer
      assert shown.watchers == opened.watchers

      refocused_hidden = FileTreeState.focus(hidden)
      assert refocused_hidden.visibility == :hidden
      refute FileTreeState.focused?(refocused_hidden)
    end
  end

  describe "interaction" do
    test "start_editing/4 stores editing payload" do
      ft = FileTreeState.start_editing(%FileTreeState{}, 3, :new_file)

      assert FileTreeState.editing?(ft)
      assert FileTreeState.editing(ft).index == 3
      assert FileTreeState.editing(ft).type == :new_file
      assert FileTreeState.editing(ft).text == ""
      assert FileTreeState.editing(ft).original_name == nil
    end

    test "rename pre-fills text and original_name" do
      ft = FileTreeState.start_editing(%FileTreeState{}, 2, :rename, "old.txt")

      assert FileTreeState.editing(ft).text == "old.txt"
      assert FileTreeState.editing(ft).original_name == "old.txt"
      assert FileTreeState.editing(ft).type == :rename
      assert FileTreeState.editing(ft).index == 2
    end

    test "update_editing_text/2 updates only active editing" do
      ft =
        %FileTreeState{}
        |> FileTreeState.start_editing(0, :new_file)
        |> FileTreeState.update_editing_text("café.txt")

      assert FileTreeState.editing(ft).text == "café.txt"
      assert FileTreeState.update_editing_text(%FileTreeState{}, "ignored").interaction == :browse
    end

    test "cancel_editing/1 returns to browse" do
      ft =
        %FileTreeState{}
        |> FileTreeState.start_editing(0, :new_file, "partial")
        |> FileTreeState.cancel_editing()

      assert ft.interaction == :browse
      assert FileTreeState.editing(ft) == nil
      assert FileTreeState.cancel_editing(%FileTreeState{}).interaction == :browse
    end

    test "editing, filtering, and help are mutually exclusive" do
      tree = FileTree.new("/tmp") |> FileTree.put_entries([])
      opened = FileTreeState.open(%FileTreeState{}, tree, nil)

      filtering =
        opened
        |> FileTreeState.start_editing(0, :new_file)
        |> FileTreeState.start_filtering()

      assert filtering.interaction == :filtering
      assert FileTreeState.editing(filtering) == nil

      assert filtering |> FileTreeState.toggle_help() |> then(& &1.interaction) == :help

      editing = FileTreeState.start_editing(opened, 0, :new_file, "name?")
      assert FileTreeState.toggle_help(editing).interaction == editing.interaction
    end

    test "dismissal transitions clear transient interaction" do
      tree = FileTree.new("/tmp") |> FileTree.put_entries([])
      opened = FileTreeState.open(%FileTreeState{}, tree, nil)

      assert opened
             |> FileTreeState.toggle_help()
             |> FileTreeState.hide_help()
             |> then(& &1.interaction) == :browse

      assert FileTreeState.hide_help(opened).interaction == :browse

      assert opened
             |> FileTreeState.start_editing(0, :new_file)
             |> FileTreeState.loading()
             |> then(& &1.interaction) == :browse

      assert opened
             |> FileTreeState.start_editing(0, :new_file)
             |> FileTreeState.begin_root_scan(tree, :project)
             |> then(& &1.interaction) == :browse

      assert opened
             |> FileTreeState.start_editing(0, :new_file)
             |> FileTreeState.error(:enoent)
             |> then(& &1.interaction) == :browse

      assert opened
             |> FileTreeState.start_editing(0, :new_file)
             |> FileTreeState.close()
             |> then(& &1.interaction) == :browse
    end
  end
end
