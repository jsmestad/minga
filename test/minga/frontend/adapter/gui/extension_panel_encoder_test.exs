defmodule Minga.Frontend.Adapter.GUI.ExtensionPanelEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ExtensionPanelEncoder
  alias Minga.RenderModel.UI.ExtensionPanel

  @op_gui_extension_panel Minga.Protocol.Opcodes.gui_extension_panel()

  describe "encode/2" do
    test "encodes extension panel on first call" do
      model = %ExtensionPanel{
        encoded: <<@op_gui_extension_panel, 1::16, 0>>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd, _caches} = ExtensionPanelEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %ExtensionPanel{
        encoded: <<@op_gui_extension_panel, 1::16, 0>>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd1, caches} = ExtensionPanelEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = ExtensionPanelEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %ExtensionPanel{
        encoded: <<@op_gui_extension_panel, 1::16, 0>>,
        fingerprint: 12345
      }

      model2 = %ExtensionPanel{
        encoded: <<@op_gui_extension_panel, 3::16, 1, "ab">>,
        fingerprint: 99999
      }

      caches = Caches.new()
      {_, caches} = ExtensionPanelEncoder.encode(model1, caches)
      {cmd2, _caches} = ExtensionPanelEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end
  end
end
