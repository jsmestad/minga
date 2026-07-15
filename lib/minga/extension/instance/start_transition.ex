defmodule Minga.Extension.Instance.StartTransition do
  @moduledoc "Extension Instance start transition logic."

  alias Minga.Extension.Instance.Artifact
  alias Minga.Extension.Instance.Contributions
  alias Minga.Extension.Instance.Projection
  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.Source
  alias Minga.Extension.Instance.StartContext
  alias Minga.Extension.Instance.State
  alias Minga.Extension.Instance.StopContext
  alias Minga.Extension.Instance.Worker
  alias Minga.Extension.RuntimeSupervisor

  import Minga.Extension.Instance.Lifecycle

  @type callback_result :: {:reply, term(), State.t()} | {:noreply, State.t()}

  @spec request_start(State.t(), GenServer.from()) :: callback_result()
  def request_start(%State{phase: {:running, runtime}} = state, from) do
    case Projection.publish(state) do
      :ok -> {:reply, {:ok, runtime.pid}, state}
      {:error, reason} -> begin_start_rollback(state, [from], [], reason, runtime.pid)
    end
  end

  def request_start(%State{phase: {:starting, context}} = state, from) do
    {:noreply, State.starting(state, StartContext.join(context, from))}
  end

  def request_start(%State{phase: {:stopping, _context}} = state, from),
    do: {:noreply, State.queue_start(state, {:current, from})}

  def request_start(%State{phase: {:cleanup_failed, failure}} = state, _from),
    do: {:reply, {:error, {:cleanup_retry_required, failure.reason}}, state}

  def request_start(state, from) do
    context = StartContext.new([from], state.phase)
    starting = State.starting(state, context)

    case Projection.publish(starting) do
      :ok ->
        send(self(), :perform_start)
        {:noreply, starting}

      {:error, reason} ->
        {:reply, {:error, reason}, State.load_error(state, reason)}
    end
  end

  @spec request_deferred_start(State.t(), GenServer.from(), Minga.Extension.Entry.t()) ::
          callback_result()
  def request_deferred_start(state, from, declaration) do
    if State.declaration_only(declaration) == state.declaration do
      request_current_deferred_start(state, from, declaration)
    else
      {:reply, {:error, :stale_deferred_declaration}, state}
    end
  end

  @spec request_current_deferred_start(State.t(), GenServer.from(), Minga.Extension.Entry.t()) ::
          callback_result()
  def request_current_deferred_start(
        %State{phase: {:stopping, _context}} = state,
        from,
        declaration
      ),
      do: {:noreply, State.queue_start(state, {:deferred, from, declaration})}

  def request_current_deferred_start(state, from, _declaration), do: request_start(state, from)

  @spec request_prerequisite_failure(State.t(), GenServer.from(), term()) :: callback_result()
  def request_prerequisite_failure(%State{phase: {:running, runtime}} = state, _from, _reason),
    do: {:reply, {:error, {:already_running, runtime.pid}}, state}

  def request_prerequisite_failure(%State{phase: {:stopping, _context}} = state, from, reason) do
    GenServer.reply(from, {:error, reason})
    {:noreply, state}
  end

  def request_prerequisite_failure(state, from, reason) do
    begin_start_rollback(state, [from], [], reason, nil)
  end

  @spec load_policy_result(State.t()) :: callback_result()
  def load_policy_result(state) do
    case prepare_artifact(state) do
      {:ok, artifact, prepared} ->
        policy = state.declaration.load_policy || artifact.manifest.load_policy || :eager

        case Projection.publish(prepared) do
          :ok ->
            {:reply, {:ok, policy}, prepared}

          {:error, reason} ->
            {:reply, {:error, reason}, State.load_error(prepared, reason)}
        end

      {:error, reason, prepared} ->
        failed = State.load_error(prepared, reason)

        {failed, reply_reason, _publication} =
          Minga.Extension.Instance.TransitionHandler.publish_terminal(failed, reason)

        {:reply, {:error, reply_reason}, failed}
    end
  end

  @spec request_stub(State.t()) :: callback_result()
  def request_stub(%State{phase: {:stub, _artifact}} = state), do: {:reply, :ok, state}
  def request_stub(%State{phase: {:running, _runtime}} = state), do: {:reply, :ok, state}
  def request_stub(%State{phase: :stopped} = state), do: register_stub(state)
  def request_stub(%State{phase: {:load_error, _error}} = state), do: register_stub(state)
  def request_stub(%State{phase: {:crashed, _error}} = state), do: register_stub(state)
  def request_stub(state), do: {:reply, {:error, {:unexpected_phase, state.phase}}, state}

  @spec register_stub(State.t()) :: callback_result()
  def register_stub(state) do
    case prepare_artifact(state) do
      {:ok, artifact, prepared} -> register_prepared_stub(state, artifact, prepared)
      {:error, reason, prepared} -> stub_failure(prepared, reason)
    end
  end

  @spec register_prepared_stub(State.t(), Artifact.t(), State.t()) :: callback_result()
  def register_prepared_stub(state, artifact, prepared) do
    result =
      Contributions.register_stub(
        self(),
        state.name,
        state.declaration,
        artifact,
        state.declaration.config,
        state.collaborators
      )

    publish_registered_stub(result, artifact, prepared)
  end

  @spec publish_registered_stub(:ok | {:error, term()}, Artifact.t(), State.t()) ::
          callback_result()
  def publish_registered_stub(:ok, artifact, prepared) do
    updated = State.stubbed(prepared, artifact)

    case Projection.publish(updated) do
      :ok -> {:reply, :ok, updated}
      {:error, reason} -> stub_failure(prepared, reason)
    end
  end

  def publish_registered_stub({:error, reason}, _artifact, prepared),
    do: stub_failure(prepared, reason)

  @spec stub_failure(State.t(), term()) :: callback_result()
  def stub_failure(state, reason) do
    case Contributions.cleanup(state.name, state.collaborators) do
      :ok ->
        updated = State.load_error(state, reason)

        {updated, reply_reason, _publication} =
          Minga.Extension.Instance.TransitionHandler.publish_terminal(updated, reason)

        {:reply, {:error, reply_reason}, updated}

      {:error, failures} ->
        failure = wrap_cleanup_failure(reason, {:error, failures})
        stopping = State.stopping(state, nil, :explicit, :stub_failure)
        {:stopping, context} = stopping.phase
        retry = StopContext.cleanup_retry(context, stage: :cleanup)
        updated = State.cleanup_failed(state, failure, retry)

        {updated, reply_reason, _publication} =
          Minga.Extension.Instance.TransitionHandler.publish_terminal(updated, failure)

        {:reply, {:error, reply_reason}, updated}
    end
  end

  @spec perform_start(State.t()) :: {:noreply, State.t()}
  def perform_start(%State{phase: {:starting, %StartContext{worker: nil} = context}} = state) do
    owner = self()
    id = make_ref()

    worker =
      Worker.start(
        owner,
        :start,
        Minga.Extension.Instance.TransitionHandler.transition_timeout(state),
        id,
        fn ->
          start_workflow(state, context.previous, owner, id)
        end
      )

    {:noreply, State.starting(state, StartContext.begin_work(context, worker))}
  end

  def perform_start(state), do: {:noreply, state}

  @spec start_workflow(State.t(), State.phase(), pid(), reference()) ::
          {:ok, pid(), State.t()} | {:error, term(), State.t(), pid() | nil}
  def start_workflow(state, previous_phase, owner, transition_id) do
    lifecycle_span(state.name, :load, fn ->
      run_start_workflow(state, previous_phase, owner, transition_id)
    end)
  end

  @spec run_start_workflow(State.t(), State.phase(), pid(), reference()) ::
          {:ok, pid(), State.t()} | {:error, term(), State.t(), pid() | nil}
  def run_start_workflow(state, previous_phase, owner, transition_id) do
    with {:ok, artifact, prepared} <- prepare_artifact(state),
         :ok <- cleanup_stub_if_needed(previous_phase, state),
         :ok <- prepare_runtime(state, artifact),
         {:ok, pid} <- start_runtime_child(state, artifact) do
      send(owner, {Worker, :runtime_started, transition_id, pid})
      register_runtime(state, artifact, prepared, pid)
    else
      {:error, reason, prepared} -> {:error, reason, prepared, nil}
      {:error, reason} -> {:error, reason, state, nil}
    end
  end

  @spec prepare_runtime(State.t(), Artifact.t()) :: :ok | {:error, term()}
  def prepare_runtime(state, artifact) do
    lifecycle_span(state.name, :init, fn ->
      Contributions.prepare_runtime(
        state.name,
        artifact,
        state.declaration.config,
        state.collaborators
      )
    end)
  end

  @spec start_runtime_child(State.t(), Artifact.t()) :: {:ok, pid()} | {:error, term()}
  def start_runtime_child(state, artifact) do
    lifecycle_span(state.name, :child_start, fn ->
      RuntimeSupervisor.start_child(runtime_supervisor(state), artifact.child_spec)
    end)
  end

  @spec register_runtime(State.t(), Artifact.t(), State.t(), pid()) ::
          {:ok, pid(), State.t()} | {:error, term(), State.t(), pid()}
  def register_runtime(state, artifact, prepared, pid) do
    case Contributions.register_runtime(state.name, artifact, state.collaborators) do
      :ok -> {:ok, pid, prepared}
      {:error, reason} -> {:error, reason, prepared, pid}
    end
  end

  @spec runtime_started(State.t(), reference(), pid()) :: {:noreply, State.t()}
  def runtime_started(
        %State{phase: {:starting, %StartContext{worker: %Worker{id: id}} = context}} = state,
        id,
        pid
      ) do
    runtime = Runtime.monitor(pid)
    {:noreply, State.starting(state, StartContext.runtime_started(context, runtime))}
  end

  def runtime_started(state, _id, pid) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end

  @spec start_workflow_done(State.t(), term()) :: {:noreply, State.t()}
  def start_workflow_done(%State{phase: {:starting, context}} = state, {:ok, pid, prepared}) do
    runtime = Runtime.ensure(context.runtime, pid)
    running = State.running(prepared, runtime)

    case Projection.publish(running) do
      :ok ->
        complete_started_workflow(state, context, running, pid)

      {:error, reason} ->
        begin_start_rollback(running, context.waiters, context.stop_waiters, reason, pid)
    end
  end

  def start_workflow_done(
        %State{phase: {:starting, context}},
        {:error, reason, prepared, runtime_pid}
      ) do
    begin_start_rollback(prepared, context.waiters, context.stop_waiters, reason, runtime_pid)
  end

  @spec complete_started_workflow(State.t(), StartContext.t(), State.t(), pid()) ::
          {:noreply, State.t()}
  def complete_started_workflow(state, context, running, pid) do
    emit_restart_count(state.name, state.restart_count)
    broadcast_started(running)
    Enum.each(context.waiters, &GenServer.reply(&1, {:ok, pid}))
    continue_after_queued_stop(context.stop_waiters, running)
  end

  @spec continue_after_queued_stop([GenServer.from()], State.t()) :: {:noreply, State.t()}
  def continue_after_queued_stop([], running), do: {:noreply, running}

  def continue_after_queued_stop(stop_waiters, running) do
    stopping = State.stopping(running, nil, :explicit, :queued_stop)
    {:stopping, stop_context} = stopping.phase
    stopping = State.stopping(stopping, StopContext.transfer_waiters(stop_context, stop_waiters))

    case Projection.publish(stopping) do
      :ok ->
        Minga.Extension.Instance.QuiescenceTransition.begin_quiesce(stopping)

      {:error, reason} ->
        Minga.Extension.Instance.StopTransition.stop_failed(
          stopping,
          {:projection_failed, reason}
        )
    end
  end

  @spec begin_start_rollback(
          State.t(),
          [GenServer.from()],
          [GenServer.from()],
          term(),
          pid() | nil
        ) ::
          {:noreply, State.t()}
  def begin_start_rollback(state, start_waiters, stop_waiters, reason, runtime_pid) do
    base = rollback_runtime_state(state, runtime_pid)
    stopping = State.stopping(base, nil, :explicit, :failed_start)
    {:stopping, context} = stopping.phase

    context = StopContext.rollback_start(context, reason, start_waiters, stop_waiters)
    stopping = State.stopping(stopping, context)

    case Projection.publish(stopping) do
      :ok ->
        Minga.Extension.Instance.QuiescenceTransition.begin_quiesce(stopping)

      {:error, projection_reason} ->
        failure =
          Minga.Extension.Instance.TransitionHandler.publication_failure(
            state.name,
            reason,
            projection_reason
          )

        {:stopping, failed_context} = stopping.phase

        failed_context =
          StopContext.replace_start_failure(failed_context, failure, start_waiters)

        Minga.Extension.Instance.QuiescenceTransition.begin_quiesce(
          State.stopping(stopping, failed_context)
        )
    end
  end

  @spec rollback_runtime_state(State.t(), pid() | nil) :: State.t()
  def rollback_runtime_state(state, nil), do: state

  def rollback_runtime_state(%State{phase: {:running, %{pid: pid}}} = state, pid), do: state

  def rollback_runtime_state(
        %State{phase: {:starting, %StartContext{runtime: %Runtime{pid: pid} = runtime}}} = state,
        pid
      ) do
    State.running(state, runtime)
  end

  def rollback_runtime_state(state, pid), do: State.running(state, Runtime.monitor(pid))

  @spec prepare_artifact(State.t()) ::
          {:ok, Artifact.t(), State.t()} | {:error, term(), State.t()}
  def prepare_artifact(state) do
    case State.artifact(state) do
      {:ok, artifact} ->
        _changed? = Source.pending_restart?(state.name, state.declaration, state.collaborators)
        {:ok, artifact, state}

      :error ->
        case Source.prepare(state.name, state.declaration, state.collaborators) do
          {:ok, artifact} -> {:ok, artifact, State.put_artifact(state, artifact)}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  @spec cleanup_stub_if_needed(State.phase(), State.t()) :: :ok | {:error, term()}
  def cleanup_stub_if_needed({:stub, _artifact}, state) do
    case Contributions.cleanup(state.name, state.collaborators) do
      :ok -> :ok
      {:error, failures} -> {:error, {:cleanup_failed, failures}}
    end
  end

  def cleanup_stub_if_needed(_phase, _state), do: :ok
end
