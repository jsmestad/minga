defmodule MingaAgent.StagedDraftKeeper do
  @moduledoc """
  Keeps staged agent edits durable and reachable across Editor restarts and full restarts.

  Approved agent edits wait in a workspace's overlay `MingaAgent.ProjectView` (a changeset plus buffer forks) until the user publishes or discards them. Those processes live under `MingaAgent.Supervisor`, so they outlive an Editor restart, but the restarted Editor has no handle to them, and a full restart loses them. This process is the single owner of their durability:

    * **Tracking.** `persist/3` registers a view with the workspace it belongs to. Views are tracked by their own identity; the workspace id is an attribute that can change. A new view for a workspace never displaces another live view or its drafts. The keeper monitors the view's changeset and subscribes to its revisions.
    * **Rebuildable tracking.** When the keeper subscribes, the changeset keeps its view and workspace id as its staging registration and joins a `:pg` scope (`:scope` option). The membership belongs to the changeset, so it outlives a keeper crash; a restarted keeper adopts every member's view and re-saves it. `:pg` monitors members rather than linking them, so a failing scope cannot take staged edits down with it.
    * **Oversized drafts.** A draft above the store's size limit is not saved. Its stored copy is replaced with a content-free "lost: too large" marker, so the next start names it as lost instead of restoring an older version, and the user is told once per path in `*Messages*`.
    * **Persistence.** After each staged change the keeper writes the view's drafts with `Minga.Session.StagedDrafts` (one private, atomic file per draft). Only drafts whose content changed are rewritten; files for paths that are no longer staged are removed. A snapshot that fails to leave disk matching the staged drafts is not recorded as saved and is retried with backoff (`:retry_ms`, doubling up to a minute), without waiting for another staged change.
    * **Deletion.** A changeset stops normally only after a successful publish, a discard, or a close of a clean view, so a `:normal` exit retires that view: its drafts are deleted behind a tombstone (`StagedDrafts.retire_view/3`). A deletion that fails is kept as a pending delete and retried with the same backoff as a failed save until it succeeds or Minga stops; the tombstone keeps the view from being offered again, in this run or after a restart, and the next start finishes the deletion. Any other exit (a crash, an application shutdown) keeps the drafts for the next start.
    * **Ownership.** Several Minga instances can run on one project and share the store. Before it writes a view's drafts, the keeper claims the view for its instance (`StagedDrafts.claim_view_dir/4`, identity from `MingaAgent.StagedDraftKeeper.Instance`). Recovery claims a stored view before it touches it: a view whose owner is still running belongs to that instance and is neither rebuilt nor offered here; the view of an instance that exited without publishing is taken over and recovered.
    * **Recovery.** `recover/3` hands an Editor every staged view of its project: views that are still running (`:live`, after an Editor restart) and views rebuilt from disk (`:disk`, after a full restart). The reply is `{:staged_drafts_recovered, project_root, [Recovery.t()]}`, sent only when there is something to offer. A draft file is deleted only when it can never be restored; a draft that fails for a reason that may pass (I/O, an unavailable process) stays on disk, and its whole view waits for the next start.

  All disk I/O and every call into the changeset and forks happen here, never on the Editor process. Callers only cast.
  """

  use GenServer

  alias Minga.Session.StagedDraft
  alias Minga.Session.StagedDrafts
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.Overlay
  alias MingaAgent.StagedDraftKeeper.Instance
  alias MingaAgent.StagedDraftKeeper.Recovery

  @scope MingaAgent.StagedDraftKeeper.Scope
  @retry_ms 1_000
  @max_retry_ms 60_000

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
           written: %{String.t() => binary() | nil},
           too_large: MapSet.t(String.t()),
           retry_delay: pos_integer() | nil,
           retry_pending: boolean(),
           owned: boolean()
         }

  @typep state :: %{
           store_opts: keyword(),
           retry_ms: pos_integer(),
           scope: atom(),
           tracked: %{view_id() => tracked()},
           pending: MapSet.t(view_id()),
           deletes: %{String.t() => pos_integer()},
           instance: StagedDrafts.owner() | nil,
           instance_alive?: StagedDrafts.owner_alive?()
         }

  @typedoc """
  Start options. `:staged_drafts_dir` overrides the store directory, `:scope` names the `:pg` scope of live staged views (default `#{inspect(@scope)}`), `:owner_uid` fixes the uid that must own the store, `:max_file_bytes` sets the largest saved draft, `:instance` and `:instance_alive?` replace this instance's identity and the liveness check of other instances (`MingaAgent.StagedDraftKeeper.Instance`), and `:retry_ms` is the first delay before an incomplete save is retried (default #{@retry_ms} ms, doubling up to #{@max_retry_ms} ms).
  """
  @type start_opt ::
          {:name, GenServer.name() | nil}
          | {:staged_drafts_dir, String.t()}
          | {:scope, atom()}
          | {:owner_uid, non_neg_integer()}
          | {:max_file_bytes, pos_integer()}
          | {:retry_ms, pos_integer()}
          | {:instance, StagedDrafts.owner()}
          | {:instance_alive?, StagedDrafts.owner_alive?()}

  # ── Client API ──────────────────────────────────────────────────────────

  @doc "Returns the default `:pg` scope of live staged views."
  @spec scope() :: atom()
  def scope, do: @scope

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

    store_opts = Keyword.take(opts, [:staged_drafts_dir, :owner_uid, :max_file_bytes])

    store_opts =
      case StagedDrafts.owner_uid(store_opts) do
        {:ok, uid} -> Keyword.put(store_opts, :owner_uid, uid)
        {:error, _reason} -> store_opts
      end

    state = %{
      store_opts: store_opts,
      scope: Keyword.get(opts, :scope, @scope),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      tracked: %{},
      pending: MapSet.new(),
      deletes: %{},
      # Resolved in handle_continue/2: finding the identity runs `ps`, which
      # must not hold up the supervisor.
      instance: Keyword.get(opts, :instance),
      instance_alive?: Keyword.get(opts, :instance_alive?, &Instance.alive?/1)
    }

    {:ok, state, {:continue, :adopt}}
  end

  @impl true
  def handle_continue(:adopt, state) do
    state = %{state | instance: state.instance || Instance.current()}
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

  def handle_info({:retry_snapshot, view_id}, state) do
    case Map.get(state.tracked, view_id) do
      nil ->
        {:noreply, state}

      tracked ->
        state = put_tracked(state, %{tracked | retry_pending: false})
        {:noreply, snapshot(state, view_id)}
    end
  end

  def handle_info({:retry_delete, dir}, state) do
    if pending_delete?(state, dir),
      do: {:noreply, retire(state, dir)},
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
    state.scope
    |> registered_views()
    |> Enum.reduce(state, fn {view, workspace_id}, state ->
      case track(state, view, workspace_id) do
        {:ok, state} -> snapshot(state, view.id)
        {:error, state} -> state
      end
    end)
  end

  @spec registered_views(atom()) :: [{ProjectView.t(), non_neg_integer()}]
  defp registered_views(scope) do
    for changeset <- staging_members(scope),
        {%ProjectView{}, workspace_id} = registration <- [staging(changeset)],
        is_integer(workspace_id),
        do: registration
  end

  @spec staging_members(atom()) :: [pid()]
  defp staging_members(scope) do
    :pg.get_members(scope, :staged_views)
  catch
    :error, _reason -> []
  end

  @spec staging(pid()) :: term()
  defp staging(changeset) do
    Changeset.staging(changeset)
  catch
    :exit, _reason -> nil
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
        tracked = %{tracked | workspace_id: workspace_id, written: %{}, too_large: MapSet.new()}
        {:ok, %{state | tracked: Map.put(state.tracked, view_id, tracked)}}

      nil ->
        start_tracking(state, view, workspace_id, %{}, false)
    end
  end

  @spec start_tracking(
          state(),
          ProjectView.t(),
          non_neg_integer(),
          %{String.t() => binary() | nil},
          boolean()
        ) :: {:ok, state()} | {:error, state()}
  defp start_tracking(state, view, workspace_id, written, owned) do
    changeset = Overlay.changeset_pid(view)
    # Monitor first: a changeset that stops normally between the two calls
    # then reports `:normal` (drafts deleted), not `:noproc` (drafts kept).
    monitor = Process.monitor(changeset)

    case register(state, changeset, view, workspace_id) do
      :ok ->
        tracked = %{
          view: view,
          workspace_id: workspace_id,
          changeset: changeset,
          monitor: monitor,
          written: written,
          too_large: MapSet.new(),
          retry_delay: nil,
          retry_pending: false,
          owned: owned
        }

        {:ok, %{state | tracked: Map.put(state.tracked, view.id, tracked)}}

      {:error, _reason} ->
        Process.demonitor(monitor, [:flush])
        {:error, state}
    end
  end

  @spec register(state(), pid(), ProjectView.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp register(state, changeset, view, workspace_id) do
    Changeset.observe(changeset, self(), {state.scope, {view, workspace_id}})
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
        state = %{
          state
          | tracked: Map.delete(state.tracked, view_id),
            pending: MapSet.delete(state.pending, view_id)
        }

        # A normal stop follows publish, discard, or closing a clean view:
        # nothing is staged any more. Any other exit keeps the last snapshot.
        if reason == :normal do
          %ProjectView{project_root: root} = tracked.view
          retire(state, StagedDrafts.view_dir(root, view_id, state.store_opts))
        else
          state
        end
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

  # ── Retirement ──────────────────────────────────────────────────────────

  # Deletes a published or discarded view's drafts. A failure stays pending
  # and is retried with backoff; the warning is given once per run of
  # failures. The view's tombstone keeps it from being offered meanwhile.
  @spec retire(state(), String.t()) :: state()
  defp retire(state, dir) do
    case StagedDrafts.retire_view_dir(dir) do
      :ok ->
        %{state | deletes: Map.delete(state.deletes, dir)}

      {:error, reason} ->
        previous = Map.get(state.deletes, dir)
        if is_nil(previous), do: cleanup_warning(reason)
        delay = next_retry_delay(state, previous)
        Process.send_after(self(), {:retry_delete, dir}, delay)
        %{state | deletes: Map.put(state.deletes, dir, delay)}
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

  # A snapshot that did not leave disk matching the staged drafts (a failed
  # write, prune, or delete, or unreadable drafts) is retried with backoff, so
  # a transient failure never waits for the next staged change.
  @spec snapshot(state(), view_id()) :: state()
  defp snapshot(state, view_id) do
    %{view: view, written: written} = tracked = Map.fetch!(state.tracked, view_id)
    # Warn once per run of failures; retries stay quiet until a save succeeds.
    warn? = is_nil(tracked.retry_delay)

    {complete?, tracked} =
      case Overlay.staged_drafts(view) do
        {:ok, []} ->
          # The view directory goes, with its owner record.
          deleted = StagedDrafts.delete_view(view.project_root, view.id, state.store_opts)
          {cleaned_up?(deleted, warn?), %{tracked | written: %{}, owned: false}}

        {:ok, drafts} ->
          case claim(state, tracked, warn?) do
            {:ok, tracked} -> save(state, tracked, drafts, written, warn?)
            {:error, tracked} -> {false, tracked}
          end

        {:error, reason} ->
          Minga.Log.debug(
            :agent,
            "Staged agent edits were not saved: #{inspect(Recovery.safe_reason(reason))}"
          )

          {false, tracked}
      end

    put_tracked(state, settle(state, tracked, complete?))
  end

  @spec save(state(), tracked(), [StagedDraft.t()], %{String.t() => binary() | nil}, boolean()) ::
          {boolean(), tracked()}
  defp save(state, %{view: view} = tracked, drafts, written, warn?) do
    {written, tracked} = write_changed(state, tracked, drafts, written)
    pruned = StagedDrafts.prune(view.project_root, view.id, Map.keys(written), state.store_opts)
    saved? = Enum.all?(written, fn {_path, digest} -> is_binary(digest) end)
    {saved? and cleaned_up?(pruned, warn?), %{tracked | written: written}}
  end

  # Drafts are written only into a view directory this instance has claimed.
  @spec claim(state(), tracked(), boolean()) :: {:ok, tracked()} | {:error, tracked()}
  defp claim(_state, %{owned: true} = tracked, _warn?), do: {:ok, tracked}

  defp claim(state, %{view: view} = tracked, warn?) do
    dir = StagedDrafts.view_dir(view.project_root, view.id, state.store_opts)

    case StagedDrafts.claim_view_dir(dir, state.instance, state.instance_alive?, state.store_opts) do
      :ok ->
        {:ok, %{tracked | owned: true}}

      {:error, reason} ->
        if warn? do
          Minga.Log.warning(
            :agent,
            "Staged agent edits could not be saved, retrying: #{inspect(Recovery.safe_reason(reason))}"
          )
        end

        {:error, tracked}
    end
  end

  @spec settle(state(), tracked(), boolean()) :: tracked()
  defp settle(_state, tracked, true), do: %{tracked | retry_delay: nil}

  defp settle(_state, %{retry_pending: true} = tracked, false), do: tracked

  defp settle(state, tracked, false) do
    delay = next_retry_delay(state, tracked.retry_delay)
    Process.send_after(self(), {:retry_snapshot, tracked.view.id}, delay)
    %{tracked | retry_delay: delay, retry_pending: true}
  end

  @spec next_retry_delay(state(), pos_integer() | nil) :: pos_integer()
  defp next_retry_delay(state, nil), do: state.retry_ms
  defp next_retry_delay(_state, previous), do: min(previous * 2, @max_retry_ms)

  @spec put_tracked(state(), tracked()) :: state()
  defp put_tracked(state, tracked),
    do: %{state | tracked: Map.put(state.tracked, tracked.view.id, tracked)}

  @spec write_changed(state(), tracked(), [StagedDraft.t()], %{String.t() => binary() | nil}) ::
          {%{String.t() => binary() | nil}, tracked()}
  defp write_changed(state, tracked, drafts, written) do
    Enum.reduce(drafts, {%{}, tracked}, fn draft, {acc, tracked} ->
      digest = StagedDraft.digest(draft)

      {saved, tracked} =
        if Map.get(written, draft.path) == digest,
          do: {digest, tracked},
          else: write_draft(state, tracked, draft, digest)

      {Map.put(acc, draft.path, saved), tracked}
    end)
  end

  # Returns the digest now on disk (`nil` retries at the next snapshot) and
  # the tracked view with its too-large notices updated.
  @spec write_draft(state(), tracked(), StagedDraft.t(), binary()) :: {binary() | nil, tracked()}
  defp write_draft(state, %{view: view, workspace_id: workspace_id} = tracked, draft, digest) do
    case StagedDrafts.write(view.project_root, view.id, workspace_id, draft, state.store_opts) do
      :ok ->
        {digest, %{tracked | too_large: MapSet.delete(tracked.too_large, draft.path)}}

      {:error, :draft_too_large} ->
        mark_too_large(state, tracked, draft, digest)

      {:error, reason} ->
        # Warn once per run of failures; retries stay quiet until a save succeeds.
        if is_nil(tracked.retry_delay) do
          Minga.Log.warning(
            :agent,
            "Staged agent edit for #{display_path(draft.path)} could not be saved, retrying: #{inspect(Recovery.safe_reason(reason))}"
          )
        end

        {nil, tracked}
    end
  end

  # The stored older version must not come back after a restart: replace it
  # with a lost marker, and tell the user once per path.
  @spec mark_too_large(state(), tracked(), StagedDraft.t(), binary()) ::
          {binary() | nil, tracked()}
  defp mark_too_large(state, %{view: view} = tracked, draft, digest) do
    case StagedDrafts.write_lost(
           view.project_root,
           view.id,
           tracked.workspace_id,
           draft.path,
           :too_large,
           state.store_opts
         ) do
      :ok ->
        unless MapSet.member?(tracked.too_large, draft.path) do
          Minga.API.message(
            "Staged agent edit for #{display_path(draft.path)} is larger than #{StagedDrafts.max_file_bytes(state.store_opts)} bytes, so it is not saved for a restart. Publish or discard it before quitting."
          )
        end

        {digest, %{tracked | too_large: MapSet.put(tracked.too_large, draft.path)}}

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Staged agent edit for #{display_path(draft.path)} is too large to save, and its saved copy could not be retired: #{inspect(Recovery.safe_reason(reason))}"
        )

        {nil, tracked}
    end
  end

  @spec delete_files(state(), ProjectView.t()) :: :ok | {:error, term()}
  defp delete_files(state, %ProjectView{project_root: root, id: view_id}) do
    log_error(StagedDrafts.delete_view(root, view_id, state.store_opts))
  end

  @spec log_error(:ok | {:error, term()}) :: :ok | {:error, term()}
  defp log_error(:ok), do: :ok

  defp log_error({:error, reason} = error) do
    cleanup_warning(reason)
    error
  end

  @spec cleaned_up?(:ok | {:error, term()}, boolean()) :: boolean()
  defp cleaned_up?(:ok, _warn?), do: true

  defp cleaned_up?({:error, reason}, true) do
    cleanup_warning(reason)
    false
  end

  defp cleaned_up?({:error, _reason}, false), do: false

  @spec cleanup_warning(term()) :: :ok
  defp cleanup_warning(reason) do
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
  # the snapshot of that running view. A retired view, or one whose deletion
  # is pending, is never offered; the deletion of a retired view left by an
  # earlier run is finished here.
  @spec disk_recoveries(state(), String.t()) :: {[Recovery.t()], state()}
  defp disk_recoveries(state, root) do
    case StagedDrafts.load(root, state.store_opts) do
      {:ok, stored} ->
        {retired, stored} = Enum.split_with(stored, & &1.retired)
        state = Enum.reduce(retired, state, &finish_retirement(&2, &1.dir))

        stored
        |> Enum.reject(
          &(Map.has_key?(state.tracked, &1.view_id) or pending_delete?(state, &1.dir))
        )
        |> Enum.flat_map_reduce(state, &claim_and_restore(&2, root, &1))

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Staged agent edits from the previous run were not loaded: #{inspect(Recovery.safe_reason(reason))}"
        )

        {[], state}
    end
  end

  # A deletion that is already pending waits for its retry timer.
  @spec finish_retirement(state(), String.t()) :: state()
  defp finish_retirement(state, dir) do
    if pending_delete?(state, dir), do: state, else: retire(state, dir)
  end

  @spec pending_delete?(state(), String.t()) :: boolean()
  defp pending_delete?(state, dir), do: Map.has_key?(state.deletes, dir)

  # A stored view is restored only by the instance that claims it. The view
  # of another instance that is still running is left alone and not offered.
  # A claim that is not kept by a tracked view is given up again, so an
  # instance never holds drafts it does not keep alive.
  @spec claim_and_restore(state(), String.t(), StagedDrafts.stored_view()) ::
          {[Recovery.t()], state()}
  defp claim_and_restore(state, root, %{dir: dir} = stored) do
    case StagedDrafts.claim_view_dir(dir, state.instance, state.instance_alive?, state.store_opts) do
      :ok ->
        {recovery, state} = restore_view(state, root, stored)
        if recovery.view == nil, do: log_error(StagedDrafts.release_view_dir(dir, state.instance))
        {[recovery], state}

      {:error, :owned} ->
        {[], state}

      {:error, reason} ->
        retained = for entry <- stored.entries, do: {entry_name(entry), {:claim_failed, reason}}
        {[Recovery.restored(stored.workspace_id, nil, retained: retained)], state}
    end
  end

  @spec entry_name(StagedDrafts.entry()) :: String.t()
  defp entry_name({:ok, _file, draft}), do: draft.path
  defp entry_name({_kind, _file, name, _reason}), do: name

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
      case start_tracking(state, view, workspace_id, written, true) do
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
        base_changed: base_changed_paths(view.project_root, restored, state.store_opts),
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

  @spec base_changed_paths(String.t(), [StagedDraft.t()], keyword()) :: [String.t()]
  defp base_changed_paths(root, drafts, store_opts) do
    max = StagedDrafts.max_file_bytes(store_opts)

    for draft <- drafts,
        StagedDraft.base_changed?(draft, read_project_file(Path.join(root, draft.path), max)),
        do: draft.path
  end

  # Regular files only, bounded: a FIFO or device in the project must not
  # block or exhaust the keeper.
  @spec read_project_file(String.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  defp read_project_file(path, max) do
    case Minga.SecureFile.read(path, max) do
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
