defmodule Minga.Git.Repo do
  @moduledoc """
  Per-repository GenServer that owns repo-wide git state.

  One `Git.Repo` exists per git root, registered via `Minga.Git.Repo.Registry`.
  It caches the working tree status (staged, unstaged, untracked, conflict files),
  the current branch name, and ahead/behind counts relative to the upstream.

  ## Refresh strategy

  Event-driven, not polling. Git.Repo starts its own `file_system` watcher on
  the `.git/` directory and filters for changes to `index` (stage/unstage/commit)
  and `HEAD` (branch switch, new commits). A fallback refresh fires on
  `:buffer_saved` events to catch cases where FileWatcher misses changes.

  ## Event publication

  Publishes `:git_status_changed` on the event bus whenever status changes.
  The status panel, modeline, and other consumers subscribe to this event
  for live updates.
  """

  use GenServer

  alias Minga.Git
  alias Minga.Git.Repo.Profile
  alias Minga.Git.Repo.StatusSnapshot
  alias Minga.Git.StatusEntry

  @registry Minga.Git.Repo.Registry
  @supervisor Minga.Git.Repo.Supervisor

  @debounce_ms 150

  @enforce_keys [:git_root]
  defstruct [
    :git_root,
    project_root: nil,
    entries: [],
    branch: nil,
    ahead: 0,
    behind: 0,
    last_commit_message: "",
    stash_count: 0,
    watcher_pid: nil,
    debounce_ref: nil,
    refresh_task: nil,
    refresh_pending?: false,
    awaiting_refresh: [],
    profile: nil,
    degraded?: false,
    degraded_reason: nil,
    events_registry: Minga.Events.default_registry()
  ]

  @typedoc "Git.Repo internal state."
  @type t :: %__MODULE__{
          git_root: String.t(),
          project_root: String.t() | nil,
          entries: [StatusEntry.t()],
          branch: String.t() | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          last_commit_message: String.t(),
          stash_count: non_neg_integer(),
          watcher_pid: pid() | nil,
          debounce_ref: reference() | nil,
          refresh_task: refresh_task() | nil,
          refresh_pending?: boolean(),
          awaiting_refresh: [GenServer.from()],
          profile: Profile.t() | nil,
          degraded?: boolean(),
          degraded_reason: degraded_reason() | nil,
          events_registry: Minga.Events.registry()
        }

  @typedoc """
  Why the cached status is degraded.

  `:status_timeout` means `git status` exceeded the profile's bounded timeout on
  a full checkout, so the entry list may be missing untracked (and other)
  changes. The UI surfaces this so the omission is visible, never silent.
  """
  @type degraded_reason :: :status_timeout

  @typedoc "Options for starting a Git.Repo process."
  @type start_opt ::
          {:git_root, String.t()}
          | {:project_root, String.t() | nil}
          | {:events_registry, Minga.Events.registry()}

  @typedoc "Summary of repo status for display."
  @type summary :: %{
          branch: String.t() | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          staged_count: non_neg_integer(),
          unstaged_count: non_neg_integer(),
          untracked_count: non_neg_integer(),
          conflict_count: non_neg_integer(),
          last_commit_message: String.t(),
          stash_count: non_neg_integer(),
          degraded?: boolean(),
          degraded_reason: degraded_reason() | nil
        }

  @typedoc "Cached status entries plus the path they are relative to."
  @type status_snapshot :: StatusSnapshot.t()

  # ── Client API ─────────────────────────────────────────────────────────

  @doc "Starts a Git.Repo for the given git root."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    git_root = Keyword.fetch!(opts, :git_root)
    name = {:via, Registry, {@registry, git_root}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the child spec for supervision."
  @spec child_spec([start_opt()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    git_root = Keyword.fetch!(opts, :git_root)

    %{
      id: {__MODULE__, git_root},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc """
  Looks up the Git.Repo process for a git root.

  Returns the pid or nil if no repo is tracked for that root.
  """
  @spec lookup(String.t()) :: pid() | nil
  def lookup(git_root) when is_binary(git_root) do
    case Registry.lookup(@registry, git_root) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Ensures a Git.Repo process exists for the given git root.

  Returns `{:ok, pid}` if one already exists or was started successfully,
  or `{:error, reason}` if it couldn't be started.
  """
  @spec ensure_started(String.t(), String.t() | nil, Minga.Events.registry()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(
        git_root,
        project_root \\ nil,
        events_registry \\ Minga.Events.default_registry()
      )
      when is_binary(git_root) do
    case lookup(git_root) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        DynamicSupervisor.start_child(
          @supervisor,
          {__MODULE__,
           git_root: git_root, project_root: project_root, events_registry: events_registry}
        )
    end
  end

  @doc "Returns the cached status entries."
  @spec status(GenServer.server()) :: [StatusEntry.t()]
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc "Returns cached status for the tracked repo containing `path`, without shelling out to git."
  @spec cached_status_for_path(String.t()) :: {:ok, status_snapshot()} | :not_tracked
  def cached_status_for_path(path) when is_binary(path) do
    path = Path.expand(path)

    case tracked_repo_for_path(path) do
      nil -> :not_tracked
      {_git_root, pid} -> {:ok, status_snapshot(pid)}
    end
  catch
    :exit, _ -> :not_tracked
  end

  @doc "Returns the cached status entries with the path they are relative to."
  @spec status_snapshot(GenServer.server()) :: status_snapshot()
  def status_snapshot(server) do
    GenServer.call(server, :status_snapshot)
  end

  @doc "Returns the current branch name."
  @spec branch(GenServer.server()) :: String.t() | nil
  def branch(server) do
    GenServer.call(server, :branch)
  end

  @doc "Returns a summary of the repo status."
  @spec summary(GenServer.server()) :: summary()
  def summary(server) do
    GenServer.call(server, :summary)
  end

  @doc """
  Returns whether the cached status is degraded and why.

  `{true, reason}` means the last `git status` was trimmed (e.g. timed out on a
  full checkout) so untracked or other changes may be missing. `{false, nil}`
  means the cache is complete.
  """
  @spec degraded(GenServer.server()) :: {boolean(), degraded_reason() | nil}
  def degraded(server) do
    GenServer.call(server, :degraded)
  end

  @doc "Forces a status refresh. Used after staging/committing operations."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server) do
    GenServer.cast(server, :refresh)
  end

  @doc "Blocks until the repo has no in-flight or pending refresh work."
  @spec await_refresh(GenServer.server()) :: :ok
  def await_refresh(server) do
    GenServer.call(server, :await_refresh, 5_000)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    git_root = Keyword.fetch!(opts, :git_root)
    project_root = Keyword.get(opts, :project_root)
    events_registry = Keyword.get(opts, :events_registry, Minga.Events.default_registry())

    Minga.Events.subscribe(:buffer_saved, events_registry)

    state = %__MODULE__{
      git_root: git_root,
      project_root: project_root,
      events_registry: events_registry
    }

    state = start_git_watcher(state)
    send(self(), :initial_refresh)

    Minga.Log.debug(:editor, "[Git.Repo] started for #{git_root}")

    {:ok, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), t()) :: {:reply, term(), t()}
  def handle_call(:status, _from, state) do
    {:reply, state.entries, state}
  end

  def handle_call(:status_snapshot, _from, state) do
    snapshot =
      StatusSnapshot.new(
        state.git_root,
        entry_base_path(state),
        state.entries,
        state.degraded?,
        state.degraded_reason
      )

    {:reply, snapshot, state}
  end

  def handle_call(:branch, _from, state) do
    {:reply, state.branch, state}
  end

  def handle_call(:summary, _from, state) do
    summary = build_summary(state)
    {:reply, summary, state}
  end

  def handle_call(:degraded, _from, state) do
    {:reply, {state.degraded?, state.degraded_reason}, state}
  end

  def handle_call(
        :await_refresh,
        _from,
        %{refresh_task: nil, refresh_pending?: false, debounce_ref: nil} = state
      ) do
    {:reply, :ok, state}
  end

  def handle_call(:await_refresh, from, state) do
    {:noreply, %{state | awaiting_refresh: [from | state.awaiting_refresh]}}
  end

  @impl true
  @spec handle_cast(term(), t()) :: {:noreply, t()}
  def handle_cast(:refresh, state) do
    {:noreply, request_refresh(state)}
  end

  @impl true
  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info(:initial_refresh, state) do
    {:noreply, request_refresh(state)}
  end

  def handle_info({:refresh_result, pid, result}, %{refresh_task: %{pid: pid, ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      state
      |> clear_refresh_task()
      |> apply_refresh_result(result)
      |> maybe_run_pending_refresh()
      |> reply_refresh_waiters_if_idle()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{refresh_task: %{ref: ref}} = state) do
    Minga.Log.warning(
      :editor,
      "[Git.Repo] refresh failed for #{state.git_root}: #{inspect(reason)}"
    )

    state =
      state
      |> clear_refresh_task()
      |> maybe_run_pending_refresh()
      |> reply_refresh_waiters_if_idle()

    {:noreply, state}
  end

  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    path_str = to_string(path)

    if refresh_path?(path_str) do
      {:noreply, schedule_debounce(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Minga.Log.warning(:editor, "[Git.Repo] file watcher stopped, restarting")
    state = start_git_watcher(state)
    {:noreply, state}
  end

  def handle_info(:debounce_refresh, state) do
    {:noreply, state |> cancel_debounce() |> request_refresh()}
  end

  def handle_info(
        {:minga_event, :buffer_saved, %Minga.Events.BufferEvent{path: path}},
        state
      ) do
    # Fallback refresh: if a saved file is inside our git root, refresh
    if String.starts_with?(Path.expand(path), state.git_root) do
      {:noreply, schedule_debounce(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), t()) :: :ok
  def terminate(_reason, state) do
    stop_refresh_task(state)
    stop_git_watcher(state)
    :ok
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec tracked_repo_for_path(String.t()) :: {String.t(), pid()} | nil
  defp tracked_repo_for_path(path) do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {git_root, pid} ->
      is_binary(git_root) and path_under_root?(path, git_root) and Process.alive?(pid)
    end)
    |> Enum.sort_by(fn {git_root, _pid} -> byte_size(git_root) end, :desc)
    |> List.first()
  end

  @spec path_under_root?(String.t(), String.t()) :: boolean()
  defp path_under_root?(path, root) do
    expanded_root = Path.expand(root)
    path == expanded_root or String.starts_with?(path, path_prefix(expanded_root))
  end

  @spec path_prefix(String.t()) :: String.t()
  defp path_prefix("/"), do: "/"
  defp path_prefix(root), do: root <> "/"

  @spec entry_base_path(t()) :: String.t()
  defp entry_base_path(%{project_root: root}) when is_binary(root), do: root
  defp entry_base_path(%{git_root: root}), do: root

  @typep refresh_task :: %{pid: pid(), ref: reference()}
  @typep fetch_result(value) :: {:ok, value} | :error

  @typep status_result :: %{
           entries: fetch_result([StatusEntry.t()]),
           degraded?: boolean(),
           degraded_reason: degraded_reason() | nil
         }

  @typep refresh_result :: %{
           profile: Profile.t(),
           status: status_result(),
           branch: fetch_result(String.t() | nil),
           ahead_behind: fetch_result({non_neg_integer(), non_neg_integer()}),
           last_commit_message: fetch_result(String.t()),
           stash_count: fetch_result(non_neg_integer())
         }

  @spec request_refresh(t()) :: t()
  defp request_refresh(%{refresh_task: nil} = state), do: start_refresh_task(state)
  defp request_refresh(state), do: %{state | refresh_pending?: true}

  @spec start_refresh_task(t()) :: t()
  defp start_refresh_task(state) do
    task = async_refresh(state.git_root, state.project_root, state.profile)
    %{state | refresh_task: task, refresh_pending?: false}
  end

  @spec async_refresh(String.t(), String.t() | nil, Profile.t() | nil) :: refresh_task()
  defp async_refresh(git_root, project_root, profile) do
    fun = fn -> build_refresh_result(git_root, project_root, profile) end

    case Process.whereis(Minga.Eval.TaskSupervisor) do
      nil -> monitored_process(fun)
      _pid -> supervised_monitored_process(Minga.Eval.TaskSupervisor, fun)
    end
  end

  @spec supervised_monitored_process(atom(), (-> term())) :: refresh_task()
  defp supervised_monitored_process(supervisor, fun) when is_atom(supervisor) do
    owner = self()

    case Task.Supervisor.start_child(supervisor, fn ->
           send(owner, {:refresh_result, self(), fun.()})
         end) do
      {:ok, pid} -> %{pid: pid, ref: Process.monitor(pid)}
      {:error, _reason} -> monitored_process(fun)
    end
  end

  @spec monitored_process((-> term())) :: refresh_task()
  defp monitored_process(fun) when is_function(fun, 0) do
    owner = self()
    {pid, ref} = spawn_monitor(fn -> send(owner, {:refresh_result, self(), fun.()}) end)
    %{pid: pid, ref: ref}
  end

  @spec build_refresh_result(String.t(), String.t() | nil, Profile.t() | nil) :: refresh_result()
  defp build_refresh_result(git_root, project_root, profile) do
    profile = profile || Profile.detect(git_root)

    %{
      profile: profile,
      status: fetch_status(git_root, project_root, profile),
      branch: fetch_branch(git_root),
      ahead_behind: fetch_ahead_behind(git_root),
      last_commit_message: fetch_last_commit_message(git_root),
      stash_count: fetch_stash_count(git_root)
    }
  end

  @spec clear_refresh_task(t()) :: t()
  defp clear_refresh_task(state), do: %{state | refresh_task: nil}

  @spec maybe_run_pending_refresh(t()) :: t()
  defp maybe_run_pending_refresh(%{refresh_pending?: true} = state), do: request_refresh(state)
  defp maybe_run_pending_refresh(state), do: state

  @spec reply_refresh_waiters_if_idle(t()) :: t()
  defp reply_refresh_waiters_if_idle(
         %{refresh_task: nil, refresh_pending?: false, debounce_ref: nil} = state
       ) do
    Enum.each(state.awaiting_refresh, &GenServer.reply(&1, :ok))
    %{state | awaiting_refresh: []}
  end

  defp reply_refresh_waiters_if_idle(state), do: state

  @spec apply_refresh_result(t(), refresh_result()) :: t()
  defp apply_refresh_result(state, result) do
    old_entries = state.entries
    old_branch = state.branch
    old_ahead = state.ahead
    old_behind = state.behind
    old_last_commit_message = state.last_commit_message
    old_stash_count = state.stash_count
    old_degraded? = state.degraded?

    # On a degraded (timed-out) status we keep the previously cached entries
    # rather than dropping them, so the file list stays visible while the
    # degraded flag tells the user it may be incomplete.
    entries = fetched_or_current(result.status.entries, old_entries)
    branch = fetched_or_current(result.branch, old_branch)
    {ahead, behind} = fetched_or_current(result.ahead_behind, {old_ahead, old_behind})
    last_commit_message = fetched_or_current(result.last_commit_message, old_last_commit_message)
    stash_count = fetched_or_current(result.stash_count, old_stash_count)

    state = %{
      state
      | entries: entries,
        branch: branch,
        ahead: ahead,
        behind: behind,
        last_commit_message: last_commit_message,
        stash_count: stash_count,
        profile: result.profile,
        degraded?: result.status.degraded?,
        degraded_reason: result.status.degraded_reason
    }

    changed =
      entries != old_entries or branch != old_branch or
        ahead != old_ahead or behind != old_behind or
        last_commit_message != old_last_commit_message or stash_count != old_stash_count or
        state.degraded? != old_degraded?

    if changed do
      Minga.Events.broadcast(
        :git_status_changed,
        %Minga.Events.GitStatusEvent{
          git_root: state.git_root,
          entries: state.entries,
          branch: state.branch,
          ahead: state.ahead,
          behind: state.behind,
          entry_base_path: entry_base_path(state),
          last_commit_message: state.last_commit_message,
          stash_count: state.stash_count,
          degraded?: state.degraded?,
          degraded_reason: state.degraded_reason
        },
        state.events_registry
      )
    end

    state
  end

  @spec refresh_path?(String.t()) :: boolean()
  defp refresh_path?(path_str) do
    basename = Path.basename(path_str)
    git_status_file?(basename) or stash_ref_path?(path_str)
  end

  @spec git_status_file?(String.t()) :: boolean()
  defp git_status_file?(basename) do
    basename in ["index", "HEAD", "MERGE_HEAD", "REBASE_HEAD"]
  end

  @spec stash_ref_path?(String.t()) :: boolean()
  defp stash_ref_path?(path_str) do
    String.ends_with?(path_str, "/refs/stash") or String.ends_with?(path_str, "/logs/refs/stash")
  end

  @spec fetched_or_current(fetch_result(value), value) :: value when value: term()
  defp fetched_or_current({:ok, value}, _current), do: value
  defp fetched_or_current(:error, current), do: current

  @spec fetch_status(String.t(), String.t() | nil, Profile.t()) :: status_result()
  defp fetch_status(git_root, project_root, %Profile{} = profile) do
    case Git.status(git_root,
           untracked_mode: profile.untracked_mode,
           timeout_ms: profile.timeout_ms
         ) do
      {:ok, entries} ->
        # A clean run clears any prior degraded flag.
        %{
          entries: {:ok, maybe_relativize_paths(entries, git_root, project_root)},
          degraded?: false,
          degraded_reason: nil
        }

      {:error, reason} ->
        status_error_result(reason, profile)
    end
  end

  # A status timeout on a full checkout (untracked_mode: :normal) means results
  # were trimmed while untracked files were in scope. We keep the previously
  # cached entries (handled in apply_refresh_result) and flag the cache degraded
  # so the UI shows it, rather than silently dropping untracked visibility.
  @spec status_error_result(String.t(), Profile.t()) :: status_result()
  defp status_error_result(reason, profile) do
    if status_timed_out?(reason) and Profile.degrades_visibly?(profile) do
      Minga.Log.warning(:editor, "[Git.Repo] status degraded (timeout): #{reason}")
      %{entries: :error, degraded?: true, degraded_reason: :status_timeout}
    else
      Minga.Log.warning(:editor, "[Git.Repo] status failed: #{reason}")
      %{entries: :error, degraded?: false, degraded_reason: nil}
    end
  end

  @spec status_timed_out?(String.t()) :: boolean()
  defp status_timed_out?(reason), do: String.contains?(reason, "timed out")

  @spec fetch_branch(String.t()) :: fetch_result(String.t() | nil)
  defp fetch_branch(git_root) do
    case Git.current_branch(git_root) do
      {:ok, branch} -> {:ok, branch}
      :error -> :error
    end
  end

  @spec fetch_ahead_behind(String.t()) :: fetch_result({non_neg_integer(), non_neg_integer()})
  defp fetch_ahead_behind(git_root) do
    case Git.ahead_behind(git_root) do
      {:ok, ahead, behind} -> {:ok, {ahead, behind}}
      :error -> :error
    end
  end

  @spec fetch_last_commit_message(String.t()) :: fetch_result(String.t())
  defp fetch_last_commit_message(git_root) do
    case Git.last_commit_message(git_root) do
      {:ok, message} -> {:ok, message}
      :error -> :error
    end
  end

  @spec fetch_stash_count(String.t()) :: fetch_result(non_neg_integer())
  defp fetch_stash_count(git_root) do
    case Git.stash_list(git_root) do
      {:ok, entries} -> {:ok, length(entries)}
      {:error, reason} -> log_stash_count_failure(reason)
    end
  end

  @spec log_stash_count_failure(String.t()) :: :error
  defp log_stash_count_failure(reason) do
    Minga.Log.warning(:editor, "[Git.Repo] stash list failed: #{reason}")
    :error
  end

  @spec maybe_relativize_paths([StatusEntry.t()], String.t(), String.t() | nil) :: [
          StatusEntry.t()
        ]
  defp maybe_relativize_paths(entries, _git_root, nil), do: entries

  defp maybe_relativize_paths(entries, git_root, project_root) when git_root == project_root,
    do: entries

  defp maybe_relativize_paths(entries, git_root, project_root) do
    # In a monorepo, git root might be /repo and project root /repo/apps/my_app.
    # Convert paths from git-relative to project-relative for display.
    prefix = Path.relative_to(project_root, git_root) <> "/"

    for entry <- entries,
        String.starts_with?(entry.path, prefix),
        do: %{entry | path: String.replace_prefix(entry.path, prefix, "")}
  end

  @spec build_summary(t()) :: summary()
  defp build_summary(state) do
    counts =
      Enum.reduce(state.entries, %{staged: 0, unstaged: 0, untracked: 0, conflict: 0}, fn entry,
                                                                                          acc ->
        case {entry.status, entry.staged} do
          {:conflict, _} -> %{acc | conflict: acc.conflict + 1}
          {:untracked, _} -> %{acc | untracked: acc.untracked + 1}
          {_, true} -> %{acc | staged: acc.staged + 1}
          {_, false} -> %{acc | unstaged: acc.unstaged + 1}
        end
      end)

    %{
      branch: state.branch,
      ahead: state.ahead,
      behind: state.behind,
      staged_count: counts.staged,
      unstaged_count: counts.unstaged,
      untracked_count: counts.untracked,
      conflict_count: counts.conflict,
      last_commit_message: state.last_commit_message,
      stash_count: state.stash_count,
      degraded?: state.degraded?,
      degraded_reason: state.degraded_reason
    }
  end

  @spec start_git_watcher(t()) :: t()
  defp start_git_watcher(state) do
    git_dir = Path.join(state.git_root, ".git")

    if File.dir?(git_dir) do
      do_start_git_watcher(state, git_dir)
    else
      state
    end
  end

  @spec do_start_git_watcher(t(), String.t()) :: t()
  defp do_start_git_watcher(state, git_dir) do
    case FileSystem.start_link(dirs: [git_dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        %{state | watcher_pid: pid}

      {:error, reason} ->
        Minga.Log.warning(:editor, "[Git.Repo] failed to start .git watcher: #{inspect(reason)}")
        state

      :ignore ->
        state
    end
  end

  @spec stop_refresh_task(t()) :: :ok
  defp stop_refresh_task(%{refresh_task: nil}), do: :ok

  defp stop_refresh_task(%{refresh_task: %{pid: pid, ref: ref}}) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    :ok
  end

  @spec stop_git_watcher(t()) :: :ok
  defp stop_git_watcher(%{watcher_pid: nil}), do: :ok

  defp stop_git_watcher(%{watcher_pid: pid}) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  @spec cancel_debounce(t()) :: t()
  defp cancel_debounce(%{debounce_ref: nil} = state), do: state

  defp cancel_debounce(%{debounce_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | debounce_ref: nil}
  end

  @spec schedule_debounce(t()) :: t()
  defp schedule_debounce(%{debounce_ref: nil} = state) do
    ref = Process.send_after(self(), :debounce_refresh, @debounce_ms)
    %{state | debounce_ref: ref}
  end

  defp schedule_debounce(%{debounce_ref: existing_ref} = state)
       when is_reference(existing_ref) do
    Process.cancel_timer(existing_ref)
    ref = Process.send_after(self(), :debounce_refresh, @debounce_ms)
    %{state | debounce_ref: ref}
  end
end
