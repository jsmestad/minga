defmodule MingaEditor.Renderer.RecoveryDecision do
  @moduledoc "Pure recovery policy. Source tags keep timeout/request recovery distinct from frontend dispositions."

  alias MingaEditor.Renderer.AckLease

  @type source ::
          {:transaction, non_neg_integer(), non_neg_integer()}
          | {:timeout, non_neg_integer(), non_neg_integer()}
          | MingaEditor.Frontend.Protocol.input_event()
  @type plan :: %{
          generation: non_neg_integer(),
          force_keyframe?: boolean(),
          invalidate_window: non_neg_integer() | nil,
          seq: non_neg_integer()
        }
  @type result :: {:retry, plan()} | {:terminal, atom()} | :stale

  @doc "Chooses recovery from immutable lease evidence and a state-owned sequence."
  @spec decide(AckLease.t() | nil, source(), non_neg_integer()) :: result()
  def decide(%AckLease{} = lease, {source, generation, seq}, next_seq)
      when source in [:transaction, :timeout] do
    if AckLease.matches?(lease, generation, seq), do: keyframe(lease, next_seq), else: :stale
  end

  def decide(
        %AckLease{} = lease,
        {:frame_rejected, generation, seq, base, reason, disposition},
        next_seq
      ) do
    if matches?(lease, generation, seq, base) do
      rejection(lease, reason, disposition, next_seq)
    else
      :stale
    end
  end

  def decide(%AckLease{} = lease, {:window_ref_miss, generation, seq, base, window_id}, next_seq) do
    if matches?(lease, generation, seq, base) do
      window(lease, window_id, next_seq)
    else
      :stale
    end
  end

  def decide(_lease, _status, _next_seq), do: :stale

  defp matches?(lease, generation, seq, base),
    do:
      AckLease.matches_base?(
        lease,
        generation,
        seq,
        base,
        lease.output.caches.last_acknowledged_frame_seq
      )

  defp rejection(lease, reason, :retryable_recovery, next_seq) when reason != :resource_policy,
    do: keyframe(lease, next_seq)

  # Adaptation is authorized by RejectionState's one-shot evidence, never by a
  # frontend disposition alone. The handler supplies the adapted semantic intent.
  defp rejection(lease, _reason, :adapted_retry, next_seq), do: keyframe(lease, next_seq)
  defp rejection(_lease, reason, _disposition, _next_seq), do: {:terminal, reason}

  defp window(lease, window_id, next_seq) do
    if Map.has_key?(lease.attempt.intent.windows, window_id) do
      {:retry,
       %{
         generation: lease.generation,
         force_keyframe?: false,
         invalidate_window: window_id,
         seq: max(next_seq, lease.attempt.seq + 1)
       }}
    else
      keyframe(lease, next_seq)
    end
  end

  defp keyframe(lease, next_seq) do
    {:retry,
     %{
       generation: lease.generation + 1,
       force_keyframe?: true,
       invalidate_window: nil,
       seq: max(next_seq, lease.attempt.seq + 1)
     }}
  end
end
