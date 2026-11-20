defmodule Minga.FileWatcher do
  @moduledoc """
  Watches parent directories of open files for external changes.

  Uses the `file_system` library (FSEvents on macOS, inotify on Linux) to
  detect when files are modified by other programs. Events are debounced
  and forwarded to a subscriber (typically the Editor GenServer) as
  `{:file_changed_on_disk, path}` messages.

  ## Design

  Rather than watching the entire project root (which would include `.git`,
  `_build`, `node_modules`, etc.), we watch only the parent directories of
  files that are actually open in the editor and the directories registered
  for project surfaces. Native watcher directories are derived from those
  registrations, but event coverage also distinguishes explicit files from
  project subtrees. Repeating the same registration is idempotent.

  Events are debounced per-path with a configurable window (default 100ms)
  to coalesce rapid writes (e.g., `git checkout` touching many files).
  """

  use GenServer

  alias Minga.FileWatcher.Intent

  @enforce_keys [:subscriber, :debounce_ms]
  defstruct subscriber: nil,
            subscriber_monitor: nil,
            debounce_ms: nil,
            watcher: nil,
            watched_dirs: MapSet.new(),
            intent: %Intent{},
            pending: %{},
            events_registry: Minga.Events.default_registry()

  @typep state :: %__MODULE__{
           subscriber: pid() | nil,
           subscriber_monitor: reference() | nil,
           watcher: pid() | nil,
           watched_dirs: MapSet.t(String.t()),
           intent: Intent.t(),
           pending: %{String.t() => reference()},
           debounce_ms: pos_integer(),
           events_registry: Minga.Events.registry()
         }

  @default_debounce_ms 100
  @call_timeout_ms 15_000

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the file watcher."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Registers a file path to watch for external changes."
  @spec watch_path(GenServer.server(), String.t()) :: :ok
  def watch_path(server \\ __MODULE__, path) when is_binary(path) do
    GenServer.call(server, {:watch_path, Path.expand(path)}, @call_timeout_ms)
  end

  @doc "Registers a directory so child create, delete, rename, and modify events refresh project surfaces."
  @spec watch_directory(GenServer.server(), String.t()) :: :ok
  def watch_directory(server \\ __MODULE__, path) when is_binary(path) do
    GenServer.call(server, {:watch_directory, Path.expand(path)}, @call_timeout_ms)
  end

  @doc "Unregisters a file path. Stops watching the parent directory if nothing else needs it."
  @spec unwatch_path(GenServer.server(), String.t()) :: :ok
  def unwatch_path(server \\ __MODULE__, path) when is_binary(path) do
    GenServer.call(server, {:unwatch_path, Path.expand(path)}, @call_timeout_ms)
  end

  @doc "Unregisters a watched directory."
  @spec unwatch_directory(GenServer.server(), String.t()) :: :ok
  def unwatch_directory(server \\ __MODULE__, path) when is_binary(path) do
    GenServer.call(server, {:unwatch_directory, Path.expand(path)}, @call_timeout_ms)
  end

  @doc "Unregisters all watched project directories under a root."
  @spec unwatch_directory_tree(GenServer.server(), String.t()) :: :ok
  def unwatch_directory_tree(server \\ __MODULE__, root) when is_binary(root) do
    GenServer.call(server, {:unwatch_directory_tree, Path.expand(root)}, @call_timeout_ms)
  end

  @doc "Sets the subscriber process that receives `{:file_changed_on_disk, path}` messages."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server \\ __MODULE__, pid) when is_pid(pid) do
    GenServer.call(server, {:subscribe, pid}, @call_timeout_ms)
  end

  @doc "Atomically restores the subscriber and complete declarative watch intent."
  @spec restore_authority(GenServer.server(), pid(), [String.t()], [String.t()]) :: :ok
  def restore_authority(
        server \\ __MODULE__,
        subscriber,
        watched_files,
        watched_project_dirs
      )
      when is_pid(subscriber) and is_list(watched_files) and is_list(watched_project_dirs) do
    GenServer.call(
      server,
      {:restore_authority, subscriber, expand_paths(watched_files),
       expand_paths(watched_project_dirs)},
      @call_timeout_ms
    )
  end

  @doc "Checks all watched files for mtime changes and notifies the subscriber."
  @spec check_all(GenServer.server()) :: :ok
  def check_all(server \\ __MODULE__) do
    GenServer.cast(server, :check_all)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)
    subscriber = Keyword.get(opts, :subscriber)
    events_registry = Keyword.get(opts, :events_registry, Minga.Events.default_registry())

    state = %__MODULE__{
      subscriber: nil,
      debounce_ms: debounce_ms,
      events_registry: events_registry
    }

    state = maybe_monitor_subscriber(state, subscriber)

    Minga.Events.broadcast(
      :file_watcher_ready,
      %Minga.FileWatcher.ReadyEvent{watcher: self()},
      events_registry
    )

    {:ok, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, :ok, state()}
  def handle_call({:subscribe, pid}, _from, %__MODULE__{} = state) do
    {:reply, :ok, monitor_subscriber(state, pid)}
  end

  def handle_call(
        {:restore_authority, subscriber, watched_files, watched_project_dirs},
        _from,
        %__MODULE__{} = state
      ) do
    state = monitor_subscriber(state, subscriber)
    intent = Intent.new(watched_files, watched_project_dirs)
    {:reply, :ok, reconcile_watch_intent(state, intent)}
  end

  def handle_call({:watch_path, path}, _from, %__MODULE__{} = state) do
    {:reply, :ok, reconcile_watch_intent(state, Intent.watch_path(state.intent, path))}
  end

  def handle_call({:watch_directory, path}, _from, %__MODULE__{} = state) do
    {:reply, :ok, reconcile_watch_intent(state, Intent.watch_directory(state.intent, path))}
  end

  def handle_call({:unwatch_path, path}, _from, %__MODULE__{} = state) do
    {:reply, :ok, reconcile_watch_intent(state, Intent.unwatch_path(state.intent, path))}
  end

  def handle_call({:unwatch_directory, path}, _from, %__MODULE__{} = state) do
    {:reply, :ok, reconcile_watch_intent(state, Intent.unwatch_directory(state.intent, path))}
  end

  def handle_call({:unwatch_directory_tree, root}, _from, %__MODULE__{} = state) do
    intent = Intent.unwatch_directory_tree(state.intent, root)
    {:reply, :ok, reconcile_watch_intent(state, intent)}
  end

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast(:check_all, %__MODULE__{} = state) do
    notify_all_watched(state)
    notify_all_watched_project_dirs(state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:file_event, _watcher_pid, {path, _events}}, %__MODULE__{} = state) do
    path = Path.expand(to_string(path))

    if Intent.covers?(state.intent, path) do
      {:noreply, schedule_debounce(state, path)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, %__MODULE__{} = state) do
    Minga.Log.warning(:editor, "File watcher stopped unexpectedly")
    {:noreply, %__MODULE__{state | watcher: nil}}
  end

  def handle_info({:debounce_fire, path}, %__MODULE__{} = state) do
    case Map.pop(state.pending, path) do
      {nil, _pending} ->
        {:noreply, state}

      {_ref, pending} ->
        notify_subscriber(state.subscriber, path)
        {:noreply, %__MODULE__{state | pending: pending}}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %__MODULE__{subscriber: pid, subscriber_monitor: ref} = state
      ) do
    {:noreply, %__MODULE__{state | subscriber: nil, subscriber_monitor: nil}}
  end

  def handle_info(_msg, %__MODULE__{} = state) do
    {:noreply, state}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec reconcile_watch_intent(state(), Intent.t()) :: state()
  defp reconcile_watch_intent(%__MODULE__{} = state, intent) do
    watched_dirs = Intent.native_dirs(intent)
    watcher = reconcile_watcher(state.watcher, state.watched_dirs, watched_dirs)
    pending = retain_watched_pending(state.pending, intent)

    %__MODULE__{
      state
      | watched_dirs: watched_dirs,
        intent: intent,
        watcher: watcher,
        pending: pending
    }
  end

  @spec reconcile_watcher(pid() | nil, MapSet.t(String.t()), MapSet.t(String.t())) :: pid() | nil
  defp reconcile_watcher(existing_watcher, old_dirs, new_dirs) do
    if old_dirs == new_dirs do
      existing_watcher
    else
      ensure_watcher(existing_watcher, new_dirs)
    end
  end

  @spec ensure_watcher(pid() | nil, MapSet.t(String.t())) :: pid() | nil
  defp ensure_watcher(existing_watcher, dirs) do
    ensure_watcher_for_dirs(existing_watcher, MapSet.to_list(dirs))
  end

  @spec ensure_watcher_for_dirs(pid() | nil, [String.t()]) :: pid() | nil
  defp ensure_watcher_for_dirs(existing_watcher, []) do
    if existing_watcher do
      try do
        GenServer.stop(existing_watcher)
      catch
        :exit, _ -> :ok
      end
    end

    nil
  end

  defp ensure_watcher_for_dirs(existing_watcher, dirs) do
    stop_watcher(existing_watcher)

    dir_list = Enum.filter(dirs, &File.dir?/1)

    if dir_list == [] do
      nil
    else
      start_watcher(dir_list)
    end
  end

  @spec stop_watcher(pid() | nil) :: :ok
  defp stop_watcher(nil), do: :ok

  defp stop_watcher(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  @spec start_watcher([String.t()]) :: pid() | nil
  defp start_watcher(dir_list) do
    case FileSystem.start_link(dirs: dir_list) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        pid

      :ignore ->
        Minga.Log.warning(:editor, "File watcher not supported on this platform")
        nil

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to start file watcher: #{inspect(reason)}")
        nil
    end
  end

  @spec maybe_monitor_subscriber(state(), pid() | nil) :: state()
  defp maybe_monitor_subscriber(%__MODULE__{} = state, nil), do: state
  defp maybe_monitor_subscriber(%__MODULE__{} = state, pid), do: monitor_subscriber(state, pid)

  @spec monitor_subscriber(state(), pid()) :: state()
  defp monitor_subscriber(
         %__MODULE__{subscriber: pid, subscriber_monitor: ref} = state,
         pid
       )
       when is_reference(ref),
       do: state

  defp monitor_subscriber(%__MODULE__{} = state, pid) do
    demonitor_subscriber(state.subscriber_monitor)
    %__MODULE__{state | subscriber: pid, subscriber_monitor: Process.monitor(pid)}
  end

  @spec demonitor_subscriber(reference() | nil) :: :ok
  defp demonitor_subscriber(nil), do: :ok

  defp demonitor_subscriber(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  @spec retain_watched_pending(%{String.t() => reference()}, Intent.t()) ::
          %{String.t() => reference()}
  defp retain_watched_pending(pending, intent) do
    Enum.reduce(pending, pending, fn {path, ref}, kept ->
      if Intent.covers?(intent, path) do
        kept
      else
        Process.cancel_timer(ref)
        Map.delete(kept, path)
      end
    end)
  end

  @spec expand_paths([String.t()]) :: [String.t()]
  defp expand_paths(paths), do: Enum.map(paths, &Path.expand/1)

  @spec schedule_debounce(state(), String.t()) :: state()
  defp schedule_debounce(%__MODULE__{} = state, path) do
    # Cancel existing timer for this path if any
    case Map.get(state.pending, path) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    ref = Process.send_after(self(), {:debounce_fire, path}, state.debounce_ms)
    %__MODULE__{state | pending: Map.put(state.pending, path, ref)}
  end

  @spec notify_subscriber(pid() | nil, String.t()) :: :ok
  defp notify_subscriber(nil, _path), do: :ok

  defp notify_subscriber(pid, path) do
    send(pid, {:file_changed_on_disk, path})

    Minga.Events.broadcast(:file_written, %Minga.Events.FileWrittenEvent{
      path: path,
      change_type: :changed
    })

    :ok
  end

  @spec notify_all_watched(state()) :: :ok
  defp notify_all_watched(%__MODULE__{} = state) do
    Enum.each(state.intent.files, fn path ->
      notify_subscriber(state.subscriber, path)
    end)
  end

  @spec notify_all_watched_project_dirs(state()) :: :ok
  defp notify_all_watched_project_dirs(%__MODULE__{} = state) do
    Enum.each(state.intent.project_dirs, fn path ->
      notify_subscriber(state.subscriber, path)
    end)
  end
end
