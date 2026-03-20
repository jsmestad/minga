defmodule Minga.LSP.SyncServer do
  @moduledoc """
  Manages LSP document synchronization by subscribing to the event bus.

  Owns the mapping of buffer pids to LSP client pids and handles the
  LSP document lifecycle protocol (didOpen, didChange, didSave, didClose)
  independently of the Editor GenServer.

  Maintains an ETS table (`Minga.LSP.SyncServer.Registry`) mapping
  buffer pids to their attached LSP client pids. Consumers like
  `CompletionTrigger`, `LspActions`, and `BufferLifecycle` look up
  clients via `clients_for_buffer/1` (direct ETS read, no GenServer
  call needed).

  ## Event subscriptions

  | Event              | Action                                           |
  |--------------------|--------------------------------------------------|
  | `:buffer_opened`   | Detect filetype, start LSP clients, send didOpen  |
  | `:buffer_saved`    | Send didSave to attached clients                   |
  | `:buffer_closed`   | Send didClose, remove tracking                     |
  | `:buffer_changed`  | Debounce and send didChange to attached clients    |
  """

  use GenServer

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Events
  alias Minga.LSP.Client
  alias Minga.LSP.RootDetector
  alias Minga.LSP.ServerRegistry
  alias Minga.LSP.Supervisor, as: LSPSupervisor

  @registry_table __MODULE__.Registry
  @debounce_ms 150

  @typedoc "Internal state."
  @type state :: %{
          debounce_timers: %{pid() => reference()}
        }

  # ── Client API ─────────────────────────────────────────────────────────

  @doc "Starts the LSP sync server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the LSP client pids attached to a buffer.

  Direct ETS read with `:read_concurrency`. Safe to call from any
  process without blocking.
  """
  @spec clients_for_buffer(pid()) :: [pid()]
  def clients_for_buffer(buffer_pid) when is_pid(buffer_pid) do
    case :ets.lookup(@registry_table, buffer_pid) do
      [{^buffer_pid, clients}] -> clients
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    :ets.new(@registry_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    Events.subscribe(:buffer_opened)
    Events.subscribe(:buffer_saved)
    Events.subscribe(:buffer_closed)
    Events.subscribe(:buffer_changed)

    {:ok, %{debounce_timers: %{}}}
  end

  @impl true
  def handle_info(
        {:minga_event, :buffer_changed, %Events.BufferChangedEvent{buffer: buf}},
        state
      ) do
    {:noreply, schedule_did_change(state, buf)}
  end

  def handle_info(
        {:minga_event, :buffer_opened, %Events.BufferEvent{buffer: buf, path: _path}},
        state
      ) do
    do_buffer_open(buf)
    {:noreply, state}
  end

  def handle_info({:minga_event, :buffer_saved, %Events.BufferEvent{buffer: buf}}, state) do
    do_buffer_save(buf)
    {:noreply, state}
  end

  def handle_info({:minga_event, :buffer_closed, %Events.BufferClosedEvent{buffer: buf}}, state) do
    state = do_buffer_close(state, buf)
    {:noreply, state}
  end

  def handle_info({:flush_did_change, buffer_pid}, state) do
    state = flush_did_change(state, buffer_pid)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private: buffer lifecycle ──────────────────────────────────────────

  @spec do_buffer_open(pid()) :: :ok
  defp do_buffer_open(buffer_pid) do
    filetype = BufferServer.filetype(buffer_pid)
    file_path = BufferServer.file_path(buffer_pid)

    case file_path do
      nil ->
        :ok

      path ->
        configs = ServerRegistry.servers_for(filetype)
        uri = path_to_uri(path)
        {content, _cursor} = BufferServer.content_and_cursor(buffer_pid)
        language_id = to_string(filetype)

        clients =
          configs
          |> Enum.map(fn config ->
            root = RootDetector.find_root(path, config.root_markers)
            LSPSupervisor.ensure_client(config, root)
          end)
          |> Enum.filter(fn
            {:ok, _pid} -> true
            _ -> false
          end)
          |> Enum.map(fn {:ok, pid} ->
            Client.did_open(pid, uri, language_id, content)
            pid
          end)

        if clients != [] do
          :ets.insert(@registry_table, {buffer_pid, clients})
        end

        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @spec do_buffer_save(pid()) :: :ok
  defp do_buffer_save(buffer_pid) do
    clients = clients_for_buffer(buffer_pid)
    notify_clients(clients, buffer_pid, &Client.did_save/2)
  catch
    :exit, _ -> :ok
  end

  @spec do_buffer_close(state(), pid()) :: state()
  defp do_buffer_close(state, buffer_pid) do
    clients = clients_for_buffer(buffer_pid)
    notify_clients(clients, buffer_pid, &Client.did_close/2)

    :ets.delete(@registry_table, buffer_pid)
    cancel_debounce(state, buffer_pid)
  catch
    :exit, _ -> state
  end

  # ── Private: didChange debouncing ──────────────────────────────────────

  @spec schedule_did_change(state(), pid()) :: state()
  defp schedule_did_change(state, buffer_pid) do
    clients = clients_for_buffer(buffer_pid)

    case clients do
      [] ->
        state

      _ ->
        state = cancel_debounce(state, buffer_pid)

        timer =
          Process.send_after(
            self(),
            {:flush_did_change, buffer_pid},
            @debounce_ms
          )

        %{state | debounce_timers: Map.put(state.debounce_timers, buffer_pid, timer)}
    end
  end

  @spec flush_did_change(state(), pid()) :: state()
  defp flush_did_change(state, buffer_pid) do
    clients = clients_for_buffer(buffer_pid)
    timers = Map.delete(state.debounce_timers, buffer_pid)
    state = %{state | debounce_timers: timers}

    notify_clients_change(clients, buffer_pid)
    state
  end

  @spec cancel_debounce(state(), pid()) :: state()
  defp cancel_debounce(state, buffer_pid) do
    case Map.get(state.debounce_timers, buffer_pid) do
      nil ->
        state

      timer ->
        Process.cancel_timer(timer)
        %{state | debounce_timers: Map.delete(state.debounce_timers, buffer_pid)}
    end
  end

  # ── Private: LSP notification helpers ──────────────────────────────────

  @spec notify_clients([pid()], pid(), (pid(), String.t() -> :ok)) :: :ok
  defp notify_clients([], _buffer_pid, _fun), do: :ok

  defp notify_clients(clients, buffer_pid, fun) do
    uri = buffer_uri(buffer_pid)
    if uri, do: send_to_alive_clients(clients, fn c -> fun.(c, uri) end)
    :ok
  end

  @spec notify_clients_change([pid()], pid()) :: :ok
  defp notify_clients_change([], _buffer_pid), do: :ok

  defp notify_clients_change(clients, buffer_pid) do
    with uri when is_binary(uri) <- buffer_uri(buffer_pid) do
      {content, _cursor} = BufferServer.content_and_cursor(buffer_pid)
      send_to_alive_clients(clients, fn c -> Client.did_change(c, uri, content) end)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @spec buffer_uri(pid()) :: String.t() | nil
  defp buffer_uri(buffer_pid) do
    case BufferServer.file_path(buffer_pid) do
      nil -> nil
      path -> path_to_uri(path)
    end
  end

  @spec send_to_alive_clients([pid()], (pid() -> term())) :: :ok
  defp send_to_alive_clients(clients, fun) do
    Enum.each(clients, fn client ->
      try do
        fun.(client)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  @doc """
  Converts a file system path to a `file://` URI.
  """
  @spec path_to_uri(String.t()) :: String.t()
  def path_to_uri(path) when is_binary(path) do
    "file://" <> Path.expand(path)
  end

  @doc """
  Converts a `file://` URI back to a file system path.
  """
  @spec uri_to_path(String.t()) :: String.t()
  def uri_to_path("file://" <> path), do: path
  def uri_to_path(uri), do: uri
end
