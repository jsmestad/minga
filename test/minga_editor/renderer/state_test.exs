defmodule MingaEditor.Renderer.StateTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.RenderModel.Window.Row
  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Renderer.AckLease
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.RecoveryHandler
  alias MingaEditor.Renderer.State
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Renderer.TextPresentations

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

  test "rejection recovery preserves the visible lease until recovered activation" do
    old = presentation(1, 101, 3, "old")
    registry = TextPresentations.acknowledge(TextPresentations.new(), [old])
    assert {:ok, registry} = TextPresentations.activate(registry, 1, old.presentation_id)

    state =
      %{State.new(generation_reserver: fn -> 2 end) | text_presentations: registry}

    assert {:noreply, recovered} = RecoveryHandler.transaction(state, attempt(10))

    assert {:ok, %TextTarget{line: 3}} = State.resolve_text_target(recovered, event(old))

    replacement = presentation(1, 102, 4, "recovered")

    admitted =
      TextPresentations.acknowledge(recovered.text_presentations, [replacement])

    recovered = %{recovered | text_presentations: admitted}

    assert {:ok, recovered} =
             State.text_presentation_state(
               recovered,
               1,
               replacement.presentation_id,
               :active
             )

    assert {:ok, %TextTarget{line: 4}} = State.resolve_text_target(recovered, event(replacement))

    reset = State.reset_connection(recovered, 3)
    assert {:error, :inactive} = State.resolve_text_target(reset, event(replacement))
  end

  defp presentation(window_id, row_id, line, text) do
    row = %Row{
      row_id: row_id,
      row_type: :normal,
      buf_line: line,
      text: text,
      spans: [],
      content_hash: Row.compute_hash(text, [])
    }

    visual =
      VisualRow.new(
        row,
        SourceOffsetMap.new(text, text, Decorations.new(), line),
        0,
        byte_size(text),
        0
      )

    TextPresentation.new(window_id, self(), 7, {:identity, row_id}, {:windowed, {visual}})
  end

  defp event(presentation) do
    {%VisualRow{row: row}} = elem(presentation.rows, 1)

    TextEvent.new(%{
      window_id: presentation.window_id,
      presentation_id: presentation.presentation_id,
      row_index: 0,
      row_id: row.row_id,
      utf16_offset: 1,
      button: :left,
      mods: 0,
      event_type: :press,
      click_count: 1,
      scroll_x: 0,
      scroll_y: 0
    })
  end

  defp attempt(seq), do: FrameAttempt.new(intent(), seq, 0)
  defp intent, do: input().intent

  defp input do
    TestHelpers.base_state()
    |> Input.from_editor_state()
  end
end
