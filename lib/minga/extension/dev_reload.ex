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
          watcher: pid() | nil,
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
    {:ok, %{watcher: nil, extensions: %{}, pending_timer: nil, pending_paths: MapSet.new()}}
  end

  @impl true
  def handle_cast({:watch, extension_name, source_path}, state) do
    lib_path = Path.join(source_path, "lib")

    if File.dir?(lib_path) do
      state = ensure_watcher(state, lib_path)
      extensions = Map.put(state.extensions, Path.expand(lib_path), extension_name)
      {:noreply, %{state | extensions: extensions}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:unwatch, extension_name}, state) do
    extensions =
      state.extensions
      |> Enum.reject(fn {_path, name} -> name == extension_name end)
      |> Map.new()

    {:noreply, %{state | extensions: extensions}}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    if String.ends_with?(path, ".ex") do
      pending = MapSet.put(state.pending_paths, path)

      timer =
        if state.pending_timer do
          Process.cancel_timer(state.pending_timer)
          Process.send_after(self(), :debounced_reload, @debounce_ms)
        else
          Process.send_after(self(), :debounced_reload, @debounce_ms)
        end

      {:noreply, %{state | pending_paths: pending, pending_timer: timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    {:noreply, %{state | watcher: nil}}
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
      {:ok, %{path: path, status: :running} = entry} when is_binary(path) ->
        Minga.Log.info(:config, "Dev reload: recompiling #{ext_name}")

        case recompile_extension(path) do
          :ok ->
            Minga.Extension.Supervisor.stop_extension(
              Minga.Extension.Supervisor,
              Minga.Extension.Registry,
              ext_name,
              entry
            )

            Minga.Extension.Supervisor.start_extension(
              Minga.Extension.Supervisor,
              Minga.Extension.Registry,
              ext_name,
              entry
            )

            Minga.Events.broadcast(
              :log_message,
              %Minga.Events.LogMessageEvent{
                text: "Extension #{ext_name} reloaded",
                level: :info
              }
            )

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

  @spec recompile_extension(String.t()) :: :ok | {:error, term()}
  defp recompile_extension(path) do
    lib_path = Path.join(path, "lib")

    ex_files =
      Path.wildcard(Path.join(lib_path, "**/*.ex"))

    if ex_files == [] do
      {:error, :no_source_files}
    else
      Enum.each(ex_files, fn file ->
        Code.compile_file(file)
      end)

      :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec ensure_watcher(state(), String.t()) :: state()
  defp ensure_watcher(%{watcher: nil} = state, path) do
    case FileSystem.start_link(dirs: [path]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        %{state | watcher: pid}

      _ ->
        state
    end
  end

  defp ensure_watcher(state, _path), do: state
end
