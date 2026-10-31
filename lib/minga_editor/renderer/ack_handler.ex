defmodule MingaEditor.Renderer.AckHandler do
  @moduledoc "Owns frontend acknowledgement, rejection, and timeout transitions."

  alias MingaEditor.Renderer.{AckLease, Caches, FrameHandler, RecoveryHandler, State}

  @spec handle(State.t(), term()) :: {:noreply, State.t()}
  def handle(
        %State{frame_credit: {:awaiting_ack, %AckLease{} = lease, _successor}} = state,
        {:frame_applied, generation, seq}
      ) do
    if AckLease.matches?(lease, generation, seq) do
      AckLease.cancel_timer(lease)

      caches = Caches.acknowledge_frame(lease.output.caches, seq, generation)
      output = %{lease.output | caches: caches}

      FrameHandler.send_receipt(state.editor_pid, output, seq, lease.attempt.intent)

      state
      |> State.acknowledge_text_presentations(output)
      |> FrameHandler.commit_output(output)
      |> FrameHandler.advance()
    else
      {:noreply, state}
    end
  end

  def handle(
        %State{frame_credit: {:awaiting_ack, %AckLease{} = lease, _successor}} = state,
        {:frame_rejected, generation, seq, last_applied, reason, :adapted_retry} = status
      ) do
    if matching_base?(state, lease, generation, seq, last_applied) do
      RecoveryHandler.adapted(state, last_applied, reason)
    else
      RecoveryHandler.status(state, status)
    end
  end

  def handle(state, {:frame_rejected, _, _, _, _, _} = status),
    do: RecoveryHandler.status(state, status)

  def handle(
        %State{frame_credit: {:awaiting_ack, %AckLease{} = lease, _successor}} = state,
        {:window_ref_miss, generation, seq, last_applied, window_id}
      ) do
    if matching_base?(state, lease, generation, seq, last_applied),
      do: RecoveryHandler.window(state, lease.attempt, window_id),
      else: {:noreply, state}
  end

  def handle(state, _status), do: {:noreply, state}

  @spec timeout(State.t(), non_neg_integer(), non_neg_integer()) :: {:noreply, State.t()}
  def timeout(
        %State{frame_credit: {:awaiting_ack, %AckLease{}, _successor}} = state,
        generation,
        seq
      ) do
    RecoveryHandler.status(state, {:timeout, generation, seq})
  end

  def timeout(state, _generation, _seq), do: {:noreply, state}

  defp matching_base?(state, lease, generation, seq, last_applied) do
    AckLease.matches_base?(
      lease,
      generation,
      seq,
      last_applied,
      state.caches.last_acknowledged_frame_seq
    )
  end
end
