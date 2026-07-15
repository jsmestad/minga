defmodule Minga.Extension.Instance.RuntimeTransition do
  @moduledoc "Extension Instance runtime transition logic."

  alias Minga.Extension.Instance.Artifact
  alias Minga.Extension.Instance.Projection
  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.StartContext
  alias Minga.Extension.Instance.State
  alias Minga.Extension.Instance.StopContext
  alias Minga.Extension.Instance.Worker
  alias Minga.Extension.RuntimeSupervisor

  import Minga.Extension.Instance.Lifecycle

  @spec runtime_down(State.t(), reference(), pid(), term()) :: {:noreply, State.t()}
  def runtime_down(
        %State{
          phase:
            {:starting,
             %{
               runtime: %Runtime{monitor: ref, pid: pid},
               worker: %Worker{} = worker
             } = context}
        } = state,
        ref,
        pid,
        reason
      ) do
    :ok = Worker.cancel(worker)

    starting = State.starting(state, StartContext.runtime_exited(context))

    Minga.Extension.Instance.StartTransition.begin_start_rollback(
      starting,
      context.waiters,
      context.stop_waiters,
      reason,
      nil
    )
  end

  def runtime_down(
        %State{phase: {:running, %Runtime{monitor: ref, pid: pid}}} = state,
        ref,
        pid,
        reason
      ) do
    {:ok, artifact} = State.artifact(state)

    if Artifact.restart?(artifact.restart, reason) do
      replace_runtime(state, artifact, reason)
    else
      exit_kind = if Artifact.crash?(reason), do: :crash, else: :normal
      stopped = State.stopping(state, nil, exit_kind, reason)

      case Projection.publish(stopped) do
        :ok ->
          Minga.Extension.Instance.QuiescenceTransition.begin_quiesce(stopped)

        {:error, projection_reason} ->
          failure =
            Minga.Extension.Instance.TransitionHandler.publication_failure(
              state.name,
              reason,
              projection_reason
            )

          {:stopping, context} = stopped.phase

          updated = StopContext.record_terminal_failure(context, failure)

          Minga.Extension.Instance.QuiescenceTransition.begin_quiesce(
            State.stopping(stopped, updated)
          )
      end
    end
  end

  def runtime_down(
        %State{
          phase: {:stopping, %StopContext{runtime: %Runtime{monitor: ref, pid: pid}} = context}
        } = state,
        ref,
        pid,
        _reason
      ) do
    {:noreply, State.stopping(state, StopContext.runtime_exited(context))}
  end

  def runtime_down(state, _ref, _pid, _reason), do: {:noreply, state}

  @spec replace_runtime(State.t(), Artifact.t(), term()) :: {:noreply, State.t()}
  def replace_runtime(state, artifact, _reason) do
    begin_runtime_replacement_start(state, artifact)
  end

  @spec begin_runtime_replacement_start(State.t(), Artifact.t()) :: {:noreply, State.t()}
  def begin_runtime_replacement_start(state, artifact) do
    owner = self()
    id = make_ref()
    restarting = State.increment_restart(state)
    context = StartContext.new([], state.phase)
    starting = State.starting(restarting, context)

    case Projection.publish(starting) do
      :ok ->
        worker =
          Worker.start(
            owner,
            :start,
            Minga.Extension.Instance.TransitionHandler.transition_timeout(state),
            id,
            fn ->
              replacement_workflow(restarting, artifact, owner, id)
            end
          )

        {:noreply, State.starting(starting, StartContext.begin_work(context, worker))}

      {:error, reason} ->
        Minga.Extension.Instance.StartTransition.begin_start_rollback(
          starting,
          [],
          [],
          reason,
          nil
        )
    end
  end

  @spec replacement_workflow(State.t(), Artifact.t(), pid(), reference()) ::
          {:ok, pid(), State.t()} | {:error, term(), State.t(), nil}
  def replacement_workflow(state, artifact, owner, transition_id) do
    case lifecycle_span(state.name, :child_start, fn ->
           RuntimeSupervisor.start_child(runtime_supervisor(state), artifact.child_spec)
         end) do
      {:ok, pid} ->
        send(owner, {Worker, :runtime_started, transition_id, pid})
        {:ok, pid, state}

      {:error, reason} ->
        {:error, {:restart_failed, reason}, state, nil}
    end
  end
end
