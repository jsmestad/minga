defmodule MingaFileTree.Freshness do
  @moduledoc """
  Keeps the editor file tree fresh in response to filesystem, git, diagnostics, buffer, and project events.

  The renderer reads current row state, but this module owns the event-time invalidation work that should not happen during rendering.
  """

  alias Minga.Buffer
  alias Minga.LSP.SyncServer
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias Minga.Project.FileTree.GitStatus
  alias MingaEditor.State, as: EditorState
  alias MingaFileTree.State, as: FileTreeState

  @type state :: EditorState.t()

  @doc "Returns true when the file tree is open."
  @spec open?(state()) :: boolean()
  def open?(state), do: match?(%FileTreeState{tree: %FileTree{}}, file_tree_state(state))

  @doc "Returns true when the path is under the current tree root."
  @spec path_under_tree?(state(), String.t() | nil) :: boolean()
  def path_under_tree?(_state, nil), do: false

  def path_under_tree?(state, path) when is_binary(path) do
    case file_tree_state(state) do
      %FileTreeState{tree: %FileTree{root: root}} ->
        path_under_root?(Path.expand(path), Path.expand(root))

      %FileTreeState{project_root: root} when is_binary(root) ->
        path_under_root?(Path.expand(path), Path.expand(root))

      %FileTreeState{} ->
        false
    end
  end

  def path_under_tree?(_state, _path), do: false

  @doc "Returns true when the diagnostic URI maps to a path under the current tree root."
  @spec diagnostic_uri_under_tree?(state(), String.t()) :: boolean()
  def diagnostic_uri_under_tree?(state, uri) when is_binary(uri) do
    path_under_tree?(state, SyncServer.uri_to_path(uri))
  rescue
    ArgumentError -> false
  end

  @doc "Returns true when the buffer belongs to a path under the current tree root."
  @spec buffer_under_tree?(state(), pid()) :: boolean()
  def buffer_under_tree?(state, buffer) when is_pid(buffer) do
    path_under_tree?(state, Buffer.file_path(buffer))
  catch
    :exit, _ -> false
  end

  @doc "Marks a debounced filesystem refresh as scheduled."
  @spec schedule_refresh(state(), reference()) :: state()
  def schedule_refresh(state, ref) when is_reference(ref) do
    set_file_tree(state, FileTreeState.schedule_refresh(file_tree_state(state), ref))
  end

  @doc "Returns true when a filesystem refresh timer is already pending."
  @spec refresh_scheduled?(state()) :: boolean()
  def refresh_scheduled?(state) do
    state
    |> file_tree_state()
    |> FileTreeState.refresh_scheduled?()
  end

  @doc "Refreshes cached filesystem entries after the debounce timer fires."
  @spec flush_refresh(state()) :: state()
  def flush_refresh(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} = file_tree ->
        set_file_tree(state, FileTreeState.clear_refresh(file_tree))

      %FileTreeState{tree: %FileTree{} = tree} = file_tree ->
        refreshed_tree = tree |> FileTree.refresh() |> FileTree.refresh_git_status()
        watch_expanded_dirs(refreshed_tree)

        file_tree =
          file_tree
          |> FileTreeState.clear_refresh()
          |> FileTreeState.replace_tree(refreshed_tree)

        state
        |> set_file_tree(file_tree)
        |> sync_buffer(refreshed_tree)
    end
  end

  @doc "Updates tree git badges from an already-fetched git status event."
  @spec refresh_git_status(state(), Minga.Events.GitStatusEvent.t()) :: state()
  def refresh_git_status(state, %Minga.Events.GitStatusEvent{git_root: git_root, entries: entries}) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} ->
        state

      %FileTreeState{tree: %FileTree{} = tree} = file_tree ->
        status = GitStatus.from_entries(entries, git_root, tree.root)
        updated_tree = FileTree.replace_git_status(tree, status)
        file_tree = FileTreeState.replace_tree(file_tree, updated_tree)

        state
        |> set_file_tree(file_tree)
        |> sync_buffer(updated_tree)
    end
  end

  @doc "Refreshes tree git badges by querying the current git backend."
  @spec refresh_git_status_from_disk(state()) :: state()
  def refresh_git_status_from_disk(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} ->
        state

      %FileTreeState{tree: %FileTree{} = tree} = file_tree ->
        updated_tree = FileTree.refresh_git_status(tree)
        file_tree = FileTreeState.replace_tree(file_tree, updated_tree)

        state
        |> set_file_tree(file_tree)
        |> sync_buffer(updated_tree)
    end
  end

  @doc "Updates the remembered project root and replaces visible stale tree entries when the project changes."
  @spec update_project_root(state(), String.t()) :: state()
  def update_project_root(state, root) when is_binary(root) do
    expanded_root = Path.expand(root)
    file_tree = file_tree_state(state)

    case file_tree.tree do
      %FileTree{root: ^expanded_root} ->
        set_file_tree(state, FileTreeState.set_project_root(file_tree, expanded_root))

      %FileTree{} = old_tree ->
        unwatch_expanded_dirs(old_tree)

        new_tree =
          expanded_root
          |> FileTree.new(width: old_tree.width)
          |> FileTree.refresh_git_status()

        watch_expanded_dirs(new_tree)

        file_tree =
          file_tree
          |> FileTreeState.set_project_root(expanded_root)
          |> FileTreeState.replace_tree(new_tree)

        state
        |> set_file_tree(file_tree)
        |> sync_buffer(new_tree)

      nil ->
        set_file_tree(state, FileTreeState.set_project_root(file_tree, expanded_root))
    end
  end

  @doc "Registers expanded tree directories with the external file watcher when it is running."
  @spec watch_expanded_dirs(FileTree.t()) :: :ok
  def watch_expanded_dirs(%FileTree{expanded: expanded}) do
    Enum.each(expanded, &safe_watch_directory/1)
  end

  @doc "Unregisters every watched project directory under the tree root when the file tree closes or changes root."
  @spec unwatch_expanded_dirs(FileTree.t()) :: :ok
  def unwatch_expanded_dirs(%FileTree{root: root}) do
    safe_unwatch_directory_tree(root)
  end

  @spec sync_buffer(state(), FileTree.t()) :: state()
  defp sync_buffer(state, tree) do
    case file_tree_state(state).buffer do
      buffer when is_pid(buffer) ->
        BufferSync.sync(buffer, tree)
        state

      _ ->
        state
    end
  catch
    :exit, reason ->
      Minga.Log.warning(
        :editor,
        "File tree buffer sync failed for #{tree.root}: #{inspect(reason)}"
      )

      state
  end

  @spec file_tree_state(state()) :: FileTreeState.t()
  defp file_tree_state(state), do: state |> EditorState.file_tree_state() |> FileTreeState.coerce()

  @spec set_file_tree(state(), FileTreeState.t()) :: state()
  defp set_file_tree(%EditorState{} = state, %FileTreeState{} = file_tree) do
    :ok = MingaFileTree.Feature.sync_sidebar(file_tree)
    EditorState.set_file_tree(state, file_tree)
  end

  @spec safe_watch_directory(String.t()) :: :ok
  defp safe_watch_directory(path) when is_binary(path) do
    Minga.FileWatcher.watch_directory(path)
  catch
    :exit, reason ->
      Minga.Log.warning(
        :editor,
        "File tree watch registration failed for #{path}: #{inspect(reason)}"
      )

      :ok
  end

  @spec safe_unwatch_directory_tree(String.t()) :: :ok
  defp safe_unwatch_directory_tree(path) when is_binary(path) do
    Minga.FileWatcher.unwatch_directory_tree(path)
  catch
    :exit, reason ->
      Minga.Log.warning(:editor, "File tree watch cleanup failed for #{path}: #{inspect(reason)}")
      :ok
  end

  @spec path_under_root?(String.t(), String.t()) :: boolean()
  defp path_under_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
