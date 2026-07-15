defmodule MingaEditor.EffectScheduler.Engine do
  @moduledoc "Lifecycle, admission-policy, and worker coordination for `EffectScheduler`."

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler.State

  @type admission_error ::
          :already_admitted
          | :owner_unavailable
          | :policy_mismatch
          | :queue_full
          | :scheduler_full
  @type admission :: {:ok, Request.id(), :running | :queued} | {:error, admission_error()}
  @type handoff :: admission() | {:error, :not_found}
  @type claim :: :ok | {:error, :not_pending}

  @doc "Attaches the scheduler's single owner."
  @spec attach(State.t(), pid()) :: {:ok | {:error, :already_attached}, State.t()}
  def attach(%State{owner: nil} = state, owner) do
    monitor = Process.monitor(owner)
    {:ok, %{state | owner: owner, owner_monitor: monitor}}
  end

  def attach(%State{} = state, _owner), do: {{:error, :already_attached}, state}

  @doc "Admits a request according to its resource policy."
  @spec schedule(State.t(), Request.t()) :: {admission(), State.t()}
  def schedule(%State{owner: nil} = state, %Request{}),
    do: {{:error, :owner_unavailable}, state}

  def schedule(%State{} = state, %Request{} = request), do: admit(state, request)

  @doc "Cancels an admitted request."
  @spec cancel(State.t(), Request.id()) :: {:ok | {:error, :not_found}, State.t()}
  def cancel(%State{} = state, request_id) do
    case cancel_request(state, request_id) do
      {:ok, state} -> {:ok, state}
      :not_found -> {{:error, :not_found}, state}
    end
  end

  @doc "Cancels the admitted request correlated with a semantic operation."
  @spec cancel_operation(State.t(), MingaEditor.State.Operation.id()) ::
          {:ok | {:error, :not_found}, State.t()}
  def cancel_operation(%State{} = state, operation_id)
      when is_integer(operation_id) and operation_id > 0 do
    case request_id_for_operation(state, operation_id) do
      nil -> {{:error, :not_found}, state}
      request_id -> cancel(state, request_id)
    end
  end

  @doc "Cancels and terminalizes all work attributed to a contribution source."
  @spec cancel_source(State.t(), Minga.Extension.ContributionCleanup.contribution_source()) ::
          {:ok, State.t()}
  def cancel_source(%State{} = state, source) do
    {:ok, cancel_matching(state, &(&1.source == source), :source_canceled, false)}
  end

  @doc "Cancels and terminalizes all work for one semantic resource."
  @spec cancel_resource(State.t(), Request.resource()) :: {:ok, State.t()}
  def cancel_resource(%State{} = state, resource) do
    {:ok, cancel_matching(state, &(&1.resource == resource), :resource_canceled, true)}
  end

  @doc "Returns whether a source has running, queued, or pending work."
  @spec active_source?(State.t(), Minga.Extension.ContributionCleanup.contribution_source()) ::
          boolean()
  def active_source?(%State{} = state, source), do: request_active?(state, &(&1.source == source))

  @doc "Returns whether an exact request still holds scheduler admission."
  @spec admitted?(State.t(), Request.id()) :: boolean()
  def admitted?(%State{} = state, request_id) when is_reference(request_id) do
    MapSet.member?(state.admitted, request_id)
  end

  @doc "Atomically claims a still-pending candidate without releasing its resource."
  @spec claim(State.t(), Outcome.t()) :: {claim(), State.t()}
  def claim(%State{} = state, %Outcome{} = outcome) do
    request_id = outcome.request.id

    case {Map.get(state.pending, request_id), MapSet.member?(state.claimed, request_id)} do
      {^outcome, false} -> {:ok, %{state | claimed: MapSet.put(state.claimed, request_id)}}
      {_candidate, _claimed?} -> {{:error, :not_pending}, state}
    end
  end

  @doc "Finalizes a candidate and admits its follow-up as one scheduler transition."
  @spec finalize_and_schedule(State.t(), Outcome.t(), Request.t()) :: {handoff(), State.t()}
  def finalize_and_schedule(%State{} = state, %Outcome{} = outcome, %Request{} = request) do
    case take_candidate(state, outcome) do
      :not_found ->
        {{:error, :not_found}, state}

      {:ok, state} ->
        {reply, state} = admit(state, request)
        state = start_next(state, outcome.request.resource)
        notify_terminal(state.observer, handoff_outcome(outcome, reply))
        {reply, state}
    end
  end

  @doc "Returns whether a handler has running, queued, or pending work."
  @spec active?(State.t(), module()) :: boolean()
  def active?(%State{} = state, handler), do: handler_active?(state, handler)

  @doc "Returns bounded scheduler statistics."
  @spec stats(State.t()) :: map()
  def stats(%State{} = state) do
    running =
      Enum.count(state.lanes, fn
        {_resource, %{running: %{task: %Task{}}}} -> true
        _lane -> false
      end)

    queued = Enum.sum(Enum.map(state.lanes, fn {_resource, lane} -> :queue.len(lane.queue) end))

    %{
      resources: map_size(state.lanes),
      running: running,
      queued: queued,
      pending: map_size(state.pending),
      admitted: MapSet.size(state.admitted),
      capacity: state.max_admitted
    }
  end

  @doc "Finalizes a domain-applied candidate, if it is still pending."
  @spec finalize(State.t(), Outcome.t()) :: State.t()
  def finalize(%State{} = state, %Outcome{} = outcome) do
    case take_candidate(state, outcome) do
      :not_found ->
        state

      {:ok, state} ->
        state = start_next(state, outcome.request.resource)
        notify_terminal(state.observer, outcome)
        state
    end
  end

  @doc "Processes a successful worker reply."
  @spec task_result(State.t(), reference(), term()) :: State.t()
  def task_result(%State{} = state, task_ref, result) do
    case Map.pop(state.tasks, task_ref) do
      {nil, _tasks} ->
        state

      {resource, tasks} ->
        Process.demonitor(task_ref, [:flush])
        state = %{state | tasks: tasks}
        finish_running(state, resource, outcome_from_result(state, resource, result))
    end
  end

  @doc "Processes an owner or worker DOWN message."
  @spec process_down(State.t(), reference(), pid(), term()) :: State.t()
  def process_down(
        %State{owner_monitor: ref, owner: owner} = state,
        ref,
        owner,
        _reason
      ) do
    state = shutdown_all(state, :owner_shutdown)
    %{state | owner: nil, owner_monitor: nil}
  end

  def process_down(%State{} = state, task_ref, _pid, reason) do
    case Map.pop(state.tasks, task_ref) do
      {nil, _tasks} ->
        state

      {resource, tasks} ->
        state = %{state | tasks: tasks}
        request = running_request(state, resource)
        finish_running(state, resource, Outcome.failed(request, {:worker_exit, reason}))
    end
  end

  @doc "Stops all work and terminalizes every admitted request."
  @spec shutdown(State.t(), term()) :: State.t()
  def shutdown(%State{} = state, reason), do: shutdown_all(state, reason)

  @spec handoff_outcome(Outcome.t(), admission()) :: Outcome.t()
  defp handoff_outcome(outcome, {:ok, _request_id, _disposition}), do: outcome
  defp handoff_outcome(outcome, {:error, reason}), do: Outcome.failed(outcome.request, reason)

  @spec admit(State.t(), Request.t()) :: {admission(), State.t()}
  defp admit(state, %Request{id: request_id} = request) do
    if MapSet.member?(state.admitted, request_id) do
      {{:error, :already_admitted}, state}
    else
      admit_available(state, request)
    end
  end

  @spec admit_available(State.t(), Request.t()) :: {admission(), State.t()}
  defp admit_available(state, %Request{resource: resource, policy: policy} = request) do
    case Map.get(state.lanes, resource) do
      nil ->
        admit_new_lane(state, resource, policy, request)

      %{policy: existing_policy} when existing_policy != policy ->
        {{:error, :policy_mismatch}, state}

      %{running: nil} ->
        admit_idle_lane(state, resource, request)

      %{policy: %Policy{mode: :fifo}} = lane ->
        admit_fifo(state, resource, lane, request)

      %{policy: %Policy{mode: :latest_wins}} = lane ->
        state = supersede_lane(state, resource, lane)
        state = admit_request(state, request)
        state = start_request(state, resource, request)
        {{:ok, request.id, :running}, state}

      %{policy: %Policy{mode: :coalescing}} = lane ->
        admit_coalescing(state, resource, lane, request)
    end
  end

  @spec admit_idle_lane(State.t(), Request.resource(), Request.t()) ::
          {admission(), State.t()}
  defp admit_idle_lane(state, resource, request) do
    if capacity_available?(state) do
      state = state |> admit_request(request) |> start_request(resource, request)
      {{:ok, request.id, :running}, state}
    else
      {{:error, :scheduler_full}, state}
    end
  end

  @spec admit_new_lane(State.t(), Request.resource(), Policy.t(), Request.t()) ::
          {admission(), State.t()}
  defp admit_new_lane(state, resource, policy, request) do
    if capacity_available?(state) do
      lane = %{policy: policy, running: nil, queue: :queue.new()}

      state =
        state
        |> admit_request(request)
        |> put_lane(resource, lane)
        |> start_request(resource, request)

      {{:ok, request.id, :running}, state}
    else
      {{:error, :scheduler_full}, state}
    end
  end

  @spec admit_fifo(State.t(), Request.resource(), State.lane(), Request.t()) ::
          {admission(), State.t()}
  defp admit_fifo(state, resource, lane, request) do
    case {:queue.len(lane.queue) < lane.policy.max_queued, capacity_available?(state)} do
      {false, _capacity} ->
        {{:error, :queue_full}, state}

      {true, false} ->
        {{:error, :scheduler_full}, state}

      {true, true} ->
        queue = :queue.in(request, lane.queue)

        state =
          state
          |> admit_request(request)
          |> put_lane(resource, %{lane | queue: queue})
          |> notify_queued_lifecycle(queue)

        {{:ok, request.id, :queued}, state}
    end
  end

  @spec admit_coalescing(State.t(), Request.resource(), State.lane(), Request.t()) ::
          {admission(), State.t()}
  defp admit_coalescing(state, resource, lane, request) do
    queue_length = :queue.len(lane.queue)

    case {queue_length < lane.policy.max_queued, capacity_available?(state)} do
      {true, false} ->
        {{:error, :scheduler_full}, state}

      {true, true} ->
        queue = :queue.in(request, lane.queue)

        state =
          state
          |> admit_request(request)
          |> put_lane(resource, %{lane | queue: queue})
          |> notify_queued_lifecycle(queue)

        {{:ok, request.id, :queued}, state}

      {false, _capacity} ->
        queued = :queue.to_list(lane.queue)
        older = :queue.get_r(lane.queue)
        request = Request.coalesce(older, request)
        queue = queued |> List.replace_at(-1, request) |> :queue.from_list()

        state =
          state
          |> put_lane(resource, %{lane | queue: queue})
          |> terminalize_direct(Outcome.stale(Outcome.canceled(older, :coalesced), :coalesced))
          |> admit_request(request)
          |> notify_queued_lifecycle(queue)

        {{:ok, request.id, :queued}, state}
    end
  end

  @spec start_request(State.t(), Request.resource(), Request.t()) :: State.t()
  defp start_request(state, resource, request) do
    notify_lifecycle(state.owner, Outcome.running(request))
    lane = Map.fetch!(state.lanes, resource)
    state = put_lane(state, resource, %{lane | running: %{task: nil, request: request}})

    case start_task(state.task_supervisor, request) do
      {:ok, task} ->
        lane = Map.fetch!(state.lanes, resource)
        lane = %{lane | running: %{task: task, request: request}}

        state
        |> put_lane(resource, lane)
        |> put_in([Access.key(:tasks), task.ref], resource)

      {:error, reason} ->
        deliver_result(state, Outcome.failed(request, {:start_failed, reason}))
    end
  end

  @spec start_task(GenServer.server(), Request.t()) :: {:ok, Task.t()} | {:error, term()}
  defp start_task(task_supervisor, request) do
    {:ok, Task.Supervisor.async_nolink(task_supervisor, fn -> Request.run(request) end)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec outcome_from_result(State.t(), Request.resource(), term()) :: Outcome.t()
  defp outcome_from_result(state, resource, {:ok, result}) do
    Outcome.completed(running_request(state, resource), result)
  end

  defp outcome_from_result(state, resource, {:error, reason}) do
    Outcome.failed(running_request(state, resource), reason)
  end

  defp outcome_from_result(state, resource, result) do
    Outcome.completed(running_request(state, resource), result)
  end

  @spec finish_running(State.t(), Request.resource(), Outcome.t()) :: State.t()
  defp finish_running(state, resource, outcome) do
    lane = Map.fetch!(state.lanes, resource)
    running = Map.fetch!(lane, :running)

    state
    |> put_lane(resource, %{lane | running: %{running | task: nil}})
    |> deliver_result(outcome)
  end

  @spec start_next(State.t(), Request.resource()) :: State.t()
  defp start_next(state, resource) do
    case Map.get(state.lanes, resource) do
      nil ->
        state

      %{running: nil, queue: queue} = lane ->
        case :queue.out(queue) do
          {:empty, _queue} ->
            %{state | lanes: Map.delete(state.lanes, resource)}

          {{:value, request}, rest} ->
            state
            |> put_lane(resource, %{lane | queue: rest})
            |> notify_queued_lifecycle(rest)
            |> start_request(resource, request)
        end

      _lane ->
        state
    end
  end

  @spec supersede_lane(State.t(), Request.resource(), State.lane()) :: State.t()
  defp supersede_lane(state, resource, lane) do
    state = stop_running_task(state, lane.running)
    requests = current_request(lane.running) ++ :queue.to_list(lane.queue)
    state = put_lane(state, resource, %{lane | running: nil, queue: :queue.new()})

    Enum.reduce(requests, state, fn request, acc ->
      terminalize_direct(acc, Outcome.canceled(request, :superseded))
    end)
  end

  @spec stop_running_task(State.t(), State.running() | nil) :: State.t()
  defp stop_running_task(state, %{task: %Task{} = task}) do
    _shutdown_result = Task.shutdown(task, :brutal_kill)
    Process.demonitor(task.ref, [:flush])
    %{state | tasks: Map.delete(state.tasks, task.ref)}
  end

  defp stop_running_task(state, _running), do: state

  @spec current_request(State.running() | nil) :: [Request.t()]
  defp current_request(%{request: request}), do: [request]
  defp current_request(nil), do: []

  @spec cancel_running_without_advance(State.t(), Request.resource(), State.lane(), term()) ::
          State.t()
  defp cancel_running_without_advance(
         state,
         resource,
         %{running: %{task: %Task{} = task} = running} = lane,
         reason
       ) do
    _shutdown_result = Task.shutdown(task, :brutal_kill)
    Process.demonitor(task.ref, [:flush])

    state
    |> Map.put(:tasks, Map.delete(state.tasks, task.ref))
    |> put_lane(resource, %{lane | running: %{running | task: nil}})
    |> deliver_result(Outcome.canceled(running.request, reason))
  end

  @spec request_id_for_operation(State.t(), MingaEditor.State.Operation.id()) ::
          Request.id() | nil
  defp request_id_for_operation(state, operation_id) do
    Enum.find_value(state.lanes, fn {_resource, lane} ->
      case lane.running do
        %{request: %Request{operation_id: ^operation_id, id: request_id}} -> request_id
        _running -> queued_request_id_for_operation(lane.queue, operation_id)
      end
    end)
  end

  @spec queued_request_id_for_operation(
          :queue.queue(Request.t()),
          MingaEditor.State.Operation.id()
        ) ::
          Request.id() | nil
  defp queued_request_id_for_operation(queue, operation_id) do
    queue
    |> :queue.to_list()
    |> Enum.find_value(fn
      %Request{operation_id: ^operation_id, id: request_id} -> request_id
      %Request{} -> nil
    end)
  end

  @spec cancel_request(State.t(), Request.id()) :: {:ok, State.t()} | :not_found
  defp cancel_request(state, request_id) do
    Enum.reduce_while(state.lanes, :not_found, fn {resource, lane}, _acc ->
      case cancel_in_lane(state, resource, lane, request_id) do
        :not_found -> {:cont, :not_found}
        {:ok, new_state} -> {:halt, {:ok, new_state}}
      end
    end)
  end

  @spec cancel_in_lane(State.t(), Request.resource(), State.lane(), Request.id()) ::
          {:ok, State.t()} | :not_found
  defp cancel_in_lane(
         state,
         resource,
         %{running: %{task: %Task{}, request: %{id: request_id}}} = lane,
         request_id
       ) do
    {:ok, cancel_running_without_advance(state, resource, lane, :requested)}
  end

  defp cancel_in_lane(state, resource, lane, request_id) do
    queued = :queue.to_list(lane.queue)

    case Enum.split_with(queued, &(&1.id == request_id)) do
      {[], _rest} ->
        :not_found

      {[request], rest} ->
        queue = :queue.from_list(rest)

        state =
          state
          |> put_lane(resource, %{lane | queue: queue})
          |> notify_queued_lifecycle(queue)

        {:ok, deliver_result(state, Outcome.canceled(request, :requested))}
    end
  end

  @spec cancel_matching(State.t(), (Request.t() -> boolean()), term(), boolean()) :: State.t()
  defp cancel_matching(state, match?, reason, notify_owner?) do
    {state, resources} = cancel_matching_lanes(state, match?, reason, notify_owner?)

    state =
      state.pending
      |> Enum.map(fn {_request_id, outcome} -> outcome.request end)
      |> Enum.filter(match?)
      |> Enum.reduce(state, fn request, acc ->
        terminalize_canceled_request(acc, request, reason, notify_owner?)
      end)

    Enum.reduce(resources, state, &start_next(&2, &1))
  end

  @spec cancel_matching_lanes(State.t(), (Request.t() -> boolean()), term(), boolean()) ::
          {State.t(), [Request.resource()]}
  defp cancel_matching_lanes(state, match?, reason, notify_owner?) do
    Enum.reduce(state.lanes, {state, []}, fn {resource, lane}, {acc, resources} ->
      {acc, running, canceled_running} = cancel_matching_running(acc, lane.running, match?)
      {queue, canceled_queued} = split_matching_queue(lane.queue, match?)
      changed? = canceled_running != [] or canceled_queued != []

      acc =
        acc
        |> put_lane(resource, %{lane | running: running, queue: queue})
        |> maybe_notify_queued_lifecycle(queue, changed?)

      acc =
        Enum.reduce(canceled_running ++ canceled_queued, acc, fn request, inner_acc ->
          terminalize_canceled_request(inner_acc, request, reason, notify_owner?)
        end)

      if changed?, do: {acc, [resource | resources]}, else: {acc, resources}
    end)
  end

  @spec cancel_matching_running(
          State.t(),
          State.running() | nil,
          (Request.t() -> boolean())
        ) :: {State.t(), State.running() | nil, [Request.t()]}
  defp cancel_matching_running(state, %{request: request} = running, match?) do
    if match?.(request) do
      {stop_running_task(state, running), nil, [request]}
    else
      {state, running, []}
    end
  end

  defp cancel_matching_running(state, nil, _match?), do: {state, nil, []}

  @spec split_matching_queue(:queue.queue(Request.t()), (Request.t() -> boolean())) ::
          {:queue.queue(Request.t()), [Request.t()]}
  defp split_matching_queue(queue, match?) do
    {canceled, retained} = queue |> :queue.to_list() |> Enum.split_with(match?)
    {:queue.from_list(retained), canceled}
  end

  @spec maybe_notify_queued_lifecycle(State.t(), :queue.queue(Request.t()), boolean()) ::
          State.t()
  defp maybe_notify_queued_lifecycle(state, queue, true),
    do: notify_queued_lifecycle(state, queue)

  defp maybe_notify_queued_lifecycle(state, _queue, false), do: state

  @spec terminalize_canceled_request(State.t(), Request.t(), term(), boolean()) :: State.t()
  defp terminalize_canceled_request(state, request, reason, notify_owner?) do
    outcome = Outcome.canceled(request, reason)

    state =
      state
      |> release_current(request)
      |> Map.put(:pending, Map.delete(state.pending, request.id))
      |> Map.put(:claimed, MapSet.delete(state.claimed, request.id))

    if MapSet.member?(state.admitted, request.id) do
      if notify_owner?, do: notify_lifecycle(state.owner, outcome)
      notify_terminal(state.observer, outcome)
      release_admission(state, request.id)
    else
      state
    end
  end

  @spec running_request(State.t(), Request.resource()) :: Request.t()
  defp running_request(state, resource) do
    state.lanes |> Map.fetch!(resource) |> Map.fetch!(:running) |> Map.fetch!(:request)
  end

  @spec take_candidate(State.t(), Outcome.t()) :: {:ok, State.t()} | :not_found
  defp take_candidate(state, %Outcome{} = outcome) do
    request_id = outcome.request.id

    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        :not_found

      {%Outcome{}, pending} ->
        state =
          state
          |> Map.put(:pending, pending)
          |> Map.put(:claimed, MapSet.delete(state.claimed, request_id))
          |> release_admission(request_id)
          |> release_current(outcome.request)

        {:ok, state}
    end
  end

  @spec deliver_result(State.t(), Outcome.t()) :: State.t()
  defp deliver_result(%State{owner: owner} = state, %Outcome{} = outcome) when is_pid(owner) do
    send(owner, {:effect_result, self(), outcome})
    %{state | pending: Map.put(state.pending, outcome.request.id, outcome)}
  end

  defp deliver_result(state, %Outcome{} = outcome), do: terminalize_direct(state, outcome)

  @spec terminalize_direct(State.t(), Outcome.t()) :: State.t()
  defp terminalize_direct(state, %Outcome{} = outcome) do
    request_id = outcome.request.id

    if MapSet.member?(state.admitted, request_id) do
      notify_lifecycle(state.owner, outcome)
      notify_terminal(state.observer, outcome)

      state
      |> Map.put(:pending, Map.delete(state.pending, request_id))
      |> Map.put(:claimed, MapSet.delete(state.claimed, request_id))
      |> release_admission(request_id)
    else
      state
    end
  end

  @spec admit_request(State.t(), Request.t()) :: State.t()
  defp admit_request(state, %Request{id: request_id}) do
    %{state | admitted: MapSet.put(state.admitted, request_id)}
  end

  @spec release_admission(State.t(), Request.id()) :: State.t()
  defp release_admission(state, request_id) do
    %{state | admitted: MapSet.delete(state.admitted, request_id)}
  end

  @spec capacity_available?(State.t()) :: boolean()
  defp capacity_available?(state), do: MapSet.size(state.admitted) < state.max_admitted

  @spec release_current(State.t(), Request.t()) :: State.t()
  defp release_current(state, %Request{resource: resource, id: request_id}) do
    case Map.get(state.lanes, resource) do
      %{running: %{request: %{id: ^request_id}}} = lane ->
        put_lane(state, resource, %{lane | running: nil})

      _lane ->
        state
    end
  end

  @spec notify_queued_lifecycle(State.t(), :queue.queue(Request.t())) :: State.t()
  defp notify_queued_lifecycle(%State{} = state, queue) do
    requests = :queue.to_list(queue)
    total = Enum.count(requests)

    requests
    |> Enum.with_index(1)
    |> Enum.each(fn {request, position} ->
      notify_lifecycle(state.owner, Outcome.queued(request, position, total))
    end)

    state
  end

  @spec notify_lifecycle(pid() | nil, Outcome.t()) :: :ok
  defp notify_lifecycle(owner, outcome) when is_pid(owner) do
    send(owner, {:effect_lifecycle, outcome})
    :ok
  end

  defp notify_lifecycle(_owner, _outcome), do: :ok

  @spec notify_terminal(pid() | nil, Outcome.t()) :: :ok
  defp notify_terminal(observer, outcome) when is_pid(observer) do
    send(observer, {:effect_terminal, outcome})
    :ok
  end

  defp notify_terminal(_observer, _outcome), do: :ok

  @spec put_lane(State.t(), Request.resource(), State.lane()) :: State.t()
  defp put_lane(state, resource, lane) do
    %{state | lanes: Map.put(state.lanes, resource, lane)}
  end

  @spec handler_active?(State.t(), module()) :: boolean()
  defp handler_active?(state, handler) do
    request_active?(state, &(&1.handler == handler))
  end

  @spec request_active?(State.t(), (Request.t() -> boolean())) :: boolean()
  defp request_active?(state, match?) do
    Enum.any?(state.lanes, fn {_resource, lane} ->
      running_matches?(lane.running, match?) or queued_matches?(lane.queue, match?)
    end) or Enum.any?(state.pending, fn {_id, outcome} -> match?.(outcome.request) end)
  end

  @spec running_matches?(State.running() | nil, (Request.t() -> boolean())) :: boolean()
  defp running_matches?(%{request: request}, match?), do: match?.(request)
  defp running_matches?(_running, _match?), do: false

  @spec queued_matches?(:queue.queue(Request.t()), (Request.t() -> boolean())) :: boolean()
  defp queued_matches?(queue, match?) do
    queue |> :queue.to_list() |> Enum.any?(match?)
  end

  @spec shutdown_all(State.t(), term()) :: State.t()
  defp shutdown_all(state, reason) do
    requests =
      state.lanes
      |> Enum.flat_map(fn {_resource, lane} ->
        current_request(lane.running) ++ :queue.to_list(lane.queue)
      end)
      |> Enum.concat(Enum.map(state.pending, fn {_id, outcome} -> outcome.request end))
      |> Map.new(fn request -> {request.id, request} end)

    Enum.each(state.lanes, fn
      {_resource, %{running: %{task: %Task{} = task}}} ->
        _shutdown_result = Task.shutdown(task, :brutal_kill)
        Process.demonitor(task.ref, [:flush])

      _lane ->
        :ok
    end)

    Enum.each(state.admitted, fn request_id ->
      case Map.fetch(requests, request_id) do
        {:ok, request} -> notify_terminal(state.observer, Outcome.canceled(request, reason))
        :error -> :ok
      end
    end)

    %{
      state
      | lanes: %{},
        tasks: %{},
        pending: %{},
        admitted: MapSet.new(),
        claimed: MapSet.new()
    }
  end
end
