defmodule MingaEditor.Input.VimNavIntegrationTest do
  @moduledoc """
  Integration tests verifying full vim navigation works in non-file
  buffers (file tree and agent panel) via mode FSM delegation through
  the keymap scope system.

  Tests cover motions (j, k, gg, G), count prefix, path copy, insert mode
  blocking, and tree-specific keys to confirm these buffers inherit the
  full vim vocabulary while scope-specific bindings take priority.
  """
  use ExUnit.Case, async: true

  import Hammox

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Input.FileTreeHandler
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Viewport
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync

  setup :verify_on_exit!

  setup do
    test_pid = self()

    stub(Minga.Clipboard.Mock, :write, fn text ->
      send(test_pid, {:clipboard_written, text})
      :ok
    end)

    stub(Minga.Clipboard.Mock, :read, fn -> nil end)

    :ok
  end

  defp ft(state), do: EditorState.file_tree_state(state)

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

    %EditorState{
      port_manager: self(),
      workspace:
        %SessionState{viewport: Viewport.new(24, 80), keymap_scope: :file_tree}
        |> SessionState.set_file_tree(%FileTreeState{tree: tree, focused: true, buffer: buf}),
      focus_stack: [Scoped, MingaEditor.Input.ModeFSM]
    }
  end

  describe "file tree: gg and G motions" do
    test "G moves cursor to the last entry", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      entries = FileTree.visible_entries(ft(state).tree)
      max_idx = length(entries) - 1

      {:handled, state} = FileTreeHandler.handle_key(state, ?G, 0)
      assert ft(state).tree.cursor == max_idx
    end

    test "gg moves cursor to the first entry", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      # First move to bottom
      {:handled, state} = FileTreeHandler.handle_key(state, ?G, 0)
      assert ft(state).tree.cursor > 0

      # Then gg to top (g enters prefix trie, second g triggers)
      {:handled, state} = FileTreeHandler.handle_key(state, ?g, 0)
      {:handled, state} = FileTreeHandler.handle_key(state, ?g, 0)
      assert ft(state).tree.cursor == 0
    end
  end

  describe "file tree: count prefix" do
    test "3j moves cursor down 3 entries", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      assert ft(state).tree.cursor == 0

      # Type 3j
      {:handled, state} = FileTreeHandler.handle_key(state, ?3, 0)
      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      assert ft(state).tree.cursor == 3
    end
  end

  describe "file tree: copy path" do
    test "y copies the selected path without modifying the read-only tree buffer", %{
      tmp_dir: tmp_dir
    } do
      state = make_tree_state(tmp_dir)
      buf = ft(state).buffer
      content_before = BufferProcess.content(buf)
      selected_path = FileTree.selected_entry(ft(state).tree).path

      {:handled, _state} = FileTreeHandler.handle_key(state, ?y, 0)

      assert BufferProcess.content(buf) == content_before
      assert_receive {:clipboard_written, ^selected_path}, 200
    end
  end

  describe "file tree: insert mode blocked" do
    test "i does not enter insert mode", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      # i is not a tree-specific key, so it delegates to mode FSM
      # The mode FSM should block insert on read-only buffer
      {:handled, state} = FileTreeHandler.handle_key(state, ?i, 0)
      assert state.workspace.editing.mode == :normal
    end

    test "a does not enter insert mode", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?a, 0)
      assert state.workspace.editing.mode == :normal
    end

    test "o does not enter insert mode", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?o, 0)
      assert state.workspace.editing.mode == :normal
    end
  end

  describe "file tree: custom bindings still work" do
    test "Tab on directory toggles expand", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))
      File.write!(Path.join(tmp_dir, "subdir/inner.txt"), "")

      state = make_tree_state(tmp_dir, 0)
      tree = ft(state).tree
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
        entries_before = length(FileTree.visible_entries(ft(state).tree))
        {:handled, state} = FileTreeHandler.handle_key(state, 9, 0)
        entries_after = length(FileTree.visible_entries(ft(state).tree))

        # Should have more entries after expanding
        assert entries_after > entries_before
      end
    end

    test "H toggles hidden files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "")
      File.write!(Path.join(tmp_dir, "visible.txt"), "")

      state = make_tree_state(tmp_dir, 0)
      entries_default = FileTree.visible_entries(ft(state).tree)

      {:handled, state} = FileTreeHandler.handle_key(state, ?H, 0)
      entries_with_hidden = FileTree.visible_entries(ft(state).tree)

      # Toggling hidden should change the entry count
      assert length(entries_with_hidden) != length(entries_default)
    end

    test "q closes the file tree", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      {:handled, state} = FileTreeHandler.handle_key(state, ?q, 0)
      assert ft(state).tree == nil
      assert ft(state).focused == false
    end
  end

  describe "file tree: g prefix passes through to mode FSM" do
    test "g is not intercepted as refresh (reserved for gg motion)", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      # Move down first so we can verify gg works
      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      {:handled, state} = FileTreeHandler.handle_key(state, ?j, 0)
      assert ft(state).tree.cursor == 2

      # g should delegate to mode FSM (prefix trie)
      {:handled, state} = FileTreeHandler.handle_key(state, ?g, 0)
      assert state.workspace.editing.mode_state.prefix_node != nil

      # second g should trigger gg (go to top)
      {:handled, state} = FileTreeHandler.handle_key(state, ?g, 0)
      assert ft(state).tree.cursor == 0
    end
  end
end
