defmodule MingaAgent.StagedDraftKeeper do
  @moduledoc """
  Keeps staged agent edits durable and reachable across Editor restarts and full restarts.

  Approved agent edits wait in a workspace's overlay `MingaAgent.ProjectView` (a changeset plus buffer forks) until the user publishes or discards them. Those processes live under `MingaAgent.Supervisor`, so they outlive an Editor restart, but the restarted Editor has no handle to them, and a full restart loses them. This process is the single owner of their durability:

    * **Tracking.** `persist/3` registers a workspace's view, keyed by `{project_root, workspace_id}`. The keeper monitors the view's changeset and subscribes to its revisions.
    * **Persistence.** After each staged change the keeper writes the view's drafts with `Minga.Session.StagedDrafts` (one private, atomic file per draft). Only drafts whose content changed are rewritten; files for paths that are no longer staged are removed.
    * **Deletion.** A changeset stops normally only after a successful publish, a discard, or a close of a clean view, so a `:normal` exit deletes the workspace's draft files. Any other exit (a crash, an application shutdown) keeps them for the next start.
    * **Recovery.** `recover/3` hands an Editor every staged view of its project: views that are still running (`:live`, after an Editor restart) and views rebuilt from disk (`:disk`, after a full restart). The reply is `{:staged_drafts_recovered, project_root, [Recovery.t()]}`, sent only when there is something to offer.

  All disk I/O and every call into the changeset and forks happen here, never on the Editor process. Callers only cast.
  """

  use GenServer

  alias Minga.Session.StagedDraft
  alias Minga.Session.StagedDrafts
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.Overlay
  alias MingaAgent.StagedDraftKeeper.Recovery

  @typedoc "A tracked workspace."
  @type key :: {project_root :: String.t(), workspace_id :: non_neg_integer()}

  @typep tracked :: %{
           view: ProjectView.t(),
           changeset: pid(),
           monitor: reference(),
           written: %{String.t() => binary() | nil}
         }

  @typep state :: %{
           store_opts: keyword(),
           tracked: %{key() => tracked()},
           pending: MapSet.t(key())
         }

  @typedoc "Start options. `:staged_drafts_dir` overrides the store directory."
  @type start_opt :: {:name, GenServer.name() | nil} | {:staged_drafts_dir, String.t()}

  # ── Client API ──────────────────────────────────────────────────────────

  @doc "Starts the keeper."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Tracks `view` as the staged view of `workspace_id` and persists its drafts.

  Only overlay views stage edits; other views are ignored. Tracking a view under a new workspace id moves its drafts to that workspace.
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
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    # Trapping exits runs terminate/2 on shutdown, where pending exit reports
    # of discarded or published changesets still delete their drafts.
    Process.flag(:trap_exit, true)

    {:ok,
     %{store_opts: Keyword.take(opts, [:staged_drafts_dir]), tracked: %{}, pending: MapSet.new()}}
  end

  @impl true
  def handle_cast({:persist, %ProjectView{} = view, workspace_id}, state) do
    key = {view.project_root, workspace_id}

    case track(state, key, view) do
      {:ok, state} -> {:noreply, snapshot(state, key)}
      {:error, state} -> {:noreply, state}
    end
  end

  def handle_cast({:recover, root, reply_to}, state) do
    {live, state} = live_recoveries(state, root)
    {restored, state} = disk_recoveries(state, root, tracked_ids(state, root))

    case live ++ restored do
      [] -> :ok
      recoveries -> send(reply_to, {:staged_drafts_recovered, root, recoveries})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:changeset_revised, changeset}, state) do
    case key_for_changeset(state, changeset) do
      nil -> {:noreply, state}
      key -> {:noreply, schedule_snapshot(state, key)}
    end
  end

  def handle_info({:snapshot, key}, state) do
    state = %{state | pending: MapSet.delete(state.pending, key)}

    if Map.has_key?(state.tracked, key),
      do: {:noreply, snapshot(state, key)},
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

  @spec track(state(), key(), ProjectView.t()) :: {:ok, state()} | {:error, state()}
  defp track(state, key, view) do
    changeset = Overlay.changeset_pid(view)

    case Map.get(state.tracked, key) do
      %{changeset: ^changeset} -> {:ok, state}
      previous -> start_tracking(state, key, view, changeset, written_files(previous))
    end
  end

  @spec start_tracking(state(), key(), ProjectView.t(), pid(), %{String.t() => binary() | nil}) ::
          {:ok, state()} | {:error, state()}
  defp start_tracking(state, key, view, changeset, written) do
    state = state |> untrack_changeset_elsewhere(changeset, key) |> forget(key)

    case observe(changeset) do
      :ok ->
        tracked = %{
          view: view,
          changeset: changeset,
          monitor: Process.monitor(changeset),
          # The files on disk for this key belong to the previous view until the
          # first snapshot of the new view reconciles them.
          written: written
        }

        {:ok, %{state | tracked: Map.put(state.tracked, key, tracked)}}

      {:error, _reason} ->
        {:error, state}
    end
  end

  @spec written_files(tracked() | nil) :: %{String.t() => binary() | nil}
  defp written_files(nil), do: %{}
  defp written_files(%{written: written}), do: written

  # A view moved to another workspace id: its drafts move with it.
  @spec untrack_changeset_elsewhere(state(), pid(), key()) :: state()
  defp untrack_changeset_elsewhere(state, changeset, key) do
    case key_for_changeset(state, changeset) do
      nil ->
        state

      ^key ->
        state

      old_key ->
        delete_files(state, old_key)
        forget(state, old_key)
    end
  end

  @spec forget(state(), key()) :: state()
  defp forget(state, key) do
    case Map.pop(state.tracked, key) do
      {nil, _tracked} ->
        state

      {%{monitor: monitor}, tracked} ->
        Process.demonitor(monitor, [:flush])
        %{state | tracked: tracked, pending: MapSet.delete(state.pending, key)}
    end
  end

  @spec observe(pid()) :: :ok | {:error, term()}
  defp observe(changeset) do
    Changeset.observe(changeset, self())
  catch
    :exit, reason -> {:error, {:changeset_unavailable, reason}}
  end

  @spec key_for_changeset(state(), pid()) :: key() | nil
  defp key_for_changeset(state, changeset) do
    Enum.find_value(state.tracked, fn
      {key, %{changeset: ^changeset}} -> key
      _other -> nil
    end)
  end

  @spec changeset_down(state(), reference(), term()) :: state()
  defp changeset_down(state, ref, reason) do
    case Enum.find(state.tracked, fn {_key, tracked} -> tracked.monitor == ref end) do
      nil ->
        state

      {key, _tracked} ->
        # A normal stop follows publish, discard, or closing a clean view:
        # nothing is staged any more. Any other exit keeps the last snapshot.
        if reason == :normal, do: delete_files(state, key)

        %{
          state
          | tracked: Map.delete(state.tracked, key),
            pending: MapSet.delete(state.pending, key)
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
  @spec schedule_snapshot(state(), key()) :: state()
  defp schedule_snapshot(state, key) do
    if MapSet.member?(state.pending, key) do
      state
    else
      send(self(), {:snapshot, key})
      %{state | pending: MapSet.put(state.pending, key)}
    end
  end

  @spec snapshot(state(), key()) :: state()
  defp snapshot(state, {root, workspace_id} = key) do
    %{view: view, written: written} = tracked = Map.fetch!(state.tracked, key)

    case Overlay.staged_drafts(view) do
      {:ok, []} ->
        delete_files(state, key)
        put_written(state, key, tracked, %{})

      {:ok, drafts} ->
        written = write_changed(state, key, drafts, written)
        log_error(StagedDrafts.prune(root, workspace_id, Map.keys(written), state.store_opts))
        put_written(state, key, tracked, written)

      {:error, reason} ->
        Minga.Log.debug(:agent, "Staged agent edits were not saved: #{inspect(reason)}")
        state
    end
  end

  @spec write_changed(state(), key(), [StagedDraft.t()], %{String.t() => binary() | nil}) ::
          %{String.t() => binary() | nil}
  defp write_changed(state, key, drafts, written) do
    Map.new(drafts, fn draft ->
      digest = StagedDraft.digest(draft)

      if Map.get(written, draft.path) == digest,
        do: {draft.path, digest},
        else: {draft.path, write_draft(state, key, draft, digest)}
    end)
  end

  # Returns the digest now on disk; `nil` forces a retry at the next snapshot.
  @spec write_draft(state(), key(), StagedDraft.t(), binary()) :: binary() | nil
  defp write_draft(state, {root, workspace_id}, draft, digest) do
    case StagedDrafts.write(root, workspace_id, draft, state.store_opts) do
      :ok ->
        digest

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Staged agent edit for #{draft.path} could not be saved: #{inspect(reason)}"
        )

        nil
    end
  end

  @spec put_written(state(), key(), tracked(), %{String.t() => binary() | nil}) :: state()
  defp put_written(state, key, tracked, written) do
    %{state | tracked: Map.put(state.tracked, key, %{tracked | written: written})}
  end

  @spec delete_files(state(), key()) :: :ok
  defp delete_files(state, {root, workspace_id}) do
    log_error(StagedDrafts.delete_workspace(root, workspace_id, state.store_opts))
  end

  @spec log_error(:ok | {:error, term()}) :: :ok
  defp log_error(:ok), do: :ok

  defp log_error({:error, reason}) do
    Minga.Log.warning(
      :agent,
      "Staged agent edit files could not be cleaned up: #{inspect(reason)}"
    )
  end

  # ── Recovery ────────────────────────────────────────────────────────────

  @spec live_recoveries(state(), String.t()) :: {[Recovery.t()], state()}
  defp live_recoveries(state, root) do
    recoveries =
      for {{^root, workspace_id}, %{view: view}} <- state.tracked,
          {:ok, [_ | _] = changes} <- [view_diff(view)],
          do: Recovery.live(workspace_id, view, changes)

    {Enum.sort_by(recoveries, & &1.workspace_id), state}
  end

  # A workspace whose view is still tracked is never rebuilt from disk; its
  # files are the snapshot of that running view.
  @spec tracked_ids(state(), String.t()) :: MapSet.t(non_neg_integer())
  defp tracked_ids(state, root) do
    for {{^root, workspace_id}, _tracked} <- state.tracked, into: MapSet.new(), do: workspace_id
  end

  @spec disk_recoveries(state(), String.t(), MapSet.t(non_neg_integer())) ::
          {[Recovery.t()], state()}
  defp disk_recoveries(state, root, live_ids) do
    root
    |> StagedDrafts.load(state.store_opts)
    |> Enum.reject(fn {workspace_id, _entries} -> MapSet.member?(live_ids, workspace_id) end)
    |> Enum.map_reduce(state, fn {workspace_id, entries}, state ->
      restore_workspace(state, root, workspace_id, entries)
    end)
  end

  @spec restore_workspace(state(), String.t(), non_neg_integer(), [StagedDrafts.entry()]) ::
          {Recovery.t(), state()}
  defp restore_workspace(state, root, workspace_id, entries) do
    drafts = for {:ok, _file, draft} <- entries, do: draft

    # A draft that cannot be decoded cannot be recovered later either.
    unreadable =
      for {:lost, file, name, reason} <- entries do
        _ = StagedDrafts.remove_file(file)
        {name, reason}
      end

    case restore_view(root, drafts) do
      {:ok, view, failures} ->
        Enum.each(failures, fn {path, _reason} ->
          StagedDrafts.delete(root, workspace_id, path, state.store_opts)
        end)

        restored = reject_failed(drafts, failures)
        recovery_with_view(state, root, workspace_id, view, restored, unreadable ++ failures)

      {:error, reason} ->
        retained = for draft <- drafts, do: {draft.path, reason}
        {Recovery.restored(workspace_id, nil, lost: unreadable, retained: retained), state}
    end
  end

  @spec restore_view(String.t(), [StagedDraft.t()]) ::
          {:ok, ProjectView.t() | nil, [Recovery.failed_draft()]} | {:error, term()}
  defp restore_view(_root, []), do: {:ok, nil, []}
  defp restore_view(root, drafts), do: Overlay.restore(root, drafts)

  @spec reject_failed([StagedDraft.t()], [Recovery.failed_draft()]) :: [StagedDraft.t()]
  defp reject_failed(drafts, failures) do
    failed = MapSet.new(failures, &elem(&1, 0))
    Enum.reject(drafts, &MapSet.member?(failed, &1.path))
  end

  @spec recovery_with_view(
          state(),
          String.t(),
          non_neg_integer(),
          ProjectView.t() | nil,
          [StagedDraft.t()],
          [Recovery.failed_draft()]
        ) :: {Recovery.t(), state()}
  defp recovery_with_view(state, root, workspace_id, view, [], lost) do
    close_view(view)
    delete_files(state, {root, workspace_id})
    {Recovery.restored(workspace_id, nil, lost: lost), state}
  end

  defp recovery_with_view(state, root, workspace_id, view, restored, lost) do
    key = {root, workspace_id}
    written = Map.new(restored, &{&1.path, StagedDraft.digest(&1)})

    state =
      case start_tracking(state, key, view, Overlay.changeset_pid(view), written) do
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
        base_changed: base_changed_paths(root, restored),
        lost: lost
      )

    {recovery, state}
  end

  @spec base_changed_paths(String.t(), [StagedDraft.t()]) :: [String.t()]
  defp base_changed_paths(root, drafts) do
    for draft <- drafts,
        StagedDraft.base_changed?(draft, File.read(Path.join(root, draft.path))),
        do: draft.path
  end

  @spec view_diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  defp view_diff(view) do
    if ProjectView.active?(view), do: ProjectView.diff(view), else: {:error, :inactive}
  end

  @spec close_view(ProjectView.t() | nil) :: :ok
  defp close_view(nil), do: :ok

  defp close_view(view) do
    _ = ProjectView.close(view)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
