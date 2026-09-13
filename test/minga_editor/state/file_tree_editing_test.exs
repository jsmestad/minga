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
    test "default state is closed hidden browse" do
      ft = %FileTreeState{}

      assert FileTreeState.content(ft) == :closed
      assert FileTreeState.status(ft) == :hidden
      refute FileTreeState.loaded?(ft)
      assert FileTreeState.tree(ft) == nil
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
      assert FileTreeState.content(hidden) == FileTreeState.content(opened)
      assert hidden.buffer == opened.buffer
      assert hidden.watchers == opened.watchers

      shown = FileTreeState.show(hidden)
      assert shown.visibility == :focused
      assert FileTreeState.content(shown) == FileTreeState.content(opened)
      assert shown.buffer == opened.buffer
      assert shown.watchers == opened.watchers

      refocused_hidden = FileTreeState.focus(hidden)
      assert refocused_hidden.visibility == :hidden
      refute FileTreeState.focused?(refocused_hidden)
    end

    test "loading, error, close, and root scan publish single content tags" do
      tree = FileTree.new("/tmp") |> FileTree.put_entries([])
      opened = FileTreeState.open(%FileTreeState{}, tree, nil)

      assert FileTreeState.content(FileTreeState.loading(opened)) == {:loading, tree}

      errored = FileTreeState.error(opened, :enoent)
      assert FileTreeState.content(errored) == {:error, "no such file or directory", tree}
      assert FileTreeState.status(errored) == {:error, "no such file or directory"}

      hidden_loading = opened |> FileTreeState.loading() |> FileTreeState.hide()
      assert FileTreeState.status(hidden_loading) == :hidden
      assert FileTreeState.content(hidden_loading) == {:loading, tree}

      hidden_error = opened |> FileTreeState.error(:eacces) |> FileTreeState.hide()
      assert FileTreeState.status(hidden_error) == :hidden
      assert FileTreeState.content(hidden_error) == {:error, "permission denied", tree}

      assert FileTreeState.status(FileTreeState.loading(%FileTreeState{})) == :loading

      assert FileTreeState.status(FileTreeState.error(%FileTreeState{}, :eacces)) ==
               {:error, "permission denied"}

      root_scan = FileTreeState.begin_root_scan(opened, FileTree.new("/other"), :reroot)
      assert {:loading, %FileTree{root: "/other"}} = FileTreeState.content(root_scan)

      closed = FileTreeState.close(opened)
      assert FileTreeState.content(closed) == :closed
      assert FileTreeState.tree(closed) == nil
    end
  end

  describe "interaction" do
    test "start_editing/5 stores the admitted operation token for a new entry" do
      ft = FileTreeState.start_editing(%FileTreeState{}, 3, :new_file, 101)

      assert FileTreeState.editing?(ft)
      assert FileTreeState.editing(ft).index == 3
      assert FileTreeState.editing(ft).type == :new_file
      assert FileTreeState.editing(ft).text == ""
      assert FileTreeState.editing(ft).original_name == nil
      assert FileTreeState.editing(ft).source_path == nil
      assert FileTreeState.editing(ft).token == 101
    end

    test "rename admission captures the source path and a distinct operation token" do
      source = %{path: "/tmp/old.txt", name: "old.txt"}
      ft = FileTreeState.start_rename(%FileTreeState{}, 2, source, 101)

      assert FileTreeState.editing(ft).text == "old.txt"
      assert FileTreeState.editing(ft).original_name == "old.txt"
      assert FileTreeState.editing(ft).type == :rename
      assert FileTreeState.editing(ft).index == 2
      assert FileTreeState.editing(ft).source_path == "/tmp/old.txt"
      assert FileTreeState.editing(ft).token == 101

      replacement =
        FileTreeState.start_rename(ft, 1, %{path: "/tmp/new.txt", name: "new.txt"}, 102)

      refute FileTreeState.editing(replacement).token == FileTreeState.editing(ft).token
    end

    test "native confirmation text is accepted only for the current operation token" do
      ft = FileTreeState.start_editing(%FileTreeState{}, 0, :new_file, 101)
      token = FileTreeState.editing(ft).token

      assert {:stale, ^ft} = FileTreeState.accept_edit_confirmation(ft, token + 1, "wrong.txt")

      assert {:accepted, accepted} =
               FileTreeState.accept_edit_confirmation(ft, token, "right.txt")

      assert FileTreeState.editing(accepted).text == "right.txt"
    end

    test "update_editing_text/2 updates only active editing" do
      ft =
        %FileTreeState{}
        |> FileTreeState.start_editing(0, :new_file, 1)
        |> FileTreeState.update_editing_text("café.txt")

      assert FileTreeState.editing(ft).text == "café.txt"
      assert FileTreeState.update_editing_text(%FileTreeState{}, "ignored").interaction == :browse
    end

    test "cancel_editing/1 returns to browse" do
      ft =
        %FileTreeState{}
        |> FileTreeState.start_editing(0, :new_file, 1, "partial")
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
        |> FileTreeState.start_editing(0, :new_file, 1)
        |> FileTreeState.start_filtering()

      assert filtering.interaction == :filtering
      assert FileTreeState.editing(filtering) == nil

      assert filtering |> FileTreeState.toggle_help() |> then(& &1.interaction) == :help

      editing = FileTreeState.start_editing(opened, 0, :new_file, 1, "name?")
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
             |> FileTreeState.start_editing(0, :new_file, 1)
             |> FileTreeState.loading()
             |> then(& &1.interaction) == :browse

      assert opened
             |> FileTreeState.start_editing(0, :new_file, 1)
             |> FileTreeState.begin_root_scan(tree, :project)
             |> then(& &1.interaction) == :browse

      assert opened
             |> FileTreeState.start_editing(0, :new_file, 1)
             |> FileTreeState.error(:enoent)
             |> then(& &1.interaction) == :browse

      assert opened
             |> FileTreeState.start_editing(0, :new_file, 1)
             |> FileTreeState.close()
             |> then(& &1.interaction) == :browse
    end
  end
end
