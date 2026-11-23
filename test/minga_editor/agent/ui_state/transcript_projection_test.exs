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

  test "a streamed content revision keeps the presentation epoch, but a shape change does not" do
    source =
      Source.new([{:user, "question"}, {:assistant, "Str"}], ~U[2026-01-01 00:00:00Z], make_ref())

    {:snapshot, snapshot} = Source.since(source, :snapshot)
    context = {nil, %{}, fn _message, _id, _syntax -> nil end}

    projection =
      TranscriptProjection.replace(
        TranscriptProjection.new(),
        snapshot.entries,
        snapshot.pinned_ids,
        snapshot.cursor,
        context
      )

    epoch = TranscriptProjection.presentation_epoch(projection)

    streamed = Source.append_stream_tail(source, :assistant, ["eaming"])
    {:changes, changes} = Source.since(streamed, snapshot.cursor)
    {revised, :follow} = TranscriptProjection.apply_changes(projection, changes, :follow, context)
    revised = TranscriptProjection.bump_version(revised)

    assert revised.version == projection.version + 1
    assert TranscriptProjection.presentation_epoch(revised) == epoch

    {:snapshot, replacement} = Source.since(streamed, :snapshot)

    replaced =
      TranscriptProjection.replace(
        revised,
        replacement.entries,
        replacement.pinned_ids,
        replacement.cursor,
        context
      )

    shape_changes = [
      replaced,
      TranscriptProjection.set_display_start(revised, 1),
      TranscriptProjection.clear(revised)
    ]

    for changed <- shape_changes do
      refute TranscriptProjection.presentation_epoch(changed) == epoch
    end
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
