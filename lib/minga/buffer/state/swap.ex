defmodule Minga.Buffer.State.Swap do
  @moduledoc """
  Buffer-owned admission state for crash-recovery swap writes.

  The state bounds work to one active preparation and one latest pending
  snapshot. Its generation advances on every admission and invalidation, so a
  prepared older snapshot cannot publish after newer work becomes authoritative.
  """

  alias Minga.Buffer.UndoHistory

  @typedoc "Monotonic swap admission generation."
  @type generation :: non_neg_integer()

  @typedoc "Immutable text and optional review histories captured from one buffer state."
  @type capture ::
          {binary(), UndoHistory.t() | nil, UndoHistory.saved_checkpoint() | nil, binary() | nil}

  @typedoc "An admitted buffer snapshot: generation, source path, and captured data."
  @type snapshot :: {generation(), String.t(), capture()}

  @typedoc "The active preparation worker: snapshot, worker pid, and monitor."
  @type active_work :: {snapshot(), pid(), reference()}

  @typedoc "Function that starts the debounce timer for an admitted swap."
  @type timer_start :: (pid(), term(), non_neg_integer() -> reference())

  @typep source :: %{required(:swap_path) => String.t(), optional(atom()) => term()}

  @type t :: %__MODULE__{
          directory: String.t() | nil,
          backend: module() | nil,
          backend_options: keyword(),
          timer_start: timer_start(),
          timer: reference() | nil,
          timer_token: reference() | nil,
          generation: generation(),
          incarnation: pos_integer() | nil,
          saved: UndoHistory.saved_checkpoint() | nil,
          held_for_recovery: boolean(),
          sources: %{String.t() => source()},
          adopted: source() | nil,
          active: active_work() | nil,
          pending: snapshot() | nil
        }

  defstruct directory: nil,
            backend: nil,
            backend_options: [],
            timer_start: &Process.send_after/3,
            timer: nil,
            timer_token: nil,
            generation: 0,
            incarnation: nil,
            saved: nil,
            held_for_recovery: false,
            sources: %{},
            adopted: nil,
            active: nil,
            pending: nil

  @doc "Builds swap admission state from Buffer start options."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      directory: Keyword.get(opts, :swap_dir),
      backend: Keyword.get(opts, :swap_backend),
      backend_options: Keyword.get(opts, :swap_backend_options, []),
      incarnation: Keyword.get(opts, :swap_incarnation),
      timer_start: Keyword.get(opts, :swap_timer_start, &Process.send_after/3)
    }
  end

  @doc "Returns true when this buffer has a configured swap directory."
  @spec configured?(t()) :: boolean()
  def configured?(%__MODULE__{directory: directory}), do: is_binary(directory)

  @doc "Returns true when this buffer writes its swap file into `directory`."
  @spec writes_into?(t(), String.t()) :: boolean()
  def writes_into?(%__MODULE__{directory: directory}, directory) when is_binary(directory),
    do: true

  def writes_into?(%__MODULE__{}, directory) when is_binary(directory), do: false

  @doc """
  Turns swap writes off for the rest of this buffer's life.

  The editor releases every buffer's swap when the user quits on purpose. A buffer that is edited again while the VM stops must not write a new one.
  """
  @spec release(t()) :: t()
  def release(%__MODULE__{} = state), do: %{state | directory: nil}

  @doc "Keeps an unadopted record for explicit recovery instead of deleting it at close."
  @spec hold_for_recovery(t()) :: t()
  def hold_for_recovery(%__MODULE__{} = state), do: %{state | held_for_recovery: true}

  @doc "A new publication superseded any unadopted record at this buffer's own swap path."
  @spec published(t()) :: t()
  def published(%__MODULE__{} = state), do: %{state | held_for_recovery: false}

  @doc "Retains the exact source until the replacement generation is durable."
  @spec track_source(t(), source() | nil) :: t()
  def track_source(%__MODULE__{} = state, nil), do: state

  def track_source(%__MODULE__{} = state, %{swap_path: path} = source),
    do: %{state | sources: Map.put(state.sources, path, source)}

  @doc "Drops a source whose exact generation is no longer waiting to be retired."
  @spec retire_source(t(), String.t()) :: t()
  def retire_source(%__MODULE__{} = state, path),
    do: %{state | sources: Map.delete(state.sources, path)}

  @doc "Records the exact recovery already taken over when this buffer opened."
  @spec remember_adoption(t(), source()) :: t()
  def remember_adoption(%__MODULE__{} = state, source), do: %{state | adopted: source}

  @doc "Returns the configured storage backend."
  @spec backend(t()) :: module()
  def backend(%__MODULE__{backend: backend}) when is_atom(backend) and not is_nil(backend),
    do: backend

  @doc "Returns backend options for a generation, including the swap directory."
  @spec backend_options(t(), generation()) :: keyword()
  def backend_options(%__MODULE__{} = state, generation) do
    state.backend_options
    |> Keyword.put(:swap_dir, state.directory)
    |> Keyword.put(:generation, generation)
    |> Keyword.put(:incarnation, state.incarnation)
  end

  @doc "Records the clean review checkpoint for this file's last saved bytes."
  @spec put_saved(t(), UndoHistory.saved_checkpoint() | nil) :: t()
  def put_saved(%__MODULE__{} = state, saved), do: %{state | saved: saved}

  @doc "Returns the configured debounce timer starter."
  @spec timer_start(t()) :: timer_start()
  def timer_start(%__MODULE__{timer_start: timer_start}), do: timer_start

  @doc "Records the current debounce timer and its stale-message token."
  @spec schedule(t(), reference(), reference()) :: t()
  def schedule(%__MODULE__{} = state, timer, token)
      when is_reference(timer) and is_reference(token) do
    %{state | timer: timer, timer_token: token}
  end

  @doc "Consumes the matching timer token and rejects stale timer messages."
  @spec consume_timer(t(), reference()) :: {:ok, t()} | :stale
  def consume_timer(%__MODULE__{timer_token: token} = state, token) do
    {:ok, clear_timer(state)}
  end

  def consume_timer(%__MODULE__{}, _token), do: :stale

  @doc "Clears the current timer and returns its timer reference for cancellation."
  @spec take_timer(t()) :: {reference() | nil, t()}
  def take_timer(%__MODULE__{timer: timer} = state), do: {timer, clear_timer(state)}

  @doc "Admits a snapshot, starting it immediately or replacing the latest pending work."
  @spec admit(t(), String.t(), capture()) :: {:start, snapshot(), t()} | {:pending, t()}
  def admit(%__MODULE__{} = state, path, {content, _history, _saved, _disk_hash} = capture)
      when is_binary(path) and is_binary(content) do
    generation = state.generation + 1
    snapshot = {generation, path, capture}
    state = %{state | generation: generation}

    case state.active do
      nil -> {:start, snapshot, state}
      {_snapshot, _pid, _monitor} -> {:pending, %{state | pending: snapshot}}
    end
  end

  @doc "Records the monitored worker that is preparing an admitted snapshot."
  @spec worker_started(t(), snapshot(), pid(), reference()) :: t()
  def worker_started(%__MODULE__{active: nil} = state, snapshot, pid, monitor)
      when is_pid(pid) and is_reference(monitor) do
    %{state | active: {snapshot, pid, monitor}}
  end

  @doc "Checks whether a worker's prepared result is still the newest admitted snapshot."
  @spec publication_status(t(), pid(), generation()) :: :current | :obsolete | :unknown
  def publication_status(
        %__MODULE__{
          generation: generation,
          active: {{generation, _path, _content}, pid, _monitor},
          pending: nil
        },
        pid,
        generation
      ),
      do: :current

  def publication_status(
        %__MODULE__{active: {{generation, _path, _content}, pid, _monitor}},
        pid,
        generation
      ),
      do: :obsolete

  def publication_status(%__MODULE__{}, _pid, _generation), do: :unknown

  @doc "Completes matching active work and returns the latest pending snapshot, if any."
  @spec complete(t(), pid(), generation()) ::
          {:ok, reference(), snapshot() | nil, t()} | :unknown
  def complete(
        %__MODULE__{active: {{generation, _path, _content}, pid, monitor}} = state,
        pid,
        generation
      ) do
    {:ok, monitor, state.pending, %{state | active: nil, pending: nil}}
  end

  def complete(%__MODULE__{}, _pid, _generation), do: :unknown

  @doc "Completes matching active work identified by its process monitor."
  @spec complete_monitor(t(), pid(), reference()) ::
          {:ok, generation(), snapshot() | nil, t()} | :unknown
  def complete_monitor(
        %__MODULE__{active: {{generation, _path, _content}, pid, monitor}} = state,
        pid,
        monitor
      ) do
    {:ok, generation, state.pending, %{state | active: nil, pending: nil}}
  end

  def complete_monitor(%__MODULE__{}, _pid, _monitor), do: :unknown

  @doc "Invalidates every admitted write and returns resources the Buffer process must revoke."
  @spec invalidate(t()) :: {reference() | nil, active_work() | nil, t()}
  def invalidate(%__MODULE__{} = state) do
    {state.timer, state.active,
     %{
       state
       | timer: nil,
         timer_token: nil,
         generation: state.generation + 1,
         active: nil,
         pending: nil
     }}
  end

  @spec clear_timer(t()) :: t()
  defp clear_timer(%__MODULE__{} = state), do: %{state | timer: nil, timer_token: nil}
end
