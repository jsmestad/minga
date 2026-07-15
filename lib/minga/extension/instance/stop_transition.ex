defmodule Minga.Extension.Instance.StopTransition do
  @moduledoc "Extension Instance stop transition logic."

  alias Minga.Extension.Instance.Contributions
  alias Minga.Extension.Instance.Projection
  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.StartContext
  alias Minga.Extension.Instance.State
  alias Minga.Extension.Instance.StopContext
  alias Minga.Extension.Instance.TransitionHandler
  alias Minga.Extension.Instance.Worker
  alias Minga.Extension.RuntimeSupervisor

  import Minga.Extension.Instance.Lifecycle

  @type callback_result :: {:reply, term(), State.t()} | {:noreply, State.t()}

  @spec request_stop(State.t(), GenServer.from()) :: callback_result()
  def request_stop(%State{phase: :stopped} = state, _from) do
    case Projection.publish(state) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, TransitionHandler.put_terminal_failure(state, reason)}
    end
  end

  def request_stop(%State{phase: {:stopping, _context}} = state, from),
    do: {:noreply, State.join_stop(state, from)}

  def request_stop(%State{phase: {:starting, context}} = state, from) do
    {:noreply, State.starting(state, StartContext.queue_stop(context, from))}
  end

  def request_stop(%State{phase: {:cleanup_failed, failure}} = state, from) do
    retry = failure.retry
    retry_stop(State.stopping(state, retry), retry, from)
  end

  def request_stop(state, from) do
    updated = State.stopping(state, from, :explicit, :explicit_stop)

    case Projection.publish(updated) do
      :ok -> Minga.Extension.Instance.QuiescenceTransition.begin_quiesce(updated)
      {:error, reason} -> stop_failed(updated, {:projection_failed, reason})
    end
  end

  @spec advance_runtime_termination(State.t()) :: {:noreply, State.t()}
  def advance_runtime_termination(%State{phase: {:stopping, context}} = state) do
    begin_runtime_termination(State.stopping(state, StopContext.begin_termination(context)))
  end

  @spec begin_runtime_termination(State.t()) :: {:noreply, State.t()}
  def begin_runtime_termination(%State{phase: {:stopping, %StopContext{runtime: nil}}} = state),
    do: request_cleanup(state)

  def begin_runtime_termination(%State{phase: {:stopping, context}} = state) do
    worker =
      Worker.start(
        self(),
        :terminate,
        Minga.Extension.Instance.TransitionHandler.callback_timeout(state),
        fn ->
          terminate_runtime(state, context.runtime)
        end
      )

    {:noreply, State.stopping(state, StopContext.attach_worker(context, worker))}
  end

  @spec terminate_runtime(State.t(), Runtime.t()) :: :ok | {:error, term()}
  def terminate_runtime(state, runtime) do
    lifecycle_span(state.name, :stop, fn ->
      case RuntimeSupervisor.terminate_child(runtime_supervisor(state), runtime.pid) do
        :ok -> :ok
        {:error, :not_found} -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec request_cleanup(State.t()) :: {:noreply, State.t()}
  def request_cleanup(%State{phase: {:stopping, context}} = state) do
    worker =
      Worker.start(
        self(),
        :cleanup,
        Minga.Extension.Instance.TransitionHandler.callback_timeout(state),
        fn ->
          Contributions.cleanup(state.name, state.collaborators)
        end
      )

    updated = StopContext.begin_cleanup(context, worker)
    {:noreply, State.stopping(state, updated)}
  end

  @spec cleanup_ack(State.t(), reference(), term()) :: {:noreply, State.t()}
  def cleanup_ack(
        %State{phase: {:stopping, %StopContext{stage: :cleanup, editor_ref: ref} = context}} =
          state,
        ref,
        result
      ) do
    finish_stop(state, context, result)
  end

  def cleanup_ack(state, _ref, _result), do: {:noreply, state}

  @spec finish_stop(State.t(), StopContext.t(), term()) :: {:noreply, State.t()}
  def finish_stop(
        state,
        %{exit_kind: exit_kind, finalizer_error: reason} = context,
        :ok
      )
      when exit_kind in [:normal, :crash] and not is_nil(reason) do
    maybe_demonitor(context.runtime)
    failure = terminal_finalizer_error(exit_kind, reason)
    failed = State.load_error(state, failure)

    {failed, reply_reason, _publication} =
      Minga.Extension.Instance.TransitionHandler.publish_terminal(failed, failure)

    Minga.Extension.Instance.TransitionHandler.reply_terminal_waiters(
      context,
      {:error, reply_reason}
    )

    {:noreply, failed}
  end

  def finish_stop(
        state,
        %{completion: {:start_failure, reason, start_waiters}} = context,
        :ok
      ) do
    maybe_demonitor(context.runtime)
    failed = State.load_error(state, reason)

    {failed, reply_reason, publication} =
      Minga.Extension.Instance.TransitionHandler.publish_terminal(failed, reason)

    Enum.each(start_waiters, &GenServer.reply(&1, {:error, reply_reason}))

    reply_queued_starts(
      context.start_waiters,
      {:error, reply_reason}
    )

    stop_reply = if publication == :ok, do: :ok, else: {:error, reply_reason}
    Enum.each(context.waiters, &GenServer.reply(&1, stop_reply))
    {:noreply, failed}
  end

  def finish_stop(state, context, :ok) do
    maybe_demonitor(context.runtime)
    stopped = State.terminal(state, context)
    phase = stopped.phase

    case Minga.Extension.Instance.TransitionHandler.publish_terminal(
           stopped,
           {:terminal_projection, phase}
         ) do
      {published, _reason, :ok} ->
        finish_published_stop(published, context, phase)

      {failed, reason, :error} ->
        Minga.Extension.Instance.TransitionHandler.reply_terminal_waiters(
          context,
          {:error, reason}
        )

        {:noreply, failed}
    end
  end

  def finish_stop(
        state,
        %{completion: {:start_failure, start_reason, start_waiters}} = context,
        {:error, failures}
      ) do
    reason = wrap_cleanup_failure(start_reason, {:error, failures})
    retry = StopContext.cleanup_retry(context, completion: :stop)
    failed = State.cleanup_failed(state, reason, retry)

    {failed, reply_reason, _publication} =
      Minga.Extension.Instance.TransitionHandler.publish_terminal(failed, reason)

    Enum.each(start_waiters, &GenServer.reply(&1, {:error, reply_reason}))

    reply_queued_starts(
      context.start_waiters,
      {:error, reply_reason}
    )

    Enum.each(context.waiters, &GenServer.reply(&1, {:error, reply_reason}))
    {:noreply, failed}
  end

  def finish_stop(state, %{exit_kind: :explicit} = context, {:error, failures}) do
    reason = terminal_cleanup_error(context, failures)
    retry = StopContext.cleanup_retry(context)
    failed = State.cleanup_failed(state, reason, retry)

    {failed, reply_reason, _publication} =
      Minga.Extension.Instance.TransitionHandler.publish_terminal(failed, reason)

    Enum.each(context.waiters, &GenServer.reply(&1, {:error, reply_reason}))

    reply_queued_starts(
      context.start_waiters,
      {:error, {:cleanup_retry_required, reply_reason}}
    )

    {:noreply, failed}
  end

  def finish_stop(state, context, {:error, failures}) do
    reason = terminal_cleanup_error(context, failures)

    retry = StopContext.cleanup_retry(context, stage: :cleanup)
    failed = State.cleanup_failed(state, reason, retry)

    {failed, reply_reason, _publication} =
      Minga.Extension.Instance.TransitionHandler.publish_terminal(failed, reason)

    Minga.Extension.Instance.TransitionHandler.reply_terminal_waiters(
      context,
      {:error, reply_reason}
    )

    {:noreply, failed}
  end

  @spec finish_published_stop(State.t(), StopContext.t(), State.phase()) ::
          {:noreply, State.t()}
  def finish_published_stop(stopped, context, phase) do
    emit_terminal_phase(stopped.name, phase)
    Enum.each(context.waiters, &GenServer.reply(&1, :ok))

    {waiters, stale_waiters} =
      queued_start_waiters(
        stopped,
        context.start_waiters
      )

    Enum.each(stale_waiters, &GenServer.reply(&1, {:error, :stale_deferred_declaration}))

    case waiters do
      [] ->
        {:noreply, stopped}

      valid_waiters ->
        start_context = StartContext.new(valid_waiters, stopped.phase)
        starting = State.starting(stopped, start_context)

        case Projection.publish(starting) do
          :ok ->
            send(self(), :perform_start)
            {:noreply, starting}

          {:error, reason} ->
            Enum.each(valid_waiters, &GenServer.reply(&1, {:error, reason}))
            {:noreply, State.load_error(stopped, reason)}
        end
    end
  end

  @spec retry_stop(State.t(), StopContext.t(), GenServer.from()) :: {:noreply, State.t()}
  def retry_stop(state, %{stage: :cleanup} = context, from) do
    updated_context = StopContext.retry_cleanup(context, from)
    request_cleanup(State.stopping(state, updated_context))
  end

  def retry_stop(state, context, from) do
    updated_context = StopContext.retry_quiescence(context, from)

    Minga.Extension.Instance.QuiescenceTransition.begin_quiesce(
      State.stopping(state, updated_context)
    )
  end

  @spec stop_failed(State.t(), term()) :: {:noreply, State.t()}
  def stop_failed(
        %State{
          phase:
            {:stopping,
             %StopContext{completion: {:start_failure, start_reason, start_waiters}} = context}
        } =
          state,
        reason
      ) do
    cancel_timer(context.drain_timer)
    failure = wrap_cleanup_failure(start_reason, {:error, rollback_stage_failure(reason)})

    retry = StopContext.cleanup_retry(context, completion: :stop)
    failed = State.cleanup_failed(state, failure, retry)

    {failed, reply_reason, _publication} =
      Minga.Extension.Instance.TransitionHandler.publish_terminal(failed, failure)

    Enum.each(start_waiters, &GenServer.reply(&1, {:error, reply_reason}))

    reply_queued_starts(
      context.start_waiters,
      {:error, reply_reason}
    )

    Enum.each(context.waiters, &GenServer.reply(&1, {:error, reply_reason}))
    {:noreply, failed}
  end

  def stop_failed(%State{phase: {:stopping, context}} = state, reason) do
    cancel_timer(context.drain_timer)
    retry = StopContext.clear_drain_timer(context)
    failed = State.cleanup_failed(state, reason, retry)

    {failed, reply_reason, _publication} =
      Minga.Extension.Instance.TransitionHandler.publish_terminal(failed, reason)

    Enum.each(context.waiters, &GenServer.reply(&1, {:error, reply_reason}))

    reply_queued_starts(
      context.start_waiters,
      {:error, {:cleanup_retry_required, reply_reason}}
    )

    {:noreply, failed}
  end

  @spec rollback_stage_failure(term()) :: keyword()
  def rollback_stage_failure({:runtime_termination_failed, reason}),
    do: [runtime_termination: reason]

  def rollback_stage_failure(reason), do: [quiesce: reason]

  @spec queued_start_waiters(State.t(), [
          State.queued_start()
        ]) ::
          {[GenServer.from()], [GenServer.from()]}
  def queued_start_waiters(state, queued_starts) do
    current_declaration = Minga.Extension.Registry.get(state.registry, state.name)

    queued_starts
    |> Enum.reduce({[], []}, fn
      {:current, from}, {valid, stale} ->
        {[from | valid], stale}

      {:deferred, from, declaration}, {valid, stale} ->
        if deferred_declaration_current?(current_declaration, declaration) do
          {[from | valid], stale}
        else
          {valid, [from | stale]}
        end
    end)
  end

  @spec deferred_declaration_current?(term(), Minga.Extension.Entry.t()) :: boolean()
  def deferred_declaration_current?({:ok, current}, declaration),
    do: State.declaration_only(current) == State.declaration_only(declaration)

  def deferred_declaration_current?(_current, _declaration), do: false

  @spec reply_queued_starts(
          [State.queued_start()],
          term()
        ) :: :ok
  def reply_queued_starts(queued_starts, reply) do
    Enum.each(queued_starts, fn
      {:current, from} -> GenServer.reply(from, reply)
      {:deferred, from, _declaration} -> GenServer.reply(from, reply)
    end)
  end
end
