defmodule MingaAgent.Providers.Native.ExecutionState do
  @moduledoc """
  Tagged lifecycle state for native provider execution.

  Replaces the independent `streaming`, `interrupted`, `task`,
  `active_request`, and `tool_workers` fields with one value whose tag
  determines which fields are populated. Transitions are exhaustive:
  every public function pattern-matches the valid source tag.

  Admitted work is identified by its request and generation. `cancel/2` stops only the active work admitted for the named request, so a delayed or repeated cancellation cannot stop a replacement. `register_workers/3` accepts workers only for the active generation, so a stale turn loop cannot attach work to its replacement.
  """

  alias MingaAgent.Session.Request

  @type tag :: :idle | :active | :interrupted

  @type t :: %__MODULE__{
          tag: tag(),
          generation: non_neg_integer(),
          task: Task.t() | nil,
          request: Request.t() | nil,
          workers: MapSet.t(pid())
        }

  @enforce_keys [:tag, :generation]
  defstruct tag: :idle,
            generation: 0,
            task: nil,
            request: nil,
            workers: MapSet.new()

  @doc "Returns the initial idle execution state."
  @spec idle() :: t()
  def idle, do: %__MODULE__{tag: :idle, generation: 0}

  @doc "Transitions from idle or interrupted to active, incrementing the generation."
  @spec start(t(), Task.t(), Request.t()) :: t()
  def start(%__MODULE__{tag: :idle, generation: gen}, %Task{} = task, %Request{} = request) do
    %__MODULE__{tag: :active, generation: gen + 1, task: task, request: request}
  end

  def start(%__MODULE__{tag: :interrupted, generation: gen}, %Task{} = task, %Request{} = request) do
    %__MODULE__{tag: :active, generation: gen + 1, task: task, request: request}
  end

  @doc "Returns the generation that `start/3` admits next. Only idle and interrupted states can start."
  @spec next_generation(t()) :: pos_integer()
  def next_generation(%__MODULE__{tag: tag, generation: gen}) when tag in [:idle, :interrupted],
    do: gen + 1

  @doc "Transitions from active to idle on successful completion."
  @spec complete(t()) :: t()
  def complete(%__MODULE__{tag: :active, generation: gen}) do
    %__MODULE__{tag: :idle, generation: gen}
  end

  @doc "Transitions from active to interrupted (stream cut, turn limit)."
  @spec interrupt(t()) :: t()
  def interrupt(%__MODULE__{tag: :active, generation: gen}) do
    %__MODULE__{tag: :interrupted, generation: gen}
  end

  @doc """
  Prepares an abort from any tag. Returns the new idle state plus the task
  and worker set the caller must clean up. No side effects.
  """
  @spec abort(t()) :: {t(), Task.t() | nil, MapSet.t(pid())}
  def abort(%__MODULE__{tag: :idle} = state) do
    {state, nil, state.workers}
  end

  def abort(%__MODULE__{tag: :active, generation: gen, task: task, workers: workers}) do
    {%__MODULE__{tag: :idle, generation: gen}, task, workers}
  end

  def abort(%__MODULE__{tag: :interrupted, generation: gen}) do
    {%__MODULE__{tag: :idle, generation: gen}, nil, MapSet.new()}
  end

  @doc """
  Prepares a cancellation of the work admitted for `request_id`.

  Returns `{:cancelled, idle, task, workers}` with the task and workers the caller must stop, or `:stale` when no active work belongs to that request (already finished, interrupted, or replaced). No side effects.
  """
  @spec cancel(t(), String.t()) :: {:cancelled, t(), Task.t(), MapSet.t(pid())} | :stale
  def cancel(
        %__MODULE__{tag: :active, request: %Request{request_id: request_id}} = state,
        request_id
      ) do
    {:cancelled, %__MODULE__{tag: :idle, generation: state.generation}, state.task, state.workers}
  end

  def cancel(%__MODULE__{tag: :active}, request_id) when is_binary(request_id), do: :stale
  def cancel(%__MODULE__{tag: :idle}, request_id) when is_binary(request_id), do: :stale
  def cancel(%__MODULE__{tag: :interrupted}, request_id) when is_binary(request_id), do: :stale

  @doc "Registers worker PIDs for the active generation that admitted them. The caller owns linking."
  @spec register_workers(t(), pos_integer(), [pid()]) :: {:ok, t()} | {:error, :stale_generation}
  def register_workers(
        %__MODULE__{tag: :active, generation: generation} = state,
        generation,
        pids
      )
      when is_list(pids) do
    {:ok, %{state | workers: Enum.reduce(pids, state.workers, &MapSet.put(&2, &1))}}
  end

  def register_workers(%__MODULE__{}, generation, pids)
      when is_integer(generation) and is_list(pids),
      do: {:error, :stale_generation}

  @doc "Unregisters worker PIDs from the active state. No-op if not active. The caller owns unlinking."
  @spec unregister_workers(t(), [pid()]) :: t()
  def unregister_workers(%__MODULE__{tag: :active, workers: workers} = state, pids)
      when is_list(pids) do
    %{state | workers: MapSet.difference(workers, MapSet.new(pids))}
  end

  def unregister_workers(%__MODULE__{} = state, _pids), do: state

  @doc "Removes a single worker (e.g. on EXIT). No-op if not active."
  @spec remove_worker(t(), pid()) :: t()
  def remove_worker(%__MODULE__{tag: :active, workers: workers} = state, pid) when is_pid(pid) do
    %{state | workers: MapSet.delete(workers, pid)}
  end

  def remove_worker(%__MODULE__{} = state, _pid), do: state

  # ── Predicates ───────────────────────────────────────────────────────────

  @doc "Returns true when execution is active (streaming)."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{tag: :active}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "Returns true when the last turn was interrupted."
  @spec interrupted?(t()) :: boolean()
  def interrupted?(%__MODULE__{tag: :interrupted}), do: true
  def interrupted?(%__MODULE__{}), do: false

  @doc "Returns true when idle."
  @spec idle?(t()) :: boolean()
  def idle?(%__MODULE__{tag: :idle}), do: true
  def idle?(%__MODULE__{}), do: false

  @doc "Returns true when a request is active (the provider should not accept config changes)."
  @spec request_active?(t()) :: boolean()
  def request_active?(%__MODULE__{tag: :active}), do: true
  def request_active?(%__MODULE__{}), do: false

  @doc "Returns the Task reference for matching handle_info, or nil."
  @spec task_ref(t()) :: reference() | nil
  def task_ref(%__MODULE__{tag: :active, task: %Task{ref: ref}}), do: ref
  def task_ref(%__MODULE__{}), do: nil

  @doc "Returns the Task PID for matching EXIT messages, or nil."
  @spec task_pid(t()) :: pid() | nil
  def task_pid(%__MODULE__{tag: :active, task: %Task{pid: pid}}), do: pid
  def task_pid(%__MODULE__{}), do: nil

  @doc "Returns the active request, or nil."
  @spec request(t()) :: Request.t() | nil
  def request(%__MODULE__{request: request}), do: request

  @doc "Returns the current generation."
  @spec generation(t()) :: non_neg_integer()
  def generation(%__MODULE__{generation: gen}), do: gen

  @doc "Returns the worker set."
  @spec workers(t()) :: MapSet.t(pid())
  def workers(%__MODULE__{workers: workers}), do: workers
end
