defmodule MingaEditor.FileTree.Freshness do
  @moduledoc """
  Keeps the editor file tree fresh in response to filesystem, git, diagnostics, buffer, and project events.

  The renderer reads current row state, but this module owns the event-time invalidation work that should not happen during rendering.
  """

  alias Minga.Buffer
  alias Minga.LSP.SyncServer
  alias Minga.Git.Repo, as: GitRepo
  alias Minga.Git.Repo.StatusSnapshot
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias Minga.Project.FileTree.GitStatus
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @type state :: EditorState.t()

  @typedoc "Effects emitted by the async refresh orchestration (interpreted by EffectHandler)."
  @type effect ::
          {:render, pos_integer()}
          | {:start_file_tree_refresh, FileTree.t(), reference()}

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

  @doc """
  Starts an async filesystem rescan after the debounce timer fires (#2632).

  The heavy recursive `File.ls`/`File.lstat` walk must not run on the Editor
  GenServer. This clears the debounce timer and, unless a rescan is already in
  flight, mints a token and emits a `{:start_file_tree_refresh, tree, token}`
  effect so `EffectHandler` can spawn the work off-process. The Task replies with
  `{:file_tree_refresh_result, refreshed_tree, token}`, handled by
  `apply_refresh_result/3`.

  If a rescan is already in flight, the request is coalesced into a single
  follow-up (`refresh_pending?`) instead of piling up Tasks (AC3): the in-flight
  walk finishes, then exactly one fresh rescan starts.
  """
  @spec begin_refresh(state()) :: {state(), [effect()]}
  def begin_refresh(state) do
    state |> file_tree_state() |> begin_refresh(state)
  end

  # No open tree: just drop the debounce timer.
  @spec begin_refresh(FileTreeState.t(), state()) :: {state(), [effect()]}
  defp begin_refresh(%FileTreeState{tree: nil} = file_tree, state) do
    {set_file_tree(state, FileTreeState.clear_refresh(file_tree)), []}
  end

  # A rescan is already running: coalesce instead of spawning another Task.
  defp begin_refresh(%FileTreeState{tree: %FileTree{}, refresh_inflight: ref} = file_tree, state)
       when is_reference(ref) do
    file_tree =
      file_tree
      |> FileTreeState.clear_refresh()
      |> FileTreeState.mark_refresh_pending()

    {set_file_tree(state, file_tree), []}
  end

  # Idle: mint a token, mark in-flight, and emit the spawn effect.
  defp begin_refresh(%FileTreeState{tree: %FileTree{} = tree} = file_tree, state) do
    token = make_ref()
    file_tree = FileTreeState.begin_inflight_refresh(file_tree, token)
    {set_file_tree(state, file_tree), [{:start_file_tree_refresh, tree, token}]}
  end

  @doc """
  Applies a finished async rescan, swapping the whole tree atomically (#2632 AC4).

  The result is discarded when stale: the token no longer matches the in-flight
  refresh, or the user re-rooted/closed the tree while the walk ran, so the
  refreshed tree's root no longer matches the live tree (AC3/AC4 staleness
  guard). After applying or dropping, a coalesced `refresh_pending?` request, if
  any, starts exactly one fresh rescan.
  """
  @spec apply_refresh_result(state(), FileTree.t(), reference()) :: {state(), [effect()]}
  def apply_refresh_result(state, %FileTree{} = refreshed_tree, token) when is_reference(token) do
    state |> file_tree_state() |> apply_refresh_result(state, refreshed_tree, token)
  end

  # Fresh: the in-flight token matches and the tree is still rooted where the
  # walk ran. Swap the whole tree in one cheap assignment (no FS walk here).
  @spec apply_refresh_result(FileTreeState.t(), state(), FileTree.t(), reference()) ::
          {state(), [effect()]}
  defp apply_refresh_result(
         %FileTreeState{refresh_inflight: token, tree: %FileTree{root: root}} = file_tree,
         state,
         %FileTree{root: root} = refreshed_tree,
         token
       ) do
    watch_expanded_dirs(refreshed_tree)

    file_tree = FileTreeState.replace_tree(file_tree, refreshed_tree)

    state =
      state
      |> set_file_tree(file_tree)
      |> sync_buffer(refreshed_tree)

    finish_refresh(state, refreshed_tree, [{:render, 16}])
  end

  # Stale: re-rooted, closed, or superseded while the walk ran. Drop the result.
  defp apply_refresh_result(%FileTreeState{}, state, _refreshed_tree, _token) do
    finish_refresh(state, current_tree(state), [])
  end

  # Clears in-flight tracking and, when a refresh was coalesced while the Task
  # ran, starts exactly one fresh rescan of the current tree (#2632 AC3).
  @spec finish_refresh(state(), FileTree.t() | nil, [effect()]) :: {state(), [effect()]}
  defp finish_refresh(state, tree, effects) do
    state |> file_tree_state() |> finish_refresh(state, tree, effects)
  end

  @spec finish_refresh(FileTreeState.t(), state(), FileTree.t() | nil, [effect()]) ::
          {state(), [effect()]}
  defp finish_refresh(%FileTreeState{refresh_pending?: true}, state, %FileTree{} = tree, effects) do
    token = make_ref()

    file_tree =
      state
      |> file_tree_state()
      |> FileTreeState.begin_inflight_refresh(token)

    {set_file_tree(state, file_tree), [{:start_file_tree_refresh, tree, token} | effects]}
  end

  defp finish_refresh(%FileTreeState{}, state, _tree, effects) do
    file_tree =
      state
      |> file_tree_state()
      |> FileTreeState.clear_inflight_refresh()

    {set_file_tree(state, file_tree), effects}
  end

  @spec current_tree(state()) :: FileTree.t() | nil
  defp current_tree(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: %FileTree{} = tree} -> tree
      %FileTreeState{} -> nil
    end
  end

  @doc "Updates tree git badges from an already-fetched git status event."
  @spec refresh_git_status(state(), Minga.Events.GitStatusEvent.t()) :: state()
  def refresh_git_status(state, %Minga.Events.GitStatusEvent{
        git_root: git_root,
        entry_base_path: entry_base_path,
        entries: entries
      }) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} ->
        state

      %FileTreeState{tree: %FileTree{} = tree} = file_tree ->
        status = GitStatus.from_entries(entries, entry_base_path || git_root, tree.root)
        updated_tree = FileTree.replace_git_status(tree, status)
        file_tree = FileTreeState.replace_tree(file_tree, updated_tree)

        state
        |> set_file_tree(file_tree)
        |> sync_buffer(updated_tree)
    end
  end

  @doc "Refreshes tree git badges from the cached Git.Repo snapshot without shelling out to git."
  @spec refresh_tree_git_status_from_cache(FileTree.t(), Minga.Events.registry()) :: FileTree.t()
  def refresh_tree_git_status_from_cache(
        %FileTree{} = tree,
        events_registry \\ Minga.Events.default_registry()
      ) do
    case GitRepo.cached_status_for_path(tree.root) do
      {:ok, %StatusSnapshot{entry_base_path: entry_base_path, entries: entries}} ->
        status = GitStatus.from_entries(entries, entry_base_path, tree.root)
        FileTree.replace_git_status(tree, status)

      :not_tracked ->
        ensure_repo_started(tree.root, events_registry)
        tree
    end
  catch
    :exit, _ -> tree
  end

  @doc "Refreshes tree git badges from the cached Git.Repo snapshot without shelling out to git."
  @spec refresh_git_status_from_cache(state()) :: state()
  def refresh_git_status_from_cache(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} ->
        state

      %FileTreeState{tree: %FileTree{} = tree} = file_tree ->
        updated_tree =
          refresh_tree_git_status_from_cache(tree, EditorState.events_registry(state))

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
        file_tree
        |> FileTreeState.set_project_root(expanded_root)
        |> refilter_active_tree()
        |> then(&set_file_tree(state, &1))

      %FileTree{} = old_tree ->
        unwatch_expanded_dirs(old_tree)

        new_tree =
          expanded_root
          |> FileTree.new(width: old_tree.width)
          |> refresh_tree_git_status_from_cache(EditorState.events_registry(state))

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

  # Re-applies the active filter so an open filtered tree picks up the freshly
  # rebuilt project cache (#2377 AC3). No-op when no filter is active, so normal
  # expanded browsing keeps its lazy-walked entries untouched.
  @spec refilter_active_tree(FileTreeState.t()) :: FileTreeState.t()
  defp refilter_active_tree(%FileTreeState{tree: %FileTree{filter: filter}} = file_tree)
       when is_binary(filter) and filter != "" do
    FileTreeState.update_filter(file_tree, filter)
  end

  defp refilter_active_tree(%FileTreeState{} = file_tree), do: file_tree

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

  @spec ensure_repo_started(String.t(), Minga.Events.registry()) :: :ok
  defp ensure_repo_started(root, events_registry) when is_binary(root) do
    case Minga.Git.root_for(root) do
      {:ok, git_root} ->
        case GitRepo.ensure_started(git_root, root, events_registry) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Minga.Log.warning(
              :editor,
              "File tree git repo start failed for #{root}: #{inspect(reason)}"
            )
        end

      :not_git ->
        :ok
    end
  catch
    :exit, reason ->
      Minga.Log.warning(
        :editor,
        "File tree git repo lookup failed for #{root}: #{inspect(reason)}"
      )

      :ok
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
  defp file_tree_state(state), do: EditorState.file_tree_state(state)

  @spec set_file_tree(state(), FileTreeState.t()) :: state()
  defp set_file_tree(%EditorState{} = state, %FileTreeState{} = file_tree) do
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
  defp path_under_root?(path, "/"), do: String.starts_with?(path, "/")
  defp path_under_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
