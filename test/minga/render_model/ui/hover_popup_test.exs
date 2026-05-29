defmodule Minga.RenderModel.UI.HoverPopupTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.HoverPopup
  alias Minga.RenderModel.UI.HoverPopup.Line
  alias Minga.RenderModel.UI.HoverPopup.Segment

  describe "%HoverPopup{}" do
    test "defaults to hidden" do
      model = %HoverPopup{}

      refute model.visible?
      assert model.anchor_row == 0
      assert model.anchor_col == 0
      refute model.focused?
      assert model.scroll_offset == 0
      assert model.content_lines == []
      assert model.open_action_name == nil
    end

    test "stores semantic markdown lines" do
      model = %HoverPopup{
        visible?: true,
        anchor_row: 5,
        anchor_col: 10,
        focused?: true,
        scroll_offset: 3,
        content_lines: [
          %Line{segments: [%Segment{text: "hello", style: :bold}], line_type: :text}
        ],
        open_action_name: "goto_location"
      }

      assert model.visible?
      assert model.focused?
      assert [%Line{segments: [%Segment{text: "hello", style: :bold}]}] = model.content_lines
      assert model.open_action_name == "goto_location"
    end
  end
end
