defmodule MingaEditor.Renderer.RecoveryHandler do
  @moduledoc "Owns connection reset, timeout recovery, and targeted window recovery."

  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.FrameHandler
  alias MingaEditor.Renderer.State

  @spec reset(State.t(), Intent.t(), non_neg_integer(), integer()) :: {:reply, :ok, State.t()}
  def reset(state, intent, seq, pushed_at) do
    cancel_timer(state.awaiting_ack)
    state = state |> State.reset_frontend(:renderer_restart) |> State.clear_rejection()
    token = schedule_render()

    {:reply, :ok,
     %{
       state
       | rendering?: true,
         render_token: token,
         stale_retry_count: 0,
         pending: nil,
         in_flight: {Intent.force_keyframe(intent), seq, pushed_at},
         awaiting_ack: nil
     }}
  end

  @doc "Resets frontend state and renders a synchronous recovery keyframe."
  @spec reset_sync(State.t(), Intent.t(), non_neg_integer(), integer()) ::
          {:reply, {:ok, MingaEditor.Renderer.RenderReceipt.t()} | {:error, Exception.t()},
           State.t()}
  def reset_sync(state, intent, seq, pushed_at) do
    cancel_timer(state.awaiting_ack)

    state
    |> State.reset_frontend(:renderer_restart)
    |> State.clear_rejection()
    |> FrameHandler.render_sync(Intent.force_keyframe(intent), seq, pushed_at)
  end

  @spec request(State.t()) :: {:noreply, State.t()}
  def request(%State{awaiting_ack: %{intent: intent, seq: seq, pushed_at: pushed_at}} = state),
    do: transaction(state, intent, seq, pushed_at)

  def request(%State{pending: {intent, seq, pushed_at}} = state),
    do: transaction(state, intent, seq, pushed_at)

  def request(state), do: {:noreply, state}

  @doc "Starts one fresh-generation retry only after consuming explicit adaptation evidence."
  @spec adapted(State.t(), non_neg_integer(), atom()) :: {:noreply, State.t()}
  def adapted(
        %State{
          awaiting_ack: %{
            generation: generation,
            seq: rejected_seq,
            pushed_at: pushed_at
          }
        } = state,
        last_applied,
        reason
      ) do
    case State.consume_adaptation(state, generation, rejected_seq) do
      {:ok, adapted_state, adapted_intent} ->
        adapted_transaction(adapted_state, adapted_intent, rejected_seq, pushed_at)

      :error ->
        terminal_without_adaptation(state, last_applied, reason)
    end
  end

  @spec adapted_transaction(State.t(), Intent.t(), non_neg_integer(), integer()) ::
          {:noreply, State.t()}
  defp adapted_transaction(state, adapted_intent, rejected_seq, pushed_at) do
    cancel_timer(state.awaiting_ack)
    retry_seq = max(System.unique_integer([:positive, :monotonic]), rejected_seq + 1)

    state
    |> State.reset_frontend()
    |> State.queue_frame({adapted_intent, retry_seq, pushed_at})
    |> FrameHandler.advance()
  end

  @doc "Starts transaction recovery from the latest semantic intent."
  @spec transaction(State.t(), Intent.t(), non_neg_integer(), integer()) ::
          {:noreply, State.t()}
  def transaction(state, rejected_intent, rejected_seq, rejected_pushed_at) do
    cancel_timer(state.awaiting_ack)

    {latest, seq, pushed_at} =
      latest(state.pending, rejected_intent, rejected_seq, rejected_pushed_at)

    state
    |> State.reset_frontend()
    |> State.queue_frame({Intent.force_keyframe(latest), seq, pushed_at})
    |> FrameHandler.advance()
  end

  @doc "Recovers one missed retained window without resetting unrelated frontend state."
  @spec window(State.t(), Intent.t(), non_neg_integer(), integer(), non_neg_integer()) ::
          {:noreply, State.t()}
  def window(state, rejected_intent, rejected_seq, rejected_pushed_at, window_id) do
    cancel_timer(state.awaiting_ack)

    {latest, seq, pushed_at} =
      latest(state.pending, rejected_intent, rejected_seq, rejected_pushed_at)

    recover_existing_window(state, latest, seq, pushed_at, window_id)
  end

  @doc "Cancels an acknowledgement lease timer."
  @spec cancel_timer(State.ack_lease() | nil) :: :ok
  def cancel_timer(nil), do: :ok

  def cancel_timer(%{timer_ref: timer_ref}) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  @spec recover_existing_window(
          State.t(),
          Intent.t(),
          non_neg_integer(),
          integer(),
          non_neg_integer()
        ) ::
          {:noreply, State.t()}
  defp recover_existing_window(state, intent, seq, pushed_at, window_id) do
    if Map.has_key?(intent.windows, window_id) do
      state
      |> BufferChanges.invalidate_window(window_id)
      |> State.queue_frame({intent, seq, pushed_at})
      |> FrameHandler.advance()
    else
      transaction(state, intent, seq, pushed_at)
    end
  end

  @spec terminal_without_adaptation(State.t(), non_neg_integer(), atom()) ::
          {:noreply, State.t()}
  defp terminal_without_adaptation(state, last_applied, reason) do
    cancel_timer(state.awaiting_ack)
    {:noreply, State.terminal_failure(state, last_applied, reason)}
  end

  @spec latest(State.frame_work() | nil, Intent.t(), non_neg_integer(), integer()) ::
          State.frame_work()
  defp latest({intent, seq, pushed_at}, _fallback, rejected_seq, _fallback_at)
       when seq > rejected_seq,
       do: {intent, seq, pushed_at}

  defp latest(_pending, fallback, rejected_seq, fallback_at) do
    unique_seq = System.unique_integer([:positive, :monotonic])
    {fallback, max(unique_seq, rejected_seq + 1), fallback_at}
  end

  @spec schedule_render() :: reference()
  defp schedule_render do
    token = make_ref()
    send(self(), {:do_render, token})
    token
  end
end
