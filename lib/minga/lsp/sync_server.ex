defmodule Minga.LSP.SyncServer do
  @moduledoc """
  Manages LSP document synchronization by subscribing to the event bus.

  Owns the mapping of buffer pids to LSP client pids and handles the
  LSP document lifecycle protocol (didOpen, didChange, didSave, didClose)
  independently of the Editor GenServer.

  Maintains an ETS table (`Minga.LSP.SyncServer.Registry`) mapping
  buffer pids to their attached LSP client pids. Consumers like
  `CompletionTrigger` and `LspActions` look up
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

  alias Minga.Buffer
  alias Minga.Config.Options
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
          delta_accumulators: %{pid() => delta_accumulator()},
          pending_revisions: %{pid() => non_neg_integer()},
          events_registry: Events.registry()
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

  @doc "The ETS table name used for buffer-to-client registration."
  @spec registry_table() :: atom()
  def registry_table, do: @registry_table

  @doc "Inserts a buffer-to-clients mapping into the sync registry."
  @spec put_clients(pid(), [pid()]) :: true
  def put_clients(buffer_pid, clients) when is_pid(buffer_pid) and is_list(clients) do
    :ets.insert(@registry_table, {buffer_pid, clients})
  end

  @doc "Removes a buffer entry from the sync registry."
  @spec remove_buffer(pid()) :: true
  def remove_buffer(buffer_pid) when is_pid(buffer_pid) do
    :ets.delete(@registry_table, buffer_pid)
  end

  @doc "Removes all entries from the sync registry."
  @spec clear_registry() :: true
  def clear_registry do
    :ets.delete_all_objects(@registry_table)
  end

  @doc """
  Reattaches open buffers to their language servers after client restart.

  This clears stale client monitors and ETS entries for the given buffers, then
  runs the same document-open path used for `:buffer_opened` events. It is used
  after system wake, when LSP clients may have been restarted while buffers stay
  open in the editor.
  """
  @spec resync_buffers([pid()], GenServer.server()) :: :ok
  def resync_buffers(buffer_pids, server \\ __MODULE__) when is_list(buffer_pids) do
    GenServer.cast(server, {:resync_buffers, buffer_pids})
  end

  @doc """
  Flushes one document's pending synchronization and asks its producing Client to admit an asynchronous request against `expected_revision`.
  """
  @spec request_document(
          pid(),
          pid(),
          non_neg_integer(),
          String.t(),
          map(),
          GenServer.server()
        ) :: {:ok, reference(), Minga.LSP.DocumentContext.t()} | {:error, atom()}
  def request_document(buffer, client, expected_revision, method, params, server \\ __MODULE__)
      when is_pid(buffer) and is_pid(client) and is_integer(expected_revision) and
             expected_revision >= 0 and is_binary(method) and is_map(params) do
    GenServer.call(
      server,
      {:request_document, buffer, client, expected_revision, method, params}
    )
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    :ets.new(@registry_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    events_registry = Keyword.get(opts, :events_registry, Events.default_registry())

    Events.subscribe(:buffer_opened, events_registry)
    Events.subscribe(:buffer_saved, events_registry)
    Events.subscribe(:buffer_closed, events_registry)
    Events.subscribe(:buffer_changed, events_registry)
    Events.subscribe(:tool_install_complete, events_registry)
    Events.subscribe(:file_written, events_registry)

    {:ok,
     %{
       debounce_timers: %{},
       client_monitors: %{},
       pending_tool_buffers: %{},
       # Accumulated deltas per buffer pid. When a delta is nil (bulk op),
       # the value is set to :full_sync to force full content sync.
       delta_accumulators: %{},
       pending_revisions: %{},
       events_registry: events_registry
     }}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call(
        {:request_document, buffer, client, expected_revision, method, params},
        {response_to, _tag},
        state
      ) do
    state = flush_did_change(state, buffer)

    reply =
      with true <- client in clients_for_buffer(buffer),
           path when is_binary(path) <- safe_file_path(buffer),
           uri = path_to_uri(path),
           {content, ^expected_revision} <- safe_content_with_version(buffer) do
        Client.request_document(
          client,
          uri,
          buffer,
          expected_revision,
          method,
          params,
          content,
          response_to
        )
      else
        false -> {:error, :client_replaced}
        nil -> {:error, :unknown_document}
        :stale -> {:error, :stale_document}
        {_content, _revision} -> {:error, :stale_document}
      end

    {:reply, reply, state}
  catch
    :exit, _ -> {:reply, {:error, :client_unavailable}, state}
  end

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:resync_buffers, buffer_pids}, state) when is_list(buffer_pids) do
    state =
      buffer_pids
      |> Enum.uniq()
      |> Enum.reduce(state, fn buffer_pid, acc -> resync_buffer(acc, buffer_pid) end)

    {:noreply, state}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info(
        {:minga_event, :buffer_changed,
         %Events.BufferChangedEvent{buffer: buf, delta: delta, version: version}},
        state
      ) do
    if clients_for_buffer(buf) == [] do
      {:noreply, state}
    else
      state = accumulate_delta(state, buf, delta, event_revision(buf, version))
      {:noreply, schedule_did_change(state, buf)}
    end
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

  def handle_info(
        {:minga_event, :file_written,
         %Events.FileWrittenEvent{path: path, change_type: change_type}},
        state
      ) do
    notify_file_watchers(path, change_type)
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
  @spec resync_buffer(state(), pid() | term()) :: state()
  defp resync_buffer(state, buffer_pid) when is_pid(buffer_pid) do
    state = demonitor_clients_for_buffer(state, buffer_pid)
    state = cancel_debounce(state, buffer_pid)
    state = %{state | delta_accumulators: Map.delete(state.delta_accumulators, buffer_pid)}
    state = %{state | pending_revisions: Map.delete(state.pending_revisions, buffer_pid)}
    :ets.delete(@registry_table, buffer_pid)
    do_buffer_open(state, buffer_pid)
  end

  defp resync_buffer(state, _buffer_pid), do: state

  defp do_buffer_open(state, buffer_pid) do
    if remote_buffer?(buffer_pid) do
      state
    else
      open_local_buffer(state, buffer_pid)
    end
  end

  @spec open_local_buffer(state(), pid()) :: state()
  defp open_local_buffer(state, buffer_pid) do
    if lsp_auto_start?() do
      do_open_local_buffer(state, buffer_pid)
    else
      state
    end
  end

  @spec do_open_local_buffer(state(), pid()) :: state()
  defp do_open_local_buffer(state, buffer_pid) do
    filetype = Buffer.filetype(buffer_pid)
    file_path = Buffer.file_path(buffer_pid)

    case file_path do
      nil ->
        state

      path ->
        configs = ServerRegistry.servers_for(filetype)
        uri = path_to_uri(path)
        {content, revision} = Buffer.content_with_version(buffer_pid)
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
            Client.did_open(pid, uri, language_id, content, buffer_pid, revision)
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
    exception ->
      Minga.Log.warning(
        :lsp,
        "LSP buffer open failed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )

      state
  catch
    :exit, reason ->
      Minga.Log.warning(:lsp, "LSP buffer open exited: #{inspect(reason)}")
      state
  end

  @spec lsp_auto_start?() :: boolean()
  defp lsp_auto_start? do
    Options.get(:lsp_auto_start)
  catch
    :exit, _ -> true
  end

  @spec remote_buffer?(pid()) :: boolean()
  defp remote_buffer?(buffer_pid) do
    case Buffer.storage(buffer_pid) do
      {:remote, _node, _path} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
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
    state = %{state | pending_revisions: Map.delete(state.pending_revisions, buffer_pid)}
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
      Events.broadcast(
        :tool_missing,
        %ToolMissingEvent{command: config.command},
        state.events_registry
      )

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
    {revision, pending_revisions} = Map.pop(state.pending_revisions, buffer_pid)

    state = %{
      state
      | debounce_timers: timers,
        delta_accumulators: accumulators,
        pending_revisions: pending_revisions
    }

    if is_integer(revision), do: notify_clients_change(clients, buffer_pid, deltas, revision)
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
  @spec accumulate_delta(
          state(),
          pid(),
          Minga.Buffer.EditDelta.t() | nil,
          non_neg_integer()
        ) :: state()
  defp accumulate_delta(state, buffer_pid, delta, revision) do
    previous_revision = Map.get(state.pending_revisions, buffer_pid)

    if is_integer(previous_revision) and revision <= previous_revision do
      state
    else
      state = put_accumulated_delta(state, buffer_pid, delta)
      %{state | pending_revisions: Map.put(state.pending_revisions, buffer_pid, revision)}
    end
  end

  @spec put_accumulated_delta(state(), pid(), Minga.Buffer.EditDelta.t() | nil) :: state()
  defp put_accumulated_delta(state, buffer_pid, nil) do
    # Bulk op (undo, redo, replace_content): discard accumulated deltas
    # and mark as full sync needed
    %{state | delta_accumulators: Map.put(state.delta_accumulators, buffer_pid, :full_sync)}
  end

  defp put_accumulated_delta(state, buffer_pid, delta) do
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

  # ── Private: file watcher notifications ───────────────────────────────

  @spec notify_file_watchers(String.t(), Minga.Events.FileWrittenEvent.change_type()) :: :ok
  defp notify_file_watchers(path, change_type) do
    changes = [{path, change_type}]

    LSPSupervisor.all_clients()
    |> Enum.each(fn client_pid ->
      try do
        Client.notify_file_changes(client_pid, changes)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # ── Private: LSP notification helpers ──────────────────────────────────

  @spec notify_clients([pid()], pid(), (pid(), String.t() -> :ok)) :: :ok
  defp notify_clients([], _buffer_pid, _fun), do: :ok

  defp notify_clients(clients, buffer_pid, fun) do
    uri = buffer_uri(buffer_pid)
    if uri, do: send_to_alive_clients(clients, fn c -> fun.(c, uri) end)
    :ok
  end

  @spec notify_clients_change([pid()], pid(), [Minga.Buffer.EditDelta.t()], non_neg_integer()) ::
          :ok
  defp notify_clients_change([], _buffer_pid, _deltas, _revision), do: :ok

  defp notify_clients_change(clients, buffer_pid, deltas, revision) do
    with uri when is_binary(uri) <- buffer_uri(buffer_pid) do
      send_to_alive_clients(clients, fn client ->
        send_change(client, uri, buffer_pid, deltas, revision)
      end)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # Sends a change notification using incremental sync if the server supports
  # it and deltas are available, otherwise falls back to full sync.
  @spec send_change(
          pid(),
          String.t(),
          pid(),
          [Minga.Buffer.EditDelta.t()],
          non_neg_integer()
        ) :: :ok
  defp send_change(client, uri, buffer_pid, deltas, revision) do
    sync_kind =
      try do
        Client.sync_kind(client)
      catch
        :exit, _ -> :full
      end

    encoding =
      try do
        Client.encoding(client)
      catch
        :exit, _ -> :unknown
      end

    case {sync_kind, encoding, deltas} do
      {:incremental, :utf8, [_ | _]} ->
        changes = Enum.map(deltas, &delta_to_lsp_change/1)
        Client.did_change_incremental(client, uri, changes, buffer_pid, revision)

      _ ->
        {content, current_revision} = Buffer.content_with_version(buffer_pid)
        Client.did_change(client, uri, content, buffer_pid, current_revision)
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
    case Buffer.file_path(buffer_pid) do
      nil -> nil
      path -> path_to_uri(path)
    end
  end

  @spec event_revision(pid(), non_neg_integer() | nil) :: non_neg_integer()
  defp event_revision(_buffer_pid, version) when is_integer(version) and version >= 0, do: version
  defp event_revision(buffer_pid, _version), do: Buffer.version(buffer_pid)

  @spec safe_file_path(pid()) :: String.t() | nil
  defp safe_file_path(buffer) do
    Buffer.file_path(buffer)
  catch
    :exit, _ -> nil
  end

  @spec safe_content_with_version(pid()) :: {String.t(), non_neg_integer()} | :stale
  defp safe_content_with_version(buffer) do
    Buffer.content_with_version(buffer)
  catch
    :exit, _ -> :stale
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
