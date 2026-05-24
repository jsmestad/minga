defmodule Minga.Extension.DevReload do
  @moduledoc """
  Watches local extension source directories and hot-reloads on change.

  When configured, starts a file system watcher for each extension that
  uses a `path:` source. On file change (debounced), recompiles the
  extension's modules and restarts the extension process.

  Only active when `config :minga, extension_dev_reload: true` (or not
  explicitly set to false). Ignored for git and hex extensions.
  """

  use GenServer

  @debounce_ms 200

  @type state :: %{
          watchers: %{String.t() => pid()},
          watcher_monitors: %{reference() => String.t()},
          extensions: %{String.t() => atom()},
          pending_timer: reference() | nil,
          pending_paths: MapSet.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a local extension path for file watching."
  @spec watch(atom(), String.t()) :: :ok
  def watch(extension_name, source_path)
      when is_atom(extension_name) and is_binary(source_path) do
    GenServer.cast(__MODULE__, {:watch, extension_name, source_path})
  end

  @doc "Unregisters an extension from file watching."
  @spec unwatch(atom()) :: :ok
  def unwatch(extension_name) when is_atom(extension_name) do
    GenServer.cast(__MODULE__, {:unwatch, extension_name})
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    {:ok,
     %{
       watchers: %{},
       watcher_monitors: %{},
       extensions: %{},
       pending_timer: nil,
       pending_paths: MapSet.new()
     }}
  end

  @impl true
  def handle_cast({:watch, extension_name, source_path}, state) do
    lib_path = Path.expand(Path.join(source_path, "lib"))

    if File.dir?(lib_path) do
      state = start_watcher_for_path(state, lib_path)
      extensions = Map.put(state.extensions, lib_path, extension_name)
      {:noreply, %{state | extensions: extensions}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:unwatch, extension_name}, state) do
    orphaned_paths =
      state.extensions
      |> Enum.filter(fn {_path, name} -> name == extension_name end)
      |> Enum.map(fn {path, _name} -> path end)

    extensions =
      state.extensions
      |> Enum.reject(fn {_path, name} -> name == extension_name end)
      |> Map.new()

    state = %{state | extensions: extensions}
    state = cleanup_orphaned_watchers(state, orphaned_paths)

    {:noreply, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    if String.ends_with?(path, ".ex") do
      pending = MapSet.put(state.pending_paths, path)

      timer =
        if state.pending_timer do
          Process.cancel_timer(state.pending_timer)
        end

      _ = timer
      new_timer = Process.send_after(self(), :debounced_reload, @debounce_ms)

      {:noreply, %{state | pending_paths: pending, pending_timer: new_timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Minga.Log.warning(:config, "Dev reload: file watcher stopped")
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.watcher_monitors, ref) do
      {lib_path, monitors} when is_binary(lib_path) ->
        Minga.Log.warning(:config, "Dev reload: watcher for #{lib_path} crashed, restarting")
        watchers = Map.delete(state.watchers, lib_path)
        state = %{state | watchers: watchers, watcher_monitors: monitors}
        state = start_watcher_for_path(state, lib_path)
        {:noreply, state}

      {nil, _monitors} ->
        {:noreply, state}
    end
  end

  def handle_info(:debounced_reload, state) do
    extensions_to_reload =
      state.pending_paths
      |> Enum.flat_map(fn path ->
        state.extensions
        |> Enum.filter(fn {lib_path, _name} -> String.starts_with?(path, lib_path) end)
        |> Enum.map(fn {_lib_path, name} -> name end)
      end)
      |> Enum.uniq()

    for ext_name <- extensions_to_reload do
      reload_extension(ext_name)
    end

    {:noreply, %{state | pending_paths: MapSet.new(), pending_timer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec reload_extension(atom()) :: :ok
  defp reload_extension(ext_name) do
    case Minga.Extension.Registry.get(Minga.Extension.Registry, ext_name) do
      {:ok, %{path: path, status: :running}} when is_binary(path) ->
        Minga.Log.info(:config, "Dev reload: recompiling #{ext_name}")

        case recompile_extension(path) do
          :ok ->
            restart_result = restart_extension(ext_name)

            broadcast_reload_result(ext_name, restart_result)

          {:error, reason} ->
            Minga.Events.broadcast(
              :log_message,
              %Minga.Events.LogMessageEvent{
                text: "Extension #{ext_name} reload failed: #{inspect(reason)}",
                level: :error
              }
            )
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Minga.Log.error(:config, "Dev reload error for #{ext_name}: #{Exception.message(e)}")
  end

  @spec restart_extension(atom()) :: :ok | {:error, term()}
  defp restart_extension(ext_name) do
    case Minga.Extension.Registry.get(Minga.Extension.Registry, ext_name) do
      {:ok, fresh_entry} ->
        case Minga.Extension.Supervisor.stop_extension(
               Minga.Extension.Supervisor,
               Minga.Extension.Registry,
               ext_name,
               fresh_entry
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            Minga.Log.warning(
              :config,
              "Dev reload: stop failed for #{ext_name}: #{inspect(reason)}"
            )
        end

        case Minga.Extension.Registry.get(Minga.Extension.Registry, ext_name) do
          {:ok, stopped_entry} ->
            case Minga.Extension.Supervisor.start_extension(
                   Minga.Extension.Supervisor,
                   Minga.Extension.Registry,
                   ext_name,
                   stopped_entry
                 ) do
              {:ok, _pid} -> :ok
              {:error, reason} -> {:error, reason}
            end

          :error ->
            {:error, :not_found_after_stop}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @spec broadcast_reload_result(atom(), :ok | {:error, term()}) :: :ok
  defp broadcast_reload_result(ext_name, :ok) do
    Minga.Events.broadcast(
      :log_message,
      %Minga.Events.LogMessageEvent{text: "Extension #{ext_name} reloaded", level: :info}
    )
  end

  defp broadcast_reload_result(ext_name, {:error, reason}) do
    Minga.Events.broadcast(
      :log_message,
      %Minga.Events.LogMessageEvent{
        text: "Extension #{ext_name} restart failed: #{inspect(reason)}",
        level: :error
      }
    )
  end

  @spec recompile_extension(String.t()) :: :ok | {:error, term()}
  defp recompile_extension(path) do
    lib_path = Path.join(path, "lib")
    ex_files = Path.wildcard(Path.join(lib_path, "**/*.ex"))

    if ex_files == [] do
      {:error, :no_source_files}
    else
      case Kernel.ParallelCompiler.compile(ex_files) do
        {:ok, _modules, _warnings} -> :ok
        {:error, errors, _warnings} -> {:error, errors}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec start_watcher_for_path(state(), String.t()) :: state()
  defp start_watcher_for_path(state, lib_path) do
    if Map.has_key?(state.watchers, lib_path) do
      state
    else
      case FileSystem.start_link(dirs: [lib_path]) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          ref = Process.monitor(pid)

          %{
            state
            | watchers: Map.put(state.watchers, lib_path, pid),
              watcher_monitors: Map.put(state.watcher_monitors, ref, lib_path)
          }

        _ ->
          state
      end
    end
  end

  @spec cleanup_orphaned_watchers(state(), [String.t()]) :: state()
  defp cleanup_orphaned_watchers(state, paths) do
    Enum.reduce(paths, state, fn path, acc ->
      if Map.has_key?(acc.extensions, path) do
        acc
      else
        case Map.pop(acc.watchers, path) do
          {pid, watchers} when is_pid(pid) ->
            GenServer.stop(pid, :normal, 1_000)

            {ref, monitors} =
              Enum.find(acc.watcher_monitors, fn {_ref, p} -> p == path end)
              |> case do
                {ref, _} -> {ref, Map.delete(acc.watcher_monitors, ref)}
                nil -> {nil, acc.watcher_monitors}
              end

            if ref, do: Process.demonitor(ref, [:flush])
            %{acc | watchers: watchers, watcher_monitors: monitors}

          {nil, _watchers} ->
            acc
        end
      end
    end)
  end
end
