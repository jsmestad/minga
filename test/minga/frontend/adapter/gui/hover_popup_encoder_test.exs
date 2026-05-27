defmodule Minga.Frontend.Adapter.GUI.HoverPopupEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.HoverPopupEncoder
  alias Minga.RenderModel.UI.HoverPopup

  @op_gui_hover_popup Minga.Protocol.Opcodes.gui_hover_popup()

  describe "encode/2" do
    test "encodes hover popup on first call" do
      model = %HoverPopup{
        encoded: <<@op_gui_hover_popup, 0>>,
        fingerprint: 12_345
      }

      caches = Caches.new()

      {cmd, _caches} = HoverPopupEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %HoverPopup{
        encoded: <<@op_gui_hover_popup, 0>>,
        fingerprint: 12_345
      }

      caches = Caches.new()

      {cmd1, caches} = HoverPopupEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = HoverPopupEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %HoverPopup{
        encoded: <<@op_gui_hover_popup, 0>>,
        fingerprint: 12_345
      }

      model2 = %HoverPopup{
        encoded: <<@op_gui_hover_popup, 1, 0::16, 0::16, 0, 0::16, 0::16>>,
        fingerprint: 99_999
      }

      caches = Caches.new()
      {_, caches} = HoverPopupEncoder.encode(model1, caches)
      {cmd2, _caches} = HoverPopupEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end
  end
end
