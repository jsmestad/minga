defmodule MingaEditor.RenderModel.UI.EditTimelineBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.EditTimelineBuilder
  alias Minga.RenderModel.UI.EditTimeline
  alias MingaEditor.Agent.EditTimeline, as: EditTimelineState
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.TestHelpers

  describe "build/1" do
    test "builds a hidden timeline when there is no agent_ui" do
      assert %EditTimeline{visible?: false, entries: []} = EditTimelineBuilder.build(context(nil))
    end

    test "builds a hidden timeline when there is no active buffer" do
      ctx = context(nil)

      assert %EditTimeline{visible?: false} = EditTimelineBuilder.build(ctx)
    end

    test "builds aggregate file entries for multi-file turns without an active buffer path" do
      timeline =
        EditTimelineState.new()
        |> EditTimelineState.record_edit("lib/a.ex", "tc1", "edit_file", "old\n", "new\n")
        |> EditTimelineState.record_edit("lib/b.ex", "tc2", "edit_file", "one\n", "one\ntwo\n")

      ctx = context(timeline)

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

  defp context(timeline) do
    ctx =
      TestHelpers.base_state(port_manager: nil)
      |> Context.from_editor_state()

    agent_ui = UIState.new()
    agent_ui = put_in(agent_ui.view.edit_timeline, timeline)
    buffers = %{ctx.workspace.buffers | active: nil, list: [], active_index: 0}
    workspace = %{ctx.workspace | agent_ui: agent_ui, buffers: buffers}

    %{ctx | workspace: workspace, intent: %{ctx.intent | workspace: workspace}}
  end
end
