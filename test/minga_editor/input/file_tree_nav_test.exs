defmodule MingaEditor.Input.FileTreeNavTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Input.FileTreeHandler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Viewport
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    %{sidebar_registry: table}
  end

  defp handle_file_tree_key(state, cp, mods), do: FileTreeHandler.handle_key(state, cp, mods)

  # Build a minimal EditorState with file tree focused and keymap_scope: :file_tree
  defp make_state(tmp_dir, sidebar_registry, file_count \\ 5) do
    for i <- 1..file_count do
      File.write!(Path.join(tmp_dir, "file_#{String.pad_leading(to_string(i), 2, "0")}.txt"), "")
    end

    tree = FileTree.new(tmp_dir)
    buf = BufferSync.start_buffer(tree)

    workspace =
      %SessionState{viewport: Viewport.new(24, 80), keymap_scope: :file_tree}
      |> SessionState.set_file_tree(%FileTreeState{tree: tree, focused: true, buffer: buf})

    %EditorState{
      port_manager: self(),
      sidebar_registry: sidebar_registry,
      workspace: workspace,
      focus_stack: [Scoped, MingaEditor.Input.ModeFSM]
    }
  end

  defp ft(state), do: EditorState.file_tree_state(state)

  describe "vim navigation in file tree" do
    test "j moves tree cursor down", %{tmp_dir: tmp_dir, sidebar_registry: table} do
      state = make_state(tmp_dir, table)
      assert ft(state).tree.cursor == 0

      {:handled, state} = handle_file_tree_key(state, ?j, 0)
      assert ft(state).tree.cursor == 1

      {:handled, state} = handle_file_tree_key(state, ?j, 0)
      assert ft(state).tree.cursor == 2
    end

    test "k moves tree cursor up", %{tmp_dir: tmp_dir, sidebar_registry: table} do
      state = make_state(tmp_dir, table)
      # Move down first
      {:handled, state} = handle_file_tree_key(state, ?j, 0)
      {:handled, state} = handle_file_tree_key(state, ?j, 0)
      assert ft(state).tree.cursor == 2

      {:handled, state} = handle_file_tree_key(state, ?k, 0)
      assert ft(state).tree.cursor == 1
    end

    test "q closes the file tree", %{tmp_dir: tmp_dir, sidebar_registry: table} do
      state = make_state(tmp_dir, table)
      {:handled, state} = handle_file_tree_key(state, ?q, 0)
      assert ft(state).tree == nil
      assert ft(state).focused == false
      assert state.workspace.keymap_scope == :editor
    end

    test "Escape closes the file tree", %{tmp_dir: tmp_dir, sidebar_registry: table} do
      state = make_state(tmp_dir, table)
      {:handled, state} = handle_file_tree_key(state, 27, 0)
      assert ft(state).tree == nil
      assert state.workspace.keymap_scope == :editor
    end

    test "passthrough when tree not focused", %{tmp_dir: tmp_dir, sidebar_registry: table} do
      state = make_state(tmp_dir, table)
      state = EditorState.set_file_tree(state, %{ft(state) | focused: false})
      {:passthrough, _state} = FileTreeHandler.handle_key(state, ?j, 0)
    end

    test "tree cursor stays in bounds", %{tmp_dir: tmp_dir, sidebar_registry: table} do
      state = make_state(tmp_dir, table, 3)
      entries = FileTree.visible_entries(ft(state).tree)
      max_idx = length(entries) - 1

      # Move down past the end
      state =
        Enum.reduce(1..(max_idx + 5), state, fn _i, acc ->
          {:handled, new_acc} = handle_file_tree_key(acc, ?j, 0)
          new_acc
        end)

      assert ft(state).tree.cursor <= max_idx
    end

    test "buffer cursor syncs with tree cursor after j/k", %{
      tmp_dir: tmp_dir,
      sidebar_registry: table
    } do
      state = make_state(tmp_dir, table)
      buf = ft(state).buffer

      {:handled, state} = handle_file_tree_key(state, ?j, 0)
      {:handled, state} = handle_file_tree_key(state, ?j, 0)

      {buf_line, _col} = BufferProcess.cursor(buf)
      assert buf_line == ft(state).tree.cursor
    end
  end
end
