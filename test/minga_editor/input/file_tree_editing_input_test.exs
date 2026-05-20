defmodule MingaEditor.Input.FileTreeEditingInputTest do
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

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Viewport
  alias MingaEditor.Input.FileTreeHandler
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
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        file_tree: %FileTreeState{} |> FileTreeState.open(tree, buf),
        keymap_scope: :file_tree
      },
      focus_stack: [MingaEditor.Input.Scoped, MingaEditor.Input.ModeFSM]
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

  describe "file operation and re-root dispatch" do
    test "c then p copies the selected entry into the selected directory", %{tmp_dir: dir} do
      state = make_state(dir) |> select_entry("existing.txt")
      selected_path = Path.join(dir, "existing.txt")
      destination = Path.join([dir, "subdir", "existing.txt"])

      {:handled, state} = FileTreeHandler.handle_key(state, ?c, 0)
      state = select_entry(state, "subdir")
      {:handled, _state} = FileTreeHandler.handle_key(state, ?p, 0)

      assert File.read!(destination) == File.read!(selected_path)
    end

    test ". re-roots to selected directory and ~ returns to original root", %{tmp_dir: dir} do
      state = make_state(dir) |> select_entry("subdir")

      {:handled, state} = FileTreeHandler.handle_key(state, ?., 0)
      assert state.workspace.file_tree.tree.root == Path.join(dir, "subdir")

      {:handled, state} = FileTreeHandler.handle_key(state, ?~, 0)
      assert state.workspace.file_tree.tree.root == Path.expand(dir)
    end
  end

  describe "filter input" do
    test "/ enters filtering, printable keys narrow, Enter accepts, and Escape clears", %{
      tmp_dir: dir
    } do
      state = make_state(dir)
      File.write!(Path.join(dir, "alpha.txt"), "alpha")
      File.write!(Path.join(dir, "beta.txt"), "beta")
      tree = FileTree.refresh(state.workspace.file_tree.tree)
      file_tree = FileTreeState.replace_tree(state.workspace.file_tree, tree)

      state =
        EditorState.update_workspace(
          state,
          &MingaEditor.Session.State.set_file_tree(&1, file_tree)
        )

      {:handled, state} = FileTreeHandler.handle_key(state, ?/, 0)
      assert state.workspace.file_tree.filtering == true

      {:handled, state} = FileTreeHandler.handle_key(state, ?a, 0)
      {:handled, state} = FileTreeHandler.handle_key(state, ?l, 0)
      assert state.workspace.file_tree.tree.filter == "al"
      assert BufferProcess.content(state.workspace.file_tree.buffer) =~ "alpha.txt"
      refute BufferProcess.content(state.workspace.file_tree.buffer) =~ "beta.txt"

      assert Enum.map(FileTree.visible_entries(state.workspace.file_tree.tree), & &1.name) == [
               "alpha.txt"
             ]

      {:handled, state} = FileTreeHandler.handle_key(state, @backspace, 0)
      assert state.workspace.file_tree.tree.filter == "a"

      {:handled, state} = FileTreeHandler.handle_key(state, @enter, 0)
      assert state.workspace.file_tree.filtering == false
      assert state.workspace.file_tree.tree.filter == "a"

      file_tree = FileTreeState.start_filtering(state.workspace.file_tree)

      state =
        EditorState.update_workspace(
          state,
          &MingaEditor.Session.State.set_file_tree(&1, file_tree)
        )

      {:handled, state} = FileTreeHandler.handle_key(state, @escape, 0)
      assert state.workspace.file_tree.filtering == false
      assert state.workspace.file_tree.tree.filter == nil
    end

    test "/ while help is open starts filtering and hides help", %{tmp_dir: dir} do
      state = make_state(dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ??, 0)
      assert state.workspace.file_tree.help_visible == true

      {:handled, state} = FileTreeHandler.handle_key(state, ?/, 0)
      assert state.workspace.file_tree.help_visible == false
      assert state.workspace.file_tree.filtering == true
    end

    test "question mark while filtering shows help and exits filtering", %{tmp_dir: dir} do
      state = make_state(dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?/, 0)
      assert state.workspace.file_tree.filtering == true

      {:handled, state} = FileTreeHandler.handle_key(state, ??, 0)
      assert state.workspace.file_tree.help_visible == true
      refute state.workspace.file_tree.filtering
    end
  end

  describe "help overlay input" do
    test "? toggles help and Escape dismisses it without closing the tree", %{tmp_dir: dir} do
      state = make_state(dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ??, 0)
      assert state.workspace.file_tree.help_visible == true

      {:handled, state} = FileTreeHandler.handle_key(state, @escape, 0)
      assert state.workspace.file_tree.help_visible == false
      assert state.workspace.file_tree.tree != nil
    end
  end

  @spec select_entry(EditorState.t(), String.t()) :: EditorState.t()
  defp select_entry(state, name) do
    entries = FileTree.visible_entries(state.workspace.file_tree.tree)
    index = Enum.find_index(entries, &(&1.name == name))
    refute index == nil

    tree = FileTree.select(state.workspace.file_tree.tree, index)
    file_tree = FileTreeState.replace_tree(state.workspace.file_tree, tree)

    EditorState.update_workspace(
      state,
      &MingaEditor.Session.State.set_file_tree(&1, file_tree)
    )
  end

  describe "key swallowing (no leaking to mode FSM)" do
    test "modifier keys are swallowed during editing", %{tmp_dir: dir} do
      state = make_editing_state(dir, text: "test")

      {:handled, state} = FileTreeHandler.handle_key(state, ?a, 0x02)
      assert state.workspace.file_tree.editing.text == "test"
    end

    test "protocol special keys are swallowed during inline editing", %{tmp_dir: dir} do
      state = make_editing_state(dir, text: "test")

      for code <- [
            57_348,
            57_360,
            57_361,
            57_362,
            57_363,
            57_364,
            57_376,
            0xF700,
            0xF701,
            0xF702,
            0xF703,
            0xF704,
            0xF728
          ] do
        {:handled, state} = FileTreeHandler.handle_key(state, code, 0)
        assert state.workspace.file_tree.editing.text == "test"
        assert state.workspace.file_tree.editing.type == :new_file
      end
    end

    test "protocol special keys are swallowed during filtering", %{tmp_dir: dir} do
      state = make_state(dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?/, 0)
      assert state.workspace.file_tree.filtering == true

      for code <- [
            57_348,
            57_360,
            57_361,
            57_362,
            57_363,
            57_364,
            57_376,
            0xF700,
            0xF701,
            0xF702,
            0xF703,
            0xF704,
            0xF728
          ] do
        {:handled, state} = FileTreeHandler.handle_key(state, code, 0)
        assert state.workspace.file_tree.tree.filter == ""
        assert state.workspace.file_tree.filtering == true
      end
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

    test "help-visible navigation keys are swallowed without moving the buffer cursor", %{
      tmp_dir: dir
    } do
      state = make_state(dir)
      buffer = state.workspace.file_tree.buffer
      before = BufferProcess.cursor(buffer)

      {:handled, state} = FileTreeHandler.handle_key(state, ??, 0)
      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)

      assert state.workspace.file_tree.help_visible == true
      assert BufferProcess.cursor(buffer) == before
      assert state.workspace.file_tree.tree.cursor == 0
    end

    test "q appends to text instead of closing tree", %{tmp_dir: dir} do
      state = make_editing_state(dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?q, 0)
      assert state.workspace.file_tree.editing.text == "q"
      assert state.workspace.file_tree.tree != nil
    end
  end
end
