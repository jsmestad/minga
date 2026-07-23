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
  alias MingaEditor.FileTree.FilterWalk
  alias MingaEditor.FileTree.FilterWalk.Result, as: FilterResult
  alias MingaEditor.FileTree.Refresh
  alias MingaEditor.FileTree.WatcherSync
  alias MingaEditor.FileTree.WatcherSync.Result, as: WatcherResult
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @type state :: EditorState.t()

  @refresh_retry_base_ms 25
  @refresh_retry_max_ms 1_000
  @watcher_retry_base_ms 25
  @watcher_retry_max_ms 1_000
  @watcher_retry_max_attempts 6

  @doc "Returns true when the file tree is open."
  @spec open?(state()) :: boolean()
  def open?(state), do: match?(%FileTree{}, FileTreeState.tree(file_tree_state(state)))

  @doc "Returns true when the path is under the current tree root."
  @spec path_under_tree?(state(), String.t() | nil) :: boolean()
  def path_under_tree?(_state, nil), do: false

  def path_under_tree?(state, path) when is_binary(path) do
    file_tree = file_tree_state(state)

    case {FileTreeState.tree(file_tree), file_tree.project_root} do
      {%FileTree{root: root}, _project_root} ->
        path_under_root?(Path.expand(path), Path.expand(root))

      {nil, root} when is_binary(root) ->
        path_under_root?(Path.expand(path), Path.expand(root))

      {_tree, _project_root} ->
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
      {:ready, tree, _attempt, file_tree} ->
        state
        |> set_file_tree(file_tree)
        |> schedule_refresh(tree)

      {:closed, _attempt, file_tree} ->
        set_file_tree(state, file_tree)

      {:stale, file_tree} ->
        set_file_tree(state, file_tree)
    end
  end

  @doc "Applies one scheduler lifecycle or terminal outcome for the file-tree domain."
  @spec apply_refresh_outcome(state(), Outcome.t()) :: {state(), Outcome.t()}
  def apply_refresh_outcome(
        state,
        %Outcome{
          value: {:completed, %FileTree{} = tree},
          request: %Request{effect: %Refresh{} = effect}
        } =
          outcome
      ) do
    apply_completed_refresh(state, effect, tree, outcome)
  end

  def apply_refresh_outcome(
        state,
        %Outcome{
          value: {:failed, {:root_unavailable, reason}},
          request: %Request{effect: %Refresh{} = effect} = request
        } = outcome
      ) do
    {finish_failed_refresh(state, effect, request.id, reason), outcome}
  end

  def apply_refresh_outcome(
        state,
        %Outcome{
          value: {:failed, reason},
          request: %Request{effect: %Refresh{} = effect} = request
        } = outcome
      ) do
    {finish_failed_refresh(state, effect, request.id, reason), outcome}
  end

  def apply_refresh_outcome(
        state,
        %Outcome{
          value: {status, _reason},
          request: %Request{effect: %Refresh{} = effect} = request
        } =
          outcome
      )
      when status in [:canceled, :stale] do
    {finish_terminal_refresh(state, effect, request.id), outcome}
  end

  def apply_refresh_outcome(state, %Outcome{} = outcome), do: {state, outcome}

  @doc "Applies one typed filter outcome with request, root, and query correlation."
  @spec apply_filter_outcome(state(), Outcome.t()) :: {state(), Outcome.t()}
  def apply_filter_outcome(
        state,
        %Outcome{
          value: {:completed, %FilterResult{} = result},
          request: %Request{effect: %FilterWalk{} = effect} = request
        } = outcome
      ) do
    case FileTreeState.accept_filter_result(
           file_tree_state(state),
           effect.root,
           effect.filter,
           request.id,
           result
         ) do
      {:accepted, file_tree} ->
        state = set_file_tree(state, file_tree)

        state =
          state
          |> sync_buffer(FileTreeState.tree(file_tree))
          |> maybe_synchronize_watchers(effect)
          |> MingaEditor.schedule_render(16)

        {state, outcome}

      {reason, file_tree} ->
        {set_file_tree(state, file_tree), Outcome.stale(outcome, reason)}
    end
  end

  def apply_filter_outcome(
        state,
        %Outcome{
          value: {:failed, reason},
          request: %Request{effect: %FilterWalk{} = effect} = request
        } = outcome
      ) do
    case FileTreeState.finish_filter(
           file_tree_state(state),
           effect.root,
           effect.filter,
           request.id
         ) do
      {:current, file_tree} ->
        file_tree = FileTreeState.filter_failed(file_tree, reason)

        state =
          state
          |> set_file_tree(file_tree)
          |> MingaEditor.schedule_render(16)

        {state, outcome}

      {stale_reason, file_tree} ->
        {set_file_tree(state, file_tree), Outcome.stale(outcome, stale_reason)}
    end
  end

  def apply_filter_outcome(
        state,
        %Outcome{
          value: {status, _reason},
          request: %Request{effect: %FilterWalk{} = effect} = request
        } = outcome
      )
      when status in [:canceled, :stale] do
    case FileTreeState.finish_filter(
           file_tree_state(state),
           effect.root,
           effect.filter,
           request.id
         ) do
      {:current, file_tree} -> {set_file_tree(state, file_tree), outcome}
      {reason, file_tree} -> {set_file_tree(state, file_tree), Outcome.stale(outcome, reason)}
    end
  end

  def apply_filter_outcome(state, %Outcome{} = outcome), do: {state, outcome}

  @doc "Applies watcher synchronization outcomes without calling watcher services."
  @spec apply_watcher_outcome(state(), Outcome.t()) :: {state(), Outcome.t()}
  def apply_watcher_outcome(
        state,
        %Outcome{
          value: {:completed, %WatcherResult{target: target}},
          request: %Request{effect: %WatcherSync{}} = request
        } = outcome
      ) do
    case FileTreeState.accept_watcher_result(file_tree_state(state), request.id, target) do
      {:current, file_tree} -> {set_file_tree(state, file_tree), outcome}
      {:stale, file_tree} -> {set_file_tree(state, file_tree), Outcome.stale(outcome, :stale)}
    end
  end

  def apply_watcher_outcome(
        state,
        %Outcome{
          value: {:failed, reason},
          request: %Request{effect: %WatcherSync{} = effect} = request
        } = outcome
      ) do
    case FileTreeState.finish_watcher_request(file_tree_state(state), request.id) do
      {:current, file_tree} ->
        state = set_file_tree(state, file_tree)
        opts = watcher_options(effect.backend, effect.backend_context)
        {schedule_watcher_retry(state, opts, reason), outcome}

      {:stale, file_tree} ->
        {set_file_tree(state, file_tree), Outcome.stale(outcome, :stale)}
    end
  end

  def apply_watcher_outcome(
        state,
        %Outcome{
          value: {status, _reason},
          request: %Request{effect: %WatcherSync{}} = request
        } = outcome
      )
      when status in [:canceled, :stale] do
    case FileTreeState.finish_watcher_request(file_tree_state(state), request.id) do
      {:current, file_tree} -> {set_file_tree(state, file_tree), outcome}
      {:stale, file_tree} -> {set_file_tree(state, file_tree), Outcome.stale(outcome, :stale)}
    end
  end

  def apply_watcher_outcome(state, %Outcome{} = outcome), do: {state, outcome}

  @spec schedule_refresh(state(), FileTree.t(), keyword()) :: state()
  defp schedule_refresh(state, tree, opts \\ [])

  defp schedule_refresh(%EditorState{effect_scheduler: nil} = state, _tree, _opts) do
    Minga.Log.warning(:editor, "File tree refresh scheduler unavailable")
    state
  end

  defp schedule_refresh(state, %FileTree{} = tree, opts) do
    request = Refresh.request(tree, state.extension_surfaces.events_registry, opts)

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

        state =
          state
          |> maybe_synchronize_watchers(effect)
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
        file_tree = failed_file_tree(file_tree, effect, reason)
        file_tree = prepare_failed_watcher_cleanup(file_tree, effect)
        state = set_file_tree(state, file_tree)
        state = maybe_synchronize_failed_watchers(state, effect)
        state = maybe_sync_failed_root(state, file_tree, effect)
        MingaEditor.schedule_render(state, 16)

      {_status, file_tree} ->
        set_file_tree(state, file_tree)
    end
  end

  @spec maybe_synchronize_failed_watchers(state(), Refresh.t()) :: state()
  defp maybe_synchronize_failed_watchers(
         state,
         %Refresh{previous_root: previous_root} = effect
       )
       when is_binary(previous_root),
       do: maybe_synchronize_watchers(state, effect)

  defp maybe_synchronize_failed_watchers(state, %Refresh{}), do: state

  @spec prepare_failed_watcher_cleanup(FileTreeState.t(), Refresh.t()) :: FileTreeState.t()
  defp prepare_failed_watcher_cleanup(
         %FileTreeState{} = file_tree,
         %Refresh{previous_root: previous_root}
       )
       when is_binary(previous_root),
       do: FileTreeState.cleanup_watchers(file_tree)

  defp prepare_failed_watcher_cleanup(%FileTreeState{} = file_tree, %Refresh{}), do: file_tree

  @spec failed_file_tree(FileTreeState.t(), Refresh.t(), term()) :: FileTreeState.t()
  defp failed_file_tree(file_tree, %Refresh{previous_root: previous_root}, reason)
       when is_binary(previous_root),
       do: FileTreeState.root_scan_failed(file_tree, reason)

  defp failed_file_tree(file_tree, %Refresh{}, reason),
    do: FileTreeState.refresh_failed(file_tree, reason)

  @spec maybe_sync_failed_root(state(), FileTreeState.t(), Refresh.t()) :: state()
  defp maybe_sync_failed_root(state, %FileTreeState{} = file_tree, %Refresh{
         previous_root: previous_root
       })
       when is_binary(previous_root) do
    case FileTreeState.tree(file_tree) do
      %FileTree{} = tree -> sync_buffer(state, tree)
      nil -> state
    end
  end

  defp maybe_sync_failed_root(state, %FileTreeState{}, %Refresh{}), do: state

  @doc "Updates tree git badges from an already-fetched git status event."
  @spec refresh_git_status(state(), Minga.Events.GitStatusEvent.t()) :: state()
  def refresh_git_status(state, %Minga.Events.GitStatusEvent{
        git_root: git_root,
        entry_base_path: entry_base_path,
        entries: entries
      }) do
    file_tree = file_tree_state(state)

    case FileTreeState.tree(file_tree) do
      nil ->
        state

      %FileTree{} = tree ->
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
    file_tree = file_tree_state(state)

    case FileTreeState.tree(file_tree) do
      nil ->
        state

      %FileTree{} = tree ->
        updated_tree =
          Refresh.with_cached_git_status(tree, state.extension_surfaces.events_registry)

        file_tree = FileTreeState.replace_tree_metadata(file_tree, updated_tree)

        state
        |> set_file_tree(file_tree)
        |> sync_buffer(updated_tree)
    end
  end

  @doc "Publishes a project-root loading state and schedules its typed root scan."
  @spec update_project_root(state(), String.t(), keyword()) :: state()
  def update_project_root(state, root, opts \\ []) when is_binary(root) do
    expanded_root = Path.expand(root)
    file_tree = file_tree_state(state)

    case FileTreeState.tree(file_tree) do
      %FileTree{root: ^expanded_root} ->
        state = set_file_tree(state, FileTreeState.set_project_root(file_tree, expanded_root))
        refilter_active_tree(state, opts)

      %FileTree{} = old_tree ->
        new_tree = FileTree.new(expanded_root, width: old_tree.width)
        file_tree = FileTreeState.begin_root_scan(file_tree, new_tree, :project)

        state
        |> set_file_tree(file_tree)
        |> schedule_refresh(new_tree, Keyword.put(opts, :previous_root, old_tree.root))

      nil ->
        set_file_tree(state, FileTreeState.set_project_root(file_tree, expanded_root))
    end
  end

  @doc "Publishes a browsing-root loading state and schedules its typed root scan."
  @spec reroot(state(), String.t(), keyword()) :: state()
  def reroot(state, root, opts \\ []) when is_binary(root) do
    expanded_root = Path.expand(root)

    file_tree = file_tree_state(state)

    case FileTreeState.tree(file_tree) do
      %FileTree{root: current_root} when current_root == expanded_root ->
        state

      %FileTree{} = old_tree ->
        new_tree = FileTree.reroot(old_tree, expanded_root)
        file_tree = FileTreeState.begin_root_scan(file_tree, new_tree, :reroot)

        state
        |> set_file_tree(file_tree)
        |> schedule_refresh(new_tree, Keyword.put(opts, :previous_root, old_tree.root))

      nil ->
        state
    end
  end

  @doc "Publishes a loading filter query and schedules its typed cache/filesystem scan."
  @spec update_filter(state(), String.t(), keyword()) :: state()
  def update_filter(state, filter, opts \\ []) when is_binary(filter) and filter != "" do
    file_tree = FileTreeState.update_filter(file_tree_state(state), filter)

    state
    |> set_file_tree(file_tree)
    |> schedule_filter(FileTreeState.tree(file_tree), opts)
  end

  @doc "Starts filter input and reschedules any existing non-empty query."
  @spec start_filtering(state(), keyword()) :: state()
  def start_filtering(state, opts \\ []) do
    file_tree = FileTreeState.start_filtering(file_tree_state(state))
    state = set_file_tree(state, file_tree)

    case FileTreeState.tree(file_tree) do
      %FileTree{filter: filter} = tree when is_binary(filter) and filter != "" ->
        schedule_filter(state, tree, opts)

      _tree ->
        state
    end
  end

  @doc "Publishes unfiltered loading rows and schedules their root scan."
  @spec clear_filter(state(), :keep_open | :dismiss, keyword()) :: state()
  def clear_filter(state, disposition, opts \\ [])
      when disposition in [:keep_open, :dismiss] do
    file_tree = FileTreeState.clear_filter_loading(file_tree_state(state), disposition)
    state = set_file_tree(state, file_tree)

    case FileTreeState.tree(file_tree) do
      %FileTree{} = tree -> schedule_refresh(state, tree, opts)
      nil -> state
    end
  end

  @spec refilter_active_tree(state(), keyword()) :: state()
  defp refilter_active_tree(state, opts) do
    case FileTreeState.tree(file_tree_state(state)) do
      %FileTree{filter: filter} when is_binary(filter) and filter != "" ->
        update_filter(state, filter, opts)

      _tree ->
        state
    end
  end

  @spec schedule_filter(state(), FileTree.t() | nil, keyword()) :: state()
  defp schedule_filter(state, nil, _opts), do: state

  defp schedule_filter(%EditorState{effect_scheduler: nil} = state, %FileTree{}, _opts) do
    Minga.Log.warning(:editor, "File tree filter scheduler unavailable")
    state
  end

  defp schedule_filter(state, %FileTree{} = tree, opts) do
    request = FilterWalk.request(tree, opts)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} ->
        file_tree =
          state
          |> file_tree_state()
          |> FileTreeState.track_filter_request(tree.root, tree.filter, request.id)

        set_file_tree(state, file_tree)

      {:error, reason} ->
        Minga.Log.warning(:editor, "File tree filter not scheduled: #{inspect(reason)}")
        set_file_tree(state, FileTreeState.filter_failed(file_tree_state(state), reason))
    end
  end

  @doc "Schedules the current file-tree watcher intent on the serialized watcher resource."
  @spec synchronize_watchers(state(), keyword()) :: state()
  def synchronize_watchers(state, opts \\ []) do
    intent = FileTreeState.watcher_intent(file_tree_state(state))
    schedule_watcher_sync(state, intent, opts)
  end

  @doc "Consumes a correlated watcher retry timer and resubmits the retained intent."
  @spec retry_watcher_sync(state(), reference(), keyword()) :: state()
  def retry_watcher_sync(state, token, opts) when is_reference(token) and is_list(opts) do
    case FileTreeState.watcher_retry_elapsed(file_tree_state(state), token) do
      {:current, file_tree} ->
        state
        |> set_file_tree(file_tree)
        |> synchronize_watchers(opts)

      {:stale, file_tree} ->
        set_file_tree(state, file_tree)
    end
  end

  @spec maybe_synchronize_watchers(state(), Refresh.t() | FilterWalk.t()) :: state()
  defp maybe_synchronize_watchers(state, %Refresh{synchronize_watchers?: false}), do: state
  defp maybe_synchronize_watchers(state, %FilterWalk{synchronize_watchers?: false}), do: state

  defp maybe_synchronize_watchers(state, %Refresh{} = effect) do
    synchronize_watchers(state, watcher_options(effect.watcher_backend, effect.watcher_context))
  end

  defp maybe_synchronize_watchers(state, %FilterWalk{} = effect) do
    synchronize_watchers(state, watcher_options(effect.watcher_backend, effect.watcher_context))
  end

  @spec schedule_watcher_sync(state(), MingaEditor.State.FileTree.Watchers.t(), keyword()) ::
          state()
  defp schedule_watcher_sync(%EditorState{effect_scheduler: nil} = state, _intent, _opts) do
    Minga.Log.warning(:editor, "File tree watcher scheduler unavailable")
    state
  end

  defp schedule_watcher_sync(state, intent, opts) do
    request = WatcherSync.request(intent.candidates, intent.target, intent.expanded_dirs, opts)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} ->
        file_tree =
          state
          |> file_tree_state()
          |> FileTreeState.track_watcher_request(request.id)

        set_file_tree(state, file_tree)

      {:error, reason} ->
        schedule_watcher_retry(state, opts, {:schedule_failed, reason})
    end
  end

  @spec schedule_watcher_retry(state(), keyword(), term()) :: state()
  defp schedule_watcher_retry(state, opts, reason) do
    token = make_ref()
    {attempt, file_tree} = FileTreeState.schedule_watcher_retry(file_tree_state(state), token)
    state = set_file_tree(state, file_tree)

    if attempt < @watcher_retry_max_attempts do
      if attempt == 1 do
        Minga.Log.warning(
          :editor,
          "File tree watcher sync failed: #{inspect(reason, limit: 20)}; retrying"
        )
      end

      Process.send_after(
        self(),
        {:file_tree_watcher_retry, token, opts},
        watcher_retry_delay(attempt)
      )

      state
    else
      watcher_retry_exhausted(state, attempt, reason)
    end
  end

  @spec watcher_retry_exhausted(state(), pos_integer(), term()) :: state()
  defp watcher_retry_exhausted(state, attempt, reason) do
    file_tree = FileTreeState.exhaust_watcher_retry(file_tree_state(state))
    target = FileTreeState.watcher_intent(file_tree).target

    Minga.Log.error(
      :editor,
      "File tree watcher sync stopped target=#{inspect(target)} attempts=#{attempt} reason=#{inspect(reason, limit: 20)}"
    )

    state
    |> set_file_tree(file_tree)
    |> NoticeWorkflow.publish("File tree watcher recovery stopped after #{attempt} attempts")
  end

  @spec watcher_retry_delay(pos_integer()) :: pos_integer()
  defp watcher_retry_delay(attempt) do
    exponent = min(attempt - 1, 6)
    min(@watcher_retry_base_ms * Integer.pow(2, exponent), @watcher_retry_max_ms)
  end

  @spec watcher_options(module() | nil, term()) :: keyword()
  defp watcher_options(nil, context), do: [watcher_context: context]
  defp watcher_options(backend, context), do: [watcher_backend: backend, watcher_context: context]

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

  @spec path_under_root?(String.t(), String.t()) :: boolean()
  defp path_under_root?(path, "/"), do: String.starts_with?(path, "/")
  defp path_under_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
