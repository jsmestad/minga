defmodule MingaEditor.Agent.UIState.TranscriptProjectionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.Transcript.Cursor
  alias MingaEditor.Agent.{ProvenanceJump, Transcript}
  alias MingaEditor.Agent.UIState.TranscriptProjection

  test "replacement, paging, and provenance navigation invalidate the source cursor" do
    cursor = Cursor.new(make_ref(), 0, 1)
    display = Transcript.display([{:user, "opening turn"}])

    cached =
      TranscriptProjection.cache_display(TranscriptProjection.new(), display, [],
        source_cursor: cursor
      )

    assert cached.source_cursor == cursor
    assert TranscriptProjection.clear(cached).source_cursor == nil
    assert TranscriptProjection.set_display_start(cached, 1).source_cursor == nil

    assert TranscriptProjection.set_provenance_jump(cached, ProvenanceJump.request(1)).source_cursor ==
             nil

    assert TranscriptProjection.cache_display(cached, display, []).source_cursor == nil
  end
end
