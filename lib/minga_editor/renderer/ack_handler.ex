defmodule MingaEditor.Renderer.AckHandler do
  @moduledoc "Owns frontend acknowledgement, rejection, and timeout transitions."

  alias MingaEditor.Renderer.{AckLease, Caches, FrameHandler, RecoveryHandler, State}

  @spec handle(State.t(), term()) :: {:noreply, State.t()}
  def handle(%State{awaiting_ack: %AckLease{} = lease} = state, {:frame_applied, generation, seq}) do
    if AckLease.matches?(lease, generation, seq) do
      AckLease.cancel_timer(lease)

      caches = Caches.acknowledge_frame(lease.output.caches, seq, generation)
      output = %{lease.output | caches: caches}

      FrameHandler.send_receipt(state.editor_pid, output, seq, lease.attempt.intent)

      state
      |> Map.put(:awaiting_ack, nil)
      |> FrameHandler.commit_output(output)
      |> FrameHandler.advance()
    else
      {:noreply, state}
    end
  end

  def handle(
        %State{awaiting_ack: %AckLease{} = lease} = state,
        {:frame_rejected, generation, seq, last_applied, reason, :retryable_recovery}
      )
      when reason != :resource_policy do
    if matching_base?(state, lease, generation, seq, last_applied) do
      Minga.Log.warning(:render, "Frontend rejected frame #{seq}: #{reason}")
      RecoveryHandler.transaction(state, lease.attempt)
    else
      {:noreply, state}
    end
  end

  def handle(
        %State{awaiting_ack: %AckLease{} = lease} = state,
        {:frame_rejected, generation, seq, last_applied, reason, :adapted_retry}
      ) do
    if matching_base?(state, lease, generation, seq, last_applied) do
      Minga.Log.warning(:render, "Frontend requested adapted retry for frame #{seq}: #{reason}")
      RecoveryHandler.adapted(state, last_applied, reason)
    else
      {:noreply, state}
    end
  end

  def handle(
        %State{awaiting_ack: %AckLease{} = lease} = state,
        {:frame_rejected, generation, seq, last_applied, reason, disposition}
      )
      when disposition in [
             :retryable_recovery,
             :targeted_replacement,
             :terminal_frontend_failure
           ] do
    if matching_base?(state, lease, generation, seq, last_applied) do
      terminal(state, last_applied, reason, disposition)
    else
      {:noreply, state}
    end
  end

  def handle(
        %State{awaiting_ack: %AckLease{} = lease} = state,
        {:window_ref_miss, generation, seq, last_applied, window_id}
      ) do
    if matching_base?(state, lease, generation, seq, last_applied) do
      Minga.Log.warning(:render, "Frontend missed window #{window_id} in frame #{seq}")
      RecoveryHandler.window(state, lease.attempt, window_id)
    else
      {:noreply, state}
    end
  end

  def handle(state, _status), do: {:noreply, state}

  @spec timeout(State.t(), non_neg_integer(), non_neg_integer()) :: {:noreply, State.t()}
  def timeout(%State{awaiting_ack: %AckLease{} = lease} = state, generation, seq) do
    if AckLease.matches?(lease, generation, seq) do
      Minga.Log.warning(:render, "Frontend acknowledgement timed out for frame #{seq}")
      RecoveryHandler.transaction(state, lease.attempt)
    else
      {:noreply, state}
    end
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

  defp terminal(state, last_applied, reason, disposition) do
    AckLease.cancel_timer(state.awaiting_ack)

    Minga.Log.warning(
      :render,
      "Frontend terminally rejected frame #{state.awaiting_ack.attempt.seq}: #{reason} (#{disposition})"
    )

    {:noreply, State.terminal_failure(state, last_applied, reason)}
  end
end
