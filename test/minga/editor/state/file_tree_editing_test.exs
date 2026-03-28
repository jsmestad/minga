defmodule Minga.Editor.State.FileTreeEditingTest do
  @moduledoc """
  Pure unit tests for the inline editing state on FileTree sub-state.

  Tests start_editing/4, update_editing_text/2, cancel_editing/1, and
  editing?/1. No GenServer, no processes, just struct manipulation.
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.State.FileTree, as: FileTreeState

  describe "editing?/1" do
    test "returns false when editing is nil" do
      assert FileTreeState.editing?(%FileTreeState{}) == false
    end

    test "returns true when editing state exists" do
      ft = FileTreeState.start_editing(%FileTreeState{}, 0, :new_file)
      assert FileTreeState.editing?(ft) == true
    end
  end

  describe "start_editing/4" do
    test "sets index, type, and empty text for new file" do
      ft = FileTreeState.start_editing(%FileTreeState{}, 3, :new_file)

      assert ft.editing.index == 3
      assert ft.editing.type == :new_file
      assert ft.editing.text == ""
      assert ft.editing.original_name == nil
    end

    test "sets type correctly for new folder" do
      ft = FileTreeState.start_editing(%FileTreeState{}, 1, :new_folder)

      assert ft.editing.type == :new_folder
      assert ft.editing.text == ""
      assert ft.editing.original_name == nil
    end

    test "pre-fills text and original_name for rename" do
      ft = FileTreeState.start_editing(%FileTreeState{}, 2, :rename, "old.txt")

      assert ft.editing.text == "old.txt"
      assert ft.editing.original_name == "old.txt"
      assert ft.editing.type == :rename
      assert ft.editing.index == 2
    end

    test "works at index 0" do
      ft = FileTreeState.start_editing(%FileTreeState{}, 0, :new_file)
      assert ft.editing.index == 0
    end

    test "handles unicode filename for rename" do
      ft = FileTreeState.start_editing(%FileTreeState{}, 0, :rename, "日本語.txt")

      assert ft.editing.text == "日本語.txt"
      assert ft.editing.original_name == "日本語.txt"
    end
  end

  describe "update_editing_text/2" do
    test "replaces text when editing is active" do
      ft =
        %FileTreeState{}
        |> FileTreeState.start_editing(0, :new_file)
        |> FileTreeState.update_editing_text("new_name.ex")

      assert ft.editing.text == "new_name.ex"
      assert ft.editing.type == :new_file
      assert ft.editing.index == 0
    end

    test "is a no-op when editing is nil" do
      ft = FileTreeState.update_editing_text(%FileTreeState{}, "ignored")
      assert ft.editing == nil
    end

    test "handles empty string (clearing text)" do
      ft =
        %FileTreeState{}
        |> FileTreeState.start_editing(0, :new_file, "something")
        |> FileTreeState.update_editing_text("")

      assert ft.editing.text == ""
    end

    test "handles unicode text" do
      ft =
        %FileTreeState{}
        |> FileTreeState.start_editing(0, :new_file)
        |> FileTreeState.update_editing_text("café.txt")

      assert ft.editing.text == "café.txt"
    end
  end

  describe "cancel_editing/1" do
    test "clears editing back to nil" do
      ft =
        %FileTreeState{}
        |> FileTreeState.start_editing(0, :new_file, "partial")
        |> FileTreeState.cancel_editing()

      assert ft.editing == nil
    end

    test "is idempotent on nil editing" do
      ft = FileTreeState.cancel_editing(%FileTreeState{})
      assert ft.editing == nil
    end
  end

  describe "close/1 clears editing" do
    test "close resets editing to nil" do
      ft =
        %FileTreeState{}
        |> FileTreeState.start_editing(0, :new_file)
        |> FileTreeState.close()

      assert ft.editing == nil
      assert ft.tree == nil
    end
  end
end
