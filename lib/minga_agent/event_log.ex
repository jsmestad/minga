defmodule MingaAgent.EventLog do
  @moduledoc """
  Bounded admission owner for the durable agent-session event log.

  `record/4` synchronously performs only queue admission. Accepted critical events receive a receipt and later deliver `{:event_log_commit, receipt, event_type, result}` to the admitting process. The result is `{:persisted, event_id}` only after SQLite reports the insert committed, or `{:error, {:persistence_failed, reason}}` when durability cannot be established.

  A separately monitored `MingaAgent.EventLog.Writer` owns the SQLite connection and executes inserts and retention serially. SQLite stalls therefore do not prevent EventLog from admitting work up to its configured bound or rejecting excess work explicitly.
  """

  use GenServer

  alias MingaAgent.EventLog.Entry
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.State
  alias MingaAgent.EventLog.Payload
  alias MingaAgent.EventLog.Store
  alias MingaAgent.EventLog.TouchedFiles
  alias MingaAgent.EventLog.Writer

  @default_db_dir Path.expand("~/.local/share/minga")
  @db_filename "agent_events.db"
  @default_max_queue_size 1_000
  @default_max_queue_bytes 8 * 1024 * 1024
  @default_writer_restart_delay_ms 1_000
  @retention_sweep_interval_ms :timer.hours(1)
  @initial_retention_sweep_delay_ms :timer.seconds(5)
  @health_check_delay_ms :timer.seconds(10)
  @default_health_check :quick

  @type receipt :: reference()
  @type persistence_result ::
          {:persisted, pos_integer()} | {:error, {:persistence_failed, term()}}
  @type admission_error ::
          {:error, :overloaded | :unavailable | :payload_too_large | :invalid_payload}
  @type admission_result :: {:queued, receipt()} | admission_error()
  @type best_effort_admission_result :: :queued | admission_error()

  @doc "Starts the bounded event-log admission owner and its monitored writer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the configured event-log database path."
  @spec db_path(keyword()) :: String.t()
  def db_path(opts \\ []) do
    dir = Keyword.get(opts, :db_dir, @default_db_dir)
    Path.join(dir, @db_filename)
  end

  @doc "Opens an independent read connection to the agent event database."
  @spec open_read_connection(keyword()) :: {:ok, Store.db()} | {:error, term()}
  def open_read_connection(opts \\ []) do
    path = db_path(opts)

    if File.exists?(path) do
      Store.open(path)
    else
      {:error, :database_not_found}
    end
  end

  @doc """
  Admits a durability-critical event to the bounded ordered queue.

  This call performs no SQLite work. `{:queued, receipt}` means admission only; the caller later receives the documented `{:event_log_commit, receipt, event_type, result}` message after the writer reports success or failure.
  """
  @spec record(String.t(), EventRecord.event_type(), map(), GenServer.server()) ::
          admission_result()
  def record(session_id, event_type, payload \\ %{}, server \\ __MODULE__)
      when is_binary(session_id) and is_atom(event_type) and is_map(payload) do
    with {:ok, raw_bytes} <- Payload.external_size(payload) do
      GenServer.call(
        server,
        {:admit_payload, :critical, session_id, event_type, payload, raw_bytes},
        :infinity
      )
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  Admits a high-rate event without requesting a durability acknowledgment.

  The return value reports queue admission only. Accepted events share the same ordered queue as critical events, may be rejected under pressure, and never send a durability acknowledgment.
  """
  @spec record_best_effort(String.t(), EventRecord.event_type(), map(), GenServer.server()) ::
          best_effort_admission_result()
  def record_best_effort(session_id, event_type, payload \\ %{}, server \\ __MODULE__)
      when is_binary(session_id) and is_atom(event_type) and is_map(payload) do
    with {:ok, raw_bytes} <- Payload.external_size(payload) do
      GenServer.call(
        server,
        {:admit_payload, :best_effort, session_id, event_type, payload, raw_bytes},
        :infinity
      )
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Waits for the durability result associated with a critical-event receipt."
  @spec await(receipt(), timeout()) :: persistence_result() | {:error, :timeout}
  def await(receipt, timeout \\ 5_000) when is_reference(receipt) do
    receive do
      {:event_log_commit, ^receipt, _event_type, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc "Waits until all currently outstanding event-log work has completed."
  @spec await_idle(GenServer.server(), timeout()) :: :ok | {:error, :timeout | :unavailable}
  def await_idle(server \\ __MODULE__, timeout \\ 5_000) do
    GenServer.call(server, :await_idle, timeout)
  catch
    :exit, {:timeout, _details} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Requests an immediate writer restart when admission is unavailable."
  @spec restart_writer(GenServer.server()) :: :ok | {:error, :unavailable}
  def restart_writer(server \\ __MODULE__) do
    GenServer.call(server, :restart_writer)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Returns the current monitored writer pid, primarily for operational inspection."
  @spec writer_pid(GenServer.server()) :: pid() | nil
  def writer_pid(server \\ __MODULE__), do: GenServer.call(server, :writer_pid)

  @doc "Returns one session's durably admitted file touches, most recent first."
  @spec touched_files(String.t(), GenServer.server()) ::
          {:ok, [TouchedFiles.touch()]} | {:error, :unavailable}
  def touched_files(session_id, server \\ __MODULE__) when is_binary(session_id) do
    GenServer.call(server, {:touched_files, session_id})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Queries events for a session after the given cursor."
  @spec events_after(Store.db(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [EventRecord.t()]} | {:error, term()}
  defdelegate events_after(db, session_id, last_id, limit \\ 1000), to: Store

  @doc "Returns the latest event id for a session."
  @spec latest_id(Store.db(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate latest_id(db, session_id), to: Store

  @impl GenServer
  @spec init(keyword()) :: {:ok, State.t()} | {:stop, term()}
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = db_path(opts)
    max_queue_size = Keyword.get(opts, :max_queue_size, @default_max_queue_size)
    max_queue_bytes = Keyword.get(opts, :max_queue_bytes, @default_max_queue_bytes)

    retention_days =
      Keyword.get_lazy(opts, :retention_days, fn -> Minga.Config.get(:event_retention_days) end)

    initialize(opts, path, retention_days, max_queue_size, max_queue_bytes)
  end

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), State.t()) ::
          {:reply, term(), State.t()} | {:noreply, State.t()}
  def handle_call(
        {:admit_payload, _kind, _session_id, _event_type, _payload, _raw_bytes},
        _from,
        %State{writer: :unavailable} = state
      ) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call(
        {:admit_payload, kind, session_id, event_type, payload, raw_bytes},
        from,
        state
      ) do
    admit_payload(kind, session_id, event_type, payload, raw_bytes, from, state)
  end

  def handle_call(
        {:admit, _kind, _record, _payload_bytes},
        _from,
        %State{writer: :unavailable} = state
      ) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:admit, kind, record, payload_bytes}, from, state) do
    admit(kind, record, payload_bytes, from, state)
  end

  def handle_call(
        {:touched_files, session_id},
        _from,
        %State{writer: {:ready, _writer, _ref}} = state
      ) do
    {:reply, {:ok, State.touched_files(state, session_id)}, state}
  end

  def handle_call({:touched_files, _session_id}, _from, state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call(:await_idle, from, state) do
    await_idle_reply(state, from, idle?(state))
  end

  def handle_call(:restart_writer, _from, %State{writer: :unavailable} = state) do
    new_state = state |> State.writer_restarting() |> start_writer()
    reply = if is_pid(State.writer_pid(new_state)), do: :ok, else: {:error, :unavailable}
    {:reply, reply, new_state}
  end

  def handle_call(:restart_writer, _from, state), do: {:reply, :ok, state}
  def handle_call(:writer_pid, _from, state), do: {:reply, State.writer_pid(state), state}

  @impl GenServer
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()}
  def handle_info(
        {:event_log_writer_ready, writer, events},
        %State{writer: {:opening, writer, _ref}} = state
      ) do
    {:noreply, complete_writer_start(state, events)}
  end

  def handle_info(
        {:event_log_writer_unavailable, writer, reason},
        %State{writer: {:opening, writer, _ref}} = state
      ) do
    {:noreply, mark_writer_unavailable(state, reason)}
  end

  def handle_info(
        {:event_log_writer_result, writer, token, event_type, result},
        %State{writer: {:ready, writer, _ref}, in_flight: {:event, token, entry}} = state
      ) do
    {:noreply, finish_event(state, entry, event_type, result)}
  end

  def handle_info(
        {:event_log_retention_result, writer, token, result},
        %State{writer: {:ready, writer, _ref}, in_flight: {:retention, token}} = state
      ) do
    {:noreply, finish_retention(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, writer, reason},
        %State{writer: {phase, writer, ref}} = state
      )
      when phase in [:opening, :ready] do
    {:noreply, handle_writer_down(state, reason)}
  end

  def handle_info({:EXIT, _writer, _reason}, state), do: {:noreply, state}

  def handle_info(:restart_writer, %State{writer: :unavailable} = state) do
    {:noreply, state |> State.writer_restarting() |> start_writer()}
  end

  def handle_info(:restart_writer, state), do: {:noreply, state}

  def handle_info(:retention_sweep, state) do
    {:noreply, state |> State.mark_retention_pending() |> dispatch_next()}
  end

  def handle_info({:health_check_result, result}, state) do
    handle_health_check_result(result, state)
  end

  def handle_info({:run_health_check, parent, path, mode}, state) do
    Task.start(fn -> send(parent, {:health_check_result, run_health_check(path, mode)}) end)
    {:noreply, state}
  end

  @impl GenServer
  @spec terminate(term(), State.t()) :: :ok
  def terminate(_reason, state) do
    cancel_timer(state.sweep_ref)
    stop_writer(State.writer_pid(state))
    :ok
  end

  @spec initialize(keyword(), String.t(), pos_integer(), term(), term()) ::
          {:ok, State.t()} | {:stop, term()}
  defp initialize(opts, path, retention_days, max_queue_size, max_queue_bytes)
       when is_integer(max_queue_size) and max_queue_size > 0 and
              is_integer(max_queue_bytes) and max_queue_bytes > 0 do
    state =
      State.new(
        path,
        retention_days,
        max_queue_size,
        max_queue_bytes,
        Keyword.get(opts, :store_backend, Store),
        Keyword.get(opts, :store_backend_opts, []),
        Keyword.get(opts, :writer_restart_delay_ms, @default_writer_restart_delay_ms)
      )
      |> start_writer()

    sweep_ref = schedule_initial_retention_sweep(opts)
    schedule_health_check(Keyword.get(opts, :health_check, @default_health_check), opts)
    {:ok, State.schedule_sweep(state, sweep_ref)}
  end

  defp initialize(_opts, _path, _retention_days, max_queue_size, max_queue_bytes) do
    {:stop, {:invalid_queue_limits, max_queue_size, max_queue_bytes}}
  end

  @spec admit_payload(
          :critical | :best_effort,
          String.t(),
          EventRecord.event_type(),
          map(),
          non_neg_integer(),
          GenServer.from(),
          State.t()
        ) :: {:reply, admission_result() | best_effort_admission_result(), State.t()}
  defp admit_payload(kind, session_id, event_type, payload, raw_bytes, from, state) do
    with :ok <- State.ensure_capacity(state, raw_bytes),
         {:ok, sanitized, payload_bytes} <- Payload.prepare(payload) do
      record = EventRecord.new(session_id, event_type, sanitized)
      admit(kind, record, payload_bytes, from, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec admit(
          :critical | :best_effort,
          EventRecord.t(),
          non_neg_integer(),
          GenServer.from(),
          State.t()
        ) :: {:reply, admission_result() | best_effort_admission_result(), State.t()}
  defp admit(kind, record, payload_bytes, from, state) do
    with :ok <- State.ensure_capacity(state, payload_bytes),
         :ok <- TouchedFiles.validate(record) do
      admit_validated(kind, record, payload_bytes, from, state)
    else
      {:error, :overloaded} -> {:reply, {:error, :overloaded}, state}
      {:error, {:invalid_file_edit, _field}} -> {:reply, {:error, :invalid_payload}, state}
    end
  end

  @spec admit_validated(
          :critical | :best_effort,
          EventRecord.t(),
          non_neg_integer(),
          GenServer.from(),
          State.t()
        ) :: {:reply, admission_result() | best_effort_admission_result(), State.t()}
  defp admit_validated(:critical, record, payload_bytes, {caller, _tag}, state) do
    receipt = make_ref()
    entry = Entry.critical(record, payload_bytes, receipt, caller)
    state = state |> State.enqueue(entry) |> dispatch_next()
    {:reply, {:queued, receipt}, state}
  end

  defp admit_validated(:best_effort, record, payload_bytes, _from, state) do
    entry = Entry.best_effort(record, payload_bytes)
    state = state |> State.enqueue(entry) |> dispatch_next()
    {:reply, :queued, state}
  end

  @spec dispatch_next(State.t()) :: State.t()
  defp dispatch_next(%State{writer: {:ready, writer, _ref}, in_flight: nil} = state) do
    dispatch_queued_entry(State.dequeue(state), writer)
  end

  defp dispatch_next(state), do: state

  @spec dispatch_queued_entry(
          {:empty, State.t()} | {:ok, State.entry(), State.t()},
          pid()
        ) :: State.t()
  defp dispatch_queued_entry({:empty, state}, writer) do
    dispatch_retention(state, state.pending_retention, writer)
  end

  defp dispatch_queued_entry({:ok, entry, state}, writer) do
    token = make_ref()
    send(writer, {:write_event, token, entry.record})
    State.start_event(state, token, entry)
  end

  @spec dispatch_retention(State.t(), boolean(), pid()) :: State.t()
  defp dispatch_retention(state, false, _writer), do: notify_idle_waiters(state)

  defp dispatch_retention(state, true, writer) do
    cutoff = DateTime.add(DateTime.utc_now(), -state.retention_days, :day)
    token = make_ref()
    send(writer, {:delete_before, token, cutoff})
    State.start_retention(state, token)
  end

  @spec acknowledge_entry(Entry.t(), EventRecord.event_type(), term()) :: :ok
  defp acknowledge_entry(
         %Entry{delivery: {:critical, receipt, caller}},
         event_type,
         {:ok, id}
       ) do
    send(caller, {:event_log_commit, receipt, event_type, {:persisted, id}})
    :ok
  end

  defp acknowledge_entry(
         %Entry{delivery: {:critical, receipt, caller}},
         event_type,
         {:error, reason}
       ) do
    send_persistence_failure(caller, receipt, event_type, reason)
  end

  defp acknowledge_entry(%Entry{delivery: :best_effort}, event_type, {:error, reason}) do
    Minga.Log.warning(
      :agent,
      "[AgentEventLog] best-effort #{event_type} persistence failed: #{inspect(reason)}"
    )
  end

  defp acknowledge_entry(%Entry{delivery: :best_effort}, _event_type, {:ok, _id}), do: :ok

  @spec send_persistence_failure(pid(), receipt(), EventRecord.event_type(), term()) :: :ok
  defp send_persistence_failure(caller, receipt, event_type, reason) do
    send(
      caller,
      {:event_log_commit, receipt, event_type, {:error, {:persistence_failed, reason}}}
    )

    :ok
  end

  @spec complete_writer_start(State.t(), [EventRecord.t()]) :: State.t()
  defp complete_writer_start(state, events) do
    case State.rebuild_touched_files(state, events) do
      {:ok, state} ->
        Minga.Log.info(:agent, "[AgentEventLog] started, logging to #{state.path}")
        state |> State.writer_ready() |> dispatch_next()

      {:error, reason} ->
        stop_writer(State.writer_pid(state))
        mark_writer_unavailable(state, {:reconstruction_failed, reason})
    end
  end

  @spec mark_writer_unavailable(State.t(), term()) :: State.t()
  defp mark_writer_unavailable(%State{writer: {phase, _writer, writer_ref}} = state, reason)
       when phase in [:opening, :ready] do
    Minga.Log.warning(:agent, "[AgentEventLog] failed to open database: #{inspect(reason)}")
    Process.demonitor(writer_ref, [:flush])

    state
    |> fail_all_events({:writer_start_failed, reason})
    |> State.writer_unavailable()
    |> schedule_writer_restart()
    |> notify_idle_waiters()
  end

  @spec finish_event(State.t(), State.entry(), EventRecord.event_type(), term()) :: State.t()
  defp finish_event(state, entry, event_type, {:ok, event_id}) do
    case State.record_persisted(state, entry.record, event_id) do
      {:ok, state} ->
        acknowledge_entry(entry, event_type, {:ok, event_id})
        state |> State.finish_in_flight() |> dispatch_next()

      {:error, reason} ->
        acknowledge_entry(entry, event_type, {:error, {:projection_failed, reason}})
        Minga.Log.error(:agent, "[AgentEventLog] projection failed: #{inspect(reason)}")
        state = State.finish_in_flight(state)
        stop_writer(State.writer_pid(state))
        mark_writer_unavailable(state, {:projection_failed, reason})
    end
  end

  defp finish_event(state, entry, event_type, {:error, _reason} = result) do
    acknowledge_entry(entry, event_type, result)
    state |> State.finish_in_flight() |> dispatch_next()
  end

  @spec finish_retention(State.t(), term()) :: State.t()
  defp finish_retention(state, {:ok, deleted_count, events}) do
    log_retention_result({:ok, deleted_count})

    case State.rebuild_touched_files(state, events) do
      {:ok, state} -> complete_retention(state)
      {:error, reason} -> fail_retention_projection(state, {:rebuild_failed, reason})
    end
  end

  defp finish_retention(state, {:error, {:delete_failed, reason}}) do
    log_retention_result({:error, reason})
    complete_retention(state)
  end

  defp finish_retention(state, {:error, {:reload_failed, reason}}) do
    fail_retention_projection(state, {:reload_failed, reason})
  end

  @spec complete_retention(State.t()) :: State.t()
  defp complete_retention(state) do
    state
    |> State.finish_in_flight()
    |> State.schedule_sweep(schedule_retention_sweep())
    |> dispatch_next()
  end

  @spec fail_retention_projection(State.t(), term()) :: State.t()
  defp fail_retention_projection(state, reason) do
    Minga.Log.error(:agent, "[AgentEventLog] retention projection failed: #{inspect(reason)}")
    stop_writer(State.writer_pid(state))

    state
    |> State.finish_in_flight()
    |> mark_writer_unavailable({:retention_projection_failed, reason})
    |> State.schedule_sweep(schedule_retention_sweep())
  end

  @spec handle_writer_down(State.t(), term()) :: State.t()
  defp handle_writer_down(%State{writer: {:ready, _writer, _ref}} = state, reason) do
    Minga.Log.warning(:agent, "[AgentEventLog] writer terminated: #{inspect(reason)}")

    state
    |> State.requeue_in_flight()
    |> State.writer_restarting()
    |> start_writer()
  end

  defp handle_writer_down(%State{writer: {:opening, _writer, _ref}} = state, reason) do
    Minga.Log.warning(:agent, "[AgentEventLog] writer failed to start: #{inspect(reason)}")

    state
    |> fail_all_events({:writer_start_failed, reason})
    |> State.writer_unavailable()
    |> schedule_writer_restart()
    |> notify_idle_waiters()
  end

  @spec fail_all_events(State.t(), term()) :: State.t()
  defp fail_all_events(state, reason) do
    Enum.each(outstanding_entries(state), &fail_entry(&1, reason))
    State.clear_event_work(state)
  end

  @spec outstanding_entries(State.t()) :: [State.entry()]
  defp outstanding_entries(%State{in_flight: {:event, _token, entry}} = state) do
    [entry | :queue.to_list(state.queue)]
  end

  defp outstanding_entries(state), do: :queue.to_list(state.queue)

  @spec fail_entry(Entry.t(), term()) :: :ok
  defp fail_entry(
         %Entry{delivery: {:critical, receipt, caller}, record: record},
         reason
       ) do
    send_persistence_failure(caller, receipt, record.event_type, reason)
  end

  defp fail_entry(%Entry{delivery: :best_effort}, _reason), do: :ok

  @spec start_writer(State.t()) :: State.t()
  defp start_writer(state) do
    opts = [path: state.path, backend: state.store_backend, backend_opts: state.writer_opts]

    case Writer.start(self(), opts) do
      {:ok, writer} ->
        State.writer_started(state, writer, Process.monitor(writer))

      {:error, reason} ->
        Minga.Log.warning(:agent, "[AgentEventLog] could not start writer: #{inspect(reason)}")

        state
        |> fail_all_events({:writer_start_failed, reason})
        |> State.writer_unavailable()
        |> schedule_writer_restart()
    end
  end

  @spec schedule_writer_restart(State.t()) :: State.t()
  defp schedule_writer_restart(state) do
    Process.send_after(self(), :restart_writer, state.restart_delay_ms)
    state
  end

  @spec notify_idle_waiters(State.t()) :: State.t()
  defp notify_idle_waiters(%State{idle_waiters: []} = state), do: state

  defp notify_idle_waiters(state) do
    Enum.each(state.idle_waiters, &GenServer.reply(&1, :ok))
    State.clear_idle_waiters(state)
  end

  @spec idle?(State.t()) :: boolean()
  defp idle?(state) do
    state.in_flight == nil and :queue.is_empty(state.queue) and not state.pending_retention
  end

  @spec await_idle_reply(State.t(), GenServer.from(), boolean()) ::
          {:reply, :ok, State.t()} | {:noreply, State.t()}
  defp await_idle_reply(state, _from, true), do: {:reply, :ok, state}

  defp await_idle_reply(state, from, false) do
    {:noreply, State.add_idle_waiter(state, from)}
  end

  @spec log_retention_result({:ok, non_neg_integer()} | {:error, term()}) :: :ok
  defp log_retention_result({:ok, 0}), do: :ok

  defp log_retention_result({:ok, count}) do
    Minga.Log.info(:agent, "[AgentEventLog] retention sweep deleted #{count} events")
  end

  defp log_retention_result({:error, reason}) do
    Minga.Log.warning(:agent, "[AgentEventLog] retention sweep failed: #{inspect(reason)}")
  end

  @spec schedule_initial_retention_sweep(keyword()) :: reference() | nil
  defp schedule_initial_retention_sweep(opts) do
    if Keyword.get(opts, :retention_sweep?, true) do
      Process.send_after(self(), :retention_sweep, @initial_retention_sweep_delay_ms)
    end
  end

  @spec schedule_retention_sweep() :: reference()
  defp schedule_retention_sweep do
    Process.send_after(self(), :retention_sweep, @retention_sweep_interval_ms)
  end

  @spec schedule_health_check(:none | :quick | :full, keyword()) :: :ok
  defp schedule_health_check(:none, _opts), do: :ok

  defp schedule_health_check(mode, opts) when mode in [:quick, :full] do
    parent = self()
    path = db_path(opts)

    Process.send_after(
      self(),
      {:run_health_check, parent, path, mode},
      Keyword.get(opts, :health_check_delay_ms, @health_check_delay_ms)
    )

    :ok
  end

  @spec run_health_check(String.t(), :quick | :full) :: :ok | {:error, term()}
  defp run_health_check(path, mode) do
    with {:ok, db} <- Store.open(path),
         result <- Store.integrity_check(db, mode),
         :ok <- Store.close(db) do
      case result do
        {:ok, :healthy} -> :ok
        {:error, messages} -> {:error, {:corrupt, messages}}
      end
    end
  end

  @spec handle_health_check_result(:ok | {:error, term()}, State.t()) :: {:noreply, State.t()}
  defp handle_health_check_result(:ok, state), do: {:noreply, state}

  defp handle_health_check_result({:error, reason}, state) do
    Minga.Log.warning(:agent, "[AgentEventLog] health check failed: #{inspect(reason)}")
    {:noreply, state}
  end

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  @spec stop_writer(pid() | nil) :: :ok
  defp stop_writer(nil), do: :ok

  defp stop_writer(writer) do
    Process.exit(writer, :shutdown)
    :ok
  end
end
