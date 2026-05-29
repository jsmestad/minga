defmodule MingaEditor.RenderModel.UI.HoverPopupBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.HoverPopup
  alias Minga.RenderModel.UI.HoverPopup.Line
  alias Minga.RenderModel.UI.HoverPopup.Segment
  alias MingaEditor.RenderModel.UI.HoverPopupBuilder

  import MingaEditor.RenderPipeline.TestHelpers

  describe "build/1" do
    test "builds hidden hover popup when shell_state has no hover_popup" do
      ctx = build_minimal_context(%{})

      model = HoverPopupBuilder.build(ctx)

      assert %HoverPopup{} = model
      refute model.visible?
      assert model.content_lines == []
    end

    test "builds hidden hover popup when hover_popup key is absent" do
      ctx = build_minimal_context(%{some_other_key: true})

      model = HoverPopupBuilder.build(ctx)

      refute model.visible?
      assert model.content_lines == []
    end

    test "builds semantic hover popup data" do
      popup = %MingaEditor.HoverPopup{
        content_lines: [{[{"hello", :plain}], :text}],
        anchor_row: 5,
        anchor_col: 10,
        focused: true,
        scroll_offset: 3,
        open_action: :open_docs
      }

      ctx = build_minimal_context(%{hover_popup: popup})

      model = HoverPopupBuilder.build(ctx)

      assert %HoverPopup{} = model
      assert model.visible?
      assert model.anchor_row == 5
      assert model.anchor_col == 10
      assert model.focused?
      assert model.scroll_offset == 3
      assert model.open_action_name == "open_docs"

      assert [%Line{segments: [%Segment{text: "hello", style: :plain}], line_type: :text}] =
               model.content_lines
    end

    test "empty hover content builds hidden model" do
      popup = %MingaEditor.HoverPopup{content_lines: [], anchor_row: 5, anchor_col: 10}
      ctx = build_minimal_context(%{hover_popup: popup})

      model = HoverPopupBuilder.build(ctx)

      refute model.visible?
    end
  end

  defp build_minimal_context(shell_state) do
    state = gui_state()
    ctx = MingaEditor.Frontend.Emit.Context.from_editor_state(state)
    %{ctx | shell_state: shell_state}
  end
end
