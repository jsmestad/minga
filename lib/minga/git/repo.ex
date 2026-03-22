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
    watcher_pid: nil,
    debounce_ref: nil
  ]

  @typedoc "Git.Repo internal state."
  @type t :: %__MODULE__{
          git_root: String.t(),
          project_root: String.t() | nil,
          entries: [StatusEntry.t()],
          branch: String.t() | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          watcher_pid: pid() | nil,
          debounce_ref: reference() | nil
        }

  @typedoc "Options for starting a Git.Repo process."
  @type start_opt :: {:git_root, String.t()} | {:project_root, String.t() | nil}

  @typedoc "Summary of repo status for display."
  @type summary :: %{
          branch: String.t() | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          staged_count: non_neg_integer(),
          unstaged_count: non_neg_integer(),
          untracked_count: non_neg_integer(),
          conflict_count: non_neg_integer()
        }

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
  @spec ensure_started(String.t(), String.t() | nil) :: {:ok, pid()} | {:error, term()}
  def ensure_started(git_root, project_root \\ nil) when is_binary(git_root) do
    case lookup(git_root) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        DynamicSupervisor.start_child(
          @supervisor,
          {__MODULE__, git_root: git_root, project_root: project_root}
        )
    end
  end

  @doc "Returns the cached status entries."
  @spec status(GenServer.server()) :: [StatusEntry.t()]
  def status(server) do
    GenServer.call(server, :status)
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

  @doc "Forces a status refresh. Used after staging/committing operations."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server) do
    GenServer.cast(server, :refresh)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    git_root = Keyword.fetch!(opts, :git_root)
    project_root = Keyword.get(opts, :project_root)

    Minga.Events.subscribe(:buffer_saved)

    state = %__MODULE__{
      git_root: git_root,
      project_root: project_root
    }

    # Load initial status and branch synchronously so callers have data immediately
    state = do_refresh(state)

    # Start watching .git/ for changes
    state = start_git_watcher(state)

    Minga.Log.debug(:editor, "[Git.Repo] started for #{git_root} (branch: #{state.branch})")

    {:ok, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), t()) :: {:reply, term(), t()}
  def handle_call(:status, _from, state) do
    {:reply, state.entries, state}
  end

  def handle_call(:branch, _from, state) do
    {:reply, state.branch, state}
  end

  def handle_call(:summary, _from, state) do
    summary = build_summary(state)
    {:reply, summary, state}
  end

  @impl true
  @spec handle_cast(term(), t()) :: {:noreply, t()}
  def handle_cast(:refresh, state) do
    state = do_refresh(state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    path_str = to_string(path)
    basename = Path.basename(path_str)

    if basename in ["index", "HEAD", "MERGE_HEAD", "REBASE_HEAD"] do
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
    state = %{state | debounce_ref: nil}
    state = do_refresh(state)
    {:noreply, state}
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
    stop_git_watcher(state)
    :ok
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec do_refresh(t()) :: t()
  defp do_refresh(state) do
    old_entries = state.entries
    old_branch = state.branch
    old_ahead = state.ahead
    old_behind = state.behind

    entries = fetch_status(state.git_root, state.project_root)
    branch = fetch_branch(state.git_root)
    {ahead, behind} = fetch_ahead_behind(state.git_root)

    state = %{state | entries: entries, branch: branch, ahead: ahead, behind: behind}

    # Broadcast only if something changed
    changed =
      entries != old_entries or branch != old_branch or
        ahead != old_ahead or behind != old_behind

    if changed do
      Minga.Events.broadcast(
        :git_status_changed,
        %Minga.Events.GitStatusEvent{
          git_root: state.git_root,
          entries: entries,
          branch: branch,
          ahead: ahead,
          behind: behind
        }
      )
    end

    state
  end

  @spec fetch_status(String.t(), String.t() | nil) :: [StatusEntry.t()]
  defp fetch_status(git_root, project_root) do
    case Git.status(git_root) do
      {:ok, entries} ->
        maybe_relativize_paths(entries, git_root, project_root)

      {:error, reason} ->
        Minga.Log.warning(:editor, "[Git.Repo] status failed: #{reason}")
        []
    end
  end

  @spec fetch_branch(String.t()) :: String.t() | nil
  defp fetch_branch(git_root) do
    case Git.current_branch(git_root) do
      {:ok, branch} -> branch
      :error -> nil
    end
  end

  @spec fetch_ahead_behind(String.t()) :: {non_neg_integer(), non_neg_integer()}
  defp fetch_ahead_behind(git_root) do
    case Git.ahead_behind(git_root) do
      {:ok, ahead, behind} -> {ahead, behind}
      :error -> {0, 0}
    end
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
      conflict_count: counts.conflict
    }
  end

  @spec start_git_watcher(t()) :: t()
  defp start_git_watcher(state) do
    git_dir = Path.join(state.git_root, ".git")

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

  @spec stop_git_watcher(t()) :: :ok
  defp stop_git_watcher(%{watcher_pid: nil}), do: :ok

  defp stop_git_watcher(%{watcher_pid: pid}) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
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
