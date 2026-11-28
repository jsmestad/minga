defmodule MingaEditor.Commands.FileTree do
  @moduledoc """
  File tree commands: toggling the tree panel, navigating entries,
  expanding/collapsing directories, and opening files from the tree.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.Helpers
  alias MingaEditor.Commands.FileTree.NewFileBackend
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Layout
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.Session.State
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias Minga.Mode.DeleteConfirmState
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias MingaEditor.FileTree.Copy
  alias MingaEditor.FileTree.DropIntent
  alias MingaEditor.FileTree.EmptyFolder
  alias MingaEditor.FileTree.Freshness, as: FileTreeFreshness
  alias MingaEditor.FileTree.Mutation
  alias Minga.Log

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Handles semantic sidebar actions from native frontends or generic sidebar input."
  @spec handle_sidebar_action(state(), String.t(), map()) :: state()
  def handle_sidebar_action(state, "toggle", _context), do: toggle(state)

  def handle_sidebar_action(state, "activate", _context) do
    if file_tree_state(state) |> FileTreeState.status() |> FileTreeState.visible_status?() do
      focus_visible_tree(state)
    else
      toggle(state)
    end
  end

  def handle_sidebar_action(state, _action, _context), do: state

  @spec toggle(state()) :: state()
  def toggle(state) do
    file_tree = file_tree_state(state)

    case FileTreeState.tree(file_tree) do
      nil -> open(state)
      %FileTree{} when file_tree.visibility == :hidden -> show_tree(state)
      %FileTree{} -> hide_tree(state)
    end
  end

  @spec focus_visible_tree(state()) :: state()
  defp focus_visible_tree(state) do
    state |> focus_tree() |> SidebarWorkflow.select("file_tree") |> Layout.invalidate()
  end

  @doc """
  Moves keyboard focus into a visible file tree.

  The tree always operates in Normal mode. Focusing it marks the tree focused, sets the `:file_tree` keymap scope, blurs the Agent composer, and leaves text entry, so leader keys reach the tree instead of a draft or buffer. Callers that reveal or open the tree apply that visibility transition first.
  """
  @spec focus_tree(state()) :: state()
  def focus_tree(state) do
    state = state |> update_file_tree(&FileTreeState.focus/1) |> leave_text_entry()
    %{state | workspace: State.set_keymap_scope(state.workspace, :file_tree)}
  end

  @doc """
  Returns keyboard focus from the file tree to the active window.

  Surfaces that take focus without moving through a window, such as a click on the Agent composer, call this so the `:file_tree` scope does not keep claiming their keys. The tree stays visible.
  """
  @spec leave_focus(state()) :: state()
  def leave_focus(%{workspace: %{keymap_scope: :file_tree}} = state) do
    state = update_file_tree(state, &FileTreeState.unfocus/1)
    %{state | workspace: State.set_keymap_scope(state.workspace, restore_scope(state))}
  end

  def leave_focus(state), do: state

  @spec leave_text_entry(state()) :: state()
  defp leave_text_entry(%{workspace: %{agent_ui: %{panel: %{input_focused: true}}}} = state),
    do: AgentCommands.scope_unfocus_input(state)

  defp leave_text_entry(%{workspace: %{editing: %{mode: mode}}} = state)
       when mode in [:insert, :replace],
       do: %{state | workspace: State.transition_mode(state.workspace, :normal)}

  defp leave_text_entry(state), do: state

  # Reveals a hidden-but-loaded tree. The data, buffer, and watchers are still
  # alive, so this is a pure layout change with no filesystem rebuild (#2626).
  @spec show_tree(state()) :: state()
  defp show_tree(state) do
    state
    |> update_file_tree(&FileTreeState.show/1)
    |> focus_tree()
    |> SidebarWorkflow.select("file_tree")
    |> Layout.invalidate()
  end

  # Hides the sidebar without tearing down the tree. The backing buffer keeps
  # running and watched directories stay registered so the model stays fresh and
  # ready to re-show instantly (#2626).
  @spec hide_tree(state()) :: state()
  defp hide_tree(state) do
    scope = restore_scope(state)
    state = update_file_tree(state, &FileTreeState.hide/1)
    workspace = State.set_keymap_scope(state.workspace, scope)
    state = %{state | workspace: workspace}

    state |> SidebarWorkflow.select(nil) |> Layout.invalidate()
  end

  @spec restore_scope(state()) :: atom()
  defp restore_scope(state),
    do: State.scope_for_active_window(state.workspace)

  @spec file_tree_state(state()) :: FileTreeState.t()
  defp file_tree_state(state), do: state.workspace.file_tree

  @spec set_file_tree(state(), FileTreeState.t()) :: state()
  defp set_file_tree(state, file_tree) do
    %{state | workspace: State.set_file_tree(state.workspace, file_tree)}
  end

  @spec update_file_tree(state(), (FileTreeState.t() -> FileTreeState.t())) :: state()
  defp update_file_tree(state, fun) when is_function(fun, 1) do
    %{
      state
      | workspace:
          State.set_file_tree(
            state.workspace,
            fun.(state.workspace.file_tree)
          )
    }
  end

  @spec project_browse(state()) :: state()
  def project_browse(state) do
    file_tree = file_tree_state(state)

    case FileTreeState.tree(file_tree) do
      nil -> open(state)
      %FileTree{} when file_tree.visibility == :hidden -> show_tree(state)
      %FileTree{} -> focus_visible_tree(state)
    end
  end

  # In an empty folder ↩ runs the preselected next step (New file, New folder).
  @spec open_or_toggle(state()) :: state()
  def open_or_toggle(state) do
    file_tree = file_tree_state(state)

    if FileTreeState.status(file_tree) == :empty do
      MingaEditor.Commands.execute(
        state,
        EmptyFolder.command_at(FileTreeState.empty_selected(file_tree))
      )
    else
      open_or_toggle_tree(state, file_tree)
    end
  end

  @spec open_or_toggle_tree(state(), FileTreeState.t()) :: state()
  defp open_or_toggle_tree(state, file_tree) do
    case FileTreeState.resident_tree(file_tree) do
      %FileTree{} = tree ->
        open_or_toggle_entry(state, tree, FileTree.selected_entry(tree))

      nil ->
        state
    end
  end

  @doc "Opens the exact resolved entry, selecting it only for a primary activation."
  @spec activate_entry(state(), FileTree.t(), FileTree.entry(), :primary | :toggle) :: state()
  def activate_entry(state, tree, entry, :primary) do
    {:ok, selected} = FileTree.select_path(tree, entry.path)
    state = update_file_tree(state, &FileTreeState.set_tree(&1, selected))
    open_or_toggle_entry(state, selected, entry)
  end

  def activate_entry(state, tree, %{dir?: true} = entry, :toggle) do
    {:ok, selected} = FileTree.select_path(tree, entry.path)

    selection =
      case FileTree.selected_entry(tree) do
        %{path: path} -> path
        nil -> nil
      end

    FileTreeFreshness.scan_loading(state, FileTree.toggle_expand(selected),
      selection_path: selection
    )
  end

  def activate_entry(state, _tree, %{dir?: false}, :toggle), do: state

  @doc "Starts creation at an admitted parent, independently of the tree cursor."
  @spec new_entry_at(state(), FileTree.t(), FileTree.entry() | nil, :new_file | :new_folder) ::
          state()
  def new_entry_at(state, tree, nil, type) do
    admit_new_entry(state, 0, tree.root, type)
  end

  def new_entry_at(state, tree, %{dir?: true, path: path}, type) do
    if MapSet.member?(tree.expanded, path) do
      {:ok, selected} = FileTree.select_path(tree, path)
      admit_new_entry(state, selected.cursor + 1, path, type)
    else
      pending = FileTree.expand_path(tree, path)

      FileTreeFreshness.scan_loading(state, pending,
        selection_path: FileTree.selected_entry(tree).path,
        creation: {type, path}
      )
    end
  end

  def new_entry_at(state, tree, %{path: path}, type) do
    {:ok, selected} = FileTree.select_path(tree, path)
    admit_new_entry(state, selected.cursor + 1, Path.dirname(path), type)
  end

  @doc "Starts renaming an admitted entry without changing tree selection."
  @spec rename_entry(state(), FileTree.t(), FileTree.entry()) :: state()
  def rename_entry(state, tree, entry) do
    {:ok, selected} = FileTree.select_path(tree, entry.path)

    file_tree =
      FileTreeState.start_rename(
        file_tree_state(state),
        selected.cursor,
        entry,
        FileTreeFreshness.next_edit_token()
      )

    set_file_tree(state, file_tree)
  end

  @doc "Prompts to delete the admitted entry, not the selected row."
  @spec delete_entry(state(), FileTree.entry()) :: state()
  def delete_entry(state, %{identity: identity} = entry) when is_tuple(identity) do
    state = focus_tree(state)
    mode_state = DeleteConfirmState.new(entry.path, entry.name, entry.dir?, identity)
    %{state | workspace: State.transition_mode(state.workspace, :delete_confirm, mode_state)}
  end

  def delete_entry(state, _entry) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      refresh(state),
      "Could not identify the delete target. Refresh the file tree and try again."
    )
  end

  @doc "Duplicates the admitted entry without selecting it."
  @spec duplicate_entry(state(), FileTree.entry()) :: state()
  def duplicate_entry(state, entry), do: Copy.duplicate(state, entry.path)

  @spec open_or_toggle_entry(state(), FileTree.t(), FileTree.entry() | nil) :: state()
  defp open_or_toggle_entry(state, tree, %{dir?: true, path: path}) do
    FileTreeFreshness.scan_loading(state, FileTree.toggle_expand(tree), selection_path: path)
  end

  defp open_or_toggle_entry(state, tree, %{dir?: false, path: path}) do
    state = update_file_tree(state, &FileTreeState.unfocus/1)
    # Opening a file buffer always uses :editor scope (not restore_scope)
    # because the new buffer becomes the active window content.
    state = %{
      state
      | workspace: State.set_keymap_scope(state.workspace, :editor)
    }

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
  def refresh(state), do: FileTreeFreshness.request_refresh(state, 0)

  @spec with_tree(state(), (FileTree.t() -> FileTree.t())) :: state()
  defp with_tree(state, fun) do
    case FileTreeState.tree(file_tree_state(state)) do
      %FileTree{entries: entries} = tree when is_list(entries) ->
        case fun.(tree) do
          %FileTree{entries: nil} = pending ->
            FileTreeFreshness.scan_loading(state, pending)

          %FileTree{} = resident ->
            sync_tree_buffer(state, resident)
            update_file_tree(state, &FileTreeState.replace_tree_metadata(&1, resident))
        end

      _unavailable ->
        state
    end
  end

  @doc "Copies the selected entry's absolute path to the system clipboard."
  @spec copy_path(state()) :: state()
  def copy_path(state) do
    with %FileTree{} = tree <- FileTreeState.tree(file_tree_state(state)),
         %{path: path} <- FileTree.selected_entry(tree) do
      state
      |> Helpers.force_clipboard_sync(Path.expand(path))
      |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("Copied #{Path.expand(path)}")
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
    file_tree = file_tree_state(state)

    case {FileTreeState.resident_tree(file_tree), file_tree.clipboard_mark} do
      {nil, _mark} ->
        state

      {_tree, nil} ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          state,
          "No file tree copy or move is pending"
        )

      {tree, mark} ->
        target_dir = selected_target_dir(tree)
        destination = Path.join(target_dir, mark.name)
        paste_marked_entry(state, mark, destination)
    end
  end

  @doc "Changes the tree root to the parent directory of the current root."
  @spec root_parent(state()) :: state()
  def root_parent(state) do
    case FileTreeState.tree(file_tree_state(state)) do
      %FileTree{root: root} ->
        parent = Path.dirname(root)
        if parent == root, do: state, else: reroot(state, parent)

      nil ->
        state
    end
  end

  @doc "Changes the tree root to the selected directory."
  @spec root_selected(state()) :: state()
  def root_selected(state) do
    case FileTreeState.tree(file_tree_state(state)) do
      %FileTree{} = tree ->
        case FileTree.selected_entry(tree) do
          %{dir?: true, path: path} -> reroot(state, path)
          %{dir?: false} -> state
          nil -> state
        end

      nil ->
        state
    end
  end

  @doc "Restores the tree root to the original project directory."
  @spec root_original(state()) :: state()
  def root_original(state) do
    file_tree = file_tree_state(state)

    case FileTreeState.tree(file_tree) do
      nil ->
        state

      %FileTree{} when is_binary(file_tree.original_root) ->
        reroot(state, file_tree.original_root)

      %FileTree{} when is_binary(file_tree.project_root) ->
        reroot(state, file_tree.project_root)

      %FileTree{} ->
        state
    end
  end

  @doc "Starts inline file tree filtering."
  @spec filter(state()) :: state()
  def filter(state), do: FileTreeFreshness.start_filtering(state)

  @doc "Restores unfiltered rows while keeping the filter input active."
  @spec reset_filter_query(state()) :: state()
  def reset_filter_query(state), do: FileTreeFreshness.clear_filter(state, :keep_open)

  @doc "Restores unfiltered rows and dismisses filter input."
  @spec clear_filter(state()) :: state()
  def clear_filter(state), do: FileTreeFreshness.clear_filter(state, :dismiss)

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
    case FileTreeState.resident_tree(file_tree_state(state)) do
      nil -> state
      tree -> new_entry_at(state, tree, FileTree.selected_entry(tree), type)
    end
  end

  @spec admit_new_entry(state(), non_neg_integer(), String.t(), :new_file | :new_folder) ::
          state()
  defp admit_new_entry(state, index, path, type) do
    token = FileTreeFreshness.next_edit_token()
    update_file_tree(state, &FileTreeState.start_editing(&1, index, type, path, token))
  end

  @doc """
  Enters inline editing mode to rename the selected entry.

  Pre-fills the input with the current entry name.
  """
  @spec rename(state()) :: state()
  def rename(state) do
    case FileTreeState.tree(file_tree_state(state)) do
      nil ->
        state

      tree ->
        case FileTree.selected_entry(tree) do
          nil ->
            state

          entry ->
            token = FileTreeFreshness.next_edit_token()

            ft =
              FileTreeState.start_rename(
                file_tree_state(state),
                tree.cursor,
                entry,
                token
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
    with %{} = edit <- FileTreeState.editing(file_tree_state(state)),
         {:ok, state} <- Mutation.require_idle(state) do
      case edit do
        %{text: ""} -> cancel_editing(state)
        %{type: :new_file} -> confirm_new_file(state, edit)
        %{type: :new_folder} -> confirm_new_folder(state, edit)
        %{type: :rename} -> confirm_rename(state, edit)
      end
    else
      nil -> state
      {:blocked, state} -> state
    end
  end

  @doc "Confirms native inline-edit text when its operation token is still current."
  @spec confirm_editing(state(), non_neg_integer(), String.t()) :: state()
  def confirm_editing(state, token, text)
      when is_integer(token) and token >= 0 and is_binary(text) do
    case FileTreeState.accept_edit_confirmation(file_tree_state(state), token, text) do
      {:accepted, file_tree} -> state |> set_file_tree(file_tree) |> confirm_editing()
      {:stale, _file_tree} -> stale_edit_confirmation(state)
    end
  end

  @spec confirm_new_file(state(), FileTreeState.editing()) :: state()
  defp confirm_new_file(state, %{parent_path: parent, text: name}) when is_binary(parent) do
    full_path = Path.join(parent, name)
    backend = state.interaction.file_tree_new_file_backend

    case backend.mkdir_p(Path.dirname(full_path)) do
      :ok ->
        create_new_file(state, backend, full_path)

      {:error, reason} ->
        new_file_creation_failed(state, :create_parent, Path.dirname(full_path), reason)
    end
  end

  @spec create_new_file(state(), NewFileBackend.t(), String.t()) :: state()
  defp create_new_file(state, backend, full_path) do
    case backend.touch(full_path) do
      :ok -> open_created_file(clear_editing_and_refresh(state), backend, full_path)
      {:error, reason} -> new_file_creation_failed(state, :create_file, full_path, reason)
    end
  end

  @spec open_created_file(state(), NewFileBackend.t(), String.t()) :: state()
  defp open_created_file(state, backend, full_path) do
    case backend.open_buffer(
           full_path,
           state.interaction.options_server,
           state.extension_surfaces.events_registry
         ) do
      {:ok, pid} ->
        BufferRegistry.do_file_tree_open(
          state,
          pid,
          full_path,
          FileTreeState.tree(file_tree_state(state))
        )

      {:error, reason} ->
        new_file_open_failed(state, full_path, reason)
    end
  end

  @spec new_file_creation_failed(state(), :create_parent | :create_file, String.t(), term()) ::
          state()
  defp new_file_creation_failed(state, operation, path, reason) do
    message = new_file_creation_failure_message(operation, path, reason)
    Log.warning(:editor, "[file-tree] #{message}")

    state
    |> refresh()
    |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish(message)
  end

  @spec new_file_open_failed(state(), String.t(), term()) :: state()
  defp new_file_open_failed(state, path, reason) do
    message = "Created #{path}, but opening its buffer failed: #{format_file_error(reason)}"
    Log.warning(:editor, "[file-tree] #{message}")
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, message)
  end

  @spec new_file_creation_failure_message(
          :create_parent | :create_file,
          String.t(),
          term()
        ) :: String.t()
  defp new_file_creation_failure_message(:create_parent, path, reason) do
    "New file failed to create parent directory #{path}: #{format_file_error(reason)}"
  end

  defp new_file_creation_failure_message(:create_file, path, reason) do
    "New file failed to create #{path}: #{format_file_error(reason)}"
  end

  @spec format_file_error(term()) :: String.t()
  defp format_file_error(reason) when is_atom(reason) do
    reason
    |> :file.format_error()
    |> to_string()
    |> readable_file_error(reason)
  end

  defp format_file_error(reason), do: inspect(reason)

  @spec readable_file_error(String.t(), atom()) :: String.t()
  defp readable_file_error("unknown POSIX error", reason), do: inspect(reason)
  defp readable_file_error(message, _reason), do: message

  @spec confirm_new_folder(state(), FileTreeState.editing()) :: state()
  defp confirm_new_folder(state, %{parent_path: parent, text: name}) when is_binary(parent) do
    full_path = Path.join(parent, name)

    case File.mkdir_p(full_path) do
      :ok ->
        Log.info(:editor, "[file-tree] Created folder: #{name}")
        clear_editing_and_refresh(state)

      {:error, reason} ->
        Log.warning(:editor, "[file-tree] Failed to create folder: #{inspect(reason)}")

        cancel_editing(state)
    end
  end

  @spec confirm_rename(state(), FileTreeState.editing()) :: state()
  defp confirm_rename(state, %{source_path: source_path, text: text})
       when is_binary(source_path) do
    case File.lstat(source_path) do
      {:ok, _stat} -> do_rename(state, source_path, text)
      {:error, :enoent} -> stale_rename_target(state, source_path)
      {:error, reason} -> rename_failed(state, source_path, source_path, reason)
    end
  end

  defp confirm_rename(state, _editing), do: stale_rename_target(state, nil)

  @doc """
  Enters delete confirmation mode for the selected file tree entry.

  Transitions to `:delete_confirm` mode, prompting the user with y/n.
  For directories, warns that deletion includes all contents.
  """
  @spec delete(state()) :: state()
  def delete(state) do
    with %FileTree{} = tree <- FileTreeState.tree(file_tree_state(state)),
         %{} = entry <- FileTree.selected_entry(tree) do
      delete_entry(state, entry)
    else
      _ -> state
    end
  end

  @doc "Duplicates the selected file or directory with a \" copy\" suffix."
  @spec duplicate(state()) :: state()
  def duplicate(state) do
    with %FileTree{} = tree <- FileTreeState.resident_tree(file_tree_state(state)),
         %{} = entry <- FileTree.selected_entry(tree) do
      duplicate_entry(state, entry)
    else
      _ -> state
    end
  end

  @doc "Handles a native GUI file-tree drop intent with BEAM-owned filesystem operations."
  @spec drop(state(), DropIntent.t()) :: state()

  def drop(state, %DropIntent{} = intent) do
    case FileTreeState.resident_tree(file_tree_state(state)) do
      nil ->
        Log.warning(:editor, "[file-tree] Drop rejected: file tree is unavailable")
        state

      tree ->
        drop_with_tree(state, tree, intent)
    end
  end

  @doc "Applies a drop to the resolved row, without looking up a frontend index."
  @spec drop_at(state(), FileTree.t(), FileTree.entry(), DropIntent.t()) :: state()
  def drop_at(state, tree, entry, intent) do
    apply_drop_sources(state, intent.source_paths, drop_target_dir_path(entry), tree)
  end

  @spec drop_with_tree(state(), FileTree.t(), DropIntent.t()) :: state()
  defp drop_with_tree(state, %FileTree{entries: entries} = tree, %DropIntent{} = intent) do
    case drop_target_dir(entries, intent) do
      {:ok, target_dir} ->
        apply_drop_sources(state, intent.source_paths, target_dir, tree)

      :error ->
        log_stale_drop_target(entries, intent)
        state
    end
  end

  @doc "Cancels the current inline edit without making changes."
  @spec cancel_editing(state()) :: state()
  def cancel_editing(state) do
    case FileTreeState.editing(file_tree_state(state)) do
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
        case FileTreeState.tree(file_tree_state(state)) do
          nil ->
            open(state, path)

          %FileTree{} = tree ->
            pending = FileTree.prepare_reveal(tree, path)

            state
            |> FileTreeFreshness.scan_loading(pending, selection_path: path)
            |> show_tree()
        end
    end
  end

  @spec active_editing_buffer(state()) :: pid() | nil
  defp active_editing_buffer(state) do
    case State.active_window_struct(state.workspace) do
      %{content: {:buffer, buf}} when is_pid(buf) -> buf
      _other -> state.workspace.buffers.active
    end
  end

  @spec close(state()) :: state()
  def close(state) do
    case file_tree_state(state).buffer do
      buf when is_pid(buf) -> GenServer.stop(buf, :normal)
      _ -> :ok
    end

    scope = restore_scope(state)

    state = update_file_tree(state, &FileTreeState.close/1)
    state = FileTreeFreshness.synchronize_watchers(state)
    workspace = State.set_keymap_scope(state.workspace, scope)
    state = %{state | workspace: workspace}
    SidebarWorkflow.select(state, nil)
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec mark_for_paste(state(), FileTreeState.clipboard_operation()) :: state()
  defp mark_for_paste(state, operation) do
    with %FileTree{} = tree <- FileTreeState.tree(file_tree_state(state)),
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

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "Marked #{entry.name} for #{label}"
    )
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
    Copy.paste(state, mark.path, destination)
  end

  defp paste_marked_entry(state, %{operation: :move} = mark, destination) do
    case Mutation.require_idle(state) do
      {:ok, state} ->
        if same_path?(mark.path, destination),
          do: state,
          else: execute_marked_move(state, mark, destination)

      {:blocked, state} ->
        state
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
    Log.info(:editor, "[file-tree] Moved: #{mark.name} → #{Path.dirname(destination)}")

    state
    |> refresh()
    |> update_file_tree(&FileTreeState.clear_clipboard/1)
  end

  @spec marked_move_failed(state(), String.t(), String.t(), term()) :: state()
  defp marked_move_failed(state, source, destination, reason) do
    Log.warning(
      :editor,
      "[file-tree] Move failed: #{source} → #{destination}: #{inspect(reason)}"
    )

    state
  end

  @spec move_destination_exists_status(String.t()) :: :ok | {:error, term()}
  defp move_destination_exists_status(destination) do
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
      move_destination_exists_status(destination)
    end
  end

  defp move_destination_status(_mark, destination),
    do: move_destination_exists_status(destination)

  @spec reroot(state(), String.t()) :: state()
  defp reroot(state, root), do: FileTreeFreshness.reroot(state, root)

  # Mutual exclusivity: close git status panel when opening file tree.
  @spec close_git_status_if_open(state()) :: state()
  defp close_git_status_if_open(state) do
    case SidebarWorkflow.git_status_panel(state) do
      nil ->
        state

      _panel ->
        SidebarWorkflow.close_git_status(state)
    end
  end

  # Opens a file from the tree, reusing an existing buffer when one exists
  # for the same path. Without the dedup check, the file tree creates
  # duplicate Buffer.Process processes for the same file, which causes stale
  # tree-sitter highlight spans from the old buffer's parse to be misrouted
  # to the new buffer (garbled text on first render).
  @spec open_file_from_tree(state(), String.t(), FileTree.t()) :: state()
  defp open_file_from_tree(state, path, tree) do
    case BufferRegistry.find_buffer_by_path(state, path) do
      nil ->
        case Commands.start_buffer(path, state.interaction.options_server,
               events_registry: state.extension_surfaces.events_registry
             ) do
          {:ok, pid} ->
            BufferRegistry.do_file_tree_open(state, pid, path, tree)

          {:error, :binary_file} ->
            MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
              state,
              "Cannot open binary file: #{Path.basename(path)}"
            )

          {:error, _} ->
            MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
              state,
              "Cannot open: #{Path.basename(path)}"
            )
        end

      pid ->
        # If the buffer already has a tab, switch to that tab (correctly
        # leaves agent view if needed). Otherwise fall back to buffer switch.
        {state, tab} = ShellWorkflow.resolve_tab_by_buffer(state, pid)

        state =
          if tab do
            MingaEditor.TabWorkflow.switch(state, tab.id)
          else
            buffers = Buffers.switch_to_pid(state.workspace.buffers, pid)
            MingaEditor.BufferActivation.activate(state, buffers)
          end

        update_file_tree(state, &FileTreeState.set_tree(&1, FileTree.reveal(tree, path)))
    end
  end

  @spec open(state(), String.t() | nil) :: state()
  defp open(state, reveal_path \\ nil) do
    state = close_git_status_if_open(state)
    root = file_tree_state(state).project_root || Minga.Project.root() || File.cwd!()
    buffer = active_editing_buffer(state)
    path = reveal_path || (buffer && Buffer.file_path(buffer))
    tree = FileTree.new(root)
    tree = if path, do: FileTree.prepare_reveal(tree, path), else: tree

    state
    |> FileTreeFreshness.open(tree, selection_path: path)
    |> focus_tree()
    |> SidebarWorkflow.select("file_tree")
    |> Layout.invalidate()
  end

  @spec sync_tree_buffer(state(), FileTree.t()) :: :ok
  defp sync_tree_buffer(state, tree) do
    case file_tree_state(state).buffer do
      buf when is_pid(buf) -> BufferSync.sync(buf, tree)
      _ -> :ok
    end
  end

  @spec apply_drop_sources(state(), [String.t()], String.t(), FileTree.t()) :: state()
  defp apply_drop_sources(state, source_paths, target_dir, %FileTree{root: root, entries: entries}) do
    root = Path.expand(root)

    items = Enum.map(source_paths, &admit_drop_item(Path.expand(&1), root, entries, target_dir))
    Copy.drop(state, items)
  end

  @spec admit_drop_item(String.t(), String.t(), [FileTree.entry()], String.t()) ::
          Copy.drop_item()
  defp admit_drop_item(source, root, entries, target_dir) do
    if path_under_root?(source, root) do
      case Enum.find(entries, &(Path.expand(&1.path) == source)) do
        nil -> {:stale_source, source}
        entry -> {:move, entry.path, Path.join(target_dir, entry.name)}
      end
    else
      {:copy, source, Path.join(target_dir, Path.basename(source))}
    end
  end

  # Validates the GUI-reported drop target against the current BEAM-owned tree.
  @spec drop_target_dir([FileTree.entry()], DropIntent.t()) :: {:ok, String.t()} | :error
  defp drop_target_dir(entries, %DropIntent{} = intent) do
    case Enum.find(entries, &same_path?(&1.path, intent.target_id)) do
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

  @spec log_stale_drop_target([FileTree.entry()], DropIntent.t()) :: :ok
  defp log_stale_drop_target(entries, %DropIntent{} = intent) do
    current = Enum.find(entries, &same_path?(&1.path, intent.target_id))

    Log.warning(
      :editor,
      "[file-tree] Drop rejected: stale target=#{intent.target_path} id=#{intent.target_id} hash=#{intent.target_path_hash}; current=#{drop_target_debug(current)}"
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
    ft = state |> file_tree_state() |> FileTreeState.cancel_editing()
    state = set_file_tree(state, ft)

    case {FileTreeState.status(ft), FileTreeState.tree(ft)} do
      {:empty, %FileTree{} = tree} -> FileTreeFreshness.scan_loading(state, tree)
      _ -> refresh(state)
    end
  end

  @spec do_rename(state(), String.t(), String.t()) :: state()
  defp do_rename(state, old_path, new_name) do
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

        Log.info(
          :editor,
          "[file-tree] Renamed: #{Path.basename(old_path)} \u2192 #{new_name}"
        )

        clear_editing_and_refresh(state)

      {:error, reason} ->
        rename_failed(state, old_path, new_path, reason)
    end
  end

  @spec stale_edit_confirmation(state()) :: state()
  defp stale_edit_confirmation(state) do
    Log.warning(:editor, "[file-tree] Ignored stale inline edit confirmation")

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "File tree edit is stale; try again"
    )
  end

  @spec stale_rename_target(state(), String.t() | nil) :: state()
  defp stale_rename_target(state, source_path) do
    Log.warning(:editor, "[file-tree] Rename target is stale: #{inspect(source_path)}")

    state
    |> cancel_editing()
    |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("Rename target no longer exists")
  end

  @spec rename_failed(state(), String.t(), String.t(), term()) :: state()
  defp rename_failed(state, old_path, new_path, reason) do
    Log.warning(
      :editor,
      "[file-tree] Rename failed: #{old_path} → #{new_path}: #{inspect(reason)}"
    )

    state
    |> cancel_editing()
    |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      "Rename failed: #{format_rename_error(reason)}"
    )
  end

  @spec format_rename_error(atom() | {:destination_exists, String.t()}) :: String.t()
  defp format_rename_error({:destination_exists, _path}), do: "destination already exists"

  defp format_rename_error(reason) when is_atom(reason),
    do: reason |> :file.format_error() |> to_string()

  @doc "Rebinds open buffers to paths already moved on disk."
  @spec sync_moved_buffer_path(state(), String.t(), String.t(), String.t()) :: state()
  def sync_moved_buffer_path(state, old_path, new_path, action) do
    {state, errors} = update_buffer_path(state, old_path, new_path)

    if errors != [] do
      Log.warning(
        :editor,
        "[file-tree] #{action} completed on disk, but open buffer path update failed: #{old_path} → #{new_path}: #{inspect(errors)}"
      )
    end

    if Enum.any?(errors, &match?({_path, :destination_open}, &1)) do
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
        state,
        "The moved file is already open at its new path. Use Save As for edits in the original buffer."
      )
    else
      state
    end
  end

  @spec update_buffer_path(state(), String.t(), String.t()) :: {state(), [{String.t(), term()}]}
  defp update_buffer_path(state, old_path, new_path) do
    old_path = Path.expand(old_path)
    new_path = Path.expand(new_path)
    buffer_pids = MingaEditor.BufferFileIdentity.known_open_pids(state)

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
      :ok -> {MingaEditor.BufferFileIdentity.rebind(state, pid, moved_path), errors}
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

  command(:project_browse, "Browse project",
    requires_buffer: false,
    execute: &project_browse/1
  )
end
