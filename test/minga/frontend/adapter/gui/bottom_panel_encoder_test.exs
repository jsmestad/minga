defmodule Minga.Frontend.Adapter.GUI.BottomPanelEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.BottomPanelEncoder
  alias Minga.RenderModel.UI.BottomPanel

  @op_gui_bottom_panel Minga.Protocol.Opcodes.gui_bottom_panel()

  describe "encode/2" do
    test "encodes bottom panel" do
      model = %BottomPanel{
        encoded: <<@op_gui_bottom_panel, 0::8>>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd, _caches} = BottomPanelEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %BottomPanel{
        encoded: <<@op_gui_bottom_panel, 0::8>>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd1, caches} = BottomPanelEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = BottomPanelEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %BottomPanel{
        encoded: <<@op_gui_bottom_panel, 0::8>>,
        fingerprint: 11111
      }

      model2 = %BottomPanel{
        encoded: <<@op_gui_bottom_panel, 1::8, "data">>,
        fingerprint: 22222
      }

      caches = Caches.new()
      {_, caches} = BottomPanelEncoder.encode(model1, caches)
      {cmd2, _caches} = BottomPanelEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end
  end
end
