defmodule Minga.Editor.Commands.FileTree do
  @moduledoc """
  File tree commands: toggling the tree panel, navigating entries,
  expanding/collapsing directories, and opening files from the tree.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Editor.Commands
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Workspace.State, as: WorkspaceState
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @spec toggle(state()) :: state()
  def toggle(%{workspace: %{file_tree: %{tree: nil}}} = state), do: open(state)

  def toggle(%{workspace: %{file_tree: %{buffer: buf}}} = state) when is_pid(buf) do
    GenServer.stop(buf, :normal)

    scope = restore_scope(state)

    EditorState.update_workspace(state, fn ws ->
      ws
      |> Map.put(:file_tree, FileTreeState.close(ws.file_tree))
      |> WorkspaceState.set_keymap_scope(scope)
    end)
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  def toggle(state) do
    scope = restore_scope(state)

    EditorState.update_workspace(state, fn ws ->
      ws
      |> Map.put(:file_tree, FileTreeState.close(ws.file_tree))
      |> WorkspaceState.set_keymap_scope(scope)
    end)
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec restore_scope(state()) :: atom()
  defp restore_scope(state), do: EditorState.scope_for_active_window(state)

  @spec open_or_toggle(state()) :: state()
  def open_or_toggle(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def open_or_toggle(%{workspace: %{file_tree: %{tree: tree}}} = state) do
    case FileTree.selected_entry(tree) do
      %{dir?: true} ->
        new_tree = FileTree.toggle_expand(tree)
        sync_and_update(state, new_tree)

      %{dir?: false, path: path} ->
        state = put_in(state.workspace.file_tree.focused, false)
        # Opening a file buffer always uses :editor scope (not restore_scope)
        # because the new buffer becomes the active window content.
        state = EditorState.update_workspace(state, &WorkspaceState.set_keymap_scope(&1, :editor))
        open_file_from_tree(state, path, tree)

      nil ->
        state
    end
  end

  @spec toggle_directory(state()) :: state()
  def toggle_directory(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def toggle_directory(%{workspace: %{file_tree: %{tree: tree}}} = state) do
    sync_and_update(state, FileTree.toggle_expand(tree))
  end

  @spec expand(state()) :: state()
  def expand(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def expand(%{workspace: %{file_tree: %{tree: tree}}} = state),
    do: sync_and_update(state, FileTree.expand(tree))

  @spec collapse(state()) :: state()
  def collapse(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def collapse(%{workspace: %{file_tree: %{tree: tree}}} = state),
    do: sync_and_update(state, FileTree.collapse(tree))

  @spec toggle_hidden(state()) :: state()
  def toggle_hidden(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def toggle_hidden(%{workspace: %{file_tree: %{tree: tree}}} = state),
    do: sync_and_update(state, FileTree.toggle_hidden(tree))

  @spec collapse_all(state()) :: state()
  def collapse_all(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def collapse_all(%{workspace: %{file_tree: %{tree: tree}}} = state) do
    sync_and_update(state, FileTree.collapse_all(tree))
  end

  @spec refresh(state()) :: state()
  def refresh(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def refresh(%{workspace: %{file_tree: %{tree: tree}}} = state) do
    tree = tree |> FileTree.refresh() |> FileTree.refresh_git_status()
    sync_and_update(state, tree)
  end

  @doc """
  Stub for creating a new file at the selected directory.
  Requires a name prompt UI (not yet implemented). Logs intent to *Messages*.
  """
  @spec new_file(state()) :: state()
  def new_file(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def new_file(state) do
    Minga.Editor.log_to_messages(
      "[file-tree] New file: requires name prompt (not yet implemented)"
    )

    state
  end

  @doc """
  Stub for creating a new folder at the selected directory.
  Requires a name prompt UI (not yet implemented). Logs intent to *Messages*.
  """
  @spec new_folder(state()) :: state()
  def new_folder(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def new_folder(state) do
    Minga.Editor.log_to_messages(
      "[file-tree] New folder: requires name prompt (not yet implemented)"
    )

    state
  end

  @doc """
  Reveals the active buffer's file in the tree: opens the tree if closed,
  expands parent directories, moves the cursor to the file, and focuses
  the tree panel.
  """
  @spec reveal_active_file(state()) :: state()
  def reveal_active_file(state) do
    # When the file tree is focused, state.workspace.buffers.active points at the
    # tree's backing buffer (no file path). Use the active window's buffer
    # instead, which always holds the real editing buffer.
    buf = active_editing_buffer(state)

    case buf && Buffer.file_path(buf) do
      nil ->
        state

      path ->
        state = ensure_tree_open(state)
        tree = FileTree.reveal(state.workspace.file_tree.tree, path)
        state = sync_and_update(state, tree)
        state = put_in(state.workspace.file_tree.focused, true)

        EditorState.update_workspace(state, &WorkspaceState.set_keymap_scope(&1, :file_tree))
        |> Layout.invalidate()
        |> EditorState.invalidate_all_windows()
    end
  end

  @spec active_editing_buffer(state()) :: pid() | nil
  defp active_editing_buffer(state) do
    case EditorState.active_window_struct(state) do
      %{buffer: buf} when is_pid(buf) -> buf
      _ -> state.workspace.buffers.active
    end
  end

  @spec close(state()) :: state()
  def close(%{workspace: %{file_tree: %{buffer: buf}}} = state) when is_pid(buf) do
    GenServer.stop(buf, :normal)

    scope = restore_scope(state)

    EditorState.update_workspace(state, fn ws ->
      ws
      |> Map.put(:file_tree, FileTreeState.close(ws.file_tree))
      |> WorkspaceState.set_keymap_scope(scope)
    end)
  end

  def close(state) do
    scope = restore_scope(state)

    EditorState.update_workspace(state, fn ws ->
      ws
      |> Map.put(:file_tree, FileTreeState.close(ws.file_tree))
      |> WorkspaceState.set_keymap_scope(scope)
    end)
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  # Mutual exclusivity: close git status panel when opening file tree.
  # Explicitly resets keymap_scope to :editor so we don't leave orphaned
  # :git_status scope if a future refactor separates the open steps.
  @spec close_git_status_if_open(state()) :: state()
  defp close_git_status_if_open(%{shell_state: %{git_status_panel: nil}} = state), do: state

  defp close_git_status_if_open(state),
    do:
      state
      |> EditorState.update_workspace(&WorkspaceState.set_keymap_scope(&1, :editor))
      |> EditorState.close_git_status_panel()

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
        # If the buffer already has a tab, switch to that tab (correctly
        # leaves agent view if needed). Otherwise fall back to buffer switch.
        pid = Enum.at(state.workspace.buffers.list, idx)
        tab = EditorState.find_tab_by_buffer(state, pid)

        state =
          if tab do
            EditorState.switch_tab(state, tab.id)
          else
            EditorState.switch_buffer(state, idx)
          end

        put_in(state.workspace.file_tree.tree, FileTree.reveal(tree, path))
    end
  end

  # Opens the tree if not already open. Used by reveal_active_file to
  # ensure the tree exists before calling FileTree.reveal.
  @spec ensure_tree_open(state()) :: state()
  defp ensure_tree_open(%{workspace: %{file_tree: %{tree: %FileTree{}}}} = state), do: state
  defp ensure_tree_open(state), do: open(state)

  @spec open(state()) :: state()
  defp open(state) do
    state = close_git_status_if_open(state)

    root = Minga.Project.root() || File.cwd!()
    tree = FileTree.new(root)
    tree = FileTree.refresh_git_status(tree)
    tree = reveal_active(tree, state.workspace.buffers.active)
    buf = BufferSync.start_buffer(tree)

    EditorState.update_workspace(state, fn ws ->
      ws
      |> Map.put(:file_tree, FileTreeState.open(ws.file_tree, tree, buf))
      |> WorkspaceState.set_keymap_scope(:file_tree)
    end)
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec reveal_active(FileTree.t(), pid() | nil) :: FileTree.t()
  defp reveal_active(tree, nil), do: tree

  defp reveal_active(tree, buf) do
    case Buffer.file_path(buf) do
      nil -> tree
      path -> FileTree.reveal(tree, path)
    end
  end

  @spec sync_and_update(state(), FileTree.t()) :: state()
  defp sync_and_update(%{workspace: %{file_tree: %{buffer: buf}}} = state, new_tree)
       when is_pid(buf) do
    BufferSync.sync(buf, new_tree)
    put_in(state.workspace.file_tree.tree, new_tree)
  end

  defp sync_and_update(state, new_tree) do
    put_in(state.workspace.file_tree.tree, new_tree)
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
      },
      %Minga.Command{
        name: :tree_collapse_all,
        description: "Collapse all directories in tree",
        requires_buffer: false,
        execute: &collapse_all/1
      },
      %Minga.Command{
        name: :tree_new_file,
        description: "Create new file in tree",
        requires_buffer: false,
        execute: &new_file/1
      },
      %Minga.Command{
        name: :tree_new_folder,
        description: "Create new folder in tree",
        requires_buffer: false,
        execute: &new_folder/1
      },
      %Minga.Command{
        name: :tree_reveal_active,
        description: "Reveal active file in tree",
        requires_buffer: false,
        execute: &reveal_active_file/1
      }
    ]
  end
end
