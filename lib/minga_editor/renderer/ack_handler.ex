defmodule MingaEditor.Renderer.AckHandler do
  @moduledoc "Owns frontend acknowledgement, rejection, and timeout transitions."

  alias MingaEditor.Renderer.Caches
  alias MingaEditor.Renderer.FrameHandler
  alias MingaEditor.Renderer.RecoveryHandler
  alias MingaEditor.Renderer.State

  @spec handle(State.t(), term()) :: {:noreply, State.t()}
  def handle(
        %State{
          awaiting_ack:
            %{generation: generation, seq: seq, output: output, intent: intent} = lease
        } = state,
        {:frame_applied, generation, seq}
      ) do
    RecoveryHandler.cancel_timer(lease)
    output = %{output | caches: Caches.acknowledge_frame(output.caches, seq, generation)}
    FrameHandler.send_receipt(state.editor_pid, output, seq, intent)

    state
    |> Map.put(:awaiting_ack, nil)
    |> FrameHandler.commit_output(output)
    |> FrameHandler.advance()
  end

  def handle(
        %State{
          awaiting_ack: %{generation: generation, seq: seq, intent: intent, pushed_at: pushed_at}
        } = state,
        {:frame_rejected, generation, seq, last_applied, reason, :retryable_recovery}
      )
      when reason != :resource_policy and last_applied == state.caches.last_acknowledged_frame_seq do
    Minga.Log.warning(:render, "Frontend rejected frame #{seq}: #{reason}")
    RecoveryHandler.transaction(state, intent, seq, pushed_at)
  end

  def handle(
        %State{awaiting_ack: %{generation: generation, seq: seq}} = state,
        {:frame_rejected, generation, seq, last_applied, reason, :adapted_retry}
      )
      when last_applied == state.caches.last_acknowledged_frame_seq do
    Minga.Log.warning(:render, "Frontend requested adapted retry for frame #{seq}: #{reason}")
    RecoveryHandler.adapted(state, last_applied, reason)
  end

  def handle(
        %State{awaiting_ack: %{generation: generation, seq: seq}} = state,
        {:frame_rejected, generation, seq, last_applied, reason, disposition}
      )
      when last_applied == state.caches.last_acknowledged_frame_seq and
             disposition in [
               :retryable_recovery,
               :targeted_replacement,
               :terminal_frontend_failure
             ] do
    terminal(state, last_applied, reason, disposition)
  end

  # Keep direct callers from the protocol-version-11 contract retryable.
  def handle(state, {:frame_rejected, generation, seq, last_applied, reason}) do
    handle(
      state,
      {:frame_rejected, generation, seq, last_applied, reason, :retryable_recovery}
    )
  end

  def handle(
        %State{
          awaiting_ack: %{generation: generation, seq: seq, intent: intent, pushed_at: pushed_at}
        } = state,
        {:window_ref_miss, generation, seq, last_applied, window_id}
      )
      when last_applied == state.caches.last_acknowledged_frame_seq do
    Minga.Log.warning(:render, "Frontend missed window #{window_id} in frame #{seq}")
    RecoveryHandler.window(state, intent, seq, pushed_at, window_id)
  end

  def handle(state, _status), do: {:noreply, state}

  @spec timeout(State.t(), non_neg_integer(), non_neg_integer()) :: {:noreply, State.t()}
  def timeout(
        %State{
          awaiting_ack: %{generation: generation, seq: seq, intent: intent, pushed_at: pushed_at}
        } = state,
        generation,
        seq
      ) do
    Minga.Log.warning(:render, "Frontend acknowledgement timed out for frame #{seq}")
    RecoveryHandler.transaction(state, intent, seq, pushed_at)
  end

  def timeout(state, _generation, _seq), do: {:noreply, state}

  @spec terminal(State.t(), non_neg_integer(), atom(), atom()) :: {:noreply, State.t()}
  defp terminal(state, last_applied, reason, disposition) do
    RecoveryHandler.cancel_timer(state.awaiting_ack)

    Minga.Log.warning(
      :render,
      "Frontend terminally rejected frame #{state.awaiting_ack.seq}: #{reason} (#{disposition})"
    )

    {:noreply, State.terminal_failure(state, last_applied, reason)}
  end
end
