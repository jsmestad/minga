defmodule MingaEditor.Commands.FileTree do
  @moduledoc """
  File tree commands: toggling the tree panel, navigating entries,
  expanding/collapsing directories, and opening files from the tree.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.Commands.Helpers
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias Minga.Mode.DeleteConfirmState
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias MingaEditor.FileTree.DropIntent
  alias MingaEditor.FileTree.Freshness, as: FileTreeFreshness

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Handles semantic sidebar actions from native frontends or generic sidebar input."
  @spec handle_sidebar_action(state(), String.t(), map()) :: state()
  def handle_sidebar_action(state, "toggle", _context), do: toggle(state)

  def handle_sidebar_action(state, "activate", _context) do
    case file_tree_state(state) |> FileTreeState.status() |> FileTreeState.visible_status?() do
      true -> focus_visible_tree(state)
      false -> toggle(state)
    end
  end

  def handle_sidebar_action(state, _action, _context), do: state

  @spec toggle(state()) :: state()
  def toggle(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} ->
        open(state)

      %FileTreeState{tree: tree, buffer: buf} when is_pid(buf) ->
        FileTreeFreshness.unwatch_expanded_dirs(tree)
        GenServer.stop(buf, :normal)
        close_tree(state)

      %FileTreeState{tree: %FileTree{} = tree} ->
        FileTreeFreshness.unwatch_expanded_dirs(tree)
        close_tree(state)
    end
  end

  @spec focus_visible_tree(state()) :: state()
  defp focus_visible_tree(state) do
    state
    |> EditorState.update_file_tree(&FileTreeState.focus/1)
    |> EditorState.set_keymap_scope(:file_tree)
    |> EditorState.set_sidebar_active_id("file_tree")
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec close_tree(state()) :: state()
  defp close_tree(state) do
    scope = restore_scope(state)

    state
    |> EditorState.update_file_tree(&FileTreeState.close/1)
    |> EditorState.set_keymap_scope(scope)
    |> EditorState.set_sidebar_active_id(nil)
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec restore_scope(state()) :: atom()
  defp restore_scope(state), do: EditorState.scope_for_active_window(state)

  @spec file_tree_state(state()) :: FileTreeState.t()
  defp file_tree_state(state), do: EditorState.file_tree_state(state)

  @spec set_file_tree(state(), FileTreeState.t()) :: state()
  defp set_file_tree(state, file_tree) do
    EditorState.set_file_tree(state, file_tree)
  end

  @spec update_file_tree(state(), (FileTreeState.t() -> FileTreeState.t())) :: state()
  defp update_file_tree(state, fun) when is_function(fun, 1) do
    EditorState.update_file_tree(state, fun)
  end

  @spec open_or_toggle(state()) :: state()
  def open_or_toggle(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: %FileTree{} = tree} ->
        open_or_toggle_entry(state, tree, FileTree.selected_entry(tree))

      %FileTreeState{} ->
        state
    end
  end

  @spec open_or_toggle_entry(state(), FileTree.t(), FileTree.entry() | nil) :: state()
  defp open_or_toggle_entry(state, tree, %{dir?: true}) do
    new_tree = FileTree.toggle_expand(tree)
    sync_and_update(state, new_tree)
  end

  defp open_or_toggle_entry(state, tree, %{dir?: false, path: path}) do
    state = update_file_tree(state, &FileTreeState.unfocus/1)
    # Opening a file buffer always uses :editor scope (not restore_scope)
    # because the new buffer becomes the active window content.
    state = EditorState.set_keymap_scope(state, :editor)
    open_file_from_tree(state, path, tree)
  end

  defp open_or_toggle_entry(state, _tree, nil), do: state

  @spec toggle_directory(state()) :: state()
  def toggle_directory(state), do: with_tree(state, &FileTree.toggle_expand/1)

  @spec expand(state()) :: state()
  def expand(state), do: with_tree(state, &FileTree.expand/1)

  @spec collapse(state()) :: state()
  def collapse(state), do: with_tree(state, &FileTree.collapse/1)

  @spec toggle_hidden(state()) :: state()
  def toggle_hidden(state), do: with_tree(state, &FileTree.toggle_hidden/1)

  @spec collapse_all(state()) :: state()
  def collapse_all(state), do: with_tree(state, &FileTree.collapse_all/1)

  @spec refresh(state()) :: state()
  def refresh(state) do
    with_tree(state, fn tree -> tree |> FileTree.refresh() |> FileTree.refresh_git_status() end)
  end

  @spec with_tree(state(), (FileTree.t() -> FileTree.t())) :: state()
  defp with_tree(state, fun) do
    case file_tree_state(state) do
      %FileTreeState{tree: %FileTree{} = tree} -> sync_and_update(state, fun.(tree))
      %FileTreeState{} -> state
    end
  end

  @doc "Copies the selected entry's absolute path to the system clipboard."
  @spec copy_path(state()) :: state()
  def copy_path(state) do
    with %FileTreeState{tree: %FileTree{} = tree} <- file_tree_state(state),
         %{path: path} <- FileTree.selected_entry(tree) do
      state
      |> Helpers.force_clipboard_sync(Path.expand(path))
      |> EditorState.set_status("Copied #{Path.expand(path)}")
    else
      _ -> state
    end
  end

  @doc "Marks the selected entry for a later copy operation."
  @spec mark_copy(state()) :: state()
  def mark_copy(state), do: mark_for_paste(state, :copy)

  @doc "Marks the selected entry for a later move operation."
  @spec mark_move(state()) :: state()
  def mark_move(state), do: mark_for_paste(state, :move)

  @doc "Pastes the marked copy or move entry into the selected directory or file parent."
  @spec paste(state()) :: state()
  def paste(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} ->
        state

      %FileTreeState{clipboard_mark: nil} ->
        EditorState.set_status(state, "No file tree copy or move is pending")

      %FileTreeState{clipboard_mark: mark, tree: tree} ->
        target_dir = selected_target_dir(tree)
        destination = Path.join(target_dir, mark.name)
        paste_marked_entry(state, mark, destination)
    end
  end

  @doc "Changes the tree root to the parent directory of the current root."
  @spec root_parent(state()) :: state()
  def root_parent(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: %FileTree{root: root}} ->
        parent = Path.dirname(root)
        if parent == root, do: state, else: reroot(state, parent)

      %FileTreeState{} ->
        state
    end
  end

  @doc "Changes the tree root to the selected directory."
  @spec root_selected(state()) :: state()
  def root_selected(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: %FileTree{} = tree} ->
        case FileTree.selected_entry(tree) do
          %{dir?: true, path: path} -> reroot(state, path)
          %{dir?: false} -> state
          nil -> state
        end

      %FileTreeState{} ->
        state
    end
  end

  @doc "Restores the tree root to the original project directory."
  @spec root_original(state()) :: state()
  def root_original(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} -> state
      %FileTreeState{original_root: root} when is_binary(root) -> reroot(state, root)
      %FileTreeState{project_root: root} when is_binary(root) -> reroot(state, root)
      %FileTreeState{} -> state
    end
  end

  @doc "Starts inline file tree filtering."
  @spec filter(state()) :: state()
  def filter(state) do
    update_file_tree(state, &FileTreeState.start_filtering/1)
  end

  @doc "Toggles the file tree help overlay."
  @spec toggle_help(state()) :: state()
  def toggle_help(state) do
    update_file_tree(state, &FileTreeState.toggle_help/1)
  end

  @doc "Hides the file tree help overlay."
  @spec hide_help(state()) :: state()
  def hide_help(state) do
    update_file_tree(state, &FileTreeState.hide_help/1)
  end

  @doc """
  Enters inline editing mode to create a new file.

  If the selected entry is a directory, the new file appears inside it
  (expanding the directory if collapsed). If the selected entry is a
  file, the new file appears as a sibling in the same directory.
  """
  @spec new_file(state()) :: state()
  def new_file(state), do: start_new_entry_edit(state, :new_file)

  @doc """
  Enters inline editing mode to create a new folder.

  Same positioning logic as `new_file/1`.
  """
  @spec new_folder(state()) :: state()
  def new_folder(state), do: start_new_entry_edit(state, :new_folder)

  @spec start_new_entry_edit(state(), :new_file | :new_folder) :: state()
  defp start_new_entry_edit(state, type) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} ->
        state

      %FileTreeState{tree: tree} ->
        {index, tree} = editing_insertion_index(tree)

        ft =
          file_tree_state(state)
          |> FileTreeState.start_editing(index, type)
          |> FileTreeState.replace_tree(tree)

        state = set_file_tree(state, ft)
        sync_buffer(state)
    end
  end

  @doc """
  Enters inline editing mode to rename the selected entry.

  Pre-fills the input with the current entry name.
  """
  @spec rename(state()) :: state()
  def rename(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} ->
        state

      %FileTreeState{tree: tree} ->
        case FileTree.selected_entry(tree) do
          nil ->
            state

          entry ->
            ft =
              FileTreeState.start_editing(
                file_tree_state(state),
                tree.cursor,
                :rename,
                entry.name
              )

            set_file_tree(state, ft)
        end
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
  def confirm_editing(state) do
    case file_tree_state(state).editing do
      nil -> state
      %{text: ""} -> cancel_editing(state)
      %{type: :new_file} = editing -> confirm_new_file(state, editing)
      %{type: :new_folder} = editing -> confirm_new_folder(state, editing)
      %{type: :rename} -> confirm_rename(state)
    end
  end

  @spec confirm_new_file(state(), map()) :: state()
  defp confirm_new_file(state, editing) do
    parent_dir = editing_parent_dir(state)
    full_path = Path.join(parent_dir, editing.text)

    File.mkdir_p!(Path.dirname(full_path))
    File.touch!(full_path)

    state = clear_editing_and_refresh(state)

    case Commands.start_buffer(full_path, EditorState.options_server(state)) do
      {:ok, pid} ->
        BufferRegistry.do_file_tree_open(state, pid, full_path, file_tree_state(state).tree)

      {:error, reason} ->
        MingaEditor.log_to_messages("[file-tree] Failed to open #{full_path}: #{inspect(reason)}")

        state
    end
  end

  @spec confirm_new_folder(state(), map()) :: state()
  defp confirm_new_folder(state, editing) do
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

  @spec confirm_rename(state()) :: state()
  defp confirm_rename(state) do
    case file_tree_state(state).tree do
      %FileTree{} = tree ->
        case FileTree.selected_entry(tree) do
          nil -> cancel_editing(state)
          entry -> do_rename(state, entry, file_tree_state(state).editing.text)
        end

      nil ->
        cancel_editing(state)
    end
  end

  @doc """
  Enters delete confirmation mode for the selected file tree entry.

  Transitions to `:delete_confirm` mode, prompting the user with y/n.
  For directories, includes a child count in the prompt.
  """
  @spec delete(state()) :: state()
  def delete(state) do
    with %FileTreeState{tree: %FileTree{} = tree} <- file_tree_state(state),
         %{} = entry <- FileTree.selected_entry(tree) do
      child_count = if entry.dir?, do: count_children(entry.path), else: 0
      ms = DeleteConfirmState.new(entry.path, entry.name, entry.dir?, child_count)
      EditorState.transition_mode(state, :delete_confirm, ms)
    else
      _ -> state
    end
  end

  @doc "Duplicates the selected file or directory with a \" copy\" suffix."
  @spec duplicate(state()) :: state()
  def duplicate(state) do
    with %FileTreeState{tree: %FileTree{} = tree} <- file_tree_state(state),
         %{} = entry <- FileTree.selected_entry(tree) do
      dest = unique_copy_path(entry.path)

      result =
        if entry.dir?,
          do: File.cp_r(entry.path, dest),
          else: File.cp(entry.path, dest)

      handle_duplicate_result(state, entry, dest, result)
    else
      _ -> state
    end
  end

  @spec handle_duplicate_result(state(), map(), String.t(), term()) :: state()
  defp handle_duplicate_result(state, entry, dest, result) do
    case result do
      :ok ->
        log_duplicate_success(entry, dest)
        refresh(state)

      {:ok, _} ->
        log_duplicate_success(entry, dest)
        refresh(state)

      {:error, reason, _} ->
        MingaEditor.log_to_messages("[file-tree] Duplicate failed: #{inspect(reason)}")
        state

      {:error, reason} ->
        MingaEditor.log_to_messages("[file-tree] Duplicate failed: #{inspect(reason)}")
        state
    end
  end

  @spec log_duplicate_success(map(), String.t()) :: :ok
  defp log_duplicate_success(entry, dest) do
    MingaEditor.log_to_messages("[file-tree] Duplicated: #{entry.name} → #{Path.basename(dest)}")
  end

  @doc """
  Moves a file/directory from `source_index` into the directory at `target_dir_index`.

  If the target is not a directory, uses its parent directory.
  """
  @spec move(state(), non_neg_integer(), non_neg_integer()) :: state()
  def move(state, source_index, target_dir_index) do
    case file_tree_state(state).tree do
      nil -> move_without_tree(state)
      tree -> move_with_tree(state, tree, source_index, target_dir_index)
    end
  end

  @spec move_without_tree(state()) :: state()
  defp move_without_tree(state), do: state

  @spec move_with_tree(state(), FileTree.t(), non_neg_integer(), non_neg_integer()) :: state()
  defp move_with_tree(state, tree, source_index, target_dir_index) do
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

  @doc "Handles a native GUI file-tree drop intent with BEAM-owned filesystem operations."
  @spec drop(state(), DropIntent.t()) :: state()

  def drop(state, %DropIntent{} = intent) do
    case file_tree_state(state).tree do
      nil ->
        MingaEditor.log_to_messages("[file-tree] Drop rejected: file tree is unavailable")
        state

      tree ->
        drop_with_tree(state, tree, intent)
    end
  end

  @spec drop_with_tree(state(), FileTree.t(), DropIntent.t()) :: state()
  defp drop_with_tree(state, tree, %DropIntent{} = intent) do
    entries = FileTree.visible_entries(tree)

    case drop_target_dir(entries, intent) do
      {:ok, target_dir} ->
        {state, changed?} =
          apply_drop_sources(state, intent.source_paths, target_dir, entries, tree.root)

        refresh_after_drop(state, changed?)

      :error ->
        log_stale_drop_target(entries, intent)
        state
    end
  end

  @doc "Cancels the current inline edit without making changes."
  @spec cancel_editing(state()) :: state()
  def cancel_editing(state) do
    case file_tree_state(state).editing do
      nil -> state
      _editing -> set_file_tree(state, FileTreeState.cancel_editing(file_tree_state(state)))
    end
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
        tree = FileTree.reveal(file_tree_state(state).tree, path)
        state = sync_and_update(state, tree)
        state = update_file_tree(state, &FileTreeState.focus/1)

        state
        |> EditorState.set_keymap_scope(:file_tree)
        |> EditorState.set_sidebar_active_id("file_tree")
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
  def close(state) do
    case file_tree_state(state).buffer do
      buf when is_pid(buf) -> GenServer.stop(buf, :normal)
      _ -> :ok
    end

    scope = restore_scope(state)

    state
    |> EditorState.update_file_tree(&FileTreeState.close/1)
    |> EditorState.set_keymap_scope(scope)
    |> EditorState.set_sidebar_active_id(nil)
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec mark_for_paste(state(), FileTreeState.clipboard_operation()) :: state()
  defp mark_for_paste(state, operation) do
    with %FileTreeState{tree: %FileTree{} = tree} <- file_tree_state(state),
         %{} = entry <- FileTree.selected_entry(tree) do
      store_clipboard_mark(state, entry, operation)
    else
      _ -> state
    end
  end

  @spec store_clipboard_mark(state(), FileTree.entry(), FileTreeState.clipboard_operation()) ::
          state()
  defp store_clipboard_mark(state, entry, operation) do
    label = if operation == :copy, do: "copy", else: "move"

    state =
      update_file_tree(
        state,
        &FileTreeState.mark_clipboard(
          &1,
          Path.expand(entry.path),
          entry.name,
          entry.dir?,
          operation
        )
      )

    EditorState.set_status(state, "Marked #{entry.name} for #{label}")
  end

  @spec selected_target_dir(FileTree.t()) :: String.t()
  defp selected_target_dir(%FileTree{} = tree) do
    case FileTree.selected_entry(tree) do
      %{dir?: true, path: path} -> path
      %{dir?: false, path: path} -> Path.dirname(path)
      nil -> tree.root
    end
  end

  @spec paste_marked_entry(state(), FileTreeState.clipboard_mark(), String.t()) :: state()
  defp paste_marked_entry(state, %{operation: :copy} = mark, destination) do
    execute_copy(state, mark, destination)
  end

  defp paste_marked_entry(state, %{operation: :move} = mark, destination) do
    if same_path?(mark.path, destination) do
      state
    else
      execute_marked_move(state, mark, destination)
    end
  end

  @spec execute_marked_move(state(), FileTreeState.clipboard_mark(), String.t()) :: state()
  defp execute_marked_move(state, mark, destination) do
    case move_destination_status(mark, destination) do
      :ok ->
        case guarded_rename(mark.path, destination) do
          :ok -> marked_move_succeeded(state, mark, destination)
          {:error, reason} -> marked_move_failed(state, mark.path, destination, reason)
        end

      {:error, reason} ->
        marked_move_failed(state, mark.path, destination, reason)
    end
  end

  @spec marked_move_succeeded(state(), FileTreeState.clipboard_mark(), String.t()) :: state()
  defp marked_move_succeeded(state, mark, destination) do
    state = sync_moved_buffer_path(state, mark.path, destination, "Move")
    MingaEditor.log_to_messages("[file-tree] Moved: #{mark.name} → #{Path.dirname(destination)}")

    state
    |> refresh()
    |> update_file_tree(&FileTreeState.clear_clipboard/1)
  end

  @spec marked_move_failed(state(), String.t(), String.t(), term()) :: state()
  defp marked_move_failed(state, source, destination, reason) do
    MingaEditor.log_to_messages(
      "[file-tree] Move failed: #{source} → #{destination}: #{inspect(reason)}"
    )

    state
  end

  @spec execute_copy(state(), FileTreeState.clipboard_mark(), String.t()) :: state()
  defp execute_copy(state, mark, destination) do
    execute_copy_with_destination_check(
      state,
      mark,
      destination,
      copy_destination_status(mark, destination)
    )
  end

  @spec copy_destination_status(FileTreeState.clipboard_mark(), String.t()) ::
          :ok | {:error, term()}
  defp copy_destination_status(%{dir?: true, path: source}, destination) do
    expanded_source = Path.expand(source)
    expanded_destination = Path.expand(destination)

    if path_under_root?(expanded_destination, expanded_source) do
      {:error, {:destination_inside_source, destination}}
    else
      copy_destination_exists_status(destination)
    end
  end

  defp copy_destination_status(_mark, destination),
    do: copy_destination_exists_status(destination)

  @spec copy_destination_exists_status(String.t()) :: :ok | {:error, term()}
  defp copy_destination_exists_status(destination) do
    if path_entry_exists?(destination),
      do: {:error, {:destination_exists, destination}},
      else: :ok
  end

  @spec move_destination_status(FileTreeState.clipboard_mark(), String.t()) ::
          :ok | {:error, term()}
  defp move_destination_status(%{dir?: true, path: source}, destination) do
    expanded_source = Path.expand(source)
    expanded_destination = Path.expand(destination)

    if path_under_root?(expanded_destination, expanded_source) do
      {:error, {:destination_inside_source, destination}}
    else
      copy_destination_exists_status(destination)
    end
  end

  defp move_destination_status(_mark, destination),
    do: copy_destination_exists_status(destination)

  @spec execute_copy_with_destination_check(
          state(),
          FileTreeState.clipboard_mark(),
          String.t(),
          :ok | {:error, term()}
        ) :: state()
  defp execute_copy_with_destination_check(state, mark, destination, :ok) do
    do_copy_marked_entry(state, mark, destination)
  end

  defp execute_copy_with_destination_check(state, _mark, _destination, {:error, reason}) do
    MingaEditor.log_to_messages("[file-tree] Copy failed: #{inspect(reason)}")
    state
  end

  @spec do_copy_marked_entry(state(), FileTreeState.clipboard_mark(), String.t()) :: state()
  defp do_copy_marked_entry(state, mark, destination) do
    result =
      if mark.dir?, do: File.cp_r(mark.path, destination), else: File.cp(mark.path, destination)

    case result do
      :ok ->
        copy_succeeded(state, mark, destination)

      {:ok, _files} ->
        copy_succeeded(state, mark, destination)

      {:error, reason, file} ->
        copy_failed_with_cleanup(state, mark.path, destination, reason, file)

      {:error, reason} ->
        copy_failed(state, mark.path, destination, reason)
    end
  end

  @spec copy_succeeded(state(), FileTreeState.clipboard_mark(), String.t()) :: state()
  defp copy_succeeded(state, mark, destination) do
    MingaEditor.log_to_messages("[file-tree] Copied: #{mark.name} → #{Path.dirname(destination)}")
    refresh(state)
  end

  @spec copy_failed_with_cleanup(state(), String.t(), String.t(), term(), String.t()) :: state()
  defp copy_failed_with_cleanup(state, source, destination, reason, file) do
    cleanup_result = cleanup_partial_copy(destination)

    MingaEditor.log_to_messages(
      "[file-tree] Copy failed: #{source} → #{destination} at #{file}: #{inspect(reason)}. #{cleanup_result}"
    )

    state
  end

  @spec copy_failed(state(), String.t(), String.t(), term()) :: state()
  defp copy_failed(state, source, destination, reason) do
    MingaEditor.log_to_messages(
      "[file-tree] Copy failed: #{source} → #{destination}: #{inspect(reason)}"
    )

    state
  end

  @spec reroot(state(), String.t()) :: state()
  defp reroot(state, root) do
    case file_tree_state(state).tree do
      %FileTree{} = tree ->
        FileTreeFreshness.unwatch_expanded_dirs(tree)

        new_tree =
          tree
          |> FileTree.reroot(root)
          |> FileTree.refresh_git_status()

        FileTreeFreshness.watch_expanded_dirs(new_tree)
        sync_and_update(state, new_tree)

      nil ->
        state
    end
  end

  # Mutual exclusivity: close git status panel when opening file tree.
  # Explicitly resets keymap_scope to :editor so we don't leave orphaned
  # :git_status scope if a future refactor separates the open steps.
  @spec close_git_status_if_open(state()) :: state()
  defp close_git_status_if_open(%{shell_state: %{git_status_panel: nil}} = state), do: state

  defp close_git_status_if_open(state),
    do:
      state
      |> EditorState.set_keymap_scope(:editor)
      |> EditorState.close_git_status_panel()

  # Opens a file from the tree, reusing an existing buffer when one exists
  # for the same path. Without the dedup check, the file tree creates
  # duplicate Buffer.Process processes for the same file, which causes stale
  # tree-sitter highlight spans from the old buffer's parse to be misrouted
  # to the new buffer (garbled text on first render).
  @spec open_file_from_tree(state(), String.t(), FileTree.t()) :: state()
  defp open_file_from_tree(state, path, tree) do
    case EditorState.find_buffer_by_path(state, path) do
      nil ->
        case Commands.start_buffer(path, EditorState.options_server(state)) do
          {:ok, pid} ->
            BufferRegistry.do_file_tree_open(state, pid, path, tree)

          {:error, :binary_file} ->
            EditorState.set_status(state, "Cannot open binary file: #{Path.basename(path)}")

          {:error, _} ->
            EditorState.set_status(state, "Cannot open: #{Path.basename(path)}")
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

        update_file_tree(state, &FileTreeState.set_tree(&1, FileTree.reveal(tree, path)))
    end
  end

  # Opens the tree if not already open. Used by reveal_active_file to
  # ensure the tree exists before calling FileTree.reveal.
  @spec ensure_tree_open(state()) :: state()
  defp ensure_tree_open(state) do
    case file_tree_state(state).tree do
      %FileTree{} -> state
      nil -> open(state)
    end
  end

  @spec open(state()) :: state()
  defp open(state) do
    state = close_git_status_if_open(state)

    root = file_tree_state(state).project_root || Minga.Project.root() || File.cwd!()
    tree = FileTree.new(root)
    tree = FileTree.refresh_git_status(tree)
    tree = reveal_active(tree, state.workspace.buffers.active)
    FileTreeFreshness.watch_expanded_dirs(tree)
    buf = BufferSync.start_buffer(tree, EditorState.options_server(state))

    state
    |> EditorState.update_file_tree(&FileTreeState.open(&1, tree, buf))
    |> EditorState.set_keymap_scope(:file_tree)
    |> EditorState.set_sidebar_active_id("file_tree")
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
  defp sync_and_update(state, new_tree) do
    FileTreeFreshness.watch_expanded_dirs(new_tree)

    case file_tree_state(state).buffer do
      buf when is_pid(buf) -> BufferSync.sync(buf, new_tree)
      _ -> :ok
    end

    update_file_tree(state, &FileTreeState.set_tree(&1, new_tree))
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
  defp editing_parent_dir(state) do
    %{editing: editing, tree: tree} = file_tree_state(state)
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

  @spec apply_drop_sources(state(), [String.t()], String.t(), [FileTree.entry()], String.t()) ::
          {state(), boolean()}
  defp apply_drop_sources(state, source_paths, target_dir, entries, root) do
    Enum.reduce(source_paths, {state, false}, fn source_path, acc ->
      apply_drop_source_result(source_path, acc, target_dir, entries, root)
    end)
  end

  @spec apply_drop_source_result(
          String.t(),
          {state(), boolean()},
          String.t(),
          [FileTree.entry()],
          String.t()
        ) :: {state(), boolean()}
  defp apply_drop_source_result(source_path, {state, changed?}, target_dir, entries, root) do
    case apply_drop_source(state, source_path, target_dir, entries, root) do
      {:changed, next_state} -> {next_state, true}
      {:unchanged, next_state} -> {next_state, changed?}
    end
  end

  @spec refresh_after_drop(state(), boolean()) :: state()
  defp refresh_after_drop(state, true), do: refresh(state)
  defp refresh_after_drop(state, false), do: state

  # Validates the GUI-reported drop target against the current BEAM-owned tree.
  @spec drop_target_dir([FileTree.entry()], DropIntent.t()) :: {:ok, String.t()} | :error
  defp drop_target_dir(entries, %DropIntent{} = intent) do
    case Enum.at(entries, intent.target_index) do
      nil ->
        :error

      target ->
        if drop_target_matches?(target, intent) do
          {:ok, drop_target_dir_path(target)}
        else
          :error
        end
    end
  end

  @spec drop_target_matches?(FileTree.entry(), DropIntent.t()) :: boolean()
  defp drop_target_matches?(target, %DropIntent{} = intent) do
    same_path?(target.path, intent.target_path) and same_path?(target.path, intent.target_id) and
      :erlang.phash2(Path.expand(target.path), 0xFFFFFFFF) == intent.target_path_hash and
      target.dir? == intent.target_dir?
  end

  @spec drop_target_dir_path(FileTree.entry()) :: String.t()
  defp drop_target_dir_path(%{dir?: true, path: path}), do: path
  defp drop_target_dir_path(%{dir?: false, path: path}), do: Path.dirname(path)

  @spec apply_drop_source(state(), String.t(), String.t(), [FileTree.entry()], String.t()) ::
          {:changed | :unchanged, state()}
  defp apply_drop_source(state, source_path, target_dir, entries, root) do
    source_path = Path.expand(source_path)
    root = Path.expand(root)

    if path_under_root?(source_path, root) do
      apply_internal_drop_source(state, source_path, target_dir, entries)
    else
      apply_external_drop_source(state, source_path, target_dir)
    end
  end

  @spec apply_internal_drop_source(state(), String.t(), String.t(), [FileTree.entry()]) ::
          {:changed | :unchanged, state()}
  defp apply_internal_drop_source(state, source_path, target_dir, entries) do
    case Enum.find(entries, &same_expanded_path?(&1.path, source_path)) do
      nil ->
        MingaEditor.log_to_messages("[file-tree] Drop rejected: stale source #{source_path}")
        {:unchanged, state}

      source ->
        move_drop_source(state, source, target_dir)
    end
  end

  @spec move_drop_source(state(), FileTree.entry(), String.t()) ::
          {:changed | :unchanged, state()}
  defp move_drop_source(state, source, target_dir) do
    new_path = Path.join(target_dir, source.name)

    if same_path?(source.path, new_path) do
      {:unchanged, state}
    else
      case guarded_rename(source.path, new_path) do
        :ok ->
          state = sync_moved_buffer_path(state, source.path, new_path, "Move")

          MingaEditor.log_to_messages(
            "[file-tree] Moved: #{source.name} → #{Path.dirname(new_path)}"
          )

          {:changed, state}

        {:error, reason} ->
          MingaEditor.log_to_messages(
            "[file-tree] Move failed: #{source.path} → #{new_path}: #{inspect(reason)}"
          )

          {:unchanged, state}
      end
    end
  end

  @spec apply_external_drop_source(state(), String.t(), String.t()) ::
          {:changed | :unchanged, state()}
  defp apply_external_drop_source(state, source_path, target_dir) do
    dest_path = Path.join(target_dir, Path.basename(source_path))

    if path_entry_exists?(dest_path) do
      MingaEditor.log_to_messages(
        "[file-tree] Drop copy skipped, destination exists: #{dest_path}"
      )

      {:unchanged, state}
    else
      copy_external_drop_source(state, source_path, dest_path)
    end
  end

  @spec copy_external_drop_source(state(), String.t(), String.t()) ::
          {:changed | :unchanged, state()}
  defp copy_external_drop_source(state, source_path, dest_path) do
    result =
      if File.dir?(source_path),
        do: File.cp_r(source_path, dest_path),
        else: File.cp(source_path, dest_path)

    case result do
      :ok ->
        MingaEditor.log_to_messages(
          "[file-tree] Copied: #{Path.basename(source_path)} → #{Path.dirname(dest_path)}"
        )

        {:changed, state}

      {:ok, _files} ->
        MingaEditor.log_to_messages(
          "[file-tree] Copied: #{Path.basename(source_path)} → #{Path.dirname(dest_path)}"
        )

        {:changed, state}

      {:error, reason, file} ->
        cleanup_result = cleanup_partial_copy(dest_path)

        MingaEditor.log_to_messages(
          "[file-tree] Drop copy failed: #{source_path} → #{dest_path} at #{file}: #{inspect(reason)}. #{cleanup_result}"
        )

        {:changed, state}

      {:error, reason} ->
        MingaEditor.log_to_messages(
          "[file-tree] Drop copy failed: #{source_path} → #{dest_path}: #{inspect(reason)}"
        )

        {:unchanged, state}
    end
  end

  @spec cleanup_partial_copy(String.t()) :: String.t()
  defp cleanup_partial_copy(dest_path) do
    case File.rm_rf(dest_path) do
      {:ok, []} -> "No partial output was found."
      {:ok, _paths} -> "Partial output was removed: #{dest_path}."
      {:error, reason, file} -> "Partial cleanup failed at #{file}: #{inspect(reason)}."
    end
  end

  @spec log_stale_drop_target([FileTree.entry()], DropIntent.t()) :: :ok
  defp log_stale_drop_target(entries, %DropIntent{} = intent) do
    current = Enum.at(entries, intent.target_index)

    MingaEditor.log_to_messages(
      "[file-tree] Drop rejected: stale target index=#{intent.target_index} target=#{intent.target_path} id=#{intent.target_id} hash=#{intent.target_path_hash}; current=#{drop_target_debug(current)}"
    )
  end

  @spec drop_target_debug(FileTree.entry() | nil) :: String.t()
  defp drop_target_debug(nil), do: "missing"

  defp drop_target_debug(entry) do
    "#{entry.path} dir?=#{entry.dir?} hash=#{:erlang.phash2(Path.expand(entry.path), 0xFFFFFFFF)}"
  end

  @spec guarded_rename(String.t(), String.t()) :: :ok | {:error, term()}
  defp guarded_rename(old_path, new_path) do
    if path_entry_exists?(new_path) do
      {:error, {:destination_exists, new_path}}
    else
      File.rename(old_path, new_path)
    end
  end

  @spec path_entry_exists?(String.t()) :: boolean()
  defp path_entry_exists?(path) do
    case File.lstat(path) do
      {:ok, _stat} -> true
      {:error, :enoent} -> false
      {:error, _reason} -> true
    end
  end

  @spec same_expanded_path?(String.t(), String.t()) :: boolean()
  defp same_expanded_path?(left, right), do: Path.expand(left) == Path.expand(right)

  @spec same_path?(String.t(), String.t()) :: boolean()
  defp same_path?(left, right), do: canonical_path(left) == canonical_path(right)

  @spec canonical_path(String.t()) :: String.t()
  defp canonical_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, real_path} -> List.to_string(real_path)
      {:error, _reason} -> Path.expand(path)
    end
  end

  @spec path_under_root?(String.t(), String.t()) :: boolean()
  defp path_under_root?(path, root),
    do: path == root or String.starts_with?(path, path_prefix(root))

  @spec path_prefix(String.t()) :: String.t()
  defp path_prefix("/"), do: "/"
  defp path_prefix(root), do: root <> "/"

  @spec clear_editing_and_refresh(state()) :: state()
  defp clear_editing_and_refresh(state) do
    ft = FileTreeState.cancel_editing(file_tree_state(state))
    state = set_file_tree(state, ft)
    refresh(state)
  end

  # Syncs the buffer after editing state changes.
  @spec sync_buffer(state()) :: state()
  defp sync_buffer(state) do
    case file_tree_state(state) do
      %FileTreeState{buffer: buf, tree: tree} when is_pid(buf) -> BufferSync.sync(buf, tree)
      %FileTreeState{} -> :ok
    end

    state
  end

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
    case guarded_rename(old_path, new_path) do
      :ok ->
        state = sync_moved_buffer_path(state, old_path, new_path, "Rename")

        MingaEditor.log_to_messages(
          "[file-tree] Renamed: #{Path.basename(old_path)} \u2192 #{new_name}"
        )

        clear_editing_and_refresh(state)

      {:error, reason} ->
        MingaEditor.log_to_messages(
          "[file-tree] Rename failed: #{old_path} → #{new_path}: #{inspect(reason)}"
        )

        cancel_editing(state)
    end
  end

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

  @spec sync_moved_buffer_path(state(), String.t(), String.t(), String.t()) :: state()
  defp sync_moved_buffer_path(state, old_path, new_path, action) do
    {state, errors} = update_buffer_path(state, old_path, new_path)

    if errors != [] do
      MingaEditor.log_to_messages(
        "[file-tree] #{action} completed on disk, but open buffer path update failed: #{old_path} → #{new_path}: #{inspect(errors)}"
      )
    end

    state
  end

  @spec update_buffer_path(state(), String.t(), String.t()) :: {state(), [{String.t(), term()}]}
  defp update_buffer_path(state, old_path, new_path) do
    old_path = Path.expand(old_path)
    new_path = Path.expand(new_path)
    buffer_pids = EditorState.known_open_buffer_pids(state)

    Enum.reduce(buffer_pids, {state, []}, fn pid, {acc_state, errors} ->
      update_buffer_pid_path(pid, acc_state, errors, old_path, new_path)
    end)
  end

  @spec update_buffer_pid_path(pid(), state(), [{String.t(), term()}], String.t(), String.t()) ::
          {state(), [{String.t(), term()}]}
  defp update_buffer_pid_path(pid, state, errors, old_path, new_path) do
    case safe_buffer_file_path(pid) do
      nil ->
        {state, errors}

      path ->
        retarget_moved_buffer(
          pid,
          state,
          errors,
          path,
          moved_buffer_path(path, old_path, new_path)
        )
    end
  end

  @spec retarget_moved_buffer(
          pid(),
          state(),
          [{String.t(), term()}],
          String.t(),
          String.t() | nil
        ) ::
          {state(), [{String.t(), term()}]}
  defp retarget_moved_buffer(_pid, state, errors, _path, nil), do: {state, errors}

  defp retarget_moved_buffer(pid, state, errors, path, moved_path) do
    case safe_retarget_path(pid, moved_path) do
      :ok -> {EditorState.rebind_buffer_file_identity(state, pid), errors}
      {:error, reason} -> {state, [{path, reason} | errors]}
    end
  end

  @spec safe_retarget_path(pid(), String.t()) :: :ok | {:error, term()}
  defp safe_retarget_path(pid, moved_path) do
    Buffer.retarget_path(pid, moved_path)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec safe_buffer_file_path(pid()) :: String.t() | nil
  defp safe_buffer_file_path(pid) do
    Buffer.file_path(pid)
  catch
    :exit, _ -> nil
  end

  @spec moved_buffer_path(String.t(), String.t(), String.t()) :: String.t() | nil
  defp moved_buffer_path(path, old_path, new_path) do
    expanded_path = Path.expand(path)

    if expanded_path == old_path do
      new_path
    else
      moved_descendant_buffer_path(expanded_path, old_path, new_path)
    end
  end

  @spec moved_descendant_buffer_path(String.t(), String.t(), String.t()) :: String.t() | nil
  defp moved_descendant_buffer_path(expanded_path, old_path, new_path) do
    prefix = path_prefix(old_path)

    if String.starts_with?(expanded_path, prefix) do
      suffix = String.replace_prefix(expanded_path, prefix, "")
      Path.join(new_path, suffix)
    end
  end

  @spec unique_copy_path(String.t()) :: String.t()
  defp unique_copy_path(path) do
    ext = Path.extname(path)
    base = Path.rootname(path)
    candidate = "#{base} copy#{ext}"

    if path_entry_exists?(candidate) do
      find_unique_copy(base, ext, 2)
    else
      candidate
    end
  end

  @spec find_unique_copy(String.t(), String.t(), pos_integer()) :: String.t()
  defp find_unique_copy(base, ext, n) do
    candidate = "#{base} copy #{n}#{ext}"

    if path_entry_exists?(candidate),
      do: find_unique_copy(base, ext, n + 1),
      else: candidate
  end

  @spec execute_move(state(), String.t(), String.t(), String.t()) :: state()
  defp execute_move(state, old_path, new_path, name) do
    case guarded_rename(old_path, new_path) do
      :ok ->
        state = sync_moved_buffer_path(state, old_path, new_path, "Move")

        MingaEditor.log_to_messages("[file-tree] Moved: #{name} → #{Path.dirname(new_path)}")

        refresh(state)

      {:error, reason} ->
        MingaEditor.log_to_messages(
          "[file-tree] Move failed: #{old_path} → #{new_path}: #{inspect(reason)}"
        )

        state
    end
  end

  command(:toggle_file_tree, "Toggle file tree", requires_buffer: false, execute: &toggle/1)

  command(:tree_open_or_toggle, "Open file or toggle directory",
    requires_buffer: false,
    execute: &open_or_toggle/1
  )

  command(:tree_toggle_directory, "Toggle directory in tree",
    requires_buffer: false,
    execute: &toggle_directory/1
  )

  command(:tree_expand, "Expand tree node", requires_buffer: false, execute: &expand/1)
  command(:tree_collapse, "Collapse tree node", requires_buffer: false, execute: &collapse/1)

  command(:tree_toggle_hidden, "Toggle hidden files in tree",
    requires_buffer: false,
    execute: &toggle_hidden/1
  )

  command(:tree_refresh, "Refresh file tree", requires_buffer: false, execute: &refresh/1)
  command(:tree_copy_path, "Copy file tree path", requires_buffer: false, execute: &copy_path/1)

  command(:tree_mark_copy, "Mark file tree entry for copy",
    requires_buffer: false,
    execute: &mark_copy/1
  )

  command(:tree_mark_move, "Mark file tree entry for move",
    requires_buffer: false,
    execute: &mark_move/1
  )

  command(:tree_paste, "Paste marked file tree entry", requires_buffer: false, execute: &paste/1)

  command(:tree_root_parent, "Root file tree at parent directory",
    requires_buffer: false,
    execute: &root_parent/1
  )

  command(:tree_root_selected, "Root file tree at selected directory",
    requires_buffer: false,
    execute: &root_selected/1
  )

  command(:tree_root_original, "Restore file tree project root",
    requires_buffer: false,
    execute: &root_original/1
  )

  command(:tree_filter, "Filter file tree", requires_buffer: false, execute: &filter/1)

  command(:tree_toggle_help, "Toggle file tree help",
    requires_buffer: false,
    execute: &toggle_help/1
  )

  command(:tree_close, "Close file tree", requires_buffer: false, execute: &close/1)

  command(:tree_collapse_all, "Collapse all directories in tree",
    requires_buffer: false,
    execute: &collapse_all/1
  )

  command(:tree_new_file, "Create new file in tree", requires_buffer: false, execute: &new_file/1)

  command(:tree_new_folder, "Create new folder in tree",
    requires_buffer: false,
    execute: &new_folder/1
  )

  command(:tree_rename, "Rename file or folder in tree",
    requires_buffer: false,
    execute: &rename/1
  )

  command(:tree_confirm_editing, "Confirm file tree inline edit",
    requires_buffer: false,
    execute: &confirm_editing/1
  )

  command(:tree_cancel_editing, "Cancel file tree inline edit",
    requires_buffer: false,
    execute: &cancel_editing/1
  )

  command(:tree_reveal_active, "Reveal active file in tree",
    requires_buffer: false,
    execute: &reveal_active_file/1
  )

  command(:tree_delete, "Delete file or folder in tree",
    requires_buffer: false,
    execute: &delete/1
  )

  command(:tree_duplicate, "Duplicate file or folder in tree",
    requires_buffer: false,
    execute: &duplicate/1
  )
end
