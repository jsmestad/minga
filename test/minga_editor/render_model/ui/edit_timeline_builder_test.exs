defmodule MingaEditor.RenderModel.UI.EditTimelineBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.EditTimelineBuilder
  alias Minga.RenderModel.UI.EditTimeline

  describe "build/1" do
    test "builds a hidden timeline when there is no agent_ui" do
      assert %EditTimeline{visible?: false, entries: []} = EditTimelineBuilder.build(%{})
    end

    test "builds a hidden timeline when there is no active buffer" do
      ctx = %{agent_ui: %{view: %{edit_timeline: nil}}, buffers: %{active: nil}}

      assert %EditTimeline{visible?: false} = EditTimelineBuilder.build(ctx)
    end
  end
end
