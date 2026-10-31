defmodule MingaEditor.Renderer.RecoveryDecisionTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.{AckLease, Caches, FrameAttempt, RecoveryDecision, State}

  # No renderer, timers, or buffer processes: the entire source × lease matrix
  # is a calculation over immutable evidence.
  @sources [
    {:transaction, 1, 20},
    {:timeout, 1, 20},
    {:frame_rejected, 1, 20, 19, :base_sequence_mismatch, :retryable_recovery},
    {:frame_rejected, 1, 20, 19, :resource_policy, :retryable_recovery},
    {:frame_rejected, 1, 20, 19, :resource_policy, :adapted_retry},
    {:frame_rejected, 1, 20, 19, :resource_policy, :targeted_replacement},
    {:frame_rejected, 1, 20, 19, :resource_policy, :terminal_frontend_failure},
    {:window_ref_miss, 1, 20, 19, 1},
    {:window_ref_miss, 1, 20, 19, 99},
    {:frame_applied, 1, 20}
  ]

  test "every recovery source against absent, matching, wrong-generation and wrong-sequence leases" do
    for source <- @sources do
      assert RecoveryDecision.decide(nil, source, 21) == :stale
      assert RecoveryDecision.decide(lease(2, 20), source, 21) == :stale
      assert RecoveryDecision.decide(lease(1, 21), source, 22) == :stale
      assert RecoveryDecision.decide(lease(1, 20), source, 21) == expected(source)
    end
  end

  test "frontend base evidence is required; local timeout does not impersonate a rejection" do
    lease = lease(1, 20)

    for status <- [
          {:frame_rejected, 1, 20, 18, :base_sequence_mismatch, :retryable_recovery},
          {:window_ref_miss, 1, 20, 18, 1}
        ] do
      assert RecoveryDecision.decide(lease, status, 21) == :stale
    end

    assert {:retry, %{generation: 2, seq: 21, force_keyframe?: true}} =
             RecoveryDecision.decide(lease, {:timeout, 1, 20}, 0)
  end

  test "queued caller sequences and repeated retries reserve deterministic identities" do
    attempt = lease(1, 20).attempt
    {state, 20} = State.reserve_submission_sequence(State.new([]), 20)
    {state, 21} = State.reserve_retry_sequence(state, attempt)
    {_state, 22} = State.reserve_retry_sequence(state, attempt)
    assert {:retry, %{seq: 100}} = RecoveryDecision.decide(lease(1, 20), {:timeout, 1, 20}, 100)
  end

  test "submission reservation treats requested identities as lower bounds without wrapping" do
    {state, 1} = State.reserve_submission_sequence(State.new([]), 0)
    {state, 2} = State.reserve_submission_sequence(state, 0)
    {state, 3} = State.reserve_submission_sequence(state, 1)
    {state, 10} = State.reserve_submission_sequence(state, 10)
    {state, 11} = State.reserve_submission_sequence(state, 11)
    assert state.next_frame_seq == 12
    {state, 0xFFFF_FFFF} = State.reserve_submission_sequence(state, 0xFFFF_FFFF)
    assert state.next_frame_seq == 0x1_0000_0000
  end

  test "a retry reuses its unissued successor without advancing the admission high water again" do
    lease = lease(1, 20)
    {state, 20} = State.reserve_submission_sequence(State.new([]), 20)
    {state, 21} = State.reserve_submission_sequence(state, 0)
    successor = %{lease.attempt | seq: 21}
    state = %{state | frame_credit: {:awaiting_ack, lease, successor}}
    {state, 21} = State.reserve_retry_sequence(state, lease.attempt)
    assert state.next_frame_seq == 22
    {_state, 22} = State.reserve_submission_sequence(state, 21)
  end

  defp expected({:frame_applied, _, _}), do: :stale

  defp expected({:frame_rejected, _, _, _, :resource_policy, disposition})
       when disposition != :adapted_retry, do: {:terminal, :resource_policy}

  defp expected({:window_ref_miss, _, _, _, 1}),
    do: {:retry, %{generation: 1, seq: 21, force_keyframe?: false, invalidate_window: 1}}

  defp expected(_),
    do: {:retry, %{generation: 2, seq: 21, force_keyframe?: true, invalidate_window: nil}}

  defp lease(generation, seq) do
    %AckLease{
      attempt: %FrameAttempt{intent: %{windows: %{1 => :present}}, seq: seq, pushed_at: 0},
      generation: generation,
      timer_ref: nil,
      output: %{caches: %Caches{last_acknowledged_frame_seq: 19}}
    }
  end
end
