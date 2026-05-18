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
  files that are actually open in the editor. A reference-counted directory
  map tracks how many open files live in each directory; when the last file
  in a directory is closed, that directory is unwatched.

  Events are debounced per-path with a configurable window (default 100ms)
  to coalesce rapid writes (e.g., `git checkout` touching many files).
  """

  use GenServer

  @enforce_keys [:subscriber, :debounce_ms]
  defstruct subscriber: nil,
            debounce_ms: nil,
            watcher: nil,
            watched_dirs: %{},
            watched_files: MapSet.new(),
            watched_project_dirs: MapSet.new(),
            pending: %{},
            events_registry: Minga.Events.default_registry()

  @typep state :: %__MODULE__{
           subscriber: pid() | nil,
           watcher: pid() | nil,
           watched_dirs: %{String.t() => pos_integer()},
           watched_files: MapSet.t(String.t()),
           watched_project_dirs: MapSet.t(String.t()),
           pending: %{String.t() => reference()},
           debounce_ms: pos_integer(),
           events_registry: Minga.Events.registry()
         }

  @default_debounce_ms 100

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
    GenServer.call(server, {:watch_path, Path.expand(path)})
  end

  @doc "Registers a directory so child create, delete, rename, and modify events refresh project surfaces."
  @spec watch_directory(GenServer.server(), String.t()) :: :ok
  def watch_directory(server \\ __MODULE__, path) when is_binary(path) do
    GenServer.call(server, {:watch_directory, Path.expand(path)})
  end

  @doc "Unregisters a file path. Stops watching the directory when no files remain in it."
  @spec unwatch_path(GenServer.server(), String.t()) :: :ok
  def unwatch_path(server \\ __MODULE__, path) when is_binary(path) do
    GenServer.call(server, {:unwatch_path, Path.expand(path)})
  end

  @doc "Unregisters a watched directory."
  @spec unwatch_directory(GenServer.server(), String.t()) :: :ok
  def unwatch_directory(server \\ __MODULE__, path) when is_binary(path) do
    GenServer.call(server, {:unwatch_directory, Path.expand(path)})
  end

  @doc "Unregisters all watched project directories under a root."
  @spec unwatch_directory_tree(GenServer.server(), String.t()) :: :ok
  def unwatch_directory_tree(server \\ __MODULE__, root) when is_binary(root) do
    GenServer.call(server, {:unwatch_directory_tree, Path.expand(root)})
  end

  @doc "Sets the subscriber process that receives `{:file_changed_on_disk, path}` messages."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server \\ __MODULE__, pid) when is_pid(pid) do
    GenServer.call(server, {:subscribe, pid})
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

    # Subscribe to buffer-open events so we automatically watch new files.
    # Opt-out via subscribe_events: false (used by tests to avoid global
    # event bus noise from concurrent tests flooding the watcher mailbox).
    if Keyword.get(opts, :subscribe_events, true) do
      Minga.Events.subscribe(:buffer_opened, events_registry)
    end

    state = %__MODULE__{
      subscriber: subscriber,
      debounce_ms: debounce_ms,
      events_registry: events_registry
    }

    {:ok, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, :ok, state()}
  def handle_call({:subscribe, pid}, _from, %__MODULE__{} = state) do
    Process.monitor(pid)
    {:reply, :ok, %__MODULE__{state | subscriber: pid}}
  end

  def handle_call({:watch_path, path}, _from, %__MODULE__{} = state) do
    {:reply, :ok, do_watch_path(state, path)}
  end

  def handle_call({:watch_directory, path}, _from, %__MODULE__{} = state) do
    {:reply, :ok, do_watch_directory(state, path)}
  end

  def handle_call({:unwatch_path, path}, _from, %__MODULE__{} = state) do
    dir = Path.dirname(path)
    new_dirs = decrement_watched_dir(state.watched_dirs, dir)
    new_files = MapSet.delete(state.watched_files, path)
    new_watcher = reconcile_watcher(state.watcher, state.watched_dirs, new_dirs)

    {:reply, :ok,
     %__MODULE__{state | watched_dirs: new_dirs, watched_files: new_files, watcher: new_watcher}}
  end

  def handle_call({:unwatch_directory, path}, _from, %__MODULE__{} = state) do
    {:reply, :ok, unwatch_project_dirs(state, [Path.expand(path)])}
  end

  def handle_call({:unwatch_directory_tree, root}, _from, %__MODULE__{} = state) do
    root = Path.expand(root)
    dirs = Enum.filter(state.watched_project_dirs, &path_under_root?(&1, root))
    {:reply, :ok, unwatch_project_dirs(state, dirs)}
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

    if watched_path_event?(state, path) do
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
    new_pending = Map.delete(state.pending, path)
    notify_subscriber(state.subscriber, path)
    {:noreply, %__MODULE__{state | pending: new_pending}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{subscriber: pid} = state) do
    {:noreply, %__MODULE__{state | subscriber: nil}}
  end

  def handle_info(
        {:minga_event, :buffer_opened, %Minga.Events.BufferEvent{path: path}},
        %__MODULE__{} = state
      ) do
    {:noreply, do_watch_path(state, Path.expand(path))}
  end

  def handle_info(_msg, %__MODULE__{} = state) do
    {:noreply, state}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec do_watch_path(state(), String.t()) :: state()
  defp do_watch_path(%__MODULE__{} = state, path) do
    dir = Path.dirname(path)
    new_dirs = Map.update(state.watched_dirs, dir, 1, &(&1 + 1))
    new_files = MapSet.put(state.watched_files, path)
    new_watcher = ensure_watcher(state.watcher, new_dirs)
    %__MODULE__{state | watched_dirs: new_dirs, watched_files: new_files, watcher: new_watcher}
  end

  @spec do_watch_directory(state(), String.t()) :: state()
  defp do_watch_directory(%__MODULE__{} = state, path) do
    dir = Path.expand(path)

    if MapSet.member?(state.watched_project_dirs, dir) do
      state
    else
      new_dirs = Map.update(state.watched_dirs, dir, 1, &(&1 + 1))
      new_project_dirs = MapSet.put(state.watched_project_dirs, dir)
      new_watcher = ensure_watcher(state.watcher, new_dirs)

      %__MODULE__{
        state
        | watched_dirs: new_dirs,
          watched_project_dirs: new_project_dirs,
          watcher: new_watcher
      }
    end
  end

  @spec unwatch_project_dirs(state(), [String.t()]) :: state()
  defp unwatch_project_dirs(%__MODULE__{} = state, dirs) when is_list(dirs) do
    dirs_to_remove = Enum.filter(dirs, &MapSet.member?(state.watched_project_dirs, &1))

    if dirs_to_remove == [] do
      state
    else
      new_dirs = Enum.reduce(dirs_to_remove, state.watched_dirs, &decrement_watched_dir(&2, &1))

      new_project_dirs =
        Enum.reduce(dirs_to_remove, state.watched_project_dirs, &MapSet.delete(&2, &1))

      new_watcher = reconcile_watcher(state.watcher, state.watched_dirs, new_dirs)

      %__MODULE__{
        state
        | watched_dirs: new_dirs,
          watched_project_dirs: new_project_dirs,
          watcher: new_watcher
      }
    end
  end

  @spec decrement_watched_dir(%{String.t() => pos_integer()}, String.t()) :: %{
          String.t() => pos_integer()
        }
  defp decrement_watched_dir(watched_dirs, dir) do
    case Map.get(watched_dirs, dir) do
      nil -> watched_dirs
      1 -> Map.delete(watched_dirs, dir)
      n -> Map.put(watched_dirs, dir, n - 1)
    end
  end

  @spec watched_path_event?(state(), String.t()) :: boolean()
  defp watched_path_event?(%__MODULE__{} = state, path) do
    MapSet.member?(state.watched_files, path) or
      watched_project_child?(state.watched_project_dirs, path)
  end

  @spec watched_project_child?(MapSet.t(String.t()), String.t()) :: boolean()
  defp watched_project_child?(watched_project_dirs, path) do
    Enum.any?(watched_project_dirs, fn dir -> path_under_root?(path, dir) end)
  end

  @spec path_under_root?(String.t(), String.t()) :: boolean()
  defp path_under_root?(path, root) do
    path == root or String.starts_with?(path, path_prefix(root))
  end

  @spec path_prefix(String.t()) :: String.t()
  defp path_prefix("/"), do: "/"
  defp path_prefix(root), do: root <> "/"

  @spec reconcile_watcher(pid() | nil, %{String.t() => pos_integer()}, %{
          String.t() => pos_integer()
        }) ::
          pid() | nil
  defp reconcile_watcher(existing_watcher, old_dirs, new_dirs) do
    if MapSet.new(Map.keys(old_dirs)) == MapSet.new(Map.keys(new_dirs)) do
      existing_watcher
    else
      ensure_watcher(existing_watcher, new_dirs)
    end
  end

  @spec ensure_watcher(pid() | nil, %{String.t() => pos_integer()}) :: pid() | nil
  defp ensure_watcher(existing_watcher, dirs) when map_size(dirs) == 0 do
    if existing_watcher do
      try do
        GenServer.stop(existing_watcher)
      catch
        :exit, _ -> :ok
      end
    end

    nil
  end

  defp ensure_watcher(existing_watcher, dirs) do
    stop_watcher(existing_watcher)

    dir_list = dirs |> Map.keys() |> Enum.filter(&File.dir?/1)

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
    Enum.each(state.watched_files, fn path ->
      notify_subscriber(state.subscriber, path)
    end)
  end

  @spec notify_all_watched_project_dirs(state()) :: :ok
  defp notify_all_watched_project_dirs(%__MODULE__{} = state) do
    Enum.each(state.watched_project_dirs, fn path ->
      notify_subscriber(state.subscriber, path)
    end)
  end
end
