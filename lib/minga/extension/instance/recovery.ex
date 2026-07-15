defmodule Minga.Extension.Instance.Recovery do
  @moduledoc "Extension Instance recovery logic."

  alias Minga.Extension.CodeLease
  alias Minga.Extension.Instance.Projection
  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.State
  alias Minga.Extension.RuntimeSupervisor

  import Minga.Extension.Instance.Lifecycle

  @spec recover_local_runtime(State.t()) :: {:noreply, State.t()}
  def recover_local_runtime(state) do
    case RuntimeSupervisor.local_child(
           runtime_supervisor(state),
           Minga.Extension.Instance.TransitionHandler.runtime_query_timeout(state)
         ) do
      {:ok, pid} ->
        recover_adopted_runtime(state, pid)

      :empty ->
        recover_empty_runtime(state)

      {:error, reason} ->
        Minga.Extension.Instance.TransitionHandler.replace_runtime_branch(
          state,
          {:runtime_recovery_failed, reason}
        )
    end
  end

  @spec recover_adopted_runtime(State.t(), pid()) :: {:noreply, State.t()}
  def recover_adopted_runtime(state, pid) do
    state.registry
    |> Minga.Extension.Registry.get(state.name)
    |> recover_adopted_projection(state, pid)
  end

  @spec recover_adopted_projection(term(), State.t(), pid()) :: {:noreply, State.t()}
  def recover_adopted_projection({:ok, %{status: :running}}, state, pid) do
    case Minga.Extension.Instance.StartTransition.prepare_artifact(state) do
      {:ok, _artifact, prepared} ->
        publish_adopted_runtime(prepared, pid)

      {:error, reason, prepared} ->
        Minga.Extension.Instance.StartTransition.begin_start_rollback(
          prepared,
          [],
          [],
          reason,
          pid
        )
    end
  end

  def recover_adopted_projection(
        {:ok, %{status: :stopped, last_error: {:lifecycle_transition, {:stopping, _stage}}}},
        state,
        pid
      ),
      do: recover_interrupted_stop(state, pid)

  def recover_adopted_projection({:ok, %{status: :stopped} = projection}, state, pid) do
    reason = projection.last_error || {:interrupted_lifecycle, :stopped}
    Minga.Extension.Instance.StartTransition.begin_start_rollback(state, [], [], reason, pid)
  end

  def recover_adopted_projection({:ok, projection}, state, pid) do
    reason = projection.last_error || {:interrupted_lifecycle, projection.status}
    Minga.Extension.Instance.StartTransition.begin_start_rollback(state, [], [], reason, pid)
  end

  def recover_adopted_projection(:error, state, pid),
    do:
      Minga.Extension.Instance.StartTransition.begin_start_rollback(
        state,
        [],
        [],
        {:extension_not_declared, state.name},
        pid
      )

  @spec publish_adopted_runtime(State.t(), pid()) :: {:noreply, State.t()}
  def publish_adopted_runtime(prepared, pid) do
    running = State.running(prepared, Runtime.monitor(pid))

    case Projection.publish(running) do
      :ok ->
        {:noreply, running}

      {:error, reason} ->
        Minga.Extension.Instance.StartTransition.begin_start_rollback(
          running,
          [],
          [],
          reason,
          pid
        )
    end
  end

  @spec recover_empty_runtime(State.t()) :: {:noreply, State.t()}
  def recover_empty_runtime(state) do
    projection = Minga.Extension.Registry.get(state.registry, state.name)
    lease_server = Keyword.get(state.collaborators, :code_lease, CodeLease)
    source_status = CodeLease.source_status({:extension, state.name}, server: lease_server)
    recover_empty_runtime(state, projection, source_status)
  end

  @spec recover_empty_runtime(State.t(), term(), term()) :: {:noreply, State.t()}
  def recover_empty_runtime(state, {:ok, %{status: :running}}, :active),
    do: recover_runtime_supervisor_replacement(state)

  def recover_empty_runtime(
        state,
        {:ok, %{status: :stopped, last_error: {:lifecycle_transition, {:stopping, _stage}}}},
        _source_status
      ),
      do: recover_interrupted_stop(state, nil)

  def recover_empty_runtime(state, {:ok, %{status: :stopped}}, {:quiescing, _token}),
    do: recover_interrupted_stop(state, nil)

  def recover_empty_runtime(state, {:ok, projection}, {:quiescing, _token}) do
    reason = projection.last_error || {:interrupted_lifecycle, :quiescing}
    Minga.Extension.Instance.StartTransition.begin_start_rollback(state, [], [], reason, nil)
  end

  def recover_empty_runtime(state, {:ok, %{status: :stopped}}, status)
      when status in [:active, :inactive] do
    recover_interrupted_stop(state, nil)
  end

  def recover_empty_runtime(state, {:ok, %{status: :stopped, pid: nil, last_error: nil}}, status)
      when status in [:inactive, :unknown] do
    case Minga.Extension.Instance.TransitionHandler.publish_terminal(state, :recovery_stopped) do
      {published, _reason, :ok} -> {:noreply, published}
      {failed, _reason, :error} -> {:noreply, failed}
    end
  end

  def recover_empty_runtime(state, {:ok, projection}, _source_status) do
    reason = projection.last_error || {:interrupted_lifecycle, projection.status}
    Minga.Extension.Instance.StartTransition.begin_start_rollback(state, [], [], reason, nil)
  end

  def recover_empty_runtime(state, :error, source_status)
      when source_status in [:active, :inactive] or is_tuple(source_status) do
    Minga.Extension.Instance.StartTransition.begin_start_rollback(
      state,
      [],
      [],
      {:extension_not_declared, state.name},
      nil
    )
  end

  def recover_empty_runtime(state, :error, :unknown) do
    reason = {:extension_not_declared, state.name}
    failed = State.load_error(state, reason)

    {failed, _reply_reason, _publication} =
      Minga.Extension.Instance.TransitionHandler.publish_terminal(failed, reason)

    {:noreply, failed}
  end

  @spec recover_interrupted_stop(State.t(), pid() | nil) :: {:noreply, State.t()}
  def recover_interrupted_stop(state, runtime_pid) do
    base = Minga.Extension.Instance.StartTransition.rollback_runtime_state(state, runtime_pid)
    stopping = State.stopping(base, nil, :explicit, :instance_recovery)

    case Projection.publish(stopping) do
      :ok ->
        Minga.Extension.Instance.QuiescenceTransition.begin_quiesce(stopping)

      {:error, projection_reason} ->
        failure =
          Minga.Extension.Instance.TransitionHandler.publication_failure(
            state.name,
            :instance_recovery,
            projection_reason
          )

        Minga.Extension.Instance.StopTransition.stop_failed(stopping, failure)
    end
  end

  @spec recover_runtime_supervisor_replacement(State.t()) :: {:noreply, State.t()}
  def recover_runtime_supervisor_replacement(state) do
    case Minga.Extension.Instance.StartTransition.prepare_artifact(state) do
      {:ok, artifact, prepared} ->
        Minga.Extension.Instance.RuntimeTransition.begin_runtime_replacement_start(
          prepared,
          artifact
        )

      {:error, reason, prepared} ->
        Minga.Extension.Instance.StartTransition.begin_start_rollback(
          prepared,
          [],
          [],
          reason,
          nil
        )
    end
  end
end
