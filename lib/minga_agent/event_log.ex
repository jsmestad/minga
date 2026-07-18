defmodule MingaAgent.EventLog do
  @moduledoc """
  Bounded admission owner for the durable agent-session event log.

  `record/4` synchronously performs only queue admission. Accepted critical events receive a receipt and later deliver `{:event_log_commit, receipt, event_type, result}` to the admitting process. The result is `{:persisted, event_id}` only after SQLite reports the insert committed, or `{:error, {:persistence_failed, reason}}` when durability cannot be established.

  A separately monitored `MingaAgent.EventLog.Writer` owns the SQLite connection and executes inserts and retention serially. SQLite stalls therefore do not prevent EventLog from admitting work up to its configured bound or rejecting excess work explicitly.
  """

  use GenServer

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.State
  alias MingaAgent.EventLog.Store
  alias MingaAgent.EventLog.TouchedFiles
  alias MingaAgent.EventLog.Writer

  @default_db_dir Path.expand("~/.local/share/minga")
  @db_filename "agent_events.db"
  @default_max_queue_size 1_000
  @default_max_queue_bytes 8 * 1024 * 1024
  @max_event_bytes 256 * 1024
  @max_payload_depth 64
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
    with {:ok, raw_bytes} <- bounded_raw_payload_size(payload) do
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
    with {:ok, raw_bytes} <- bounded_raw_payload_size(payload) do
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
        %State{
          status: :unavailable
        } = state
      ) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call(
        {:admit_payload, kind, session_id, event_type, payload, raw_bytes},
        from,
        state
      ) do
    admit_payload(
      kind,
      session_id,
      event_type,
      payload,
      raw_bytes,
      from,
      state,
      State.admission_available?(state, raw_bytes)
    )
  end

  def handle_call(
        {:admit, _kind, _record, _payload_bytes},
        _from,
        %State{status: :unavailable} = state
      ) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:admit, kind, record, payload_bytes}, from, state) do
    admit(
      kind,
      record,
      payload_bytes,
      from,
      state,
      State.admission_available?(state, payload_bytes)
    )
  end

  def handle_call({:touched_files, session_id}, _from, %State{status: :ready} = state) do
    {:reply, {:ok, State.touched_files(state, session_id)}, state}
  end

  def handle_call({:touched_files, _session_id}, _from, state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call(:await_idle, from, state) do
    await_idle_reply(state, from, idle?(state))
  end

  def handle_call(:restart_writer, _from, %State{status: :unavailable} = state) do
    new_state = state |> State.clear_writer(:starting) |> start_writer()
    reply = if new_state.status == :unavailable, do: {:error, :unavailable}, else: :ok
    {:reply, reply, new_state}
  end

  def handle_call(:restart_writer, _from, state), do: {:reply, :ok, state}
  def handle_call(:writer_pid, _from, state), do: {:reply, state.writer, state}

  @impl GenServer
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()}
  def handle_info({:event_log_writer_ready, writer, events}, %{writer: writer} = state) do
    {:noreply, complete_writer_start(state, events)}
  end

  def handle_info({:event_log_writer_unavailable, writer, reason}, %{writer: writer} = state) do
    {:noreply, mark_writer_unavailable(state, reason)}
  end

  def handle_info(
        {:event_log_writer_result, writer, token, event_type, result},
        %{writer: writer, in_flight: {:event, token, entry}} = state
      ) do
    {:noreply, finish_event(state, entry, event_type, result)}
  end

  def handle_info(
        {:event_log_retention_result, writer, token, result},
        %{writer: writer, in_flight: {:retention, token, cutoff}} = state
      ) do
    {:noreply, finish_retention(state, cutoff, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, writer, reason},
        %{writer_ref: ref, writer: writer} = state
      ) do
    {:noreply, handle_writer_down(state, reason)}
  end

  def handle_info({:EXIT, _writer, _reason}, state), do: {:noreply, state}

  def handle_info(:restart_writer, %State{status: :unavailable} = state) do
    {:noreply, state |> State.clear_writer(:starting) |> start_writer()}
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
    stop_writer(state.writer)
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
          State.t(),
          boolean()
        ) :: {:reply, admission_result() | best_effort_admission_result(), State.t()}
  defp admit_payload(
         _kind,
         _session_id,
         _event_type,
         _payload,
         _raw_bytes,
         _from,
         state,
         false
       ),
       do: {:reply, {:error, :overloaded}, state}

  defp admit_payload(kind, session_id, event_type, payload, _raw_bytes, from, state, true) do
    with {:ok, sanitized, payload_bytes} <- prepare_payload(payload),
         true <- State.admission_available?(state, payload_bytes) do
      record = EventRecord.new(session_id, event_type, sanitized)
      admit(kind, record, payload_bytes, from, state, true)
    else
      false -> {:reply, {:error, :overloaded}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec admit(
          :critical | :best_effort,
          EventRecord.t(),
          non_neg_integer(),
          GenServer.from(),
          State.t(),
          boolean()
        ) :: {:reply, admission_result() | best_effort_admission_result(), State.t()}
  defp admit(_kind, _record, _payload_bytes, _from, state, false),
    do: {:reply, {:error, :overloaded}, state}

  defp admit(kind, record, payload_bytes, from, state, true) do
    admit_validated(
      kind,
      record,
      payload_bytes,
      from,
      state,
      TouchedFiles.validate(record)
    )
  end

  @spec admit_validated(
          :critical | :best_effort,
          EventRecord.t(),
          non_neg_integer(),
          GenServer.from(),
          State.t(),
          :ok | {:error, TouchedFiles.rejection()}
        ) :: {:reply, admission_result() | best_effort_admission_result(), State.t()}
  defp admit_validated(_kind, _record, _payload_bytes, _from, state, {:error, _reason}) do
    {:reply, {:error, :invalid_payload}, state}
  end

  defp admit_validated(:critical, record, payload_bytes, {caller, _tag}, state, :ok) do
    receipt = make_ref()
    entry = {:critical, receipt, caller, record.event_type, payload_bytes, record}
    state = state |> State.enqueue(entry) |> dispatch_next()
    {:reply, {:queued, receipt}, state}
  end

  defp admit_validated(:best_effort, record, payload_bytes, _from, state, :ok) do
    entry = {:best_effort, record.event_type, payload_bytes, record}
    state = state |> State.enqueue(entry) |> dispatch_next()
    {:reply, :queued, state}
  end

  @spec dispatch_next(State.t()) :: State.t()
  defp dispatch_next(%State{status: :ready, in_flight: nil} = state) do
    dispatch_queued_entry(State.dequeue(state))
  end

  defp dispatch_next(state), do: state

  @spec dispatch_queued_entry({:empty, State.t()} | {:ok, State.entry(), State.t()}) :: State.t()
  defp dispatch_queued_entry({:empty, state}) do
    dispatch_retention(state, state.pending_retention)
  end

  defp dispatch_queued_entry({:ok, entry, state}) do
    token = make_ref()
    record = entry_record(entry)
    send(state.writer, {:write_event, token, record})
    State.start_event(state, token, entry)
  end

  @spec dispatch_retention(State.t(), boolean()) :: State.t()
  defp dispatch_retention(state, false), do: notify_idle_waiters(state)

  defp dispatch_retention(state, true) do
    cutoff = DateTime.add(DateTime.utc_now(), -state.retention_days, :day)
    token = make_ref()
    send(state.writer, {:delete_before, token, cutoff})
    State.start_retention(state, token, cutoff)
  end

  @spec entry_record(State.entry()) :: EventRecord.t()
  defp entry_record({:critical, _receipt, _caller, _event_type, _bytes, record}), do: record
  defp entry_record({:best_effort, _event_type, _bytes, record}), do: record

  @spec acknowledge_entry(State.entry(), EventRecord.event_type(), term()) :: :ok
  defp acknowledge_entry(
         {:critical, receipt, caller, _type, _bytes, _record},
         event_type,
         {:ok, id}
       ) do
    send(caller, {:event_log_commit, receipt, event_type, {:persisted, id}})
    :ok
  end

  defp acknowledge_entry(
         {:critical, receipt, caller, _type, _bytes, _record},
         event_type,
         {:error, reason}
       ) do
    send_persistence_failure(caller, receipt, event_type, reason)
  end

  defp acknowledge_entry({:best_effort, _type, _bytes, _record}, event_type, {:error, reason}) do
    Minga.Log.warning(
      :agent,
      "[AgentEventLog] best-effort #{event_type} persistence failed: #{inspect(reason)}"
    )
  end

  defp acknowledge_entry({:best_effort, _type, _bytes, _record}, _event_type, {:ok, _id}),
    do: :ok

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
        stop_writer(state.writer)
        mark_writer_unavailable(state, {:reconstruction_failed, reason})
    end
  end

  @spec mark_writer_unavailable(State.t(), term()) :: State.t()
  defp mark_writer_unavailable(state, reason) do
    Minga.Log.warning(:agent, "[AgentEventLog] failed to open database: #{inspect(reason)}")
    Process.demonitor(state.writer_ref, [:flush])

    state
    |> fail_all_events({:writer_start_failed, reason})
    |> State.clear_writer(:unavailable)
    |> schedule_writer_restart()
    |> notify_idle_waiters()
  end

  @spec finish_event(State.t(), State.entry(), EventRecord.event_type(), term()) :: State.t()
  defp finish_event(state, entry, event_type, {:ok, event_id}) do
    case State.record_persisted(state, entry_record(entry), event_id) do
      {:ok, state} ->
        acknowledge_entry(entry, event_type, {:ok, event_id})
        state |> State.finish_in_flight() |> dispatch_next()

      {:error, reason} ->
        acknowledge_entry(entry, event_type, {:error, {:projection_failed, reason}})
        Minga.Log.error(:agent, "[AgentEventLog] projection failed: #{inspect(reason)}")
        state = State.finish_in_flight(state)
        stop_writer(state.writer)
        mark_writer_unavailable(state, {:projection_failed, reason})
    end
  end

  defp finish_event(state, entry, event_type, {:error, _reason} = result) do
    acknowledge_entry(entry, event_type, result)
    state |> State.finish_in_flight() |> dispatch_next()
  end

  @spec finish_retention(State.t(), DateTime.t(), term()) :: State.t()
  defp finish_retention(state, _cutoff, {:ok, deleted_count, events}) do
    log_retention_result({:ok, deleted_count})

    case State.rebuild_touched_files(state, events) do
      {:ok, state} -> complete_retention(state)
      {:error, reason} -> fail_retention_projection(state, {:rebuild_failed, reason})
    end
  end

  defp finish_retention(state, _cutoff, {:error, {:delete_failed, reason}}) do
    log_retention_result({:error, reason})
    complete_retention(state)
  end

  defp finish_retention(state, _cutoff, {:error, {:reload_failed, reason}}) do
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
    stop_writer(state.writer)

    state
    |> State.finish_in_flight()
    |> mark_writer_unavailable({:retention_projection_failed, reason})
    |> State.schedule_sweep(schedule_retention_sweep())
  end

  @spec handle_writer_down(State.t(), term()) :: State.t()
  defp handle_writer_down(%State{status: :ready} = state, reason) do
    Minga.Log.warning(:agent, "[AgentEventLog] writer terminated: #{inspect(reason)}")

    state
    |> State.requeue_in_flight()
    |> State.clear_writer(:starting)
    |> start_writer()
  end

  defp handle_writer_down(%State{status: :starting} = state, reason) do
    Minga.Log.warning(:agent, "[AgentEventLog] writer failed to start: #{inspect(reason)}")

    state
    |> fail_all_events({:writer_start_failed, reason})
    |> State.clear_writer(:unavailable)
    |> schedule_writer_restart()
    |> notify_idle_waiters()
  end

  defp handle_writer_down(state, _reason), do: State.clear_writer(state, :unavailable)

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

  @spec fail_entry(State.entry(), term()) :: :ok
  defp fail_entry({:critical, receipt, caller, event_type, _bytes, _record}, reason) do
    send_persistence_failure(caller, receipt, event_type, reason)
  end

  defp fail_entry({:best_effort, _event_type, _bytes, _record}, _reason), do: :ok

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
        |> State.clear_writer(:unavailable)
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

  @secret_keys MapSet.new(
                 ~w(api_key apikey token access_token refresh_token secret password credential credentials authorization remote_token)
               )

  @spec bounded_raw_payload_size(map()) ::
          {:ok, non_neg_integer()} | {:error, :payload_too_large | :invalid_payload}
  defp bounded_raw_payload_size(payload) do
    with {:ok, raw_bytes} <- external_payload_size(payload),
         :ok <- enforce_event_size(raw_bytes) do
      {:ok, raw_bytes}
    else
      {:error, :payload_too_large} = error -> error
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  @spec prepare_payload(map()) ::
          {:ok, map(), non_neg_integer()} | {:error, :payload_too_large | :invalid_payload}
  defp prepare_payload(payload) do
    with {:ok, sanitized} <- sanitize_payload(payload, 0),
         {:ok, encoded_bytes} <- encoded_payload_size(sanitized),
         :ok <- enforce_event_size(encoded_bytes) do
      {:ok, sanitized, encoded_bytes}
    else
      {:error, :payload_too_large} = error -> error
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  @spec external_payload_size(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp external_payload_size(payload) do
    {:ok, :erlang.external_size(payload)}
  rescue
    _exception -> {:error, :invalid_external_term}
  end

  @spec encoded_payload_size(map()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp encoded_payload_size(payload) do
    {:ok, payload |> JSON.encode!() |> byte_size()}
  rescue
    _exception -> {:error, :not_json_encodable}
  end

  @spec enforce_event_size(non_neg_integer()) :: :ok | {:error, :payload_too_large}
  defp enforce_event_size(bytes) when bytes <= @max_event_bytes, do: :ok
  defp enforce_event_size(_bytes), do: {:error, :payload_too_large}

  @spec sanitize_payload(term(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  defp sanitize_payload(_payload, depth) when depth > @max_payload_depth,
    do: {:error, :payload_too_deep}

  defp sanitize_payload(%_{} = struct, depth),
    do: sanitize_payload(Map.from_struct(struct), depth + 1)

  defp sanitize_payload(map, depth) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, sanitized_map} ->
      with {:ok, string_key} <- sanitize_key(key),
           {:ok, sanitized} <- sanitize_value(string_key, value, depth) do
        {:cont, {:ok, Map.put(sanitized_map, string_key, sanitized)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp sanitize_payload(list, depth) when is_list(list), do: sanitize_list(list, depth, [])
  defp sanitize_payload(pid, _depth) when is_pid(pid), do: {:ok, "[PID]"}
  defp sanitize_payload(ref, _depth) when is_reference(ref), do: {:ok, "[REFERENCE]"}
  defp sanitize_payload(boolean, _depth) when is_boolean(boolean), do: {:ok, boolean}
  defp sanitize_payload(nil, _depth), do: {:ok, nil}
  defp sanitize_payload(atom, _depth) when is_atom(atom), do: {:ok, Atom.to_string(atom)}

  defp sanitize_payload(binary, _depth) when is_binary(binary) do
    if String.valid?(binary), do: {:ok, binary}, else: {:error, :invalid_utf8}
  end

  defp sanitize_payload(number, _depth) when is_number(number), do: {:ok, number}
  defp sanitize_payload(_other, _depth), do: {:error, :unsupported_payload_type}

  @spec sanitize_list(term(), non_neg_integer(), [term()]) ::
          {:ok, [term()]} | {:error, term()}
  defp sanitize_list([], _depth, acc), do: {:ok, Enum.reverse(acc)}

  defp sanitize_list([value | rest], depth, acc) do
    case sanitize_payload(value, depth + 1) do
      {:ok, sanitized} -> sanitize_list(rest, depth, [sanitized | acc])
      {:error, _reason} = error -> error
    end
  end

  defp sanitize_list(_improper_tail, _depth, _acc), do: {:error, :improper_list}

  @spec sanitize_key(term()) :: {:ok, String.t()} | {:error, term()}
  defp sanitize_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: {:error, :invalid_utf8_key}
  end

  defp sanitize_key(key) when is_atom(key) or is_number(key), do: {:ok, to_string(key)}
  defp sanitize_key(_key), do: {:error, :unsupported_map_key}

  @spec sanitize_value(String.t(), term(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  defp sanitize_value(key, value, depth) do
    if secret_key?(key) do
      {:ok, "[REDACTED]"}
    else
      sanitize_payload(value, depth + 1)
    end
  end

  @spec secret_key?(String.t()) :: boolean()
  defp secret_key?(key) do
    normalized = normalize_secret_key(key)

    MapSet.member?(@secret_keys, normalized) or
      String.ends_with?(normalized, "_token") or
      String.ends_with?(normalized, "_secret") or
      String.contains?(normalized, "api_key") or
      String.contains?(normalized, "password") or
      String.contains?(normalized, "credential") or
      String.contains?(normalized, "authorization")
  end

  @spec normalize_secret_key(String.t()) :: String.t()
  defp normalize_secret_key(key) do
    key
    |> Macro.underscore()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
