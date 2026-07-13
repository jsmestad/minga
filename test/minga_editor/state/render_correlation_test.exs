defmodule MingaEditor.State.RenderCorrelationTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.RenderCorrelation

  test "render timer admission coalesces until the timer is cleared" do
    first = make_ref()
    second = make_ref()

    assert {:scheduled, correlation} = RenderCorrelation.schedule(RenderCorrelation.new(), first)
    assert RenderCorrelation.scheduled?(correlation)
    assert correlation.timer == first
    assert {:coalesced, unchanged} = RenderCorrelation.schedule(correlation, second)
    assert unchanged == correlation

    cleared = RenderCorrelation.clear_timer(correlation)
    refute RenderCorrelation.scheduled?(cleared)
    assert cleared.timer == nil
  end

  test "frontend readiness and reset require a keyframe without resetting ordering evidence" do
    correlation = %RenderCorrelation{
      latest_intent_revision: 8,
      last_receipt_revision: 7,
      last_receipt_seq: 41
    }

    ready = RenderCorrelation.frontend_ready(correlation)
    assert RenderCorrelation.force_keyframe?(ready)
    assert ready.latest_intent_revision == 8
    assert ready.last_receipt_revision == 7
    assert ready.last_receipt_seq == 41

    reset = RenderCorrelation.reset(correlation)
    assert reset == ready
  end

  test "intent submissions advance independently of receipt acknowledgement" do
    {correlation, first} = RenderCorrelation.submit(RenderCorrelation.new())
    {correlation, second} = RenderCorrelation.submit(correlation)

    assert first == 1
    assert second == 2
    assert correlation.latest_intent_revision == 2
    assert correlation.last_receipt_revision == 0
  end

  test "receipt freshness rejects superseded, duplicate, and out-of-order evidence" do
    correlation = %RenderCorrelation{
      latest_intent_revision: 3,
      last_receipt_revision: 2,
      last_receipt_seq: 20
    }

    assert RenderCorrelation.classify_receipt(correlation, 2, 21) ==
             {:stale, :superseded_intent}

    assert RenderCorrelation.classify_receipt(correlation, 3, 20) ==
             {:stale, :stale_sequence}

    accepted = RenderCorrelation.accept_receipt(correlation, 3, 21, false)

    assert RenderCorrelation.classify_receipt(accepted, 3, 22) ==
             {:stale, :stale_receipt_revision}

    assert RenderCorrelation.classify_receipt(accepted, 4, 21) ==
             {:stale, :stale_sequence}

    assert RenderCorrelation.classify_receipt(accepted, 4, 22) == {:fresh, 4}
  end

  test "legacy revision zero normalizes to frame sequence before any submitted intent" do
    correlation = RenderCorrelation.new()
    assert RenderCorrelation.classify_receipt(correlation, 0, 12) == {:fresh, 12}

    correlation = RenderCorrelation.accept_receipt(correlation, 12, 12, false)

    assert RenderCorrelation.classify_receipt(correlation, 0, 12) ==
             {:stale, :stale_receipt_revision}
  end

  test "only an accepted keyframe fulfills a pending keyframe request" do
    correlation = RenderCorrelation.request_keyframe(RenderCorrelation.new())
    assert RenderCorrelation.force_keyframe?(correlation)

    delta = RenderCorrelation.accept_receipt(correlation, 1, 1, false)
    assert RenderCorrelation.force_keyframe?(delta)

    keyframe = RenderCorrelation.accept_receipt(delta, 2, 2, true)
    refute RenderCorrelation.force_keyframe?(keyframe)
  end

  test "synchronous receipts preserve monotonic revision and sequence evidence" do
    correlation = %RenderCorrelation{last_receipt_revision: 10, last_receipt_seq: 20}
    correlation = RenderCorrelation.accept_synchronous_receipt(correlation, 8, 19, false)

    assert correlation.last_receipt_revision == 10
    assert correlation.last_receipt_seq == 20
  end
end
