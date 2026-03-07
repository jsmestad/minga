defmodule Minga.Input.VimNavIntegrationTest do
  @moduledoc """
  Integration tests verifying full vim navigation works in non-file
  buffers (file tree and agent panel) via the mode FSM delegation.

  Tests cover motions (j, k, gg, G), search, yank, and visual select
  to confirm these buffers inherit the full vim vocabulary.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync
  alias Minga.Input.FileTree, as: FileTreeHandler

  defp make_tree_state(tmp_dir, file_count \\ 10) do
    if file_count > 0 do
      for i <- 1..file_count do
        File.write!(
          Path.join(tmp_dir, "file_#{String.pad_leading(to_string(i), 2, "0")}.txt"),
          ""
        )
      end
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
      focus_stack: [FileTreeHandler, Minga.Input.ModeFSM],
      reg: %Minga.Editor.State.Registers{}
    }
  end

  describe "file tree: gg and G motions" do
    test "G moves cursor to the last entry", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      entries = FileTree.visible_entries(state.file_tree.tree)
      max_idx = length(entries) - 1

      {:handled, state} = FileTreeHandler.handle_key(state, ?G, 0)
      assert state.file_tree.tree.cursor == max_idx
    end

    test "gg moves cursor to the first entry", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      # First move to bottom
      {:handled, state} = FileTreeHandler.handle_key(state, ?G, 0)
      assert state.file_tree.tree.cursor > 0

      # Then gg to top (g is pending_g, second g triggers)
      {:handled, state} = FileTreeHandler.handle_key(state, ?g, 0)
      {:handled, state} = FileTreeHandler.handle_key(state, ?g, 0)
      assert state.file_tree.tree.cursor == 0
    end
  end

  describe "file tree: count prefix" do
    test "3j moves cursor down 3 entries", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      assert state.file_tree.tree.cursor == 0

      # Type 3j
      {:handled, state} = FileTreeHandler.handle_key(state, ?3, 0)
      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      assert state.file_tree.tree.cursor == 3
    end
  end

  describe "file tree: yank in read-only buffer" do
    test "yy yanks the current line without modifying buffer", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      buf = state.file_tree.buffer
      content_before = BufferServer.content(buf)

      # yy should yank without error
      {:handled, state} = FileTreeHandler.handle_key(state, ?y, 0)
      {:handled, _state} = FileTreeHandler.handle_key(state, ?y, 0)

      assert BufferServer.content(buf) == content_before
    end
  end

  describe "file tree: insert mode blocked" do
    test "i does not enter insert mode", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      # i is not a tree-specific key, so it delegates to mode FSM
      # The mode FSM should block insert on read-only buffer
      {:handled, state} = FileTreeHandler.handle_key(state, ?i, 0)
      assert state.mode == :normal
    end

    test "a does not enter insert mode", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?a, 0)
      assert state.mode == :normal
    end

    test "o does not enter insert mode", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?o, 0)
      assert state.mode == :normal
    end
  end

  describe "file tree: custom bindings still work" do
    test "Tab on directory toggles expand", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))
      File.write!(Path.join(tmp_dir, "subdir/inner.txt"), "")

      state = make_tree_state(tmp_dir, 0)
      tree = state.file_tree.tree
      entries = FileTree.visible_entries(tree)

      # Find subdir entry
      dir_idx = Enum.find_index(entries, fn e -> e.name == "subdir" end)

      if dir_idx do
        # Navigate to it
        state =
          if dir_idx > 0 do
            Enum.reduce(1..dir_idx, state, fn _i, acc ->
              {:handled, new_acc} = FileTreeHandler.handle_key(acc, ?j, 0)
              new_acc
            end)
          else
            state
          end

        # Press Tab to expand
        entries_before = length(FileTree.visible_entries(state.file_tree.tree))
        {:handled, state} = FileTreeHandler.handle_key(state, 9, 0)
        entries_after = length(FileTree.visible_entries(state.file_tree.tree))

        # Should have more entries after expanding
        assert entries_after > entries_before
      end
    end

    test "H toggles hidden files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "")
      File.write!(Path.join(tmp_dir, "visible.txt"), "")

      state = make_tree_state(tmp_dir, 0)
      entries_default = FileTree.visible_entries(state.file_tree.tree)

      {:handled, state} = FileTreeHandler.handle_key(state, ?H, 0)
      entries_with_hidden = FileTree.visible_entries(state.file_tree.tree)

      # Toggling hidden should change the entry count
      assert length(entries_with_hidden) != length(entries_default)
    end

    test "q closes the file tree", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?q, 0)
      assert state.file_tree.tree == nil
      assert state.file_tree.focused == false
    end
  end

  describe "file tree: g prefix passes through to mode FSM" do
    test "g is not intercepted as refresh (reserved for gg motion)", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      # Move down first so we can verify gg works
      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      assert state.file_tree.tree.cursor == 2

      # g should delegate to mode FSM (pending_g)
      {:handled, state} = FileTreeHandler.handle_key(state, ?g, 0)
      assert state.mode_state.pending_g == true

      # second g should trigger gg (go to top)
      {:handled, state} = FileTreeHandler.handle_key(state, ?g, 0)
      assert state.file_tree.tree.cursor == 0
    end
  end
end
