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

  require Logger

  @typep state :: %{
           subscriber: pid() | nil,
           watcher: pid() | nil,
           watched_dirs: %{String.t() => pos_integer()},
           watched_files: MapSet.t(String.t()),
           pending: %{String.t() => reference()},
           debounce_ms: pos_integer()
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

  @doc "Unregisters a file path. Stops watching the directory when no files remain in it."
  @spec unwatch_path(GenServer.server(), String.t()) :: :ok
  def unwatch_path(server \\ __MODULE__, path) when is_binary(path) do
    GenServer.call(server, {:unwatch_path, Path.expand(path)})
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

    state = %{
      subscriber: subscriber,
      watcher: nil,
      watched_dirs: %{},
      watched_files: MapSet.new(),
      pending: %{},
      debounce_ms: debounce_ms
    }

    {:ok, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, :ok, state()}
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscriber: pid}}
  end

  def handle_call({:watch_path, path}, _from, state) do
    dir = Path.dirname(path)

    new_dirs =
      Map.update(state.watched_dirs, dir, 1, &(&1 + 1))

    new_files = MapSet.put(state.watched_files, path)

    new_watcher = ensure_watcher(state.watcher, new_dirs)

    {:reply, :ok,
     %{state | watched_dirs: new_dirs, watched_files: new_files, watcher: new_watcher}}
  end

  def handle_call({:unwatch_path, path}, _from, state) do
    dir = Path.dirname(path)

    new_dirs =
      case Map.get(state.watched_dirs, dir) do
        nil -> state.watched_dirs
        1 -> Map.delete(state.watched_dirs, dir)
        n -> Map.put(state.watched_dirs, dir, n - 1)
      end

    new_files = MapSet.delete(state.watched_files, path)

    {:reply, :ok, %{state | watched_dirs: new_dirs, watched_files: new_files}}
  end

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast(:check_all, state) do
    notify_all_watched(state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    path = to_string(path)

    if MapSet.member?(state.watched_files, path) do
      {:noreply, schedule_debounce(state, path)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("File watcher stopped unexpectedly")
    {:noreply, %{state | watcher: nil}}
  end

  def handle_info({:debounce_fire, path}, state) do
    new_pending = Map.delete(state.pending, path)
    notify_subscriber(state.subscriber, path)
    {:noreply, %{state | pending: new_pending}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscriber: pid} = state) do
    {:noreply, %{state | subscriber: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec ensure_watcher(pid() | nil, %{String.t() => pos_integer()}) :: pid() | nil
  defp ensure_watcher(existing_watcher, dirs) when map_size(dirs) == 0 do
    if existing_watcher && Process.alive?(existing_watcher) do
      GenServer.stop(existing_watcher)
    end

    nil
  end

  defp ensure_watcher(existing_watcher, dirs) do
    if existing_watcher && Process.alive?(existing_watcher) do
      # Restart watcher with updated directory list
      GenServer.stop(existing_watcher)
    end

    dir_list = Map.keys(dirs)

    case FileSystem.start_link(dirs: dir_list) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        pid

      :ignore ->
        Logger.warning("File watcher not supported on this platform")
        nil

      {:error, reason} ->
        Logger.error("Failed to start file watcher: #{inspect(reason)}")
        nil
    end
  end

  @spec schedule_debounce(state(), String.t()) :: state()
  defp schedule_debounce(state, path) do
    # Cancel existing timer for this path if any
    case Map.get(state.pending, path) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    ref = Process.send_after(self(), {:debounce_fire, path}, state.debounce_ms)
    %{state | pending: Map.put(state.pending, path, ref)}
  end

  @spec notify_subscriber(pid() | nil, String.t()) :: :ok
  defp notify_subscriber(nil, _path), do: :ok

  defp notify_subscriber(pid, path) do
    send(pid, {:file_changed_on_disk, path})
    :ok
  end

  @spec notify_all_watched(state()) :: :ok
  defp notify_all_watched(state) do
    Enum.each(state.watched_files, fn path ->
      notify_subscriber(state.subscriber, path)
    end)
  end
end
