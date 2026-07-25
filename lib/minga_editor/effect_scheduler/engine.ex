defmodule MingaEditor.EffectScheduler.Engine do
  @moduledoc "Lifecycle, admission-policy, and worker coordination for `EffectScheduler`."

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler.Lane
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

  @doc "Returns whether any active request advertises a semantic activity."
  @spec active_activity?(State.t(), atom()) :: boolean()
  def active_activity?(%State{} = state, activity) when is_atom(activity) do
    request_active?(state, &(&1.activity == activity))
  end

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
    queued = Enum.sum(Enum.map(state.lanes, fn {_resource, lane} -> :queue.len(lane.queue) end))

    %{
      resources: map_size(state.lanes),
      running: map_size(state.tasks),
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

  @doc "Processes a scheduler-owned request timeout."
  @spec timeout(State.t(), Request.id()) :: State.t()
  def timeout(%State{} = state, request_id) do
    case Enum.find_value(state.timers, fn
           {timer_ref, ^request_id} -> timer_ref
           {_timer_ref, _other_request_id} -> nil
         end) do
      nil -> state
      timer_ref -> timeout(state, timer_ref, request_id)
    end
  end

  @spec timeout(State.t(), reference(), Request.id()) :: State.t()
  defp timeout(%State{} = state, timer_ref, request_id) do
    case Map.pop(state.timers, timer_ref) do
      {^request_id, timers} ->
        state = %{state | timers: timers}
        timeout_running(state, request_id)

      {_other, _timers} ->
        state
    end
  end

  @doc "Processes a successful worker reply."
  @spec task_result(State.t(), reference(), term()) :: State.t()
  def task_result(%State{} = state, task_ref, result) do
    case Map.pop(state.tasks, task_ref) do
      {nil, _tasks} ->
        state

      {{resource, request_id, _task}, tasks} ->
        Process.demonitor(task_ref, [:flush])

        state
        |> Map.put(:tasks, tasks)
        |> clear_timer(request_id)
        |> finish_running(resource, outcome_from_result(state, resource, result))
    end
  end

  @doc "Processes an owner or worker DOWN message."
  @spec process_down(State.t(), reference(), pid(), term()) :: State.t()
  def process_down(%State{owner_monitor: ref, owner: owner} = state, ref, owner, _reason) do
    state = shutdown_all(state, :owner_shutdown)
    %{state | owner: nil, owner_monitor: nil}
  end

  def process_down(%State{} = state, task_ref, _pid, reason) do
    case Map.pop(state.tasks, task_ref) do
      {nil, _tasks} ->
        state

      {{resource, request_id, _task}, tasks} ->
        request = running_request(state, resource)

        state
        |> Map.put(:tasks, tasks)
        |> clear_timer(request_id)
        |> finish_running(resource, Outcome.failed(request, {:worker_exit, reason}))
    end
  end

  @doc "Stops all work and terminalizes every admitted request."
  @spec shutdown(State.t(), term()) :: State.t()
  def shutdown(%State{} = state, reason), do: shutdown_all(state, reason)

  @spec handoff_outcome(Outcome.t(), admission()) :: Outcome.t()
  defp handoff_outcome(outcome, {:ok, _request_id, _disposition}), do: outcome
  defp handoff_outcome(outcome, {:error, reason}), do: Outcome.failed(outcome.request, reason)

  @spec admit(State.t(), Request.t()) :: {admission(), State.t()}
  defp admit(state, %Request{id: request_id, resource: resource} = request) do
    if MapSet.member?(state.admitted, request_id) do
      {{:error, :already_admitted}, state}
    else
      {reply, lane, actions} =
        Lane.admit(Map.get(state.lanes, resource), request, capacity_available?(state))

      state = put_lane_or_delete(state, resource, lane)

      case reply do
        {:ok, ^request_id, _disposition} ->
          state = state |> admit_request(request) |> apply_actions(actions)
          {reply, state}

        {:error, _reason} ->
          {reply, state}
      end
    end
  end

  @spec start_request(State.t(), Request.resource(), Request.t()) :: State.t()
  defp start_request(state, resource, request) do
    notify_lifecycle(state.owner, Outcome.running(request))

    case start_task(state.task_supervisor, request) do
      {:ok, task} ->
        state
        |> put_in([Access.key(:tasks), task.ref], {resource, request.id, task})
        |> arm_timeout(request)

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

  @spec timeout_running(State.t(), Request.id()) :: State.t()
  defp timeout_running(state, request_id) do
    case Enum.find(state.lanes, fn {_resource, lane} ->
           match?(%Request{id: ^request_id}, lane.running)
         end) do
      {resource, %Lane{running: request}} ->
        state = stop_request(state, request)
        finish_running(state, resource, Outcome.failed(request, :timeout))

      nil ->
        state
    end
  end

  @spec arm_timeout(State.t(), Request.t()) :: State.t()
  defp arm_timeout(state, %Request{timeout_ms: nil}), do: state

  defp arm_timeout(state, %Request{timeout_ms: timeout_ms, id: request_id}) do
    timer_ref = Process.send_after(self(), {:effect_timeout, request_id}, timeout_ms)
    %{state | timers: Map.put(state.timers, timer_ref, request_id)}
  end

  @spec clear_timer(State.t(), Request.id()) :: State.t()
  defp clear_timer(state, request_id) do
    case Enum.find_value(state.timers, fn
           {timer_ref, ^request_id} -> timer_ref
           {_timer_ref, _other_request_id} -> nil
         end) do
      nil -> state
      timer_ref -> cancel_timer(state, timer_ref)
    end
  end

  @spec cancel_timer(State.t(), reference()) :: State.t()
  defp cancel_timer(state, timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    %{state | timers: Map.delete(state.timers, timer_ref)}
  end

  @spec finish_running(State.t(), Request.resource(), Outcome.t()) :: State.t()
  defp finish_running(state, _resource, outcome), do: deliver_result(state, outcome)

  @spec start_next(State.t(), Request.resource()) :: State.t()
  defp start_next(state, resource) do
    case Map.get(state.lanes, resource) do
      nil ->
        state

      %Lane{running: nil} = lane ->
        case Lane.finish_current(lane) do
          {:empty, actions} -> state |> delete_lane(resource) |> apply_actions(actions)
          {%Lane{} = lane, actions} -> state |> put_lane(resource, lane) |> apply_actions(actions)
        end

      %Lane{} ->
        state
    end
  end

  @spec request_id_for_operation(State.t(), MingaEditor.State.Operation.id()) ::
          Request.id() | nil
  defp request_id_for_operation(state, operation_id) do
    Enum.find_value(state.lanes, fn {_resource, lane} ->
      Lane.request_id_for_operation(lane, operation_id)
    end)
  end

  @spec cancel_request(State.t(), Request.id()) :: {:ok, State.t()} | :not_found
  defp cancel_request(state, request_id) do
    if Map.has_key?(state.pending, request_id) do
      :not_found
    else
      cancel_request_in_lanes(state, request_id)
    end
  end

  @spec cancel_request_in_lanes(State.t(), Request.id()) :: {:ok, State.t()} | :not_found
  defp cancel_request_in_lanes(state, request_id) do
    Enum.reduce_while(state.lanes, :not_found, fn {resource, lane}, _acc ->
      case Lane.cancel_request(lane, request_id) do
        :not_found ->
          {:cont, :not_found}

        {:ok, lane, actions} ->
          {:halt, {:ok, state |> put_lane(resource, lane) |> apply_actions(actions)}}
      end
    end)
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
      {lane, actions, changed?} = Lane.cancel_matching(lane, match?, reason)
      acc = acc |> put_lane(resource, lane) |> apply_actions(actions, notify_owner?)
      if changed?, do: {acc, [resource | resources]}, else: {acc, resources}
    end)
  end

  @spec running_request(State.t(), Request.resource()) :: Request.t()
  defp running_request(state, resource) do
    state.lanes |> Map.fetch!(resource) |> Map.fetch!(:running)
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

  @spec terminalize_canceled_request(State.t(), Request.t(), term(), boolean()) :: State.t()
  defp terminalize_canceled_request(state, request, reason, notify_owner?) do
    outcome = Outcome.canceled(request, reason)
    request_id = request.id

    state =
      state
      |> release_current(request)
      |> Map.put(:pending, Map.delete(state.pending, request_id))
      |> Map.put(:claimed, MapSet.delete(state.claimed, request_id))

    if MapSet.member?(state.admitted, request_id) do
      if notify_owner?, do: notify_lifecycle(state.owner, outcome)
      notify_terminal(state.observer, outcome)
      release_admission(state, request_id)
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
  defp release_current(state, %Request{resource: resource} = request) do
    case Map.get(state.lanes, resource) do
      %Lane{} = lane ->
        case Lane.finalize_current(lane, request) do
          {:empty, actions} -> state |> delete_lane(resource) |> apply_actions(actions)
          {%Lane{} = lane, actions} -> state |> put_lane(resource, lane) |> apply_actions(actions)
        end

      nil ->
        state
    end
  end

  @spec apply_actions(State.t(), [Lane.action()], boolean()) :: State.t()
  defp apply_actions(state, actions, notify_owner? \\ true) do
    Enum.reduce(actions, state, fn
      {:start, request}, acc ->
        start_request(acc, request.resource, request)

      {:stop, request}, acc ->
        stop_request(acc, request)

      {:candidate, request, {:canceled, reason}}, acc ->
        deliver_result(acc, Outcome.canceled(request, reason))

      {:terminal, request, {:canceled, reason}}, acc ->
        terminalize_canceled_request(acc, request, reason, notify_owner?)

      {:terminal, request, {:stale, reason}}, acc ->
        terminalize_direct(acc, Outcome.stale(Outcome.canceled(request, reason), reason))

      {:queue, positions}, acc ->
        notify_queued_lifecycle(acc, positions)
    end)
  end

  @spec stop_request(State.t(), Request.t()) :: State.t()
  defp stop_request(state, %Request{id: request_id}) do
    case Enum.find(state.tasks, fn
           {_task_ref, {_resource, ^request_id, _task}} -> true
           _entry -> false
         end) do
      {task_ref, {_resource, ^request_id, %Task{} = task}} ->
        _shutdown_result = Task.shutdown(task, :brutal_kill)
        Process.demonitor(task_ref, [:flush])

        state
        |> Map.put(:tasks, Map.delete(state.tasks, task_ref))
        |> clear_timer(request_id)

      nil ->
        clear_timer(state, request_id)
    end
  end

  @spec notify_queued_lifecycle(State.t(), [{Request.t(), pos_integer(), non_neg_integer()}]) ::
          State.t()
  defp notify_queued_lifecycle(%State{} = state, positions) do
    Enum.each(positions, fn {request, position, total} ->
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

  @spec put_lane(State.t(), Request.resource(), Lane.t()) :: State.t()
  defp put_lane(state, resource, %Lane{} = lane),
    do: %{state | lanes: Map.put(state.lanes, resource, lane)}

  @spec put_lane_or_delete(State.t(), Request.resource(), Lane.t() | nil) :: State.t()
  defp put_lane_or_delete(state, resource, nil), do: delete_lane(state, resource)
  defp put_lane_or_delete(state, resource, %Lane{} = lane), do: put_lane(state, resource, lane)

  @spec delete_lane(State.t(), Request.resource()) :: State.t()
  defp delete_lane(state, resource), do: %{state | lanes: Map.delete(state.lanes, resource)}

  @spec handler_active?(State.t(), module()) :: boolean()
  defp handler_active?(state, handler) do
    request_active?(state, &(&1.handler == handler))
  end

  @spec request_active?(State.t(), (Request.t() -> boolean())) :: boolean()
  defp request_active?(state, match?) do
    Enum.any?(state.lanes, fn {_resource, lane} -> Lane.active?(lane, match?) end) or
      Enum.any?(state.pending, fn {_id, outcome} -> match?.(outcome.request) end)
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

    Enum.each(state.tasks, fn {_task_ref, {_resource, _request_id, %Task{} = task}} ->
      _shutdown_result = Task.shutdown(task, :brutal_kill)
      Process.demonitor(task.ref, [:flush])
    end)

    Enum.each(state.timers, fn {timer_ref, _request_id} -> cancel_timer_ref(timer_ref) end)

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
        claimed: MapSet.new(),
        timers: %{}
    }
  end

  @spec current_request(Request.t() | nil) :: [Request.t()]
  defp current_request(%Request{} = request), do: [request]
  defp current_request(nil), do: []

  @spec cancel_timer_ref(reference() | nil) :: :ok
  defp cancel_timer_ref(nil), do: :ok

  defp cancel_timer_ref(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end
end
