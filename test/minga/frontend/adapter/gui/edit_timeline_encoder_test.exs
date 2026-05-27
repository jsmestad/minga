defmodule Minga.Frontend.Adapter.GUI.EditTimelineEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EditTimelineEncoder
  alias Minga.RenderModel.UI.EditTimeline

  @op_gui_edit_timeline Minga.Protocol.Opcodes.gui_edit_timeline()

  describe "encode/2" do
    test "encodes hidden edit timeline" do
      model = %EditTimeline{
        encoded: <<@op_gui_edit_timeline, 0::8>>,
        fingerprint: :hidden
      }

      caches = Caches.new()

      {cmd, _caches} = EditTimelineEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %EditTimeline{
        encoded: <<@op_gui_edit_timeline, 0::8>>,
        fingerprint: :hidden
      }

      caches = Caches.new()

      {cmd1, caches} = EditTimelineEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = EditTimelineEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %EditTimeline{
        encoded: <<@op_gui_edit_timeline, 0::8>>,
        fingerprint: :hidden
      }

      model2 = %EditTimeline{
        encoded: <<@op_gui_edit_timeline, 1::8, "data">>,
        fingerprint: 99_999
      }

      caches = Caches.new()
      {_, caches} = EditTimelineEncoder.encode(model1, caches)
      {cmd2, _caches} = EditTimelineEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end
  end
end
