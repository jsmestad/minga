defmodule MingaEditor.EffectScheduler.Engine do
  @moduledoc "Lifecycle, admission-policy, and worker coordination for `EffectScheduler`."

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler.State

  @type admission_error ::
          :owner_unavailable | :policy_mismatch | :queue_full | :scheduler_full
  @type admission :: {:ok, reference(), :running | :queued} | {:error, admission_error()}
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
  @spec cancel(State.t(), reference()) :: {:ok | {:error, :not_found}, State.t()}
  def cancel(%State{} = state, request_id) do
    case cancel_request(state, request_id) do
      {:ok, state} -> {:ok, state}
      :not_found -> {{:error, :not_found}, state}
    end
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
  defp admit(state, %Request{resource: resource, policy: policy} = request) do
    case Map.get(state.lanes, resource) do
      nil ->
        admit_new_lane(state, resource, policy, request)

      %{policy: existing_policy} when existing_policy != policy ->
        {{:error, :policy_mismatch}, state}

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
        notify_lifecycle(state.owner, Outcome.queued(request))

        state =
          state
          |> admit_request(request)
          |> put_lane(resource, %{lane | queue: queue})

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
        notify_lifecycle(state.owner, Outcome.queued(request))

        state =
          state
          |> admit_request(request)
          |> put_lane(resource, %{lane | queue: queue})

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

        notify_lifecycle(state.owner, Outcome.queued(request))
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

    state
    |> Map.put(:tasks, Map.delete(state.tasks, task.ref))
    |> put_lane(resource, %{lane | running: %{running | task: nil}})
    |> deliver_result(Outcome.canceled(running.request, reason))
  end

  @spec cancel_request(State.t(), reference()) :: {:ok, State.t()} | :not_found
  defp cancel_request(state, request_id) do
    Enum.reduce_while(state.lanes, :not_found, fn {resource, lane}, _acc ->
      case cancel_in_lane(state, resource, lane, request_id) do
        :not_found -> {:cont, :not_found}
        {:ok, new_state} -> {:halt, {:ok, new_state}}
      end
    end)
  end

  @spec cancel_in_lane(State.t(), Request.resource(), State.lane(), reference()) ::
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
        state = put_lane(state, resource, %{lane | queue: :queue.from_list(rest)})
        {:ok, deliver_result(state, Outcome.canceled(request, :requested))}
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

  @spec release_admission(State.t(), reference()) :: State.t()
  defp release_admission(state, request_id) do
    %{state | admitted: MapSet.delete(state.admitted, request_id)}
  end

  @spec capacity_available?(State.t()) :: boolean()
  defp capacity_available?(state), do: MapSet.size(state.admitted) < state.max_admitted

  @spec release_current(State.t(), Request.t()) :: State.t()
  defp release_current(state, %Request{resource: resource, id: request_id}) do
    case Map.get(state.lanes, resource) do
      %{running: %{request: %{id: ^request_id}}} = lane ->
        state
        |> put_lane(resource, %{lane | running: nil})
        |> start_next(resource)

      _lane ->
        state
    end
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
    Enum.any?(state.lanes, fn {_resource, lane} ->
      running_handler?(lane.running, handler) or queued_handler?(lane.queue, handler)
    end) or Enum.any?(state.pending, fn {_id, outcome} -> outcome.request.handler == handler end)
  end

  @spec running_handler?(State.running() | nil, module()) :: boolean()
  defp running_handler?(%{request: %{handler: handler}}, handler), do: true
  defp running_handler?(_running, _handler), do: false

  @spec queued_handler?(:queue.queue(Request.t()), module()) :: boolean()
  defp queued_handler?(queue, handler) do
    queue |> :queue.to_list() |> Enum.any?(&(&1.handler == handler))
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
      {_resource, %{running: %{task: %Task{} = task}}} -> Task.shutdown(task, :brutal_kill)
      _lane -> :ok
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
