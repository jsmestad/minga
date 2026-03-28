defmodule Minga.Input.FileTreeEditingInputTest do
  @moduledoc """
  Tests for inline editing key capture in the file tree handler.

  Verifies that when editing is active, all keys are captured (never
  :passthrough), printable chars append to text, Backspace deletes,
  Enter confirms, Escape cancels, and no keys leak to the mode FSM.

  Uses direct handler calls on constructed state (Layer 2), following
  the pattern from file_tree_nav_test.exs.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.Viewport
  alias Minga.Input.FileTreeHandler
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync

  @enter 13
  @escape 27
  @backspace 127

  defp make_state(tmp_dir) do
    File.write!(Path.join(tmp_dir, "existing.txt"), "content")
    File.mkdir_p!(Path.join(tmp_dir, "subdir"))

    tree = FileTree.new(tmp_dir)
    buf = BufferSync.start_buffer(tree)

    %EditorState{
      port_manager: self(),
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80),
        file_tree: %FileTreeState{tree: tree, focused: true, buffer: buf},
        keymap_scope: :file_tree
      },
      focus_stack: [Minga.Input.Scoped, Minga.Input.ModeFSM]
    }
  end

  defp make_editing_state(tmp_dir, opts \\ []) do
    state = make_state(tmp_dir)
    type = Keyword.get(opts, :type, :new_file)
    text = Keyword.get(opts, :text, "")
    index = state.workspace.file_tree.tree.cursor

    ft = FileTreeState.start_editing(state.workspace.file_tree, index, type, text)
    put_in(state.workspace.file_tree, ft)
  end

  describe "printable character input" do
    test "appends character to editing text", %{tmp_dir: dir} do
      state = make_editing_state(dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?h, 0)
      assert state.workspace.file_tree.editing.text == "h"

      {:handled, state} = FileTreeHandler.handle_key(state, ?e, 0)
      assert state.workspace.file_tree.editing.text == "he"

      {:handled, state} = FileTreeHandler.handle_key(state, ?l, 0)
      assert state.workspace.file_tree.editing.text == "hel"
    end

    test "handles unicode codepoints", %{tmp_dir: dir} do
      state = make_editing_state(dir)

      {:handled, state} = FileTreeHandler.handle_key(state, 0x00E9, 0)
      assert state.workspace.file_tree.editing.text == "é"
    end
  end

  describe "Enter confirms editing" do
    test "clears editing state on Enter", %{tmp_dir: dir} do
      state = make_editing_state(dir, text: "test.txt")

      {:handled, state} = FileTreeHandler.handle_key(state, @enter, 0)
      assert state.workspace.file_tree.editing == nil
    end
  end

  describe "Escape cancels editing" do
    test "clears editing state on Escape", %{tmp_dir: dir} do
      state = make_editing_state(dir, text: "partial")

      {:handled, state} = FileTreeHandler.handle_key(state, @escape, 0)
      assert state.workspace.file_tree.editing == nil
    end
  end

  describe "Backspace" do
    test "deletes last grapheme", %{tmp_dir: dir} do
      state = make_editing_state(dir, text: "abc")

      {:handled, state} = FileTreeHandler.handle_key(state, @backspace, 0)
      assert state.workspace.file_tree.editing.text == "ab"
    end

    test "cancels editing when text is empty", %{tmp_dir: dir} do
      state = make_editing_state(dir, text: "")

      {:handled, state} = FileTreeHandler.handle_key(state, @backspace, 0)
      assert state.workspace.file_tree.editing == nil
    end

    test "handles multi-byte unicode correctly", %{tmp_dir: dir} do
      state = make_editing_state(dir, text: "café")

      {:handled, state} = FileTreeHandler.handle_key(state, @backspace, 0)
      assert state.workspace.file_tree.editing.text == "caf"
    end
  end

  describe "key swallowing (no leaking to mode FSM)" do
    test "modifier keys are swallowed during editing", %{tmp_dir: dir} do
      state = make_editing_state(dir, text: "test")

      {:handled, state} = FileTreeHandler.handle_key(state, ?a, 0x02)
      assert state.workspace.file_tree.editing.text == "test"
    end

    test "Tab is swallowed during editing", %{tmp_dir: dir} do
      state = make_editing_state(dir, text: "test")

      {:handled, state} = FileTreeHandler.handle_key(state, 9, 0)
      assert state.workspace.file_tree.editing.text == "test"
    end

    test "vim navigation keys append as text instead of moving cursor", %{tmp_dir: dir} do
      state = make_editing_state(dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      assert state.workspace.file_tree.editing.text == "j"

      {:handled, state} = FileTreeHandler.handle_key(state, ?k, 0)
      assert state.workspace.file_tree.editing.text == "jk"

      {:handled, state} = FileTreeHandler.handle_key(state, ?d, 0)
      assert state.workspace.file_tree.editing.text == "jkd"
    end

    test "q appends to text instead of closing tree", %{tmp_dir: dir} do
      state = make_editing_state(dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?q, 0)
      assert state.workspace.file_tree.editing.text == "q"
      assert state.workspace.file_tree.tree != nil
    end
  end
end
