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
        {:frame_rejected, generation, seq, last_applied, reason}
      )
      when last_applied == state.caches.last_acknowledged_frame_seq do
    Minga.Log.warning(:render, "Frontend rejected frame #{seq}: #{reason}")
    RecoveryHandler.transaction(state, intent, seq, pushed_at)
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
end
