defmodule MingaEditor.FileTree.Freshness do
  @moduledoc """
  Keeps the editor file tree fresh in response to filesystem, git, diagnostics, buffer, and project events.

  The renderer reads current row state, but this module owns the event-time invalidation work that should not happen during rendering.
  """

  alias Minga.Buffer
  alias Minga.LSP.SyncServer
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias Minga.Project.FileTree.GitStatus
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Refresh
  alias MingaEditor.FileTree.Refresh.FilesystemScanner
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @type state :: EditorState.t()

  @refresh_retry_base_ms 25
  @refresh_retry_max_ms 1_000

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

  @doc "Debounces one refresh request in the Editor mailbox."
  @spec request_refresh(state(), non_neg_integer()) :: state()
  def request_refresh(state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    token = make_ref()
    file_tree = file_tree_state(state)

    case FileTreeState.request_refresh_debounce(file_tree, token) do
      {:already_scheduled, file_tree} ->
        set_file_tree(state, file_tree)

      {:scheduled, file_tree} ->
        Process.send_after(self(), {:file_tree_refresh_timer, token}, delay_ms)
        set_file_tree(state, file_tree)
    end
  end

  @doc "Consumes a correlated debounce timer and admits a typed refresh request."
  @spec begin_refresh(state(), reference()) :: state()
  def begin_refresh(state, timer_token) when is_reference(timer_token) do
    case FileTreeState.refresh_debounce_elapsed(file_tree_state(state), timer_token) do
      {:ready, tree, file_tree} ->
        state
        |> set_file_tree(file_tree)
        |> schedule_refresh(tree)

      {_status, file_tree} ->
        set_file_tree(state, file_tree)
    end
  end

  @doc "Applies one scheduler lifecycle or terminal outcome for the file-tree domain."
  @spec apply_refresh_outcome(state(), Outcome.t()) :: {state(), Outcome.t()}
  def apply_refresh_outcome(
        state,
        %Outcome{
          status: :completed,
          request: %Request{effect: %Refresh{} = effect},
          result: %FileTree{} = tree
        } =
          outcome
      ) do
    apply_completed_refresh(state, effect, tree, outcome)
  end

  def apply_refresh_outcome(
        state,
        %Outcome{
          status: :failed,
          request: %Request{effect: %Refresh{} = effect} = request,
          reason: {:root_unavailable, reason}
        } = outcome
      ) do
    {finish_failed_refresh(state, effect, request.id, reason), outcome}
  end

  def apply_refresh_outcome(
        state,
        %Outcome{status: status, request: %Request{effect: %Refresh{} = effect} = request} =
          outcome
      )
      when status in [:failed, :canceled, :stale] do
    {finish_terminal_refresh(state, effect, request.id), outcome}
  end

  def apply_refresh_outcome(state, %Outcome{} = outcome), do: {state, outcome}

  @spec schedule_refresh(state(), FileTree.t()) :: state()
  defp schedule_refresh(%EditorState{effect_scheduler: nil} = state, _tree) do
    Minga.Log.warning(:editor, "File tree refresh scheduler unavailable")
    state
  end

  defp schedule_refresh(state, %FileTree{} = tree) do
    request = Refresh.request(tree, state.extension_surfaces.events_registry)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} ->
        file_tree =
          state
          |> file_tree_state()
          |> FileTreeState.track_refresh_request(tree.root, request.id)

        set_file_tree(state, file_tree)

      {:error, reason} ->
        Minga.Log.warning(:editor, "File tree refresh not scheduled: #{inspect(reason)}")
        schedule_refresh_retry(state)
    end
  end

  @spec schedule_refresh_retry(state()) :: state()
  defp schedule_refresh_retry(state) do
    token = make_ref()
    {attempt, file_tree} = FileTreeState.track_refresh_retry(file_tree_state(state), token)
    Process.send_after(self(), {:file_tree_refresh_timer, token}, refresh_retry_delay(attempt))
    set_file_tree(state, file_tree)
  end

  @spec refresh_retry_delay(pos_integer()) :: pos_integer()
  defp refresh_retry_delay(attempt) do
    exponent = min(attempt - 1, 6)
    min(@refresh_retry_base_ms * Integer.pow(2, exponent), @refresh_retry_max_ms)
  end

  @spec apply_completed_refresh(state(), Refresh.t(), FileTree.t(), Outcome.t()) ::
          {state(), Outcome.t()}
  defp apply_completed_refresh(state, effect, refreshed_tree, outcome) do
    file_tree = file_tree_state(state)

    case FileTreeState.accept_refresh_result(
           file_tree,
           effect.root,
           outcome.request.id,
           refreshed_tree
         ) do
      {:accepted, file_tree} ->
        state = set_file_tree(state, file_tree)
        watch_expanded_dirs(refreshed_tree)

        state =
          state
          |> sync_buffer(refreshed_tree)
          |> MingaEditor.schedule_render(16)

        {state, outcome}

      {reason, file_tree} ->
        {set_file_tree(state, file_tree), Outcome.stale(outcome, reason)}
    end
  end

  @spec finish_terminal_refresh(state(), Refresh.t(), reference()) :: state()
  defp finish_terminal_refresh(state, effect, request_token) do
    {_status, file_tree} =
      state
      |> file_tree_state()
      |> FileTreeState.finish_refresh(effect.root, request_token)

    set_file_tree(state, file_tree)
  end

  @spec finish_failed_refresh(state(), Refresh.t(), reference(), term()) :: state()
  defp finish_failed_refresh(state, effect, request_token, reason) do
    case FileTreeState.finish_refresh(file_tree_state(state), effect.root, request_token) do
      {:current, file_tree} ->
        state
        |> set_file_tree(FileTreeState.refresh_failed(file_tree, reason))
        |> MingaEditor.schedule_render(16)

      {_status, file_tree} ->
        set_file_tree(state, file_tree)
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
        file_tree = FileTreeState.replace_tree_metadata(file_tree, updated_tree)

        state
        |> set_file_tree(file_tree)
        |> sync_buffer(updated_tree)
    end
  end

  @doc "Refreshes tree git badges from the cached Git.Repo snapshot without shelling out to git."
  @spec refresh_git_status_from_cache(state()) :: state()
  def refresh_git_status_from_cache(state) do
    case file_tree_state(state) do
      %FileTreeState{tree: nil} ->
        state

      %FileTreeState{tree: %FileTree{} = tree} = file_tree ->
        updated_tree =
          Refresh.with_cached_git_status(tree, state.extension_surfaces.events_registry)

        file_tree = FileTreeState.replace_tree_metadata(file_tree, updated_tree)

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
        new_tree = FileTree.new(expanded_root, width: old_tree.width)

        case FilesystemScanner.scan(new_tree, nil) do
          %FileTree{} = new_tree ->
            new_tree =
              Refresh.with_cached_git_status(new_tree, state.extension_surfaces.events_registry)

            watch_expanded_dirs(new_tree)

            file_tree =
              file_tree
              |> FileTreeState.set_project_root(expanded_root)
              |> FileTreeState.replace_tree(new_tree)

            state
            |> set_file_tree(file_tree)
            |> sync_buffer(new_tree)

          {:error, {:root_unavailable, reason}} ->
            failed_tree = FileTree.put_entries(new_tree, [])

            file_tree =
              file_tree
              |> FileTreeState.set_project_root(expanded_root)
              |> FileTreeState.replace_tree(failed_tree)
              |> FileTreeState.refresh_failed(reason)

            state
            |> set_file_tree(file_tree)
            |> sync_buffer(failed_tree)
        end

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
  defp file_tree_state(state), do: state.workspace.file_tree

  @spec set_file_tree(state(), FileTreeState.t()) :: state()
  defp set_file_tree(%EditorState{} = state, %FileTreeState{} = file_tree) do
    %{state | workspace: MingaEditor.Session.State.set_file_tree(state.workspace, file_tree)}
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
