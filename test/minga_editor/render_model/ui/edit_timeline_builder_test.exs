defmodule MingaEditor.RenderModel.UI.EditTimelineBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.EditTimelineBuilder
  alias Minga.RenderModel.UI.EditTimeline
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  describe "build/1" do
    test "builds hidden edit timeline when no agent_ui" do
      ctx = %{}

      model = EditTimelineBuilder.build(ctx)

      assert %EditTimeline{fingerprint: :hidden} = model
      assert is_binary(model.encoded)
    end

    test "builds hidden edit timeline when no active buffer" do
      ctx = %{
        agent_ui: %{view: %{edit_timeline: nil}},
        buffers: %{active: nil}
      }

      model = EditTimelineBuilder.build(ctx)

      assert %EditTimeline{fingerprint: :hidden} = model
    end

    test "produces byte-identical output to legacy for hidden state" do
      legacy_binary = ProtocolGUI.encode_gui_edit_timeline(false, nil, [])

      model = EditTimelineBuilder.build(%{})

      assert model.encoded == legacy_binary,
             "Hidden edit timeline: new builder output does not match legacy output"
    end
  end
end
