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

  Monitors all registered LSP client PIDs. If a client crashes outside
  the event bus path, the `:DOWN` handler removes stale ETS entries so
  they don't accumulate.

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
  alias Minga.Events.ToolMissingEvent
  alias Minga.LSP.Client
  alias Minga.LSP.RootDetector
  alias Minga.LSP.ServerRegistry
  alias Minga.LSP.Supervisor, as: LSPSupervisor
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry

  @registry_table __MODULE__.Registry
  @debounce_ms 150

  @typedoc "Accumulated deltas per buffer. :full_sync means a bulk op invalidated deltas."
  @type delta_accumulator :: [Minga.Buffer.EditDelta.t()] | :full_sync

  @typedoc "Internal state."
  @type state :: %{
          debounce_timers: %{pid() => reference()},
          client_monitors: %{reference() => {buffer_pid :: pid(), client_pid :: pid()}},
          pending_tool_buffers: %{String.t() => [pid()]},
          delta_accumulators: %{pid() => delta_accumulator()}
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
    Events.subscribe(:tool_install_complete)

    {:ok,
     %{
       debounce_timers: %{},
       client_monitors: %{},
       pending_tool_buffers: %{},
       # Accumulated deltas per buffer pid. When a delta is nil (bulk op),
       # the value is set to :full_sync to force full content sync.
       delta_accumulators: %{}
     }}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info(
        {:minga_event, :buffer_changed, %Events.BufferChangedEvent{buffer: buf, delta: delta}},
        state
      ) do
    state = accumulate_delta(state, buf, delta)
    {:noreply, schedule_did_change(state, buf)}
  end

  def handle_info(
        {:minga_event, :buffer_opened, %Events.BufferEvent{buffer: buf, path: _path}},
        state
      ) do
    state = do_buffer_open(state, buf)
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

  # After a tool install completes, re-trigger buffer open for any open buffers
  # that need the newly installed tool. This auto-starts the LSP server.
  def handle_info({:minga_event, :tool_install_complete, %{name: tool_name}}, state) do
    state = retry_buffers_for_tool(state, tool_name)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state = handle_client_down(state, ref, pid)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private: buffer lifecycle ──────────────────────────────────────────

  @spec do_buffer_open(state(), pid()) :: state()
  defp do_buffer_open(state, buffer_pid) do
    filetype = BufferServer.filetype(buffer_pid)
    file_path = BufferServer.file_path(buffer_pid)

    case file_path do
      nil ->
        state

      path ->
        configs = ServerRegistry.servers_for(filetype)
        uri = path_to_uri(path)
        {content, _cursor} = BufferServer.content_and_cursor(buffer_pid)
        language_id = to_string(filetype)

        results =
          Enum.map(configs, fn config ->
            root = RootDetector.find_root(path, config.root_markers)
            {config, LSPSupervisor.ensure_client(config, root)}
          end)

        # Broadcast :tool_missing for configs that failed and have a recipe
        state = track_missing_tools(state, results, buffer_pid)

        clients =
          results
          |> Enum.filter(fn
            {_config, {:ok, _pid}} -> true
            _ -> false
          end)
          |> Enum.map(fn {_config, {:ok, pid}} ->
            Client.did_open(pid, uri, language_id, content)
            pid
          end)

        if clients != [] do
          :ets.insert(@registry_table, {buffer_pid, clients})
          monitor_clients(state, buffer_pid, clients)
        else
          state
        end
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
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
    state = demonitor_clients_for_buffer(state, buffer_pid)
    state = %{state | delta_accumulators: Map.delete(state.delta_accumulators, buffer_pid)}
    cancel_debounce(state, buffer_pid)
  catch
    :exit, _ -> state
  end

  # ── Private: missing tool detection ──────────────────────────────────────

  # Broadcasts :tool_missing for failed configs that have a recipe, and
  # tracks the buffer pid per command so we can retry after install.
  @spec track_missing_tools(state(), [{map(), term()}], pid()) :: state()
  defp track_missing_tools(state, results, buffer_pid) do
    results
    |> Enum.filter(&failed_with_recipe?/1)
    |> Enum.reduce(state, fn {config, _}, acc ->
      Events.broadcast(:tool_missing, %ToolMissingEvent{command: config.command})
      track_buffer_for_command(acc, config.command, buffer_pid)
    end)
  end

  @spec failed_with_recipe?({map(), term()}) :: boolean()
  defp failed_with_recipe?({config, {:error, :not_available}}),
    do: RecipeRegistry.for_command(config.command) != nil

  defp failed_with_recipe?(_), do: false

  @spec track_buffer_for_command(state(), String.t(), pid()) :: state()
  defp track_buffer_for_command(state, command, buffer_pid) do
    existing = Map.get(state.pending_tool_buffers, command, [])

    if buffer_pid in existing do
      state
    else
      updated = Map.put(state.pending_tool_buffers, command, [buffer_pid | existing])
      %{state | pending_tool_buffers: updated}
    end
  end

  # Re-trigger buffer open for buffers that were waiting on this tool.
  @spec retry_buffers_for_tool(state(), atom()) :: state()
  defp retry_buffers_for_tool(state, tool_name) do
    recipe = RecipeRegistry.get(tool_name)

    if recipe do
      # Collect all buffer pids that were waiting on any command this tool provides
      {buffer_pids, remaining_pending} =
        Enum.reduce(recipe.provides, {[], state.pending_tool_buffers}, fn cmd, {pids, pending} ->
          {Map.get(pending, cmd, []) ++ pids, Map.delete(pending, cmd)}
        end)

      state = %{state | pending_tool_buffers: remaining_pending}

      buffer_pids
      |> Enum.uniq()
      |> Enum.reduce(state, fn buf_pid, acc ->
        do_buffer_open(acc, buf_pid)
      end)
    else
      state
    end
  end

  # ── Private: client monitoring ─────────────────────────────────────────

  @spec monitor_clients(state(), pid(), [pid()]) :: state()
  defp monitor_clients(state, buffer_pid, clients) do
    new_monitors =
      Enum.reduce(clients, state.client_monitors, fn client_pid, acc ->
        ref = Process.monitor(client_pid)
        Map.put(acc, ref, {buffer_pid, client_pid})
      end)

    %{state | client_monitors: new_monitors}
  end

  @spec demonitor_clients_for_buffer(state(), pid()) :: state()
  defp demonitor_clients_for_buffer(state, buffer_pid) do
    {to_remove, to_keep} =
      Map.split_with(state.client_monitors, fn {_ref, {buf_pid, _client_pid}} ->
        buf_pid == buffer_pid
      end)

    Enum.each(to_remove, fn {ref, _} ->
      Process.demonitor(ref, [:flush])
    end)

    %{state | client_monitors: to_keep}
  end

  @spec handle_client_down(state(), reference(), pid()) :: state()
  defp handle_client_down(state, ref, client_pid) do
    case Map.pop(state.client_monitors, ref) do
      {nil, _monitors} ->
        state

      {{buffer_pid, ^client_pid}, remaining_monitors} ->
        state = %{state | client_monitors: remaining_monitors}
        remove_client_from_buffer(buffer_pid, client_pid)
        state

      {_other, _monitors} ->
        # ref found but pid mismatch; shouldn't happen, but don't crash
        state
    end
  end

  @spec remove_client_from_buffer(pid(), pid()) :: :ok
  defp remove_client_from_buffer(buffer_pid, client_pid) do
    case :ets.lookup(@registry_table, buffer_pid) do
      [{^buffer_pid, clients}] ->
        remaining = List.delete(clients, client_pid)

        case remaining do
          [] -> :ets.delete(@registry_table, buffer_pid)
          _ -> :ets.insert(@registry_table, {buffer_pid, remaining})
        end

        :ok

      [] ->
        :ok
    end
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

    # Drain accumulated deltas for this buffer
    {deltas, accumulators} = drain_deltas(state.delta_accumulators, buffer_pid)
    state = %{state | debounce_timers: timers, delta_accumulators: accumulators}

    notify_clients_change(clients, buffer_pid, deltas)
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

  # ── Private: delta accumulation ──────────────────────────────────────

  # Accumulates a delta for a buffer. When delta is nil (bulk operation),
  # marks the buffer as needing full sync by setting the value to :full_sync.
  @spec accumulate_delta(state(), pid(), Minga.Buffer.EditDelta.t() | nil) :: state()
  defp accumulate_delta(state, buffer_pid, nil) do
    # Bulk op (undo, redo, replace_content): discard accumulated deltas
    # and mark as full sync needed
    %{state | delta_accumulators: Map.put(state.delta_accumulators, buffer_pid, :full_sync)}
  end

  defp accumulate_delta(state, buffer_pid, delta) do
    accumulators = state.delta_accumulators

    new_acc =
      case Map.get(accumulators, buffer_pid) do
        # Already marked for full sync, stay that way
        :full_sync -> :full_sync
        # Prepend delta (newest-first); reversed at drain time for correct order
        deltas when is_list(deltas) -> [delta | deltas]
        # First delta for this buffer
        nil -> [delta]
      end

    %{state | delta_accumulators: Map.put(accumulators, buffer_pid, new_acc)}
  end

  # Drains accumulated deltas for a buffer. Returns {deltas, updated_accumulators}.
  # Returns [] when full sync is needed (the caller falls back to full content).
  # Reverses the list to restore document order (deltas are prepended during accumulation).
  @spec drain_deltas(map(), pid()) :: {[Minga.Buffer.EditDelta.t()], map()}
  defp drain_deltas(accumulators, buffer_pid) do
    {value, remaining} = Map.pop(accumulators, buffer_pid)

    deltas =
      case value do
        :full_sync -> []
        deltas when is_list(deltas) -> Enum.reverse(deltas)
        nil -> []
      end

    {deltas, remaining}
  end

  # ── Private: LSP notification helpers ──────────────────────────────────

  @spec notify_clients([pid()], pid(), (pid(), String.t() -> :ok)) :: :ok
  defp notify_clients([], _buffer_pid, _fun), do: :ok

  defp notify_clients(clients, buffer_pid, fun) do
    uri = buffer_uri(buffer_pid)
    if uri, do: send_to_alive_clients(clients, fn c -> fun.(c, uri) end)
    :ok
  end

  @spec notify_clients_change([pid()], pid(), [Minga.Buffer.EditDelta.t()]) :: :ok
  defp notify_clients_change([], _buffer_pid, _deltas), do: :ok

  defp notify_clients_change(clients, buffer_pid, deltas) do
    with uri when is_binary(uri) <- buffer_uri(buffer_pid) do
      send_to_alive_clients(clients, fn client ->
        send_change(client, uri, buffer_pid, deltas)
      end)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # Sends a change notification using incremental sync if the server supports
  # it and deltas are available, otherwise falls back to full sync.
  @spec send_change(pid(), String.t(), pid(), [Minga.Buffer.EditDelta.t()]) :: :ok
  defp send_change(client, uri, buffer_pid, deltas) do
    sync_kind =
      try do
        Client.sync_kind(client)
      catch
        :exit, _ -> :full
      end

    case {sync_kind, deltas} do
      {:incremental, [_ | _]} ->
        changes = Enum.map(deltas, &delta_to_lsp_change/1)
        Client.did_change_incremental(client, uri, changes)

      _ ->
        {content, _cursor} = BufferServer.content_and_cursor(buffer_pid)
        Client.did_change(client, uri, content)
    end
  end

  @spec delta_to_lsp_change(Minga.Buffer.EditDelta.t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), String.t()}
  defp delta_to_lsp_change(delta) do
    {sl, sc} = delta.start_position
    {el, ec} = delta.old_end_position
    {sl, sc, el, ec, delta.inserted_text}
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
