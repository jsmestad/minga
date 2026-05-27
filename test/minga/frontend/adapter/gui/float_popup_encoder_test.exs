defmodule Minga.Frontend.Adapter.GUI.FloatPopupEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.FloatPopupEncoder
  alias Minga.RenderModel.UI.FloatPopup

  @op_gui_float_popup Minga.Protocol.Opcodes.gui_float_popup()

  describe "encode/2" do
    test "encodes float popup on first call" do
      model = %FloatPopup{
        encoded: <<@op_gui_float_popup, 0>>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd, _caches} = FloatPopupEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %FloatPopup{
        encoded: <<@op_gui_float_popup, 0>>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd1, caches} = FloatPopupEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = FloatPopupEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %FloatPopup{
        encoded: <<@op_gui_float_popup, 0>>,
        fingerprint: 12345
      }

      model2 = %FloatPopup{
        encoded: <<@op_gui_float_popup, 1, 40::16, 20::16, 0::16, 0::16>>,
        fingerprint: 99999
      }

      caches = Caches.new()
      {_, caches} = FloatPopupEncoder.encode(model1, caches)
      {cmd2, _caches} = FloatPopupEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end
  end
end
