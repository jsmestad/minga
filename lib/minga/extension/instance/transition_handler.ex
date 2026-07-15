defmodule Minga.Extension.Instance.TransitionHandler do
  @moduledoc "Extension Instance  transitionhandler logic."

  alias Minga.Extension.Instance.Projection
  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.StartContext
  alias Minga.Extension.Instance.State
  alias Minga.Extension.Instance.StopContext
  alias Minga.Extension.Instance.Worker
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.RuntimeSupervisor
  alias Minga.Log

  import Minga.Extension.Instance.Lifecycle

  @type callback_result :: {:reply, term(), State.t()} | {:noreply, State.t()}
  @default_transition_timeout_ms 120_000
  @default_callback_timeout_ms 5_000
  @default_runtime_query_timeout_ms 100
  @default_drain_timeout_ms 5_000

  @spec transition_done(State.t(), reference(), term()) :: {:noreply, State.t()}
  def transition_done(
        %State{phase: {:starting, %StartContext{worker: %Worker{id: id} = worker} = context}} =
          state,
        id,
        result
      ) do
    :ok = Worker.complete(worker)
    state = State.starting(state, StartContext.finish_work(context))

    case result do
      {:ok, workflow_result} ->
        Minga.Extension.Instance.StartTransition.start_workflow_done(state, workflow_result)

      {:error, reason} ->
        start_worker_failed(state, reason)
    end
  end

  def transition_done(
        %State{
          phase:
            {:stopping,
             %StopContext{worker: %Worker{id: id, kind: {:finalizer, family}} = worker} = context}
        } = state,
        id,
        result
      ) do
    :ok = Worker.complete(worker)
    state = State.stopping(state, StopContext.finish_work(context))
    callback_result = if match?({:ok, _}, result), do: elem(result, 1), else: result

    Minga.Extension.Instance.QuiescenceTransition.finalizer_ack(
      state,
      id,
      family,
      callback_result
    )
  end

  def transition_done(
        %State{
          phase:
            {:stopping,
             %StopContext{worker: %Worker{id: id, kind: :terminate} = worker} = context}
        } =
          state,
        id,
        result
      ) do
    :ok = Worker.complete(worker)
    state = State.stopping(state, StopContext.finish_work(context))

    case result do
      {:ok, :ok} ->
        Minga.Extension.Instance.StopTransition.request_cleanup(state)

      {:ok, {:error, reason}} ->
        runtime_termination_failed(state, reason)

      {:error, reason} ->
        runtime_termination_failed(state, reason)
    end
  end

  def transition_done(
        %State{
          phase:
            {:stopping, %StopContext{worker: %Worker{id: id, kind: :cleanup} = worker} = context}
        } =
          state,
        id,
        result
      ) do
    :ok = Worker.complete(worker)
    context = StopContext.finish_work(context)

    cleanup_result =
      case result do
        {:ok, value} -> value
        {:error, reason} -> {:error, [worker_cleanup_failure(state.name, reason)]}
      end

    Minga.Extension.Instance.StopTransition.finish_stop(
      State.stopping(state, context),
      context,
      cleanup_result
    )
  end

  def transition_done(state, _id, _result), do: {:noreply, state}

  @spec transition_timeout(State.t(), reference(), Worker.kind()) :: {:noreply, State.t()}
  def transition_timeout(
        %State{phase: {:starting, %StartContext{worker: %Worker{id: id} = worker}}} = state,
        id,
        kind
      ) do
    :ok = Worker.timeout(worker)
    reason = {:transition_timeout, kind, transition_timeout(state)}
    start_timeout_failed(state, worker, reason)
  end

  def transition_timeout(
        %State{
          phase:
            {:stopping,
             %StopContext{worker: %Worker{id: id, kind: :terminate} = worker} = context}
        } = state,
        id,
        :terminate
      ) do
    :ok = Worker.timeout(worker)

    reason =
      {:runtime_termination_failed, {:transition_timeout, :terminate, callback_timeout(state)}}

    replace_runtime_branch(State.stopping(state, StopContext.finish_work(context)), reason)
  end

  def transition_timeout(
        %State{phase: {:stopping, %StopContext{worker: %Worker{id: id} = worker}}} = state,
        id,
        kind
      ) do
    :ok = Worker.timeout(worker)
    transition_failed(state, worker, {:transition_timeout, kind, callback_timeout(state)})
  end

  def transition_timeout(state, _id, _kind), do: {:noreply, state}

  @spec process_down(State.t(), reference(), pid(), term()) :: {:noreply, State.t()}
  def process_down(
        %State{
          phase: {:starting, %StartContext{worker: %Worker{monitor: ref, pid: pid} = worker}}
        } = state,
        ref,
        pid,
        reason
      ) do
    :ok = Worker.down(worker)
    transition_failed(state, worker, {:transition_worker_down, worker.kind, reason})
  end

  def process_down(
        %State{phase: {:stopping, %StopContext{worker: %Worker{monitor: ref, pid: pid} = worker}}} =
          state,
        ref,
        pid,
        reason
      ) do
    :ok = Worker.down(worker)
    transition_failed(state, worker, {:transition_worker_down, worker.kind, reason})
  end

  def process_down(state, ref, pid, reason),
    do: Minga.Extension.Instance.RuntimeTransition.runtime_down(state, ref, pid, reason)

  @spec transition_failed(State.t(), Worker.t(), term()) :: {:noreply, State.t()}
  def transition_failed(%State{phase: {:starting, context}} = state, _worker, reason) do
    state = State.starting(state, StartContext.finish_work(context))
    start_worker_failed(state, reason)
  end

  def transition_failed(
        %State{phase: {:stopping, context}} = state,
        %Worker{kind: {:finalizer, family}, id: id},
        reason
      ) do
    state = State.stopping(state, StopContext.finish_work(context))

    Minga.Extension.Instance.QuiescenceTransition.finalizer_ack(
      state,
      id,
      family,
      {:error, reason}
    )
  end

  def transition_failed(
        %State{phase: {:stopping, context}} = state,
        %Worker{kind: :terminate},
        reason
      ) do
    runtime_termination_failed(
      State.stopping(state, StopContext.finish_work(context)),
      reason
    )
  end

  def transition_failed(
        %State{phase: {:stopping, context}} = state,
        %Worker{kind: :cleanup},
        reason
      ) do
    context = StopContext.finish_work(context)

    Minga.Extension.Instance.StopTransition.finish_stop(
      State.stopping(state, context),
      context,
      {:error, [worker_cleanup_failure(state.name, reason)]}
    )
  end

  @spec start_timeout_failed(
          State.t(),
          Worker.t(),
          term()
        ) :: {:noreply, State.t()}
  def start_timeout_failed(
        %State{phase: {:starting, %StartContext{runtime: %Runtime{pid: pid}} = context}} = state,
        _worker,
        reason
      ) do
    state = State.starting(state, StartContext.finish_work(context))

    Minga.Extension.Instance.StartTransition.begin_start_rollback(
      state,
      context.waiters,
      context.stop_waiters,
      reason,
      pid
    )
  end

  def start_timeout_failed(
        %State{phase: {:starting, context}} = state,
        _worker,
        reason
      ) do
    state = State.starting(state, StartContext.finish_work(context))

    case RuntimeSupervisor.local_child(runtime_supervisor(state), runtime_query_timeout(state)) do
      {:ok, pid} ->
        Minga.Extension.Instance.StartTransition.begin_start_rollback(
          state,
          context.waiters,
          context.stop_waiters,
          reason,
          pid
        )

      :empty ->
        Minga.Extension.Instance.StartTransition.begin_start_rollback(
          state,
          context.waiters,
          context.stop_waiters,
          reason,
          nil
        )

      {:error, {:runtime_supervisor_unavailable, :timeout}} ->
        replace_runtime_branch(state, reason)

      {:error, _reason} ->
        replace_runtime_branch(state, reason)
    end
  end

  @spec start_worker_failed(State.t(), term()) ::
          {:noreply, State.t()}
  def start_worker_failed(
        %State{phase: {:starting, %StartContext{runtime: %Runtime{pid: pid}} = context}} = state,
        reason
      ) do
    Minga.Extension.Instance.StartTransition.begin_start_rollback(
      state,
      context.waiters,
      context.stop_waiters,
      reason,
      pid
    )
  end

  def start_worker_failed(
        %State{phase: {:starting, context}} = state,
        reason
      ) do
    case RuntimeSupervisor.local_child(runtime_supervisor(state), runtime_query_timeout(state)) do
      {:ok, pid} ->
        Minga.Extension.Instance.StartTransition.begin_start_rollback(
          state,
          context.waiters,
          context.stop_waiters,
          reason,
          pid
        )

      :empty ->
        Minga.Extension.Instance.StartTransition.begin_start_rollback(
          state,
          context.waiters,
          context.stop_waiters,
          reason,
          nil
        )

      {:error, _supervisor_reason} ->
        replace_runtime_branch(state, reason)
    end
  end

  @spec runtime_termination_failed(State.t(), term()) ::
          {:noreply, State.t()}
  def runtime_termination_failed(
        %State{phase: {:stopping, context}} = state,
        reason
      ) do
    failure = {:runtime_termination_failed, reason}

    case context.exit_kind do
      :explicit ->
        Minga.Extension.Instance.StopTransition.stop_failed(state, failure)

      _terminal ->
        updated = StopContext.record_terminal_failure(context, failure)
        Minga.Extension.Instance.StopTransition.request_cleanup(State.stopping(state, updated))
    end
  end

  @spec worker_cleanup_failure(atom(), term()) :: map()
  def worker_cleanup_failure(name, reason) do
    %{family: :cleanup_worker, source: {:extension, name}, reason: reason}
  end

  @spec transition_timeout(State.t()) :: pos_integer()
  def transition_timeout(state) do
    Keyword.get(state.collaborators, :transition_timeout_ms, @default_transition_timeout_ms)
  end

  @spec callback_timeout(State.t()) :: pos_integer()
  def callback_timeout(state) do
    Keyword.get(state.collaborators, :callback_timeout_ms, @default_callback_timeout_ms)
  end

  @spec drain_timeout_ms(State.t()) :: pos_integer()
  def drain_timeout_ms(state) do
    Keyword.get(state.collaborators, :drain_timeout_ms, @default_drain_timeout_ms)
  end

  @spec runtime_query_timeout(State.t()) :: pos_integer()
  def runtime_query_timeout(state) do
    Keyword.get(
      state.collaborators,
      :runtime_query_timeout_ms,
      @default_runtime_query_timeout_ms
    )
  end

  @spec replace_runtime_branch(State.t(), term()) :: {:noreply, State.t()}
  def replace_runtime_branch(%State{phase: {:starting, context}} = state, reason) do
    failed = State.load_error(state, reason)
    reply_reason = publish_failure_reason(failed, reason)
    Enum.each(context.waiters, &GenServer.reply(&1, {:error, reply_reason}))
    Enum.each(context.stop_waiters, &GenServer.reply(&1, {:error, reply_reason}))
    replace_runtime_branch_processes(state, context.runtime)
    {:noreply, failed}
  end

  def replace_runtime_branch(%State{phase: {:stopping, context}} = state, reason) do
    retry = StopContext.cleanup_retry(context)
    failed = State.cleanup_failed(state, reason, retry)
    reply_reason = publish_failure_reason(failed, reason)
    reply_stop_context(context, reply_reason)
    replace_runtime_branch_processes(state, context.runtime)
    {:noreply, failed}
  end

  def replace_runtime_branch(state, reason) do
    failed = State.load_error(state, reason)
    _reply_reason = publish_failure_reason(failed, reason)
    replace_runtime_branch_processes(state, State.runtime(state.phase))
    {:noreply, failed}
  end

  @spec publish_failure_reason(State.t(), term()) :: term()
  def publish_failure_reason(state, reason) do
    case Projection.publish(state) do
      :ok ->
        reason

      {:error, projection_reason} ->
        publication_failure(state.name, reason, projection_reason)
    end
  end

  @spec publish_terminal(State.t(), term()) :: {State.t(), term(), :ok | :error}
  def publish_terminal(state, reason) do
    case Projection.publish(state) do
      :ok ->
        {state, reason, :ok}

      {:error, projection_reason} ->
        failure = publication_failure(state.name, reason, projection_reason)
        {put_terminal_failure(state, failure), failure, :error}
    end
  end

  @spec put_terminal_failure(State.t(), term()) :: State.t()
  def put_terminal_failure(state, failure), do: State.replace_terminal_failure(state, failure)

  @spec publication_failure(atom(), term(), term()) :: term()
  def publication_failure(name, reason, reason) do
    log_publication_failure(name, reason)
    reason
  end

  def publication_failure(
        name,
        {:lifecycle_failure, _reason, _projection} = failure,
        _projection_reason
      ) do
    log_publication_failure(name, failure)
    failure
  end

  def publication_failure(name, reason, projection_reason) do
    failure = {:lifecycle_failure, reason, {:projection_failed, projection_reason}}
    log_publication_failure(name, failure)
    failure
  end

  @spec log_publication_failure(atom(), term()) :: :ok
  def log_publication_failure(name, failure) do
    Log.error(
      :ext,
      "Extension #{name} lifecycle projection failed: #{inspect(failure)}"
    )
  end

  @spec reply_terminal_waiters(StopContext.t(), term()) :: :ok
  def reply_terminal_waiters(context, reply) do
    case context.completion do
      {:start_failure, _reason, start_waiters} ->
        Enum.each(start_waiters, &GenServer.reply(&1, reply))

      :stop ->
        :ok
    end

    Enum.each(context.waiters, &GenServer.reply(&1, reply))
    Minga.Extension.Instance.StopTransition.reply_queued_starts(context.start_waiters, reply)
  end

  @spec reply_stop_context(StopContext.t(), term()) :: :ok
  def reply_stop_context(context, reason) do
    case context.completion do
      {:start_failure, _start_reason, start_waiters} ->
        Enum.each(start_waiters, &GenServer.reply(&1, {:error, reason}))

      :stop ->
        :ok
    end

    Enum.each(context.waiters, &GenServer.reply(&1, {:error, reason}))

    Minga.Extension.Instance.StopTransition.reply_queued_starts(
      context.start_waiters,
      {:error, {:cleanup_retry_required, reason}}
    )
  end

  @spec replace_runtime_branch_processes(State.t(), Runtime.t() | nil) :: :ok
  def replace_runtime_branch_processes(state, runtime) do
    if runtime != nil, do: Process.exit(runtime.pid, :kill)

    case InstanceRegistry.whereis(state.instance_registry, :runtime, state.name) do
      pid when is_pid(pid) ->
        Process.flag(:trap_exit, false)
        Process.exit(pid, :kill)

      nil ->
        Process.exit(self(), :kill)
    end

    :ok
  end
end
