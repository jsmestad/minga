defmodule Minga.Input.FileTreeNavTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync
  alias Minga.Input.FileTree, as: FileTreeHandler

  # Build a minimal EditorState-like map with file tree focused
  defp make_state(tmp_dir, file_count \\ 5) do
    for i <- 1..file_count do
      File.write!(Path.join(tmp_dir, "file_#{String.pad_leading(to_string(i), 2, "0")}.txt"), "")
    end

    tree = FileTree.new(tmp_dir)
    buf = BufferSync.start_buffer(tree)

    %{
      file_tree: %FileTreeState{tree: tree, focused: true, buffer: buf},
      buffers: %{active: nil, list: [], recent: []},
      mode: :normal,
      mode_state: Minga.Mode.initial_state(),
      status_msg: nil,
      key_buffer: [],
      count: nil,
      marks: %{},
      registers: %{},
      change_recorder: ChangeRecorder.new(),
      macro_recorder: MacroRecorder.new(),
      agent: %{panel: %{visible: false}},
      completion: nil,
      conflict: nil,
      focus_stack: [FileTreeHandler, Minga.Input.ModeFSM]
    }
  end

  describe "vim navigation in file tree" do
    test "j moves tree cursor down", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      assert state.file_tree.tree.cursor == 0

      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      assert state.file_tree.tree.cursor == 1

      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      assert state.file_tree.tree.cursor == 2
    end

    test "k moves tree cursor up", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      # Move down first
      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      assert state.file_tree.tree.cursor == 2

      {:handled, state} = FileTreeHandler.handle_key(state, ?k, 0)
      assert state.file_tree.tree.cursor == 1
    end

    test "q closes the file tree", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      {:handled, state} = FileTreeHandler.handle_key(state, ?q, 0)
      assert state.file_tree.tree == nil
      assert state.file_tree.focused == false
      assert state.file_tree.buffer == nil
    end

    test "Escape closes the file tree", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      {:handled, state} = FileTreeHandler.handle_key(state, 27, 0)
      assert state.file_tree.tree == nil
    end

    test "passthrough when tree not focused", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      state = put_in(state.file_tree.focused, false)
      {:passthrough, _state} = FileTreeHandler.handle_key(state, ?j, 0)
    end

    test "passthrough when no tree", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      state = put_in(state.file_tree.tree, nil)
      {:passthrough, _state} = FileTreeHandler.handle_key(state, ?j, 0)
    end

    test "tree cursor stays in bounds", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir, 3)
      entries = FileTree.visible_entries(state.file_tree.tree)
      max_idx = length(entries) - 1

      # Move down past the end
      state =
        Enum.reduce(1..(max_idx + 5), state, fn _i, acc ->
          {:handled, new_acc} = FileTreeHandler.handle_key(acc, ?j, 0)
          new_acc
        end)

      assert state.file_tree.tree.cursor <= max_idx
    end

    test "buffer cursor syncs with tree cursor after j/k", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      buf = state.file_tree.buffer

      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)

      {buf_line, _col} = BufferServer.cursor(buf)
      assert buf_line == state.file_tree.tree.cursor
    end
  end
end
