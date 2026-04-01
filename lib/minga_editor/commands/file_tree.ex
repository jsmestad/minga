defmodule MingaEditor.Commands.FileTree do
  @moduledoc """
  File tree commands: toggling the tree panel, navigating entries,
  expanding/collapsing directories, and opening files from the tree.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias Minga.Mode.DeleteConfirmState
  alias MingaEditor.Workspace.State, as: WorkspaceState
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
  Enters inline editing mode to create a new file.

  If the selected entry is a directory, the new file appears inside it
  (expanding the directory if collapsed). If the selected entry is a
  file, the new file appears as a sibling in the same directory.
  """
  @spec new_file(state()) :: state()
  def new_file(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def new_file(%{workspace: %{file_tree: %{tree: tree}}} = state) do
    {index, tree} = editing_insertion_index(tree)
    ft = FileTreeState.start_editing(state.workspace.file_tree, index, :new_file)
    state = put_in(state.workspace.file_tree, %{ft | tree: tree})
    sync_buffer(state)
  end

  @doc """
  Enters inline editing mode to create a new folder.

  Same positioning logic as `new_file/1`.
  """
  @spec new_folder(state()) :: state()
  def new_folder(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def new_folder(%{workspace: %{file_tree: %{tree: tree}}} = state) do
    {index, tree} = editing_insertion_index(tree)
    ft = FileTreeState.start_editing(state.workspace.file_tree, index, :new_folder)
    state = put_in(state.workspace.file_tree, %{ft | tree: tree})
    sync_buffer(state)
  end

  @doc """
  Enters inline editing mode to rename the selected entry.

  Pre-fills the input with the current entry name.
  """
  @spec rename(state()) :: state()
  def rename(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def rename(%{workspace: %{file_tree: %{tree: tree}}} = state) do
    case FileTree.selected_entry(tree) do
      nil ->
        state

      entry ->
        ft =
          FileTreeState.start_editing(
            state.workspace.file_tree,
            tree.cursor,
            :rename,
            entry.name
          )

        put_in(state.workspace.file_tree, ft)
    end
  end

  @doc """
  Confirms the current inline edit.

  Dispatches on the editing type:
  - `:new_file` creates the file on disk, opens it as a buffer.
  - `:new_folder` creates the directory on disk.
  - `:rename` renames the file/directory and updates any open buffer.
  """
  @spec confirm_editing(state()) :: state()
  def confirm_editing(%{workspace: %{file_tree: %{editing: nil}}} = state), do: state

  def confirm_editing(%{workspace: %{file_tree: %{editing: %{text: text}}}} = state)
      when text == "" do
    cancel_editing(state)
  end

  def confirm_editing(
        %{workspace: %{file_tree: %{editing: %{type: :new_file} = editing}}} = state
      ) do
    parent_dir = editing_parent_dir(state)
    full_path = Path.join(parent_dir, editing.text)

    File.mkdir_p!(Path.dirname(full_path))
    File.touch!(full_path)

    state = clear_editing_and_refresh(state)

    case Commands.start_buffer(full_path) do
      {:ok, pid} ->
        MingaEditor.do_file_tree_open(state, pid, full_path, state.workspace.file_tree.tree)

      {:error, reason} ->
        MingaEditor.log_to_messages("[file-tree] Failed to open #{full_path}: #{inspect(reason)}")

        state
    end
  end

  def confirm_editing(
        %{workspace: %{file_tree: %{editing: %{type: :new_folder} = editing}}} = state
      ) do
    parent_dir = editing_parent_dir(state)
    full_path = Path.join(parent_dir, editing.text)

    case File.mkdir_p(full_path) do
      :ok ->
        MingaEditor.log_to_messages("[file-tree] Created folder: #{editing.text}")
        clear_editing_and_refresh(state)

      {:error, reason} ->
        MingaEditor.log_to_messages("[file-tree] Failed to create folder: #{inspect(reason)}")

        cancel_editing(state)
    end
  end

  def confirm_editing(
        %{workspace: %{file_tree: %{editing: %{type: :rename} = _editing, tree: tree}}} = state
      ) do
    case FileTree.selected_entry(tree) do
      nil -> cancel_editing(state)
      entry -> do_rename(state, entry, state.workspace.file_tree.editing.text)
    end
  end

  @doc """
  Enters delete confirmation mode for the selected file tree entry.

  Transitions to `:delete_confirm` mode, prompting the user with y/n.
  For directories, includes a child count in the prompt.
  """
  @spec delete(state()) :: state()
  def delete(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def delete(%{workspace: %{file_tree: %{tree: tree}}} = state) do
    case FileTree.selected_entry(tree) do
      nil ->
        state

      entry ->
        child_count = if entry.dir?, do: count_children(entry.path), else: 0
        ms = DeleteConfirmState.new(entry.path, entry.name, entry.dir?, child_count)
        EditorState.transition_mode(state, :delete_confirm, ms)
    end
  end

  @doc "Duplicates the selected file or directory with a \" copy\" suffix."
  @spec duplicate(state()) :: state()
  def duplicate(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state

  def duplicate(%{workspace: %{file_tree: %{tree: tree}}} = state) do
    case FileTree.selected_entry(tree) do
      nil ->
        state

      entry ->
        dest = unique_copy_path(entry.path)

        result =
          if entry.dir?,
            do: File.cp_r(entry.path, dest),
            else: File.cp(entry.path, dest)

        case result do
          :ok ->
            MingaEditor.log_to_messages(
              "[file-tree] Duplicated: #{entry.name} → #{Path.basename(dest)}"
            )

            refresh(state)

          {:ok, _} ->
            MingaEditor.log_to_messages(
              "[file-tree] Duplicated: #{entry.name} → #{Path.basename(dest)}"
            )

            refresh(state)

          {:error, reason, _} ->
            MingaEditor.log_to_messages("[file-tree] Duplicate failed: #{inspect(reason)}")
            state

          {:error, reason} ->
            MingaEditor.log_to_messages("[file-tree] Duplicate failed: #{inspect(reason)}")
            state
        end
    end
  end

  @doc """
  Moves a file/directory from `source_index` into the directory at `target_dir_index`.

  If the target is not a directory, uses its parent directory.
  """
  @spec move(state(), non_neg_integer(), non_neg_integer()) :: state()
  def move(%{workspace: %{file_tree: %{tree: nil}}} = state, _source, _target), do: state

  def move(%{workspace: %{file_tree: %{tree: tree}}} = state, source_index, target_dir_index) do
    entries = FileTree.visible_entries(tree)
    source = Enum.at(entries, source_index)
    target = Enum.at(entries, target_dir_index)

    case {source, target} do
      {nil, _} ->
        state

      {_, nil} ->
        state

      {src, tgt} ->
        target_dir = if tgt.dir?, do: tgt.path, else: Path.dirname(tgt.path)
        new_path = Path.join(target_dir, src.name)

        if src.path == new_path do
          state
        else
          execute_move(state, src.path, new_path, src.name)
        end
    end
  end

  @doc "Cancels the current inline edit without making changes."
  @spec cancel_editing(state()) :: state()
  def cancel_editing(%{workspace: %{file_tree: %{editing: nil}}} = state), do: state

  def cancel_editing(state) do
    ft = FileTreeState.cancel_editing(state.workspace.file_tree)
    put_in(state.workspace.file_tree, ft)
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
          {:ok, pid} -> MingaEditor.do_file_tree_open(state, pid, path, tree)
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

    root = state.workspace.file_tree.project_root || Minga.Project.root() || File.cwd!()
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

  # Computes the insertion index for a new file/folder.
  # If the selected entry is a directory, inserts inside it (expanding if needed).
  # If the selected entry is a file, inserts as a sibling after the cursor.
  @spec editing_insertion_index(FileTree.t()) :: {non_neg_integer(), FileTree.t()}
  defp editing_insertion_index(tree) do
    case FileTree.selected_entry(tree) do
      nil ->
        {0, tree}

      %{dir?: true, path: dir_path} ->
        tree = ensure_expanded(tree, dir_path)
        {tree.cursor + 1, tree}

      %{dir?: false} ->
        {tree.cursor + 1, tree}
    end
  end

  @spec ensure_expanded(FileTree.t(), String.t()) :: FileTree.t()
  defp ensure_expanded(tree, dir_path) do
    if MapSet.member?(tree.expanded, dir_path), do: tree, else: FileTree.toggle_expand(tree)
  end

  # Determines the parent directory path for the current editing operation.
  @spec editing_parent_dir(state()) :: String.t()
  defp editing_parent_dir(%{workspace: %{file_tree: %{editing: editing, tree: tree}}}) do
    entries = FileTree.visible_entries(tree)

    case editing.type do
      type when type in [:new_file, :new_folder] ->
        prev_entry = if editing.index > 0, do: Enum.at(entries, editing.index - 1)

        case prev_entry do
          %{dir?: true, path: path} -> path
          %{path: path} -> Path.dirname(path)
          nil -> tree.root
        end

      :rename ->
        case Enum.at(entries, editing.index) do
          %{path: path} -> Path.dirname(path)
          nil -> tree.root
        end
    end
  end

  # Clears editing state and refreshes the tree from disk.
  @spec clear_editing_and_refresh(state()) :: state()
  defp clear_editing_and_refresh(state) do
    ft = FileTreeState.cancel_editing(state.workspace.file_tree)
    state = put_in(state.workspace.file_tree, ft)
    refresh(state)
  end

  # Syncs the buffer after editing state changes.
  @spec sync_buffer(state()) :: state()
  defp sync_buffer(%{workspace: %{file_tree: %{buffer: buf, tree: tree}}} = state)
       when is_pid(buf) do
    BufferSync.sync(buf, tree)
    state
  end

  defp sync_buffer(state), do: state

  @spec do_rename(state(), FileTree.entry(), String.t()) :: state()
  defp do_rename(state, entry, new_name) do
    old_path = entry.path
    new_path = Path.join(Path.dirname(old_path), new_name)

    if old_path == new_path do
      cancel_editing(state)
    else
      execute_rename(state, old_path, new_path, new_name)
    end
  end

  @spec execute_rename(state(), String.t(), String.t(), String.t()) :: state()
  defp execute_rename(state, old_path, new_path, new_name) do
    case File.rename(old_path, new_path) do
      :ok ->
        state = update_buffer_path(state, old_path, new_path)

        MingaEditor.log_to_messages(
          "[file-tree] Renamed: #{Path.basename(old_path)} \u2192 #{new_name}"
        )

        clear_editing_and_refresh(state)

      {:error, reason} ->
        MingaEditor.log_to_messages("[file-tree] Rename failed: #{inspect(reason)}")
        cancel_editing(state)
    end
  end

  # Updates any open buffer that references the old path to the new path.
  # Counts all files and directories recursively under the given path.
  @spec count_children(String.t()) :: non_neg_integer()
  defp count_children(path) do
    case File.ls(path) do
      {:ok, children} -> Enum.reduce(children, 0, &count_child(path, &1, &2))
      {:error, _} -> 0
    end
  end

  @spec count_child(String.t(), String.t(), non_neg_integer()) :: non_neg_integer()
  defp count_child(parent, name, acc) do
    child_path = Path.join(parent, name)

    if File.dir?(child_path) do
      acc + 1 + count_children(child_path)
    else
      acc + 1
    end
  end

  @spec update_buffer_path(state(), String.t(), String.t()) :: state()
  defp update_buffer_path(state, old_path, new_path) do
    case EditorState.find_buffer_by_path(state, old_path) do
      nil ->
        state

      idx ->
        pid = Enum.at(state.workspace.buffers.list, idx)
        Buffer.save_as(pid, new_path)
        state
    end
  end

  @spec unique_copy_path(String.t()) :: String.t()
  defp unique_copy_path(path) do
    ext = Path.extname(path)
    base = Path.rootname(path)
    candidate = "#{base} copy#{ext}"

    if File.exists?(candidate) do
      find_unique_copy(base, ext, 2)
    else
      candidate
    end
  end

  @spec find_unique_copy(String.t(), String.t(), pos_integer()) :: String.t()
  defp find_unique_copy(base, ext, n) do
    candidate = "#{base} copy #{n}#{ext}"

    if File.exists?(candidate),
      do: find_unique_copy(base, ext, n + 1),
      else: candidate
  end

  @spec execute_move(state(), String.t(), String.t(), String.t()) :: state()
  defp execute_move(state, old_path, new_path, name) do
    case File.rename(old_path, new_path) do
      :ok ->
        state = update_buffer_path(state, old_path, new_path)

        MingaEditor.log_to_messages("[file-tree] Moved: #{name} → #{Path.dirname(new_path)}")

        refresh(state)

      {:error, reason} ->
        MingaEditor.log_to_messages("[file-tree] Move failed: #{inspect(reason)}")
        state
    end
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
        name: :tree_rename,
        description: "Rename file or folder in tree",
        requires_buffer: false,
        execute: &rename/1
      },
      %Minga.Command{
        name: :tree_confirm_editing,
        description: "Confirm file tree inline edit",
        requires_buffer: false,
        execute: &confirm_editing/1
      },
      %Minga.Command{
        name: :tree_cancel_editing,
        description: "Cancel file tree inline edit",
        requires_buffer: false,
        execute: &cancel_editing/1
      },
      %Minga.Command{
        name: :tree_reveal_active,
        description: "Reveal active file in tree",
        requires_buffer: false,
        execute: &reveal_active_file/1
      },
      %Minga.Command{
        name: :tree_delete,
        description: "Delete file or folder in tree",
        requires_buffer: false,
        execute: &delete/1
      },
      %Minga.Command{
        name: :tree_duplicate,
        description: "Duplicate file or folder in tree",
        requires_buffer: false,
        execute: &duplicate/1
      }
    ]
  end
end
