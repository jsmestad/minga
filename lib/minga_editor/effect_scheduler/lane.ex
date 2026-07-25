defmodule MingaEditor.EffectScheduler.Lane do
  @moduledoc "Pure scheduling transitions for one effect resource lane."

  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request

  @enforce_keys [:policy, :running, :queue]
  defstruct [:policy, :running, :queue]

  @type cancel_reason :: term()
  @type action ::
          {:start, Request.t()}
          | {:stop, Request.t()}
          | {:candidate, Request.t(), {:canceled, cancel_reason()}}
          | {:terminal, Request.t(), {:canceled, cancel_reason()}}
          | {:terminal, Request.t(), {:stale, cancel_reason()}}
          | {:queue, [{Request.t(), pos_integer(), non_neg_integer()}]}
  @type admission_error :: :policy_mismatch | :queue_full | :scheduler_full
  @type admission :: {:ok, Request.id(), :running | :queued} | {:error, admission_error()}
  @type t :: %__MODULE__{
          policy: Policy.t(),
          running: Request.t() | nil,
          queue: :queue.queue(Request.t())
        }

  @doc "Builds an empty resource lane for a stable policy."
  @spec new(Policy.t()) :: t()
  def new(%Policy{} = policy), do: %__MODULE__{policy: policy, running: nil, queue: :queue.new()}

  @doc "Admits a request into a lane without performing effects."
  @spec admit(t() | nil, Request.t(), boolean()) :: {admission(), t() | nil, [action()]}
  def admit(nil, %Request{} = request, true) do
    lane = %__MODULE__{new(request.policy) | running: request}
    {{:ok, request.id, :running}, lane, [{:start, request}]}
  end

  def admit(nil, %Request{}, false), do: {{:error, :scheduler_full}, nil, []}

  def admit(%__MODULE__{policy: policy} = lane, %Request{policy: request_policy}, _capacity?)
      when policy != request_policy do
    {{:error, :policy_mismatch}, lane, []}
  end

  def admit(%__MODULE__{running: nil} = lane, %Request{} = request, true) do
    {{:ok, request.id, :running}, %{lane | running: request}, [{:start, request}]}
  end

  def admit(%__MODULE__{running: nil} = lane, %Request{}, false),
    do: {{:error, :scheduler_full}, lane, []}

  def admit(%__MODULE__{policy: %Policy{mode: :fifo}} = lane, request, capacity?),
    do: admit_fifo(lane, request, capacity?)

  def admit(%__MODULE__{policy: %Policy{mode: :latest_wins}} = lane, request, _capacity?) do
    old_requests = requests(lane)

    actions =
      stop_running(lane) ++ Enum.map(old_requests, &{:terminal, &1, {:canceled, :superseded}})

    actions = Enum.concat(actions, [{:start, request}])
    {{:ok, request.id, :running}, %{lane | running: request, queue: :queue.new()}, actions}
  end

  def admit(%__MODULE__{policy: %Policy{mode: :coalescing}} = lane, request, capacity?),
    do: admit_coalescing(lane, request, capacity?)

  @doc "Cancels one request by id. Running work remains current until its candidate is finalized."
  @spec cancel_request(t(), Request.id()) :: {:ok, t(), [action()]} | :not_found
  def cancel_request(%__MODULE__{running: %Request{id: request_id} = request} = lane, request_id) do
    {:ok, lane, [{:stop, request}, {:candidate, request, {:canceled, :requested}}]}
  end

  def cancel_request(%__MODULE__{} = lane, request_id) do
    case pop_queued(lane.queue, &(&1.id == request_id)) do
      {nil, _queue} ->
        :not_found

      {request, queue} ->
        {:ok, %{lane | queue: queue},
         [{:candidate, request, {:canceled, :requested}} | queue_actions(queue)]}
    end
  end

  @doc "Cancels all matching requests in this lane."
  @spec cancel_matching(t(), (Request.t() -> boolean()), term()) :: {t(), [action()], boolean()}
  def cancel_matching(%__MODULE__{} = lane, match?, reason) do
    {running, running_actions, running_canceled?} =
      cancel_matching_running(lane.running, match?, reason)

    {queue, canceled_queued} = split_queue(lane.queue, match?)
    terminal_actions = Enum.map(canceled_queued, &{:terminal, &1, {:canceled, reason}})
    changed? = running_canceled? or canceled_queued != []

    actions =
      running_actions ++ terminal_actions ++ if(changed?, do: queue_actions(queue), else: [])

    {%{lane | running: running, queue: queue}, actions, changed?}
  end

  @doc "Releases the matching current request without promoting queued work."
  @spec finalize_current(t(), Request.t()) :: {:empty, [action()]} | {t(), [action()]}
  def finalize_current(%__MODULE__{running: %Request{id: running_id}} = lane, %Request{
        id: request_id
      })
      when running_id == request_id do
    release_current(lane)
  end

  def finalize_current(%__MODULE__{} = lane, %Request{}), do: {lane, []}

  @doc "Promotes the next queued request when a lane has no current request."
  @spec finish_current(t()) :: {:empty, [action()]} | {t(), [action()]}
  def finish_current(%__MODULE__{queue: queue} = lane) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        {:empty, []}

      {{:value, request}, rest} ->
        {%{lane | running: request, queue: rest},
         Enum.concat(queue_actions(rest), [{:start, request}])}
    end
  end

  @doc "Returns true when a running or queued request matches."
  @spec active?(t(), (Request.t() -> boolean())) :: boolean()
  def active?(%__MODULE__{} = lane, match?),
    do: running_matches?(lane.running, match?) or queued_matches?(lane.queue, match?)

  @doc "Finds the request id for a semantic operation id."
  @spec request_id_for_operation(t(), MingaEditor.State.Operation.id()) :: Request.id() | nil
  def request_id_for_operation(%__MODULE__{} = lane, operation_id) do
    case lane.running do
      %Request{operation_id: ^operation_id, id: request_id} -> request_id
      _running -> queued_request_id_for_operation(lane.queue, operation_id)
    end
  end

  @spec admit_fifo(t(), Request.t(), boolean()) :: {admission(), t(), [action()]}
  defp admit_fifo(%__MODULE__{} = lane, request, capacity?) do
    cond do
      :queue.len(lane.queue) >= lane.policy.max_queued -> {{:error, :queue_full}, lane, []}
      not capacity? -> {{:error, :scheduler_full}, lane, []}
      true -> enqueue(lane, request)
    end
  end

  @spec admit_coalescing(t(), Request.t(), boolean()) :: {admission(), t(), [action()]}
  defp admit_coalescing(%__MODULE__{} = lane, request, capacity?) do
    cond do
      :queue.len(lane.queue) < lane.policy.max_queued and not capacity? ->
        {{:error, :scheduler_full}, lane, []}

      :queue.len(lane.queue) < lane.policy.max_queued ->
        enqueue(lane, request)

      true ->
        older = :queue.get_r(lane.queue)
        request = Request.coalesce(older, request)

        queue = :queue.in(request, :queue.drop_r(lane.queue))

        {{:ok, request.id, :queued}, %{lane | queue: queue},
         [{:terminal, older, {:stale, :coalesced}} | queue_actions(queue)]}
    end
  end

  @spec enqueue(t(), Request.t()) :: {admission(), t(), [action()]}
  defp enqueue(%__MODULE__{} = lane, request) do
    queue = :queue.in(request, lane.queue)
    {{:ok, request.id, :queued}, %{lane | queue: queue}, queue_actions(queue)}
  end

  @spec queue_actions(:queue.queue(Request.t())) :: [action()]
  defp queue_actions(queue) do
    requests = :queue.to_list(queue)
    total = length(requests)

    positions =
      requests
      |> Enum.with_index(1)
      |> Enum.map(fn {request, position} -> {request, position, total} end)

    [{:queue, positions}]
  end

  @spec release_current(t()) :: {:empty, [action()]} | {t(), [action()]}
  defp release_current(%__MODULE__{} = lane) do
    lane = %{lane | running: nil}

    if :queue.is_empty(lane.queue), do: {:empty, []}, else: {lane, []}
  end

  @spec stop_running(t()) :: [action()]
  defp stop_running(%__MODULE__{running: %Request{} = request}), do: [{:stop, request}]
  defp stop_running(%__MODULE__{}), do: []

  @spec requests(t()) :: [Request.t()]
  defp requests(%__MODULE__{} = lane),
    do: current_request(lane.running) ++ :queue.to_list(lane.queue)

  @spec current_request(Request.t() | nil) :: [Request.t()]
  defp current_request(%Request{} = request), do: [request]
  defp current_request(nil), do: []

  @spec cancel_matching_running(Request.t() | nil, (Request.t() -> boolean()), term()) ::
          {Request.t() | nil, [action()], boolean()}
  defp cancel_matching_running(%Request{} = request, match?, reason) do
    if match?.(request),
      do: {nil, [{:stop, request}, {:terminal, request, {:canceled, reason}}], true},
      else: {request, [], false}
  end

  defp cancel_matching_running(nil, _match?, _reason), do: {nil, [], false}

  @spec pop_queued(:queue.queue(Request.t()), (Request.t() -> boolean())) ::
          {Request.t() | nil, :queue.queue(Request.t())}
  defp pop_queued(queue, match?) do
    {matches, retained} = queue |> :queue.to_list() |> Enum.split_with(match?)
    {List.first(matches), :queue.from_list(retained)}
  end

  @spec split_queue(:queue.queue(Request.t()), (Request.t() -> boolean())) ::
          {:queue.queue(Request.t()), [Request.t()]}
  defp split_queue(queue, match?) do
    {canceled, retained} = queue |> :queue.to_list() |> Enum.split_with(match?)
    {:queue.from_list(retained), canceled}
  end

  @spec running_matches?(Request.t() | nil, (Request.t() -> boolean())) :: boolean()
  defp running_matches?(%Request{} = request, match?), do: match?.(request)
  defp running_matches?(nil, _match?), do: false

  @spec queued_matches?(:queue.queue(Request.t()), (Request.t() -> boolean())) :: boolean()
  defp queued_matches?(queue, match?), do: queue |> :queue.to_list() |> Enum.any?(match?)

  @spec queued_request_id_for_operation(
          :queue.queue(Request.t()),
          MingaEditor.State.Operation.id()
        ) :: Request.id() | nil
  defp queued_request_id_for_operation(queue, operation_id) do
    queue
    |> :queue.to_list()
    |> Enum.find_value(fn
      %Request{operation_id: ^operation_id, id: request_id} -> request_id
      %Request{} -> nil
    end)
  end
end
