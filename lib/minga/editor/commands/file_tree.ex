defmodule Minga.Editor.Commands.FileTree do
  @moduledoc """
  File tree commands: toggling the tree panel, navigating entries,
  expanding/collapsing directories, and opening files from the tree.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @spec toggle(state()) :: state()
  def toggle(%{file_tree: %{tree: nil}} = state), do: open(state)

  def toggle(%{file_tree: %{buffer: buf}} = state) when is_pid(buf) do
    GenServer.stop(buf, :normal)

    %{state | file_tree: FileTreeState.close(state.file_tree), keymap_scope: restore_scope(state)}
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  def toggle(state) do
    %{state | file_tree: FileTreeState.close(state.file_tree), keymap_scope: restore_scope(state)}
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec restore_scope(state()) :: atom()
  defp restore_scope(state), do: EditorState.scope_for_active_window(state)

  @spec open_or_toggle(state()) :: state()
  def open_or_toggle(%{file_tree: %{tree: nil}} = state), do: state

  def open_or_toggle(%{file_tree: %{tree: tree}} = state) do
    case FileTree.selected_entry(tree) do
      %{dir?: true} ->
        new_tree = FileTree.toggle_expand(tree)
        sync_and_update(state, new_tree)

      %{dir?: false, path: path} ->
        state = put_in(state.file_tree.focused, false)
        # Opening a file buffer always uses :editor scope (not restore_scope)
        # because the new buffer becomes the active window content.
        state = %{state | keymap_scope: :editor}
        open_file_from_tree(state, path, tree)

      nil ->
        state
    end
  end

  @spec toggle_directory(state()) :: state()
  def toggle_directory(%{file_tree: %{tree: nil}} = state), do: state

  def toggle_directory(%{file_tree: %{tree: tree}} = state) do
    sync_and_update(state, FileTree.toggle_expand(tree))
  end

  @spec expand(state()) :: state()
  def expand(%{file_tree: %{tree: nil}} = state), do: state

  def expand(%{file_tree: %{tree: tree}} = state),
    do: sync_and_update(state, FileTree.expand(tree))

  @spec collapse(state()) :: state()
  def collapse(%{file_tree: %{tree: nil}} = state), do: state

  def collapse(%{file_tree: %{tree: tree}} = state),
    do: sync_and_update(state, FileTree.collapse(tree))

  @spec toggle_hidden(state()) :: state()
  def toggle_hidden(%{file_tree: %{tree: nil}} = state), do: state

  def toggle_hidden(%{file_tree: %{tree: tree}} = state),
    do: sync_and_update(state, FileTree.toggle_hidden(tree))

  @spec refresh(state()) :: state()
  def refresh(%{file_tree: %{tree: nil}} = state), do: state

  def refresh(%{file_tree: %{tree: tree}} = state) do
    tree = tree |> FileTree.refresh() |> FileTree.refresh_git_status()
    sync_and_update(state, tree)
  end

  @spec close(state()) :: state()
  def close(%{file_tree: %{buffer: buf}} = state) when is_pid(buf) do
    GenServer.stop(buf, :normal)
    %{state | file_tree: FileTreeState.close(state.file_tree), keymap_scope: restore_scope(state)}
  end

  def close(state),
    do: %{
      state
      | file_tree: FileTreeState.close(state.file_tree),
        keymap_scope: restore_scope(state)
    }

  # ── Private helpers ───────────────────────────────────────────────────────

  # Opens a file from the tree, reusing an existing buffer when one exists
  # for the same path. Without the dedup check, the file tree creates
  # duplicate Buffer.Server processes for the same file, which causes stale
  # tree-sitter highlight spans from the old buffer's parse to be misrouted
  # to the new buffer (garbled text on first render).
  @spec open_file_from_tree(state(), String.t(), FileTree.t()) :: state()
  defp open_file_from_tree(state, path, tree) do
    case EditorState.find_buffer_by_path(state, path) do
      nil ->
        case Commands.start_buffer(path) do
          {:ok, pid} -> Minga.Editor.do_file_tree_open(state, pid, path, tree)
          {:error, _} -> state
        end

      idx ->
        state = EditorState.switch_buffer(state, idx)
        put_in(state.file_tree.tree, FileTree.reveal(tree, path))
    end
  end

  @spec open(state()) :: state()
  defp open(state) do
    root = Minga.Project.root() || File.cwd!()
    tree = FileTree.new(root)
    tree = FileTree.refresh_git_status(tree)
    tree = reveal_active(tree, state.buffers.active)
    buf = BufferSync.start_buffer(tree)

    %{state | file_tree: FileTreeState.open(state.file_tree, tree, buf), keymap_scope: :file_tree}
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec reveal_active(FileTree.t(), pid() | nil) :: FileTree.t()
  defp reveal_active(tree, nil), do: tree

  defp reveal_active(tree, buf) do
    case BufferServer.file_path(buf) do
      nil -> tree
      path -> FileTree.reveal(tree, path)
    end
  end

  @spec sync_and_update(state(), FileTree.t()) :: state()
  defp sync_and_update(%{file_tree: %{buffer: buf}} = state, new_tree) when is_pid(buf) do
    BufferSync.sync(buf, new_tree)
    put_in(state.file_tree.tree, new_tree)
  end

  defp sync_and_update(state, new_tree) do
    put_in(state.file_tree.tree, new_tree)
  end

  @impl Minga.Command.Provider
  def __commands__ do
    [
      %Minga.Command{
        name: :toggle_file_tree,
        description: "Toggle file tree",
        requires_buffer: false,
        execute: &toggle/1
      },
      %Minga.Command{
        name: :tree_open_or_toggle,
        description: "Open file or toggle directory",
        requires_buffer: false,
        execute: &open_or_toggle/1
      },
      %Minga.Command{
        name: :tree_toggle_directory,
        description: "Toggle directory in tree",
        requires_buffer: false,
        execute: &toggle_directory/1
      },
      %Minga.Command{
        name: :tree_expand,
        description: "Expand tree node",
        requires_buffer: false,
        execute: &expand/1
      },
      %Minga.Command{
        name: :tree_collapse,
        description: "Collapse tree node",
        requires_buffer: false,
        execute: &collapse/1
      },
      %Minga.Command{
        name: :tree_toggle_hidden,
        description: "Toggle hidden files in tree",
        requires_buffer: false,
        execute: &toggle_hidden/1
      },
      %Minga.Command{
        name: :tree_refresh,
        description: "Refresh file tree",
        requires_buffer: false,
        execute: &refresh/1
      },
      %Minga.Command{
        name: :tree_close,
        description: "Close file tree",
        requires_buffer: false,
        execute: &close/1
      }
    ]
  end
end
