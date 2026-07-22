defmodule MingaEditor.Renderer.RecoveryHandler do
  @moduledoc "Owns connection reset, timeout recovery, and targeted window recovery."

  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.AckLease
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.FrameHandler
  alias MingaEditor.Renderer.State

  @spec reset(State.t(), Intent.t(), non_neg_integer(), integer()) :: {:reply, :ok, State.t()}
  def reset(state, intent, seq, pushed_at) do
    AckLease.cancel_timer(state.awaiting_ack)
    state = state |> State.reset_frontend(:renderer_restart) |> State.clear_rejection()
    token = schedule_render()

    {:reply, :ok,
     %{
       state
       | rendering?: true,
         render_token: token,
         stale_retry_count: 0,
         pending: nil,
         in_flight: FrameAttempt.new(Intent.force_keyframe(intent), seq, pushed_at),
         awaiting_ack: nil
     }}
  end

  @doc "Resets frontend state and renders a synchronous recovery keyframe."
  @spec reset_sync(State.t(), Intent.t(), non_neg_integer(), integer()) ::
          {:reply, {:ok, MingaEditor.Renderer.RenderReceipt.t()} | {:error, Exception.t()},
           State.t()}
  def reset_sync(state, intent, seq, pushed_at) do
    AckLease.cancel_timer(state.awaiting_ack)

    state
    |> State.reset_frontend(:renderer_restart)
    |> State.clear_rejection()
    |> FrameHandler.render_sync(Intent.force_keyframe(intent), seq, pushed_at)
  end

  @spec request(State.t()) :: {:noreply, State.t()}
  def request(%State{awaiting_ack: %AckLease{attempt: attempt}} = state),
    do: transaction(state, attempt)

  def request(%State{pending: %FrameAttempt{} = attempt} = state),
    do: transaction(state, attempt)

  def request(state), do: {:noreply, state}

  @doc "Starts one fresh-generation retry only after consuming explicit adaptation evidence."
  @spec adapted(State.t(), non_neg_integer(), atom()) :: {:noreply, State.t()}
  def adapted(%State{awaiting_ack: %AckLease{} = lease} = state, last_applied, reason) do
    case State.consume_adaptation(state, lease) do
      {:ok, adapted_state, adapted_intent} ->
        adapted_transaction(adapted_state, adapted_intent, lease.attempt)

      :error ->
        terminal_without_adaptation(state, last_applied, reason)
    end
  end

  @spec adapted_transaction(State.t(), Intent.t(), FrameAttempt.t()) :: {:noreply, State.t()}
  defp adapted_transaction(state, adapted_intent, %FrameAttempt{} = rejected_attempt) do
    AckLease.cancel_timer(state.awaiting_ack)
    retry_seq = max(System.unique_integer([:positive, :monotonic]), rejected_attempt.seq + 1)
    retry = FrameAttempt.new(adapted_intent, retry_seq, rejected_attempt.pushed_at)

    state
    |> State.reset_frontend()
    |> State.queue_frame(retry)
    |> FrameHandler.advance()
  end

  @doc "Starts transaction recovery from the latest semantic intent."
  @spec transaction(State.t(), FrameAttempt.t()) :: {:noreply, State.t()}
  def transaction(state, %FrameAttempt{} = rejected_attempt) do
    AckLease.cancel_timer(state.awaiting_ack)

    latest = FrameAttempt.latest(state.pending, rejected_attempt)
    retry = FrameAttempt.force_keyframe(latest)

    state
    |> State.reset_frontend()
    |> State.queue_frame(retry)
    |> FrameHandler.advance()
  end

  @doc "Recovers one missed retained window without resetting unrelated frontend state."
  @spec window(State.t(), FrameAttempt.t(), non_neg_integer()) :: {:noreply, State.t()}
  def window(state, %FrameAttempt{} = rejected_attempt, window_id) do
    AckLease.cancel_timer(state.awaiting_ack)

    latest = FrameAttempt.latest(state.pending, rejected_attempt)

    recover_existing_window(state, latest, window_id)
  end

  @spec recover_existing_window(State.t(), FrameAttempt.t(), non_neg_integer()) ::
          {:noreply, State.t()}
  defp recover_existing_window(state, %FrameAttempt{} = attempt, window_id) do
    if Map.has_key?(attempt.intent.windows, window_id) do
      state
      |> BufferChanges.invalidate_window(window_id)
      |> State.queue_frame(attempt)
      |> FrameHandler.advance()
    else
      transaction(state, attempt)
    end
  end

  @spec terminal_without_adaptation(State.t(), non_neg_integer(), atom()) ::
          {:noreply, State.t()}
  defp terminal_without_adaptation(state, last_applied, reason) do
    AckLease.cancel_timer(state.awaiting_ack)
    {:noreply, State.terminal_failure(state, last_applied, reason)}
  end

  @spec schedule_render() :: reference()
  defp schedule_render do
    token = make_ref()
    send(self(), {:do_render, token})
    token
  end
end
