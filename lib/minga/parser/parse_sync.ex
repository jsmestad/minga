defmodule Minga.Parser.ParseSync do
  @moduledoc """
  Parser synchronization and global parse-admission transitions.

  Functions accept only the relevant aggregate values and return typed results.
  The manager installs those aggregates and owns Port recovery after write failure.
  """

  alias Minga.Buffer
  alias Minga.Buffer.SyncSnapshot
  alias Minga.Parser.BufferConfig
  alias Minga.Parser.BufferRegistration
  alias Minga.Parser.BufferRegistry
  alias Minga.Parser.ParseScheduler
  alias Minga.Parser.PortLifecycle
  alias Minga.Parser.Protocol
  alias Minga.Parser.RequestHandler
  alias Minga.Parser.RequestState

  @parse_admission_timeout_ms 10_000

  @type result ::
          {:ok, BufferRegistry.t(), ParseScheduler.t(), RequestState.t()}
          | {:port_write_failed, BufferRegistry.t(), ParseScheduler.t(), RequestState.t()}
  @type completion_result ::
          {:ok, BufferRegistry.t(), ParseScheduler.t(), RequestState.t(), BufferRegistration.t()}
          | {:port_write_failed, BufferRegistry.t(), ParseScheduler.t(), RequestState.t()}
          | :stale
  @type timeout_result ::
          :ok | {:drop_buffer, RequestState.t()} | :restart_port

  @doc "Forces a full parse for a registered buffer."
  @spec force_parse(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid()
        ) :: result()
  def force_parse(port, buffers, scheduler, requests, buffer_pid) do
    case BufferRegistry.fetch(buffers, buffer_pid) do
      {:ok, registration} ->
        buffers =
          BufferRegistry.put(buffers, buffer_pid, BufferRegistration.restart(registration))

        scheduler = ParseScheduler.release(scheduler, buffer_pid)
        pump(port, buffers, scheduler, requests, buffer_pid)

      :error ->
        ok(buffers, scheduler, requests)
    end
  end

  @doc "Marks a registered buffer dirty and pumps synchronization."
  @spec mark_dirty(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid(),
          non_neg_integer()
        ) :: result()
  def mark_dirty(port, buffers, scheduler, requests, buffer_pid, sequence) do
    case BufferRegistry.fetch(buffers, buffer_pid) do
      {:ok, registration} ->
        buffers =
          buffers
          |> BufferRegistry.put(buffer_pid, BufferRegistration.mark_dirty(registration, sequence))
          |> BufferRegistry.touch(buffer_pid, monotonic_ms())

        pump(port, buffers, scheduler, requests, buffer_pid)

      :error ->
        ok(buffers, scheduler, requests)
    end
  end

  @doc "Queues a pumpable buffer and dispatches parser admission."
  @spec pump(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid()
        ) :: result()
  def pump(nil, buffers, scheduler, requests, _buffer_pid), do: ok(buffers, scheduler, requests)

  def pump(port, buffers, scheduler, requests, buffer_pid) do
    case BufferRegistry.fetch(buffers, buffer_pid) do
      {:ok, registration} ->
        enqueue_pumpable(port, buffers, scheduler, requests, buffer_pid, registration)

      :error ->
        ok(buffers, scheduler, requests)
    end
  end

  @doc "Activates the next queued parse synchronization operation."
  @spec dispatch_next(port() | nil, BufferRegistry.t(), ParseScheduler.t(), RequestState.t()) ::
          result()
  def dispatch_next(nil, buffers, scheduler, requests), do: ok(buffers, scheduler, requests)

  def dispatch_next(port, buffers, scheduler, requests) do
    case ParseScheduler.activate_next(scheduler) do
      {:ok, buffer_pid, scheduler} ->
        dispatch_activated(port, buffers, scheduler, requests, buffer_pid)

      :busy ->
        ok(buffers, scheduler, requests)

      :empty ->
        ok(buffers, scheduler, requests)
    end
  end

  @doc "Consumes an editor buffer synchronization snapshot."
  @spec handle_snapshot(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          SyncSnapshot.t()
        ) :: result()
  def handle_snapshot(
        port,
        buffers,
        scheduler,
        requests,
        %SyncSnapshot{
          buffer: buffer_pid,
          token: token
        } = snapshot
      ) do
    case BufferRegistry.fetch(buffers, buffer_pid) do
      {:ok, registration} ->
        if BufferRegistration.awaiting?(registration, token) do
          apply_snapshot(port, buffers, scheduler, requests, buffer_pid, registration, snapshot)
        else
          ok(buffers, scheduler, requests)
        end

      :error ->
        ok(buffers, scheduler, requests)
    end
  end

  @doc "Completes a matching parser version, flushes requests, and continues pumping."
  @spec complete_parse(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid(),
          pos_integer()
        ) :: completion_result()
  def complete_parse(port, buffers, scheduler, requests, buffer_pid, version) do
    with {:ok, registration} <- BufferRegistry.fetch(buffers, buffer_pid),
         {:ok, completed} <- BufferRegistration.complete_parse(registration, version) do
      buffers = BufferRegistry.put(buffers, buffer_pid, completed)
      {scheduler, requests} = release_and_flush(port, scheduler, requests, buffers, buffer_pid)

      continue_completed_parse(port, buffers, scheduler, requests, buffer_pid, completed)
    else
      _stale_or_missing -> :stale
    end
  end

  @spec continue_completed_parse(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid(),
          BufferRegistration.t()
        ) :: completion_result()
  defp continue_completed_parse(port, buffers, scheduler, requests, buffer_pid, completed) do
    with {:ok, buffers, scheduler, requests} <-
           pump(port, buffers, scheduler, requests, buffer_pid),
         {:ok, buffers, scheduler, requests} <-
           dispatch_next(port, buffers, scheduler, requests) do
      {:ok, buffers, scheduler, requests, completed}
    end
  end

  @doc "Classifies an admission timeout without conflating snapshot and parser failures."
  @spec handle_timeout(ParseScheduler.t(), RequestState.t(), pid(), term()) :: timeout_result()
  def handle_timeout(scheduler, requests, buffer_pid, {:snapshot, _ref} = token) do
    if ParseScheduler.timeout?(scheduler, buffer_pid, token) do
      Minga.Log.warning(
        :port,
        "Parser: snapshot timed out for #{inspect(buffer_pid)}; dropping buffer"
      )

      {:drop_buffer, RequestHandler.fail_buffer(requests, buffer_pid)}
    else
      :ok
    end
  end

  def handle_timeout(scheduler, _requests, buffer_pid, {:parse, _ref} = token) do
    if ParseScheduler.timeout?(scheduler, buffer_pid, token) do
      Minga.Log.error(:port, "Parser: parse timed out for #{inspect(buffer_pid)}; restarting")
      :restart_port
    else
      :ok
    end
  end

  @doc "Cancels active admission and clears all queued parse work."
  @spec reset_admission(ParseScheduler.t()) :: ParseScheduler.t()
  def reset_admission(scheduler) do
    cancel_admission_timer(scheduler)
    ParseScheduler.reset(scheduler)
  end

  @doc "Marks every registration for a fresh full snapshot and restarts pumps."
  @spec restart_pumps(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t()
        ) :: result()
  def restart_pumps(port, buffers, scheduler, requests) do
    buffer_count = BufferRegistry.count(buffers)

    if buffer_count > 0 do
      Minga.Log.info(:port, "Parser: re-syncing #{buffer_count} buffer(s)")
    end

    buffers = BufferRegistry.restart_all(buffers)
    scheduler = reset_admission(scheduler)

    buffers
    |> BufferRegistry.entries()
    |> Map.keys()
    |> Enum.reduce_while(ok(buffers, scheduler, requests), fn buffer_pid, {:ok, b, s, r} ->
      case pump(port, b, s, r, buffer_pid) do
        {:ok, _b, _s, _r} = result -> {:cont, result}
        failed -> {:halt, failed}
      end
    end)
  end

  @doc "Builds parser setup commands for a registered buffer configuration."
  @spec setup_commands(pos_integer(), BufferConfig.t()) :: [binary()]
  def setup_commands(buffer_id, %BufferConfig{} = config) do
    [Protocol.encode_set_language(buffer_id, config.language)]
    |> append_query(config.highlight_query, &Protocol.encode_set_highlight_query(buffer_id, &1))
    |> append_query(config.injection_query, &Protocol.encode_set_injection_query(buffer_id, &1))
    |> append_query(config.fold_query, &Protocol.encode_set_fold_query(buffer_id, &1))
    |> append_query(config.textobject_query, &Protocol.encode_set_textobject_query(buffer_id, &1))
    |> append_query(config.tags_query, &Protocol.encode_set_tags_query(buffer_id, &1))
  end

  @spec enqueue_pumpable(
          port(),
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid(),
          BufferRegistration.t()
        ) :: result()
  defp enqueue_pumpable(port, buffers, scheduler, requests, buffer_pid, registration) do
    if BufferRegistration.pumpable?(registration) do
      dispatch_next(port, buffers, ParseScheduler.enqueue(scheduler, buffer_pid), requests)
    else
      ok(buffers, scheduler, requests)
    end
  end

  @spec dispatch_activated(
          port(),
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid()
        ) :: result()
  defp dispatch_activated(port, buffers, scheduler, requests, buffer_pid) do
    case BufferRegistry.fetch(buffers, buffer_pid) do
      {:ok, registration} ->
        if BufferRegistration.pumpable?(registration) do
          request_snapshot(buffers, scheduler, requests, buffer_pid, registration)
        else
          continue_dispatch(port, buffers, scheduler, requests, buffer_pid)
        end

      :error ->
        continue_dispatch(port, buffers, scheduler, requests, buffer_pid)
    end
  end

  @spec continue_dispatch(
          port(),
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid()
        ) :: result()
  defp continue_dispatch(port, buffers, scheduler, requests, buffer_pid) do
    scheduler = release_admission(scheduler, buffer_pid)
    dispatch_next(port, buffers, scheduler, requests)
  end

  @spec request_snapshot(
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid(),
          BufferRegistration.t()
        ) :: result()
  defp request_snapshot(buffers, scheduler, requests, buffer_pid, registration) do
    token = make_ref()
    cursor = BufferRegistration.snapshot_cursor(registration)

    buffers =
      BufferRegistry.put(
        buffers,
        buffer_pid,
        BufferRegistration.await_snapshot(registration, token)
      )

    :ok = Buffer.request_sync_snapshot(buffer_pid, cursor, self(), token)
    scheduler = arm_admission_timeout(scheduler, buffer_pid, {:snapshot, token})
    ok(buffers, scheduler, requests)
  end

  @spec apply_snapshot(
          port() | nil,
          BufferRegistry.t(),
          ParseScheduler.t(),
          RequestState.t(),
          pid(),
          BufferRegistration.t(),
          SyncSnapshot.t()
        ) :: result()
  defp apply_snapshot(port, buffers, scheduler, requests, buffer_pid, registration, %SyncSnapshot{
         changes: :unchanged,
         sequence: sequence
       }) do
    buffers =
      BufferRegistry.put(
        buffers,
        buffer_pid,
        BufferRegistration.complete_unchanged(registration, sequence)
      )

    {scheduler, requests} = release_and_flush(port, scheduler, requests, buffers, buffer_pid)

    with {:ok, buffers, scheduler, requests} <-
           pump(port, buffers, scheduler, requests, buffer_pid) do
      dispatch_next(port, buffers, scheduler, requests)
    end
  end

  defp apply_snapshot(nil, buffers, scheduler, requests, buffer_pid, registration, _snapshot) do
    buffers = BufferRegistry.put(buffers, buffer_pid, BufferRegistration.restart(registration))
    ok(buffers, release_admission(scheduler, buffer_pid), requests)
  end

  defp apply_snapshot(port, buffers, scheduler, requests, buffer_pid, registration, snapshot) do
    {version, buffers} = BufferRegistry.next_parse_version(buffers)
    commands = snapshot_commands(registration, version, snapshot.changes)
    full? = match?({:full, _content}, snapshot.changes)

    if PortLifecycle.send_batch(port, commands) do
      parsing = BufferRegistration.begin_parse(registration, version, snapshot.sequence, full?)
      buffers = BufferRegistry.put(buffers, buffer_pid, parsing)
      scheduler = arm_admission_timeout(scheduler, buffer_pid, {:parse, make_ref()})
      ok(buffers, scheduler, requests)
    else
      Minga.Log.warning(:port, "Parser: parse write failed; scheduling restart")
      buffers = BufferRegistry.put(buffers, buffer_pid, BufferRegistration.restart(registration))
      {:port_write_failed, buffers, reset_admission(scheduler), requests}
    end
  end

  @spec release_and_flush(
          port() | nil,
          ParseScheduler.t(),
          RequestState.t(),
          BufferRegistry.t(),
          pid()
        ) :: {ParseScheduler.t(), RequestState.t()}
  defp release_and_flush(port, scheduler, requests, buffers, buffer_pid) do
    scheduler = release_admission(scheduler, buffer_pid)
    requests = RequestHandler.flush_buffer(port, requests, buffers, buffer_pid)
    {scheduler, requests}
  end

  @spec snapshot_commands(BufferRegistration.t(), pos_integer(), SyncSnapshot.changes()) :: [
          binary()
        ]
  defp snapshot_commands(registration, version, {:full, content}) do
    parse = Protocol.encode_parse_buffer(registration.id, version, content)

    if registration.force_full? do
      List.insert_at(setup_commands(registration.id, registration.config), -1, parse)
    else
      [parse]
    end
  end

  defp snapshot_commands(registration, version, {:edits, edits}) do
    encoded_edits = Enum.map(edits, &Map.from_struct/1)
    [Protocol.encode_edit_buffer(registration.id, version, encoded_edits)]
  end

  @spec append_query([binary()], String.t() | nil, (String.t() -> binary())) :: [binary()]
  defp append_query(commands, nil, _encoder), do: commands
  defp append_query(commands, query, encoder), do: List.insert_at(commands, -1, encoder.(query))

  @spec arm_admission_timeout(ParseScheduler.t(), pid(), term()) :: ParseScheduler.t()
  defp arm_admission_timeout(scheduler, buffer_pid, token) do
    cancel_admission_timer(scheduler)

    timer_ref =
      Process.send_after(
        self(),
        {:parse_admission_timeout, buffer_pid, token},
        @parse_admission_timeout_ms
      )

    ParseScheduler.arm_timeout(scheduler, token, timer_ref)
  end

  @spec release_admission(ParseScheduler.t(), pid()) :: ParseScheduler.t()
  defp release_admission(scheduler, buffer_pid) do
    if ParseScheduler.active?(scheduler, buffer_pid) do
      cancel_admission_timer(scheduler)
      ParseScheduler.release(scheduler, buffer_pid)
    else
      scheduler
    end
  end

  @spec cancel_admission_timer(ParseScheduler.t()) :: :ok
  defp cancel_admission_timer(scheduler) do
    case ParseScheduler.timeout_ref(scheduler) do
      nil ->
        :ok

      timer_ref ->
        Process.cancel_timer(timer_ref)
        :ok
    end
  end

  @spec ok(BufferRegistry.t(), ParseScheduler.t(), RequestState.t()) :: result()
  defp ok(buffers, scheduler, requests), do: {:ok, buffers, scheduler, requests}

  @spec monotonic_ms() :: integer()
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
