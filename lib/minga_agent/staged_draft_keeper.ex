defmodule MingaAgent.StagedDraftKeeper do
  @moduledoc """
  Keeps staged agent edits durable and reachable across Editor restarts and full restarts.

  Approved agent edits wait in a workspace's overlay `MingaAgent.ProjectView` (a changeset plus buffer forks) until the user publishes or discards them. Those processes live under `MingaAgent.Supervisor`, so they outlive an Editor restart, but the restarted Editor has no handle to them, and a full restart loses them. This process is the single owner of their durability:

    * **Tracking.** `persist/3` registers a view with the workspace it belongs to. Views are tracked by their own identity; the workspace id is an attribute that can change. A new view for a workspace never displaces another live view or its drafts. The keeper monitors the view's changeset and subscribes to its revisions.
    * **Rebuildable tracking.** When the keeper subscribes, the changeset registers itself in a `Registry` (`:registry` option) with its view and workspace id. The registration belongs to the changeset, so it outlives a keeper crash; a restarted keeper adopts every registered view and re-saves it.
    * **Persistence.** After each staged change the keeper writes the view's drafts with `Minga.Session.StagedDrafts` (one private, atomic file per draft). Only drafts whose content changed are rewritten; files for paths that are no longer staged are removed.
    * **Deletion.** A changeset stops normally only after a successful publish, a discard, or a close of a clean view, so a `:normal` exit deletes that view's draft files. Any other exit (a crash, an application shutdown) keeps them for the next start.
    * **Recovery.** `recover/3` hands an Editor every staged view of its project: views that are still running (`:live`, after an Editor restart) and views rebuilt from disk (`:disk`, after a full restart). The reply is `{:staged_drafts_recovered, project_root, [Recovery.t()]}`, sent only when there is something to offer. A draft file is deleted only when it can never be restored; a draft that fails for a reason that may pass (I/O, an unavailable process) stays on disk, and its whole view waits for the next start.

  All disk I/O and every call into the changeset and forks happen here, never on the Editor process. Callers only cast.
  """

  use GenServer

  alias Minga.Session.StagedDraft
  alias Minga.Session.StagedDrafts
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.Overlay
  alias MingaAgent.StagedDraftKeeper.Recovery

  @registry MingaAgent.StagedDraftKeeper.Registry

  # Failures that no later attempt can fix. Their draft files are deleted.
  @permanent_failures [
    :invalid_format,
    :invalid_path,
    :path_traversal,
    :base_fingerprint_mismatch,
    :project_mismatch,
    :too_large,
    :not_a_regular_file
  ]

  @typedoc "A view's identity (`ProjectView.t()` id)."
  @type view_id :: String.t()

  @typep tracked :: %{
           view: ProjectView.t(),
           workspace_id: non_neg_integer(),
           changeset: pid(),
           monitor: reference(),
           written: %{String.t() => binary() | nil}
         }

  @typep state :: %{
           store_opts: keyword(),
           registry: atom(),
           tracked: %{view_id() => tracked()},
           pending: MapSet.t(view_id())
         }

  @typedoc """
  Start options. `:staged_drafts_dir` overrides the store directory, `:registry` names the changeset registry (default `#{inspect(@registry)}`), and `:owner_uid` fixes the uid that must own the store.
  """
  @type start_opt ::
          {:name, GenServer.name() | nil}
          | {:staged_drafts_dir, String.t()}
          | {:registry, atom()}
          | {:owner_uid, non_neg_integer()}

  # ── Client API ──────────────────────────────────────────────────────────

  @doc "Returns the default changeset registry name."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "Starts the keeper."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Tracks `view` as staged for `workspace_id` and persists its drafts.

  Only overlay views stage edits; other views are ignored. Persisting a tracked view with another workspace id moves it to that workspace.
  """
  @spec persist(GenServer.server(), ProjectView.t(), non_neg_integer()) :: :ok
  def persist(server \\ __MODULE__, view, workspace_id)

  def persist(
        server,
        %ProjectView{backend: Overlay, project_root: root} = view,
        workspace_id
      )
      when is_binary(root) and is_integer(workspace_id) and workspace_id >= 0 do
    GenServer.cast(server, {:persist, view, workspace_id})
  end

  def persist(_server, %ProjectView{}, _workspace_id), do: :ok

  @doc "Asks for the project's staged views; replies to `reply_to` with `{:staged_drafts_recovered, project_root, recoveries}`."
  @spec recover(GenServer.server(), String.t(), pid()) :: :ok
  def recover(server \\ __MODULE__, project_root, reply_to)
      when is_binary(project_root) and is_pid(reply_to) do
    GenServer.cast(server, {:recover, Path.expand(project_root), reply_to})
  end

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state(), {:continue, :adopt}}
  def init(opts) do
    # Trapping exits runs terminate/2 on shutdown, where pending exit reports
    # of discarded or published changesets still delete their drafts.
    Process.flag(:trap_exit, true)

    store_opts = Keyword.take(opts, [:staged_drafts_dir, :owner_uid])

    store_opts =
      case StagedDrafts.owner_uid(store_opts) do
        {:ok, uid} -> Keyword.put(store_opts, :owner_uid, uid)
        {:error, _reason} -> store_opts
      end

    state = %{
      store_opts: store_opts,
      registry: Keyword.get(opts, :registry, @registry),
      tracked: %{},
      pending: MapSet.new()
    }

    {:ok, state, {:continue, :adopt}}
  end

  @impl true
  def handle_continue(:adopt, state) do
    {:noreply, adopt_registered(state)}
  end

  @impl true
  def handle_cast({:persist, %ProjectView{} = view, workspace_id}, state) do
    case track(state, view, workspace_id) do
      {:ok, state} -> {:noreply, snapshot(state, view.id)}
      {:error, state} -> {:noreply, state}
    end
  end

  def handle_cast({:recover, root, reply_to}, state) do
    recoveries = live_recoveries(state, root)
    {restored, state} = disk_recoveries(state, root)

    case recoveries ++ restored do
      [] -> :ok
      recoveries -> send(reply_to, {:staged_drafts_recovered, root, recoveries})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:changeset_revised, changeset}, state) do
    case view_for_changeset(state, changeset) do
      nil -> {:noreply, state}
      view_id -> {:noreply, schedule_snapshot(state, view_id)}
    end
  end

  def handle_info({:snapshot, view_id}, state) do
    state = %{state | pending: MapSet.delete(state.pending, view_id)}

    if Map.has_key?(state.tracked, view_id),
      do: {:noreply, snapshot(state, view_id)},
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, changeset_down(state, ref, reason)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    drain_exit_reports(state)
    :ok
  end

  # ── Tracking ────────────────────────────────────────────────────────────

  # Every live changeset that registered a staged view before this keeper
  # started (a keeper restart) is tracked again and re-saved.
  @spec adopt_registered(state()) :: state()
  defp adopt_registered(state) do
    state.registry
    |> registered_views()
    |> Enum.reduce(state, fn {view, workspace_id}, state ->
      case track(state, view, workspace_id) do
        {:ok, state} -> snapshot(state, view.id)
        {:error, state} -> state
      end
    end)
  end

  @spec registered_views(atom()) :: [{ProjectView.t(), non_neg_integer()}]
  defp registered_views(registry) do
    Registry.select(registry, [{{:_, :_, :"$1"}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @spec track(state(), ProjectView.t(), non_neg_integer()) :: {:ok, state()} | {:error, state()}
  defp track(state, %ProjectView{id: view_id} = view, workspace_id) do
    case Map.get(state.tracked, view_id) do
      %{workspace_id: ^workspace_id} ->
        {:ok, state}

      %{} = tracked ->
        # The view moved to another workspace: rewrite every draft with the
        # new workspace id.
        register(state, tracked.changeset, view, workspace_id)
        tracked = %{tracked | workspace_id: workspace_id, written: %{}}
        {:ok, %{state | tracked: Map.put(state.tracked, view_id, tracked)}}

      nil ->
        start_tracking(state, view, workspace_id, %{})
    end
  end

  @spec start_tracking(state(), ProjectView.t(), non_neg_integer(), %{
          String.t() => binary() | nil
        }) :: {:ok, state()} | {:error, state()}
  defp start_tracking(state, view, workspace_id, written) do
    changeset = Overlay.changeset_pid(view)

    case register(state, changeset, view, workspace_id) do
      :ok ->
        tracked = %{
          view: view,
          workspace_id: workspace_id,
          changeset: changeset,
          monitor: Process.monitor(changeset),
          written: written
        }

        {:ok, %{state | tracked: Map.put(state.tracked, view.id, tracked)}}

      {:error, _reason} ->
        {:error, state}
    end
  end

  @spec register(state(), pid(), ProjectView.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp register(state, changeset, view, workspace_id) do
    Changeset.observe(changeset, self(), {state.registry, {view, workspace_id}})
  catch
    :exit, reason -> {:error, {:changeset_unavailable, Overlay.exit_kind(reason)}}
  end

  @spec view_for_changeset(state(), pid()) :: view_id() | nil
  defp view_for_changeset(state, changeset) do
    Enum.find_value(state.tracked, fn
      {view_id, %{changeset: ^changeset}} -> view_id
      _other -> nil
    end)
  end

  @spec changeset_down(state(), reference(), term()) :: state()
  defp changeset_down(state, ref, reason) do
    case Enum.find(state.tracked, fn {_view_id, tracked} -> tracked.monitor == ref end) do
      nil ->
        state

      {view_id, tracked} ->
        # A normal stop follows publish, discard, or closing a clean view:
        # nothing is staged any more. Any other exit keeps the last snapshot.
        if reason == :normal, do: delete_files(state, tracked.view)

        %{
          state
          | tracked: Map.delete(state.tracked, view_id),
            pending: MapSet.delete(state.pending, view_id)
        }
    end
  end

  @spec drain_exit_reports(state()) :: :ok
  defp drain_exit_reports(state) do
    receive do
      {:DOWN, ref, :process, _pid, reason} ->
        drain_exit_reports(changeset_down(state, ref, reason))
    after
      0 -> :ok
    end
  end

  # ── Snapshots ───────────────────────────────────────────────────────────

  # Revisions arriving before the queued snapshot runs share that snapshot.
  @spec schedule_snapshot(state(), view_id()) :: state()
  defp schedule_snapshot(state, view_id) do
    if MapSet.member?(state.pending, view_id) do
      state
    else
      send(self(), {:snapshot, view_id})
      %{state | pending: MapSet.put(state.pending, view_id)}
    end
  end

  @spec snapshot(state(), view_id()) :: state()
  defp snapshot(state, view_id) do
    %{view: view, written: written} = tracked = Map.fetch!(state.tracked, view_id)

    case Overlay.staged_drafts(view) do
      {:ok, []} ->
        delete_files(state, view)
        put_written(state, tracked, %{})

      {:ok, drafts} ->
        written = write_changed(state, tracked, drafts, written)

        log_error(
          StagedDrafts.prune(view.project_root, view.id, Map.keys(written), state.store_opts)
        )

        put_written(state, tracked, written)

      {:error, reason} ->
        Minga.Log.debug(
          :agent,
          "Staged agent edits were not saved: #{inspect(Recovery.safe_reason(reason))}"
        )

        state
    end
  end

  @spec write_changed(state(), tracked(), [StagedDraft.t()], %{String.t() => binary() | nil}) ::
          %{String.t() => binary() | nil}
  defp write_changed(state, tracked, drafts, written) do
    Map.new(drafts, fn draft ->
      digest = StagedDraft.digest(draft)

      if Map.get(written, draft.path) == digest,
        do: {draft.path, digest},
        else: {draft.path, write_draft(state, tracked, draft, digest)}
    end)
  end

  # Returns the digest now on disk; `nil` forces a retry at the next snapshot.
  @spec write_draft(state(), tracked(), StagedDraft.t(), binary()) :: binary() | nil
  defp write_draft(state, %{view: view, workspace_id: workspace_id}, draft, digest) do
    case StagedDrafts.write(view.project_root, view.id, workspace_id, draft, state.store_opts) do
      :ok ->
        digest

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Staged agent edit for #{display_path(draft.path)} could not be saved: #{inspect(Recovery.safe_reason(reason))}"
        )

        nil
    end
  end

  @spec put_written(state(), tracked(), %{String.t() => binary() | nil}) :: state()
  defp put_written(state, tracked, written) do
    %{state | tracked: Map.put(state.tracked, tracked.view.id, %{tracked | written: written})}
  end

  @spec delete_files(state(), ProjectView.t()) :: :ok
  defp delete_files(state, %ProjectView{project_root: root, id: view_id}) do
    log_error(StagedDrafts.delete_view(root, view_id, state.store_opts))
  end

  @spec log_error(:ok | {:error, term()}) :: :ok
  defp log_error(:ok), do: :ok

  defp log_error({:error, reason}) do
    Minga.Log.warning(
      :agent,
      "Staged agent edit files could not be cleaned up: #{inspect(Recovery.safe_reason(reason))}"
    )
  end

  @spec display_path(String.t()) :: String.t()
  defp display_path(path), do: if(String.valid?(path), do: path, else: inspect(path))

  # ── Recovery ────────────────────────────────────────────────────────────

  @spec live_recoveries(state(), String.t()) :: [Recovery.t()]
  defp live_recoveries(state, root) do
    recoveries =
      for {_view_id, %{view: %ProjectView{project_root: ^root} = view} = tracked} <-
            state.tracked,
          {:ok, [_ | _] = changes} <- [view_diff(view)],
          do: Recovery.live(tracked.workspace_id, view, changes)

    Enum.sort_by(recoveries, &{&1.workspace_id, &1.view.id})
  end

  # A view that is still tracked is never rebuilt from disk; its files are
  # the snapshot of that running view.
  @spec disk_recoveries(state(), String.t()) :: {[Recovery.t()], state()}
  defp disk_recoveries(state, root) do
    case StagedDrafts.load(root, state.store_opts) do
      {:ok, stored} ->
        stored
        |> Enum.reject(&Map.has_key?(state.tracked, &1.view_id))
        |> Enum.map_reduce(state, &restore_view(&2, root, &1))

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Staged agent edits from the previous run were not loaded: #{inspect(Recovery.safe_reason(reason))}"
        )

        {[], state}
    end
  end

  @spec restore_view(state(), String.t(), StagedDrafts.stored_view()) :: {Recovery.t(), state()}
  defp restore_view(
         state,
         root,
         %{view_id: view_id, workspace_id: workspace_id, entries: entries} = stored
       ) do
    drafts = for {:ok, _file, draft} <- entries, do: draft
    unreadable = for {:retained, _file, name, reason} <- entries, do: {name, reason}

    # A draft that can never be decoded is gone; its file is removed.
    lost =
      for {:lost, file, name, reason} <- entries do
        _ = StagedDrafts.remove_file(file)
        {name, reason}
      end

    cond do
      unreadable != [] ->
        # Restoring only part of a view would let its next snapshot prune the
        # unreadable drafts; the whole view waits for the next start.
        retained = unreadable ++ for(draft <- drafts, do: {draft.path, :restore_deferred})
        {Recovery.restored(workspace_id, nil, lost: lost, retained: retained), state}

      drafts == [] ->
        log_error(StagedDrafts.remove_view_dir(stored))
        {Recovery.restored(workspace_id, nil, lost: lost), state}

      true ->
        rebuild_view(state, root, view_id, workspace_id, drafts, lost)
    end
  end

  @spec rebuild_view(
          state(),
          String.t(),
          view_id(),
          non_neg_integer(),
          [StagedDraft.t()],
          [Recovery.failed_draft()]
        ) :: {Recovery.t(), state()}
  defp rebuild_view(state, root, view_id, workspace_id, drafts, lost) do
    # The rebuilt view keeps its identity, so it owns the same draft files.
    case Overlay.restore(root, drafts, id: view_id) do
      {:ok, view, failures} ->
        {permanent, transient} = Enum.split_with(failures, &permanent_failure?/1)

        Enum.each(permanent, fn {path, _reason} ->
          StagedDrafts.delete(root, view_id, path, state.store_opts)
        end)

        restored_view(state, view, workspace_id, drafts, lost ++ permanent, transient)

      {:error, reason} ->
        retained = for draft <- drafts, do: {draft.path, reason}
        {Recovery.restored(workspace_id, nil, lost: lost, retained: retained), state}
    end
  end

  @spec restored_view(
          state(),
          ProjectView.t(),
          non_neg_integer(),
          [StagedDraft.t()],
          [Recovery.failed_draft()],
          [Recovery.failed_draft()]
        ) :: {Recovery.t(), state()}
  defp restored_view(state, view, workspace_id, drafts, lost, [_ | _] = transient) do
    # A failure that may pass keeps every remaining draft on disk for the
    # next start, instead of tracking a view that is missing some of them.
    abandon_view(view)
    failed = MapSet.new(lost ++ transient, &elem(&1, 0))

    deferred =
      for draft <- drafts,
          not MapSet.member?(failed, draft.path),
          do: {draft.path, :restore_deferred}

    {Recovery.restored(workspace_id, nil, lost: lost, retained: transient ++ deferred), state}
  end

  defp restored_view(state, view, workspace_id, drafts, lost, []) do
    failed = MapSet.new(lost, &elem(&1, 0))
    restored = Enum.reject(drafts, &MapSet.member?(failed, &1.path))

    if restored == [] do
      abandon_view(view)
      delete_files(state, view)
      {Recovery.restored(workspace_id, nil, lost: lost), state}
    else
      track_restored(state, view, workspace_id, restored, lost)
    end
  end

  @spec track_restored(
          state(),
          ProjectView.t(),
          non_neg_integer(),
          [StagedDraft.t()],
          [Recovery.failed_draft()]
        ) :: {Recovery.t(), state()}
  defp track_restored(state, view, workspace_id, restored, lost) do
    written = Map.new(restored, &{&1.path, StagedDraft.digest(&1)})

    state =
      case start_tracking(state, view, workspace_id, written) do
        {:ok, state} -> state
        {:error, state} -> state
      end

    changes =
      case view_diff(view) do
        {:ok, changes} -> changes
        {:error, _reason} -> []
      end

    recovery =
      Recovery.restored(workspace_id, view,
        changes: changes,
        base_changed: base_changed_paths(view.project_root, restored),
        lost: lost
      )

    {recovery, state}
  end

  @spec permanent_failure?(Recovery.failed_draft()) :: boolean()
  defp permanent_failure?({_path, reason}) when reason in @permanent_failures, do: true
  defp permanent_failure?({_path, {:unsupported_version, _version}}), do: true
  defp permanent_failure?(_failure), do: false

  # Drafts are only read back into a changeset that this keeper never
  # observed, so stopping it deletes nothing.
  @spec abandon_view(ProjectView.t()) :: :ok
  defp abandon_view(view) do
    _ = ProjectView.discard(view)
    _ = ProjectView.close(view)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @spec base_changed_paths(String.t(), [StagedDraft.t()]) :: [String.t()]
  defp base_changed_paths(root, drafts) do
    for draft <- drafts,
        StagedDraft.base_changed?(draft, read_project_file(Path.join(root, draft.path))),
        do: draft.path
  end

  # Regular files only, bounded: a FIFO or device in the project must not
  # block or exhaust the keeper.
  @spec read_project_file(String.t()) :: {:ok, binary()} | {:error, term()}
  defp read_project_file(path) do
    case Minga.SecureFile.read(path, StagedDrafts.max_file_bytes()) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, {:file_read_failed, _path, :enoent}} -> {:error, :enoent}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  @spec view_diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  defp view_diff(view) do
    if ProjectView.active?(view), do: ProjectView.diff(view), else: {:error, :inactive}
  end
end
