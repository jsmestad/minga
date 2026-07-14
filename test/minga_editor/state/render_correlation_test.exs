defmodule MingaEditor.State.RenderCorrelationTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Render
  alias MingaEditor.State.RenderCorrelation

  import MingaEditor.RenderPipeline.TestHelpers

  test "render timer admission coalesces until the timer is cleared" do
    first = make_ref()
    second = make_ref()
    correlation = RenderCorrelation.new()
    first_identity = RenderCorrelation.next_timer_identity(correlation)

    assert {:scheduled, correlation} =
             RenderCorrelation.schedule(correlation, first_identity, first)

    assert RenderCorrelation.scheduled?(correlation)
    assert RenderCorrelation.timer_reference(correlation) == first
    assert RenderCorrelation.scheduled_identity(correlation) == first_identity

    second_identity = RenderCorrelation.next_timer_identity(correlation)

    assert {:coalesced, unchanged} =
             RenderCorrelation.schedule(correlation, second_identity, second)

    assert unchanged == correlation

    cleared = RenderCorrelation.clear_timer(correlation)
    refute RenderCorrelation.scheduled?(cleared)
    assert RenderCorrelation.timer_reference(cleared) == nil
    assert RenderCorrelation.scheduled_identity(cleared) == nil
  end

  test "timer replacement gives the new window a distinct identity and rejects stale delivery" do
    correlation = RenderCorrelation.new()
    old_identity = RenderCorrelation.next_timer_identity(correlation)
    {:scheduled, correlation} = RenderCorrelation.schedule(correlation, old_identity, make_ref())

    cleared = RenderCorrelation.clear_timer(correlation)
    new_identity = RenderCorrelation.next_timer_identity(cleared)
    refute new_identity == old_identity

    {:scheduled, replacement} =
      RenderCorrelation.schedule(cleared, new_identity, make_ref())

    assert {:stale, unchanged} = RenderCorrelation.deliver(replacement, old_identity)
    assert unchanged == replacement
    assert RenderCorrelation.scheduled?(unchanged)

    assert {:current, delivered} = RenderCorrelation.deliver(replacement, new_identity)
    refute RenderCorrelation.scheduled?(delivered)
  end

  test "Editor callback changes state only for the current timer identity" do
    state = base_state(backend: :tui, rendering: :disabled)
    first = MingaEditor.schedule_render(state, 60_000)
    first_correlation = first.render.render_correlation
    first_identity = RenderCorrelation.scheduled_identity(first_correlation)
    first_timer = RenderCorrelation.timer_reference(first_correlation)

    cleared = %{
      first
      | render:
          Render.accept_correlation(
            first.render,
            RenderCorrelation.clear_timer(first_correlation)
          )
    }

    replacement = MingaEditor.schedule_render(cleared, 60_000)
    replacement_correlation = replacement.render.render_correlation
    replacement_identity = RenderCorrelation.scheduled_identity(replacement_correlation)
    replacement_timer = RenderCorrelation.timer_reference(replacement_correlation)

    on_exit(fn ->
      Process.cancel_timer(first_timer)
      Process.cancel_timer(replacement_timer)
    end)

    stale_message = {:debounced_render, first_identity}
    send(self(), stale_message)
    assert_receive ^stale_message
    assert {:noreply, unchanged} = MingaEditor.handle_info(stale_message, replacement)
    assert unchanged == replacement

    current_message = {:debounced_render, replacement_identity}
    send(self(), current_message)
    assert_receive ^current_message
    assert {:noreply, delivered} = MingaEditor.handle_info(current_message, replacement)
    refute RenderCorrelation.scheduled?(delivered.render.render_correlation)
  end

  test "frontend readiness and reset require a keyframe without resetting ordering evidence" do
    correlation = %RenderCorrelation{
      latest_intent_revision: 8,
      last_receipt_revision: 7,
      last_receipt_seq: 41
    }

    ready = RenderCorrelation.frontend_ready(correlation)
    assert RenderCorrelation.force_keyframe?(ready)
    assert RenderCorrelation.latest_intent_revision(ready) == 8
    assert RenderCorrelation.last_receipt_revision(ready) == 7
    assert RenderCorrelation.last_receipt_sequence(ready) == 41

    reset = RenderCorrelation.reset(correlation)
    assert reset == ready
  end

  test "intent submissions advance independently of receipt acknowledgement" do
    {correlation, first} = RenderCorrelation.submit(RenderCorrelation.new())
    {correlation, second} = RenderCorrelation.submit(correlation)

    assert first == 1
    assert second == 2
    assert RenderCorrelation.latest_intent_revision(correlation) == 2
    assert RenderCorrelation.last_receipt_revision(correlation) == 0
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

    assert RenderCorrelation.last_receipt_revision(correlation) == 10
    assert RenderCorrelation.last_receipt_sequence(correlation) == 20
  end
end
