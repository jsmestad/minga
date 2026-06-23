defmodule MingaEditor.RenderModel.UI.EditTimelineBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.EditTimelineBuilder
  alias Minga.RenderModel.UI.EditTimeline
  alias MingaEditor.Agent.EditTimeline, as: EditTimelineState

  describe "build/1" do
    test "builds a hidden timeline when there is no agent_ui" do
      assert %EditTimeline{visible?: false, entries: []} = EditTimelineBuilder.build(%{})
    end

    test "builds a hidden timeline when there is no active buffer" do
      ctx = %{agent_ui: %{view: %{edit_timeline: nil}}, buffers: %{active: nil}}

      assert %EditTimeline{visible?: false} = EditTimelineBuilder.build(ctx)
    end

    test "builds aggregate file entries for multi-file turns without an active buffer path" do
      timeline =
        EditTimelineState.new()
        |> EditTimelineState.record_edit("lib/a.ex", "tc1", "edit_file", "old\n", "new\n")
        |> EditTimelineState.record_edit("lib/b.ex", "tc2", "edit_file", "one\n", "one\ntwo\n")

      ctx = %{agent_ui: %{view: %{edit_timeline: timeline}}, buffers: %{active: nil}}

      assert %EditTimeline{
               visible?: true,
               entries: [],
               files: [
                 %EditTimeline.FileEntry{
                   path: "lib/a.ex",
                   entry_count: 1,
                   lines_added: 1,
                   lines_removed: 1,
                   review_status: :pending
                 },
                 %EditTimeline.FileEntry{
                   path: "lib/b.ex",
                   entry_count: 1,
                   lines_added: 1,
                   lines_removed: 0,
                   review_status: :pending
                 }
               ]
             } = EditTimelineBuilder.build(ctx)
    end
  end
end
