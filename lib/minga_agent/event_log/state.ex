defmodule MingaAgent.EventLog.State do
  @moduledoc "Owned runtime state and transitions for `MingaAgent.EventLog`."

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Limits

  @type receipt :: reference()
  @type critical_entry ::
          {:critical, receipt(), pid(), EventRecord.event_type(), non_neg_integer(),
           EventRecord.t()}
  @type best_effort_entry ::
          {:best_effort, EventRecord.event_type(), non_neg_integer(), EventRecord.t()}
  @type entry :: critical_entry() | best_effort_entry()
  @type in_flight ::
          {:event, reference(), entry()}
          | {:retention, reference(), DateTime.t()}

  @enforce_keys [
    :path,
    :retention_days,
    :limits,
    :store_backend,
    :writer_opts,
    :restart_delay_ms
  ]
  defstruct path: nil,
            retention_days: nil,
            limits: nil,
            store_backend: nil,
            writer_opts: [],
            restart_delay_ms: nil,
            queue: :queue.new(),
            writer: nil,
            writer_ref: nil,
            status: :starting,
            in_flight: nil,
            pending_retention: false,
            sweep_ref: nil,
            idle_waiters: []

  @type t :: %__MODULE__{
          path: String.t(),
          retention_days: pos_integer(),
          limits: Limits.t(),
          store_backend: module(),
          writer_opts: keyword(),
          restart_delay_ms: non_neg_integer(),
          queue: term(),
          writer: pid() | nil,
          writer_ref: reference() | nil,
          status: :starting | :ready | :unavailable,
          in_flight: in_flight() | nil,
          pending_retention: boolean(),
          sweep_ref: reference() | nil,
          idle_waiters: [GenServer.from()]
        }

  @doc "Builds initial EventLog state from validated values."
  @spec new(
          String.t(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          module(),
          keyword(),
          non_neg_integer()
        ) :: t()
  def new(
        path,
        retention_days,
        max_queue_size,
        max_queue_bytes,
        store_backend,
        writer_opts,
        restart_delay_ms
      )
      when is_binary(path) and is_integer(retention_days) and retention_days > 0 and
             is_integer(max_queue_size) and max_queue_size > 0 and is_integer(max_queue_bytes) and
             max_queue_bytes > 0 and is_atom(store_backend) and is_list(writer_opts) and
             is_integer(restart_delay_ms) and restart_delay_ms >= 0 do
    %__MODULE__{
      path: path,
      retention_days: retention_days,
      limits: Limits.new(max_queue_size, max_queue_bytes),
      store_backend: store_backend,
      writer_opts: writer_opts,
      restart_delay_ms: restart_delay_ms
    }
  end

  @doc "Marks a writer process as starting."
  @spec writer_started(t(), pid(), reference()) :: t()
  def writer_started(state, writer, writer_ref) do
    %{state | writer: writer, writer_ref: writer_ref, status: :starting}
  end

  @doc "Marks the current writer as ready."
  @spec writer_ready(t()) :: t()
  def writer_ready(state), do: %{state | status: :ready}

  @doc "Clears writer identity and sets its availability state."
  @spec clear_writer(t(), :starting | :unavailable) :: t()
  def clear_writer(state, status) do
    %{state | writer: nil, writer_ref: nil, status: status}
  end

  @doc "Returns whether one event of the given serialized size fits the outstanding-work bounds."
  @spec admission_available?(t(), non_neg_integer()) :: boolean()
  def admission_available?(state, bytes), do: Limits.available?(state.limits, bytes)

  @doc "Enqueues an admitted event at the back of the ordered queue."
  @spec enqueue(t(), entry()) :: t()
  def enqueue(state, entry) do
    %{
      state
      | queue: :queue.in(entry, state.queue),
        limits: Limits.admit(state.limits, entry_bytes(entry))
    }
  end

  @doc "Removes the next admitted event from the ordered queue."
  @spec dequeue(t()) :: {:empty, t()} | {:ok, entry(), t()}
  def dequeue(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} -> {:empty, state}
      {{:value, entry}, queue} -> {:ok, entry, %{state | queue: queue}}
    end
  end

  @doc "Marks an event as the writer's single in-flight operation."
  @spec start_event(t(), reference(), entry()) :: t()
  def start_event(state, token, entry) do
    %{state | in_flight: {:event, token, entry}}
  end

  @doc "Marks a retention sweep as the writer's single in-flight operation."
  @spec start_retention(t(), reference(), DateTime.t()) :: t()
  def start_retention(state, token, cutoff) do
    %{state | pending_retention: false, in_flight: {:retention, token, cutoff}}
  end

  @doc "Clears the completed in-flight operation and releases completed event bytes."
  @spec finish_in_flight(t()) :: t()
  def finish_in_flight(%__MODULE__{in_flight: {:event, _token, entry}} = state) do
    %{state | in_flight: nil, limits: Limits.release(state.limits, entry_bytes(entry))}
  end

  def finish_in_flight(state), do: %{state | in_flight: nil}

  @doc "Requeues an uncertain in-flight event at the front without changing its idempotency key."
  @spec requeue_in_flight(t()) :: t()
  def requeue_in_flight(%__MODULE__{in_flight: {:event, _token, entry}} = state) do
    %{state | queue: :queue.in_r(entry, state.queue), in_flight: nil}
  end

  def requeue_in_flight(%__MODULE__{in_flight: {:retention, _token, _cutoff}} = state) do
    %{state | in_flight: nil, pending_retention: true}
  end

  def requeue_in_flight(state), do: state

  @doc "Clears failed event work while preserving any pending or interrupted retention sweep."
  @spec clear_event_work(t()) :: t()
  def clear_event_work(state) do
    pending_retention =
      state.pending_retention or match?({:retention, _token, _cutoff}, state.in_flight)

    %{
      state
      | queue: :queue.new(),
        in_flight: nil,
        pending_retention: pending_retention,
        limits: Limits.reset(state.limits)
    }
  end

  @doc "Marks a retention sweep pending behind admitted events."
  @spec mark_retention_pending(t()) :: t()
  def mark_retention_pending(state), do: %{state | pending_retention: true}

  @doc "Stores the timer for the next retention sweep."
  @spec schedule_sweep(t(), reference() | nil) :: t()
  def schedule_sweep(state, sweep_ref), do: %{state | sweep_ref: sweep_ref}

  @doc "Adds a caller waiting for all currently outstanding work."
  @spec add_idle_waiter(t(), GenServer.from()) :: t()
  def add_idle_waiter(state, from), do: %{state | idle_waiters: [from | state.idle_waiters]}

  @doc "Clears callers after the owner has replied that work is idle."
  @spec clear_idle_waiters(t()) :: t()
  def clear_idle_waiters(state), do: %{state | idle_waiters: []}

  @spec entry_bytes(entry()) :: non_neg_integer()
  defp entry_bytes({:critical, _receipt, _caller, _event_type, bytes, _record}), do: bytes
  defp entry_bytes({:best_effort, _event_type, bytes, _record}), do: bytes
end
