defmodule MingaEditor.Agent.UIState.TranscriptProjectionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.Transcript, as: Source
  alias MingaEditor.Agent.ProvenanceJump
  alias MingaEditor.Agent.UIState.TranscriptProjection

  test "paging and provenance navigation preserve source identity, but clearing it does not" do
    source = Source.new([{:user, "opening turn"}], ~U[2026-01-01 00:00:00Z], make_ref())
    assert {:snapshot, snapshot} = Source.since(source, :snapshot)
    context = {nil, %{}, fn _message, _id, _syntax -> nil end}

    projection =
      TranscriptProjection.replace(
        TranscriptProjection.new(),
        snapshot.entries,
        snapshot.pinned_ids,
        snapshot.cursor,
        context
      )

    paged = TranscriptProjection.set_display_start(projection, 1)
    assert paged.source_cursor == snapshot.cursor
    assert TranscriptProjection.visible_pair(paged, 1) == nil

    revealed =
      paged
      |> TranscriptProjection.set_provenance_jump(ProvenanceJump.request({:message_id, 1}))
      |> TranscriptProjection.prepare(context)

    assert revealed.source_cursor == snapshot.cursor
    assert TranscriptProjection.visible_pair(revealed, 1) == {1, {:user, "opening turn"}}

    cleared = TranscriptProjection.clear(revealed)
    assert cleared.source_cursor == nil
    assert TranscriptProjection.visible_pair(cleared, 1) == nil
  end

  test "a provenance request resolves against the incoming generation, not the visible one" do
    tool = {:tool_call, MingaAgent.ToolCall.new("shared", "edit_file")}

    {previous, current} =
      {{:user, "old question"}, {:user, "new question"}}

    source = Source.new([previous, tool], ~U[2026-01-01 00:00:00Z], make_ref())
    {:snapshot, old} = Source.since(source, :snapshot)
    context = {nil, %{}, fn _message, _id, _syntax -> nil end}
    origin = {"/tmp/origin", 3}
    jump = ProvenanceJump.request({:tool_call_id, "shared"}, origin)

    projection =
      TranscriptProjection.new()
      |> TranscriptProjection.replace(old.entries, old.pinned_ids, old.cursor, context)
      |> TranscriptProjection.set_provenance_jump(jump)
      |> TranscriptProjection.prepare(context)

    assert projection.provenance_jump == jump

    incoming =
      Source.new(
        [{:system, "reopened", :info}, current, tool],
        ~U[2026-01-01 00:00:00Z],
        make_ref()
      )

    {:snapshot, snapshot} = Source.since(incoming, :snapshot)

    landed =
      TranscriptProjection.replace(
        projection,
        snapshot.entries,
        snapshot.pinned_ids,
        snapshot.cursor,
        context
      )

    assert %ProvenanceJump{target: {:message_id, 2}, origin: ^origin, landed?: true} =
             landed.provenance_jump

    assert {2, ^current, 0, :text} =
             TranscriptProjection.line_at(landed, TranscriptProjection.start_line(landed, 2))
  end
end
