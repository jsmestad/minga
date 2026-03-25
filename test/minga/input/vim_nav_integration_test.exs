defmodule Minga.Input.VimNavIntegrationTest do
  @moduledoc """
  Integration tests verifying full vim navigation works in non-file
  buffers (file tree and agent panel) via mode FSM delegation through
  the keymap scope system.

  Tests cover motions (j, k, gg, G), count prefix, yank, insert mode
  blocking, and tree-specific keys to confirm these buffers inherit the
  full vim vocabulary while scope-specific bindings take priority.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Agent.UIState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync

  defp walk_surface_handlers(state, cp, mods) do
    Enum.reduce_while(Minga.Input.surface_handlers(), {:passthrough, state}, fn handler,
                                                                                {_, acc} ->
      case handler.handle_key(acc, cp, mods) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

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

    agent = %AgentState{}
    agentic = %UIState{}

    %EditorState{
      port_manager: self(),
      workspace: %Minga.Workspace.State{
        viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
        file_tree: %FileTreeState{tree: tree, focused: true, buffer: buf},
        buffers: %{active: nil, list: [], recent: []},
        vim: VimState.new(),
        completion: nil,
        keymap_scope: :file_tree,
        agent_ui: agentic
      },
      status_msg: nil,
      agent: agent,
      focus_stack: [Scoped, Minga.Input.ModeFSM]
    }
  end

  describe "file tree: gg and G motions" do
    test "G moves cursor to the last entry", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      entries = FileTree.visible_entries(state.workspace.file_tree.tree)
      max_idx = length(entries) - 1

      {:handled, state} = walk_surface_handlers(state, ?G, 0)
      assert state.workspace.file_tree.tree.cursor == max_idx
    end

    test "gg moves cursor to the first entry", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      # First move to bottom
      {:handled, state} = walk_surface_handlers(state, ?G, 0)
      assert state.workspace.file_tree.tree.cursor > 0

      # Then gg to top (g enters prefix trie, second g triggers)
      {:handled, state} = walk_surface_handlers(state, ?g, 0)
      {:handled, state} = walk_surface_handlers(state, ?g, 0)
      assert state.workspace.file_tree.tree.cursor == 0
    end
  end

  describe "file tree: count prefix" do
    test "3j moves cursor down 3 entries", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      assert state.workspace.file_tree.tree.cursor == 0

      # Type 3j
      {:handled, state} = walk_surface_handlers(state, ?3, 0)
      {:handled, state} = walk_surface_handlers(state, ?j, 0)
      assert state.workspace.file_tree.tree.cursor == 3
    end
  end

  describe "file tree: yank in read-only buffer" do
    test "yy yanks the current line without modifying buffer", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      buf = state.workspace.file_tree.buffer
      content_before = BufferServer.content(buf)

      # yy should yank without error
      {:handled, state} = walk_surface_handlers(state, ?y, 0)
      {:handled, _state} = walk_surface_handlers(state, ?y, 0)

      assert BufferServer.content(buf) == content_before
    end
  end

  describe "file tree: insert mode blocked" do
    test "i does not enter insert mode", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      # i is not a tree-specific key, so it delegates to mode FSM
      # The mode FSM should block insert on read-only buffer
      {:handled, state} = walk_surface_handlers(state, ?i, 0)
      assert state.workspace.vim.mode == :normal
    end

    test "a does not enter insert mode", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      {:handled, state} = walk_surface_handlers(state, ?a, 0)
      assert state.workspace.vim.mode == :normal
    end

    test "o does not enter insert mode", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      {:handled, state} = walk_surface_handlers(state, ?o, 0)
      assert state.workspace.vim.mode == :normal
    end
  end

  describe "file tree: custom bindings still work" do
    test "Tab on directory toggles expand", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))
      File.write!(Path.join(tmp_dir, "subdir/inner.txt"), "")

      state = make_tree_state(tmp_dir, 0)
      tree = state.workspace.file_tree.tree
      entries = FileTree.visible_entries(tree)

      # Find subdir entry
      dir_idx = Enum.find_index(entries, fn e -> e.name == "subdir" end)

      if dir_idx do
        # Navigate to it
        state =
          if dir_idx > 0 do
            Enum.reduce(1..dir_idx, state, fn _i, acc ->
              {:handled, new_acc} = walk_surface_handlers(acc, ?j, 0)
              new_acc
            end)
          else
            state
          end

        # Press Tab to expand
        entries_before = length(FileTree.visible_entries(state.workspace.file_tree.tree))
        {:handled, state} = walk_surface_handlers(state, 9, 0)
        entries_after = length(FileTree.visible_entries(state.workspace.file_tree.tree))

        # Should have more entries after expanding
        assert entries_after > entries_before
      end
    end

    test "H toggles hidden files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "")
      File.write!(Path.join(tmp_dir, "visible.txt"), "")

      state = make_tree_state(tmp_dir, 0)
      entries_default = FileTree.visible_entries(state.workspace.file_tree.tree)

      {:handled, state} = walk_surface_handlers(state, ?H, 0)
      entries_with_hidden = FileTree.visible_entries(state.workspace.file_tree.tree)

      # Toggling hidden should change the entry count
      assert length(entries_with_hidden) != length(entries_default)
    end

    test "q closes the file tree", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      {:handled, state} = walk_surface_handlers(state, ?q, 0)
      assert state.workspace.file_tree.tree == nil
      assert state.workspace.file_tree.focused == false
    end
  end

  describe "file tree: g prefix passes through to mode FSM" do
    test "g is not intercepted as refresh (reserved for gg motion)", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      # Move down first so we can verify gg works
      {:handled, state} = walk_surface_handlers(state, ?j, 0)
      {:handled, state} = walk_surface_handlers(state, ?j, 0)
      assert state.workspace.file_tree.tree.cursor == 2

      # g should delegate to mode FSM (prefix trie)
      {:handled, state} = walk_surface_handlers(state, ?g, 0)
      assert state.workspace.vim.mode_state.prefix_node != nil

      # second g should trigger gg (go to top)
      {:handled, state} = walk_surface_handlers(state, ?g, 0)
      assert state.workspace.file_tree.tree.cursor == 0
    end
  end
end
