defmodule Minga.Input.FileTreeNavTest do
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
  alias Minga.Input.FileTreeHandler

  defp walk_surface_handlers(state, cp, mods) do
    Enum.reduce_while(Minga.Input.surface_handlers(), {:passthrough, state}, fn handler,
                                                                                {_, acc} ->
      case handler.handle_key(acc, cp, mods) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

  # Build a minimal EditorState with file tree focused and keymap_scope: :file_tree
  defp make_state(tmp_dir, file_count \\ 5) do
    for i <- 1..file_count do
      File.write!(Path.join(tmp_dir, "file_#{String.pad_leading(to_string(i), 2, "0")}.txt"), "")
    end

    tree = FileTree.new(tmp_dir)
    buf = BufferSync.start_buffer(tree)

    agent = %AgentState{}
    agentic = %UIState{}

    %EditorState{
      port_manager: self(),
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      file_tree: %FileTreeState{tree: tree, focused: true, buffer: buf},
      buffers: %{active: nil, list: [], recent: []},
      vim: VimState.new(),
      status_msg: nil,
      agent: agent,
      agent_ui: agentic,
      completion: nil,
      keymap_scope: :file_tree,
      focus_stack: [Scoped, Minga.Input.ModeFSM]
    }
  end

  describe "vim navigation in file tree (via Scoped)" do
    test "j moves tree cursor down", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      assert state.file_tree.tree.cursor == 0

      {:handled, state} = walk_surface_handlers(state, ?j, 0)
      assert state.file_tree.tree.cursor == 1

      {:handled, state} = walk_surface_handlers(state, ?j, 0)
      assert state.file_tree.tree.cursor == 2
    end

    test "k moves tree cursor up", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      # Move down first
      {:handled, state} = walk_surface_handlers(state, ?j, 0)
      {:handled, state} = walk_surface_handlers(state, ?j, 0)
      assert state.file_tree.tree.cursor == 2

      {:handled, state} = walk_surface_handlers(state, ?k, 0)
      assert state.file_tree.tree.cursor == 1
    end

    test "q closes the file tree via scope resolution", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      {:handled, state} = walk_surface_handlers(state, ?q, 0)
      assert state.file_tree.tree == nil
      assert state.file_tree.focused == false
      assert state.keymap_scope == :editor
    end

    test "Escape closes the file tree", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      {:handled, state} = walk_surface_handlers(state, 27, 0)
      assert state.file_tree.tree == nil
      assert state.keymap_scope == :editor
    end

    test "passthrough when tree not focused", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      state = put_in(state.file_tree.focused, false)
      {:passthrough, _state} = FileTreeHandler.handle_key(state, ?j, 0)
    end

    test "tree cursor stays in bounds", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir, 3)
      entries = FileTree.visible_entries(state.file_tree.tree)
      max_idx = length(entries) - 1

      # Move down past the end
      state =
        Enum.reduce(1..(max_idx + 5), state, fn _i, acc ->
          {:handled, new_acc} = walk_surface_handlers(acc, ?j, 0)
          new_acc
        end)

      assert state.file_tree.tree.cursor <= max_idx
    end

    test "buffer cursor syncs with tree cursor after j/k", %{tmp_dir: tmp_dir} do
      state = make_state(tmp_dir)
      buf = state.file_tree.buffer

      {:handled, state} = walk_surface_handlers(state, ?j, 0)
      {:handled, state} = walk_surface_handlers(state, ?j, 0)

      {buf_line, _col} = BufferServer.cursor(buf)
      assert buf_line == state.file_tree.tree.cursor
    end
  end
end
