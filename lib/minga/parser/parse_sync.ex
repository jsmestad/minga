defmodule Minga.Parser.ParseSync do
  @moduledoc """
  Editor-buffer synchronization work: registrations, global admission, and
  sequence-fenced requests. Workflows run in the manager process; the port
  stays explicit and the manager owns recovery after write failure.
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

  defstruct buffers: BufferRegistry.new(),
            scheduler: ParseScheduler.new(),
            requests: RequestState.new()

  @type t :: %__MODULE__{
          buffers: BufferRegistry.t(),
          scheduler: ParseScheduler.t(),
          requests: RequestState.t()
        }
  @type snapshot_result :: t() | {:port_write_failed, t()}
  @type completion_result :: {:ok, t(), BufferRegistration.t()} | :stale
  @type timeout_result :: :ok | :drop_buffer | :restart_port

  @doc "Installs the registry returned by a buffer lifecycle operation."
  @spec put_buffers(t(), BufferRegistry.t()) :: t()
  def put_buffers(work, buffers), do: %{work | buffers: buffers}

  @doc "Installs the request state returned by a request operation."
  @spec put_requests(t(), RequestState.t()) :: t()
  def put_requests(work, requests), do: %{work | requests: requests}

  @doc "Releases admission for a buffer whose registration was removed or reset."
  @spec release_buffer(t(), pid()) :: t()
  def release_buffer(work, buffer_pid) do
    %{work | scheduler: ParseScheduler.release(work.scheduler, buffer_pid)}
  end

  @doc "Forces a full parse for a registered buffer."
  @spec force_parse(t(), port() | nil, pid()) :: t()
  def force_parse(work, port, buffer_pid) do
    case BufferRegistry.fetch(work.buffers, buffer_pid) do
      {:ok, registration} ->
        work
        |> put_registration(buffer_pid, BufferRegistration.restart(registration))
        |> release_buffer(buffer_pid)
        |> pump(port, buffer_pid)

      :error ->
        work
    end
  end

  @doc "Marks a registered buffer dirty and pumps synchronization."
  @spec mark_dirty(t(), port() | nil, pid(), non_neg_integer()) :: t()
  def mark_dirty(work, port, buffer_pid, sequence) do
    case BufferRegistry.fetch(work.buffers, buffer_pid) do
      {:ok, registration} ->
        buffers =
          work.buffers
          |> BufferRegistry.put(buffer_pid, BufferRegistration.mark_dirty(registration, sequence))
          |> BufferRegistry.touch(buffer_pid, monotonic_ms())

        pump(%{work | buffers: buffers}, port, buffer_pid)

      :error ->
        work
    end
  end

  @doc "Queues a pumpable buffer and dispatches parser admission."
  @spec pump(t(), port() | nil, pid()) :: t()
  def pump(work, nil, _buffer_pid), do: work

  def pump(work, port, buffer_pid) do
    case pumpable_registration(work, buffer_pid) do
      %BufferRegistration{} ->
        scheduler = ParseScheduler.enqueue(work.scheduler, buffer_pid)
        dispatch_next(%{work | scheduler: scheduler}, port)

      nil ->
        work
    end
  end

  @doc "Activates the next queued parse synchronization operation."
  @spec dispatch_next(t(), port() | nil) :: t()
  def dispatch_next(work, nil), do: work

  def dispatch_next(work, port) do
    case ParseScheduler.activate_next(work.scheduler) do
      {:ok, buffer_pid, scheduler} ->
        dispatch_activated(%{work | scheduler: scheduler}, port, buffer_pid)

      :busy ->
        work

      :empty ->
        work
    end
  end

  @doc "Consumes an editor buffer synchronization snapshot."
  @spec handle_snapshot(t(), port() | nil, SyncSnapshot.t()) :: snapshot_result()
  def handle_snapshot(work, port, %SyncSnapshot{} = snapshot) do
    case RequestHandler.handle_snapshot(work.requests, work.buffers, snapshot) do
      {:handled, requests, buffers, buffer_pid} ->
        %{work | requests: requests, buffers: buffers}
        |> pump(port, buffer_pid)
        |> flush_buffer(port, buffer_pid)

      :unhandled ->
        handle_admitted_snapshot(work, port, snapshot)
    end
  end

  @spec handle_admitted_snapshot(t(), port() | nil, SyncSnapshot.t()) :: snapshot_result()
  defp handle_admitted_snapshot(
         work,
         port,
         %SyncSnapshot{buffer: buffer_pid, token: token} = snapshot
       ) do
    case BufferRegistry.fetch(work.buffers, buffer_pid) do
      {:ok, %BufferRegistration{phase: {:awaiting_snapshot, ^token}} = registration} ->
        apply_snapshot(work, port, buffer_pid, registration, snapshot)

      _stale_or_missing ->
        work
    end
  end

  @doc "Completes a matching parser version, flushes requests, and continues pumping."
  @spec complete_parse(t(), port() | nil, pid(), pos_integer()) :: completion_result()
  def complete_parse(work, port, buffer_pid, version) do
    with {:ok, registration} <- BufferRegistry.fetch(work.buffers, buffer_pid),
         {:ok, completed} <- BufferRegistration.complete_parse(registration, version) do
      work = finish_admission(work, port, buffer_pid, completed)
      {:ok, work, completed}
    else
      _stale_or_missing -> :stale
    end
  end

  @doc "Classifies an admission timeout without conflating snapshot and parser failures."
  @spec handle_timeout(t(), pid(), term()) :: timeout_result()
  def handle_timeout(work, buffer_pid, {:snapshot, _ref} = token) do
    if ParseScheduler.timeout?(work.scheduler, buffer_pid, token) do
      Minga.Log.warning(
        :port,
        "Parser: snapshot timed out for #{inspect(buffer_pid)}; dropping buffer"
      )

      :drop_buffer
    else
      :ok
    end
  end

  def handle_timeout(work, buffer_pid, {:parse, _ref} = token) do
    if ParseScheduler.timeout?(work.scheduler, buffer_pid, token) do
      Minga.Log.error(:port, "Parser: parse timed out for #{inspect(buffer_pid)}; restarting")
      :restart_port
    else
      :ok
    end
  end

  @doc "Cancels active admission and clears all queued parse work."
  @spec reset_admission(t()) :: t()
  def reset_admission(work) do
    cancel_admission_timer(work.scheduler)
    %{work | scheduler: ParseScheduler.reset(work.scheduler)}
  end

  @doc "Marks every registration for a fresh full snapshot and restarts pumps."
  @spec restart_pumps(t(), port() | nil) :: t()
  def restart_pumps(work, port) do
    buffer_count = BufferRegistry.count(work.buffers)

    if buffer_count > 0 do
      Minga.Log.info(:port, "Parser: re-syncing #{buffer_count} buffer(s)")
    end

    buffers = BufferRegistry.restart_all(work.buffers)
    work = reset_admission(%{work | buffers: buffers})

    buffers
    |> BufferRegistry.entries()
    |> Map.keys()
    |> Enum.reduce(work, fn buffer_pid, work -> pump(work, port, buffer_pid) end)
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

  @spec pumpable_registration(t(), pid()) :: BufferRegistration.t() | nil
  defp pumpable_registration(work, buffer_pid) do
    case BufferRegistry.fetch(work.buffers, buffer_pid) do
      {:ok, registration} -> if BufferRegistration.pumpable?(registration), do: registration
      :error -> nil
    end
  end

  @spec dispatch_activated(t(), port(), pid()) :: t()
  defp dispatch_activated(work, port, buffer_pid) do
    case pumpable_registration(work, buffer_pid) do
      %BufferRegistration{} = registration ->
        request_snapshot(work, buffer_pid, registration)

      nil ->
        work
        |> release_admission(buffer_pid)
        |> dispatch_next(port)
    end
  end

  @spec request_snapshot(t(), pid(), BufferRegistration.t()) :: t()
  defp request_snapshot(work, buffer_pid, registration) do
    token = make_ref()
    cursor = BufferRegistration.snapshot_cursor(registration)
    awaiting = BufferRegistration.await_snapshot(registration, token)
    work = put_registration(work, buffer_pid, awaiting)

    :ok = Buffer.request_sync_snapshot(buffer_pid, cursor, self(), token)
    arm_admission_timeout(work, buffer_pid, {:snapshot, token})
  end

  @spec apply_snapshot(t(), port() | nil, pid(), BufferRegistration.t(), SyncSnapshot.t()) ::
          snapshot_result()
  defp apply_snapshot(work, port, buffer_pid, registration, %SyncSnapshot{
         changes: :unchanged,
         sequence: sequence
       }) do
    completed = BufferRegistration.complete_unchanged(registration, sequence)
    finish_admission(work, port, buffer_pid, completed)
  end

  defp apply_snapshot(work, nil, buffer_pid, registration, _snapshot) do
    work
    |> put_registration(buffer_pid, BufferRegistration.restart(registration))
    |> release_admission(buffer_pid)
  end

  defp apply_snapshot(work, port, buffer_pid, registration, snapshot) do
    {version, buffers} = BufferRegistry.next_parse_version(work.buffers)
    work = %{work | buffers: buffers}
    commands = snapshot_commands(registration, version, snapshot.changes)
    full? = match?({:full, _content}, snapshot.changes)

    if PortLifecycle.send_batch(port, commands) do
      parsing = BufferRegistration.begin_parse(registration, version, snapshot.sequence, full?)

      work
      |> put_registration(buffer_pid, parsing)
      |> arm_admission_timeout(buffer_pid, {:parse, make_ref()})
    else
      Minga.Log.warning(:port, "Parser: parse write failed; scheduling restart")

      work =
        work
        |> put_registration(buffer_pid, BufferRegistration.restart(registration))
        |> reset_admission()

      {:port_write_failed, work}
    end
  end

  @spec finish_admission(t(), port() | nil, pid(), BufferRegistration.t()) :: t()
  defp finish_admission(work, port, buffer_pid, completed) do
    work
    |> put_registration(buffer_pid, completed)
    |> release_admission(buffer_pid)
    |> flush_buffer(port, buffer_pid)
    |> pump(port, buffer_pid)
    |> dispatch_next(port)
  end

  @spec flush_buffer(t(), port() | nil, pid()) :: t()
  defp flush_buffer(work, port, buffer_pid) do
    put_requests(work, RequestHandler.flush_buffer(port, work.requests, work.buffers, buffer_pid))
  end

  @spec put_registration(t(), pid(), BufferRegistration.t()) :: t()
  defp put_registration(work, buffer_pid, registration) do
    put_buffers(work, BufferRegistry.put(work.buffers, buffer_pid, registration))
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

  @spec arm_admission_timeout(t(), pid(), term()) :: t()
  defp arm_admission_timeout(work, buffer_pid, token) do
    cancel_admission_timer(work.scheduler)

    timer_ref =
      Process.send_after(
        self(),
        {:parse_admission_timeout, buffer_pid, token},
        @parse_admission_timeout_ms
      )

    %{work | scheduler: ParseScheduler.arm_timeout(work.scheduler, token, timer_ref)}
  end

  @spec release_admission(t(), pid()) :: t()
  defp release_admission(work, buffer_pid) do
    if ParseScheduler.active?(work.scheduler, buffer_pid) do
      cancel_admission_timer(work.scheduler)
      release_buffer(work, buffer_pid)
    else
      work
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

  @spec monotonic_ms() :: integer()
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
