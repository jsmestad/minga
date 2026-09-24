defmodule MingaEditor.Renderer.RecoveryHandler do
  @moduledoc "Owns connection reset, timeout recovery, and targeted window recovery."

  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.AckLease
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.FrameHandler
  alias MingaEditor.Renderer.State

  @type request_result :: :recovery_started | :stale

  @spec reset(State.t(), Intent.t(), non_neg_integer(), integer()) :: {:reply, :ok, State.t()}
  def reset(state, intent, seq, pushed_at) do
    state |> State.awaiting_lease() |> AckLease.cancel_timer()
    generation = State.reserve_recovery_generation(state)

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
    generation = State.reserve_recovery_generation(state)

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
    generation = State.reserve_recovery_generation(state)

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
    generation = State.reserve_recovery_generation(state)

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
        adapted_transaction(adapted_state, adapted_intent, lease.attempt)

      :error ->
        terminal_without_adaptation(state, last_applied, reason)
    end
  end

  @spec adapted_transaction(State.t(), Intent.t(), FrameAttempt.t()) :: {:noreply, State.t()}
  defp adapted_transaction(state, adapted_intent, %FrameAttempt{} = rejected_attempt) do
    state |> State.awaiting_lease() |> AckLease.cancel_timer()
    generation = State.reserve_recovery_generation(state)
    retry_seq = max(System.unique_integer([:positive, :monotonic]), rejected_attempt.seq + 1)
    retry = FrameAttempt.new(adapted_intent, retry_seq, rejected_attempt.pushed_at)
    token = schedule_render()

    state =
      state
      |> State.reset_frontend(generation)
      |> State.schedule_frame(retry, token)

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
    state |> State.awaiting_lease() |> AckLease.cancel_timer()
    generation = State.reserve_recovery_generation(state)

    retry =
      state
      |> State.latest_successor(rejected_attempt)
      |> FrameAttempt.force_keyframe()

    token = schedule_render()

    state
    |> State.reset_frontend(generation)
    |> State.schedule_frame(retry, token)
  end

  @doc "Recovers one missed retained window without resetting unrelated frontend state."
  @spec window(State.t(), FrameAttempt.t(), non_neg_integer()) :: {:noreply, State.t()}
  def window(state, %FrameAttempt{} = rejected_attempt, window_id) do
    state |> State.awaiting_lease() |> AckLease.cancel_timer()

    attempt = State.latest_successor(state, rejected_attempt)
    recover_existing_window(state, attempt, window_id)
  end

  @spec recover_existing_window(State.t(), FrameAttempt.t(), non_neg_integer()) ::
          {:noreply, State.t()}
  defp recover_existing_window(state, %FrameAttempt{} = attempt, window_id) do
    if Map.has_key?(attempt.intent.windows, window_id) do
      token = schedule_render()

      state =
        state
        |> BufferChanges.invalidate_window(window_id)
        |> State.schedule_frame(attempt, token)

      {:noreply, state}
    else
      transaction(state, attempt)
    end
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
