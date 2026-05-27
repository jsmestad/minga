defmodule Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoder
  alias Minga.RenderModel.UI.ExtensionOverlay

  @op_gui_extension_overlay Minga.Protocol.Opcodes.gui_extension_overlay()

  describe "encode/2" do
    test "encodes extension overlay on first call" do
      model = %ExtensionOverlay{
        encoded: <<@op_gui_extension_overlay, 1::16, 0>>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd, _caches} = ExtensionOverlayEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %ExtensionOverlay{
        encoded: <<@op_gui_extension_overlay, 1::16, 0>>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd1, caches} = ExtensionOverlayEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = ExtensionOverlayEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %ExtensionOverlay{
        encoded: <<@op_gui_extension_overlay, 1::16, 0>>,
        fingerprint: 12345
      }

      model2 = %ExtensionOverlay{
        encoded: <<@op_gui_extension_overlay, 3::16, 1, "ab">>,
        fingerprint: 99999
      }

      caches = Caches.new()
      {_, caches} = ExtensionOverlayEncoder.encode(model1, caches)
      {cmd2, _caches} = ExtensionOverlayEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end
  end
end
