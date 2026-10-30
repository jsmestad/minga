defmodule MingaEditor.Renderer.RecoveryHandler do
  @moduledoc "Owns connection reset, timeout recovery, and targeted window recovery."

  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.AckLease
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.FrameHandler
  alias MingaEditor.Renderer.RecoveryDecision
  alias MingaEditor.Renderer.State

  @doc "Applies the pure decision for a frontend status or an acknowledgement timeout."
  @spec status(State.t(), RecoveryDecision.source()) :: {:noreply, State.t()}
  def status(state, status) do
    lease = State.awaiting_lease(state)

    {retry_state, next_seq} =
      case lease do
        nil -> {state, state.next_frame_seq}
        lease -> State.reserve_retry_sequence(state, lease.attempt)
      end

    case RecoveryDecision.decide(lease, status, next_seq) do
      :stale ->
        {:noreply, state}

      {:terminal, reason} ->
        Minga.Log.warning(
          :render,
          "Frontend terminally rejected frame #{lease.attempt.seq}: #{reason}"
        )

        AckLease.cancel_timer(lease)

        {:noreply,
         State.terminal_failure(state, state.caches.last_acknowledged_frame_seq, reason)}

      {:retry, plan} ->
        Minga.Log.warning(
          :render,
          "Recovering frontend frame #{lease.attempt.seq}: #{inspect(status)}"
        )

        attempt = State.latest_successor(retry_state, lease.attempt)
        retry = FrameAttempt.new(attempt.intent, plan.seq, attempt.pushed_at)
        {:noreply, apply_retry(retry_state, retry, plan)}
    end
  end

  @type request_result :: :recovery_started | :stale

  @spec reset(State.t(), Intent.t(), non_neg_integer(), integer()) :: {:reply, :ok, State.t()}
  def reset(state, intent, seq, pushed_at) do
    state |> State.awaiting_lease() |> AckLease.cancel_timer()
    {state, {generation, _floor}} = State.reserve_recovery_context(state)

    state =
      state
      |> State.reset_connection(generation, :renderer_restart)
      |> State.clear_rejection()

    token = schedule_render()
    attempt = FrameAttempt.new(Intent.force_keyframe(intent), seq, pushed_at)

    {:reply, :ok, State.schedule_frame(state, attempt, token)}
  end

  @doc "Forces a same-connection keyframe while retaining acknowledged presentation leases."
  @spec keyframe(State.t(), Intent.t(), non_neg_integer(), integer()) :: {:reply, :ok, State.t()}
  def keyframe(state, intent, seq, pushed_at) do
    state |> State.awaiting_lease() |> AckLease.cancel_timer()
    {state, {generation, _floor}} = State.reserve_recovery_context(state)

    state =
      state
      |> State.reset_frontend(generation, :renderer_restart)
      |> State.clear_rejection()

    token = schedule_render()
    attempt = FrameAttempt.new(Intent.force_keyframe(intent), seq, pushed_at)

    {:reply, :ok, State.schedule_frame(state, attempt, token)}
  end

  @doc "Resets frontend state and renders a synchronous recovery keyframe."
  @spec reset_sync(State.t(), Intent.t(), non_neg_integer(), integer()) ::
          {:reply, {:ok, MingaEditor.Renderer.RenderReceipt.t()} | {:error, Exception.t()},
           State.t()}
  def reset_sync(state, intent, seq, pushed_at) do
    state |> State.awaiting_lease() |> AckLease.cancel_timer()
    {state, {generation, _floor}} = State.reserve_recovery_context(state)

    state
    |> State.reset_connection(generation, :renderer_restart)
    |> State.clear_rejection()
    |> FrameHandler.render_sync(Intent.force_keyframe(intent), seq, pushed_at)
  end

  @doc "Renders a synchronous same-connection keyframe without abandoning presentation leases."
  @spec keyframe_sync(State.t(), Intent.t(), non_neg_integer(), integer()) ::
          {:reply, {:ok, MingaEditor.Renderer.RenderReceipt.t()} | {:error, Exception.t()},
           State.t()}
  def keyframe_sync(state, intent, seq, pushed_at) do
    state |> State.awaiting_lease() |> AckLease.cancel_timer()
    {state, {generation, _floor}} = State.reserve_recovery_context(state)

    state
    |> State.reset_frontend(generation, :renderer_restart)
    |> State.clear_rejection()
    |> FrameHandler.render_sync(Intent.force_keyframe(intent), seq, pushed_at)
  end

  @spec request(State.t(), non_neg_integer(), non_neg_integer()) ::
          {:reply, request_result(), State.t()}
  def request(
        %State{
          frame_credit: {
            :awaiting_ack,
            %AckLease{generation: generation, attempt: attempt},
            _successor
          },
          caches: %{last_acknowledged_frame_seq: committed_base}
        } = state,
        failed_generation,
        last_applied_frame_seq
      )
      when generation == failed_generation and committed_base == last_applied_frame_seq,
      do: recover_request(state, attempt)

  def request(
        %State{
          frame_credit: {:scheduled, _token, %FrameAttempt{} = attempt, _, _successor},
          caches: %{
            recovery_generation: generation,
            last_acknowledged_frame_seq: committed_base
          }
        } = state,
        failed_generation,
        last_applied_frame_seq
      )
      when generation == failed_generation and committed_base == last_applied_frame_seq,
      do: recover_request(state, attempt)

  def request(state, _failed_generation, _last_applied_frame_seq),
    do: {:reply, :stale, state}

  @doc "Starts one fresh-generation retry only after consuming explicit adaptation evidence."
  @spec adapted(State.t(), non_neg_integer(), atom()) :: {:noreply, State.t()}
  def adapted(
        %State{frame_credit: {:awaiting_ack, %AckLease{} = lease, _successor}} = state,
        last_applied,
        reason
      ) do
    case State.consume_adaptation(state, lease) do
      {:ok, adapted_state, adapted_intent} ->
        adapted_transaction(adapted_state, adapted_intent, lease.attempt, reason)

      :error ->
        terminal_without_adaptation(state, last_applied, reason)
    end
  end

  @spec adapted_transaction(State.t(), Intent.t(), FrameAttempt.t(), atom()) ::
          {:noreply, State.t()}
  defp adapted_transaction(state, adapted_intent, %FrameAttempt{} = rejected_attempt, reason) do
    lease = State.awaiting_lease(state)
    {state, next_seq} = State.reserve_retry_sequence(state, rejected_attempt)

    status =
      {:frame_rejected, lease.generation, rejected_attempt.seq,
       state.caches.last_acknowledged_frame_seq, reason, :adapted_retry}

    {:retry, plan} = RecoveryDecision.decide(lease, status, next_seq)

    retry = FrameAttempt.new(adapted_intent, plan.seq, rejected_attempt.pushed_at)
    state = apply_retry(state, FrameAttempt.force_keyframe(retry), plan)
    {:noreply, state}
  end

  @doc "Starts transaction recovery from the latest semantic intent."
  @spec transaction(State.t(), FrameAttempt.t()) :: {:noreply, State.t()}
  def transaction(state, %FrameAttempt{} = rejected_attempt),
    do: {:noreply, transaction_state(state, rejected_attempt)}

  @spec recover_request(State.t(), FrameAttempt.t()) ::
          {:reply, :recovery_started, State.t()}
  defp recover_request(state, %FrameAttempt{} = rejected_attempt),
    do: {:reply, :recovery_started, transaction_state(state, rejected_attempt)}

  @spec transaction_state(State.t(), FrameAttempt.t()) :: State.t()
  defp transaction_state(state, %FrameAttempt{} = rejected_attempt) do
    lease = decision_lease(state, rejected_attempt)
    {state, next_seq} = State.reserve_retry_sequence(state, rejected_attempt)

    {:retry, plan} =
      RecoveryDecision.decide(
        lease,
        {:transaction, lease.generation, rejected_attempt.seq},
        next_seq
      )

    attempt = State.latest_successor(state, rejected_attempt)
    retry = FrameAttempt.new(attempt.intent, plan.seq, attempt.pushed_at)
    apply_retry(state, retry, plan)
  end

  @doc "Recovers one missed retained window without resetting unrelated frontend state."
  @spec window(State.t(), FrameAttempt.t(), non_neg_integer()) :: {:noreply, State.t()}
  def window(state, %FrameAttempt{} = rejected_attempt, window_id) do
    lease = decision_lease(state, rejected_attempt)
    latest = State.latest_successor(state, rejected_attempt)
    lease = AckLease.recovery_context(lease, latest)
    {state, next_seq} = State.reserve_retry_sequence(state, rejected_attempt)

    status =
      {:window_ref_miss, lease.generation, rejected_attempt.seq,
       lease.output.caches.last_acknowledged_frame_seq, window_id}

    {:retry, plan} = RecoveryDecision.decide(lease, status, next_seq)

    Minga.Log.warning(
      :render,
      "Frontend missed window #{window_id} in frame #{rejected_attempt.seq}"
    )

    attempt = State.latest_successor(state, rejected_attempt)
    retry = FrameAttempt.new(attempt.intent, plan.seq, attempt.pushed_at)
    {:noreply, apply_retry(state, retry, plan)}
  end

  @spec decision_lease(State.t(), FrameAttempt.t()) :: AckLease.t()
  defp decision_lease(state, attempt) do
    case State.awaiting_lease(state) do
      %AckLease{} = lease ->
        lease

      nil ->
        %AckLease{
          attempt: attempt,
          generation: state.caches.recovery_generation,
          timer_ref: nil,
          output: %{caches: state.caches}
        }
    end
  end

  @spec apply_retry(State.t(), FrameAttempt.t(), RecoveryDecision.plan()) :: State.t()
  defp apply_retry(state, attempt, %{force_keyframe?: true} = plan) do
    state |> State.awaiting_lease() |> AckLease.cancel_timer()
    {state, {reserved_generation, _floor}} = State.reserve_recovery_context(state)
    generation = max(plan.generation, reserved_generation)

    state
    |> State.reset_frontend(generation)
    |> State.schedule_frame(FrameAttempt.force_keyframe(attempt), schedule_render())
  end

  defp apply_retry(state, attempt, %{invalidate_window: window_id}) do
    state |> State.awaiting_lease() |> AckLease.cancel_timer()

    state
    |> BufferChanges.invalidate_window(window_id)
    |> State.schedule_frame(attempt, schedule_render())
  end

  @spec terminal_without_adaptation(State.t(), non_neg_integer(), atom()) ::
          {:noreply, State.t()}
  defp terminal_without_adaptation(state, last_applied, reason) do
    state |> State.awaiting_lease() |> AckLease.cancel_timer()
    {:noreply, State.terminal_failure(state, last_applied, reason)}
  end

  @spec schedule_render() :: reference()
  defp schedule_render do
    token = make_ref()
    send(self(), {:do_render, token})
    token
  end
end
