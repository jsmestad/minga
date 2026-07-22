defmodule MingaEditor.Renderer.StateTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.AckLease
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.State

  test "new state starts with idle frame credit" do
    assert State.new([]).frame_credit == :idle
    refute State.rendering?(State.new([]))
  end

  test "scheduled credit consumes only exact render token" do
    state = State.new([])
    attempt = attempt(10)
    token = make_ref()

    scheduled = State.schedule_frame(state, attempt, token)

    assert State.rendering?(scheduled)
    assert scheduled.frame_credit == {:scheduled, token, attempt, 0, nil}
    assert State.consume_render_token(scheduled, make_ref()) == :stale
    assert State.consume_render_token(scheduled, token) == {:ok, scheduled, attempt, 0}
  end

  test "coalescing preserves scheduled work and reports replaced successor" do
    state = State.schedule_frame(State.new([]), attempt(10), make_ref())
    successor_11 = attempt(11)
    successor_12 = attempt(12)

    assert {:coalesced, coalesced, nil} = State.coalesce_frame(state, successor_11)
    assert {:scheduled, _token, %FrameAttempt{seq: 10}, 0, ^successor_11} = coalesced.frame_credit

    assert {:coalesced, latest, ^successor_11} = State.coalesce_frame(coalesced, successor_12)
    assert {:scheduled, _token, %FrameAttempt{seq: 10}, 0, ^successor_12} = latest.frame_credit
  end

  test "awaiting acknowledgement preserves successor" do
    state = State.schedule_frame(State.new([]), attempt(10), make_ref())
    successor = attempt(11)
    {:coalesced, state, nil} = State.coalesce_frame(state, successor)
    lease = AckLease.start(attempt(10), input(), 1_000)

    awaiting = State.await_ack(state, lease)

    assert awaiting.frame_credit == {:awaiting_ack, lease, successor}
    assert State.awaiting_lease(awaiting) == lease
  end

  test "advance credit clears busy phase and returns successor when present" do
    scheduled = State.schedule_frame(State.new([]), attempt(10), make_ref())
    assert State.advance_credit(scheduled) == {:idle, %{scheduled | frame_credit: :idle}}

    successor = attempt(11)
    {:coalesced, awaiting_source, nil} = State.coalesce_frame(scheduled, successor)
    lease = AckLease.start(attempt(10), input(), 1_000)
    awaiting = State.await_ack(awaiting_source, lease)

    assert {:schedule, cleared, ^successor} = State.advance_credit(awaiting)
    assert cleared.frame_credit == :idle
  end

  test "retry replaces only token and increments retry count" do
    new_token = make_ref()
    attempt = attempt(10)

    state =
      State.new([])
      |> State.schedule_frame(attempt, make_ref())
      |> State.retry_scheduled_frame(new_token)

    assert state.frame_credit == {:scheduled, new_token, attempt, 1, nil}
  end

  test "latest successor chooses newer queued work or refreshes fallback" do
    fallback = attempt(10)
    successor = attempt(11)

    state = State.schedule_frame(State.new([]), fallback, make_ref())
    {:coalesced, state, nil} = State.coalesce_frame(state, successor)

    assert State.latest_successor(state, fallback) == successor

    refreshed = State.latest_successor(State.new([]), fallback)
    assert refreshed.seq > fallback.seq
    assert %{refreshed | seq: fallback.seq} == fallback
  end

  defp attempt(seq), do: FrameAttempt.new(intent(), seq, 0)
  defp intent, do: Intent.from_input(input())

  defp input do
    %Input{
      port_manager: self(),
      theme: MingaEditor.UI.Theme.get!(:doom_one),
      capabilities: %MingaEditor.Frontend.Capabilities{},
      shell_id: :traditional,
      shell: MingaEditor.Shell.Traditional,
      workspace: %{windows: %MingaEditor.State.Windows{}},
      message_store: MingaEditor.UI.Panel.MessageStore.new()
    }
  end
end
