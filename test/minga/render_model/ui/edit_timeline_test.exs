defmodule Minga.RenderModel.UI.EditTimelineTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.EditTimeline
  alias Minga.RenderModel.UI.EditTimeline.Entry

  describe "%EditTimeline{}" do
    test "defaults to a hidden timeline" do
      timeline = %EditTimeline{}

      refute timeline.visible?
      assert timeline.viewing_index == nil
      assert timeline.entries == []
    end

    test "carries viewing index and entries" do
      entry = %Entry{index: 0, tool_name: "edit_file", timestamp_delta: 0}
      timeline = %EditTimeline{visible?: true, viewing_index: 1, entries: [entry]}

      assert timeline.viewing_index == 1
      assert [%Entry{tool_name: "edit_file"}] = timeline.entries
    end
  end

  describe "%EditTimeline.Entry{}" do
    test "requires index, tool_name, and timestamp_delta" do
      assert_raise ArgumentError, fn -> struct!(Entry, %{index: 0}) end
    end
  end
end
