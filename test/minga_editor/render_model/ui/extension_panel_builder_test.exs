defmodule MingaEditor.RenderModel.UI.ExtensionPanelBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.ExtensionPanelBuilder
  alias Minga.RenderModel.UI.ExtensionPanel
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_extension_panel Minga.Protocol.Opcodes.gui_extension_panel()

  describe "build/0" do
    test "builds extension panel model with empty panels" do
      model = ExtensionPanelBuilder.build()

      assert %ExtensionPanel{} = model
      assert is_binary(model.encoded)
      assert is_integer(model.fingerprint)
      assert <<@op_gui_extension_panel, _rest::binary>> = model.encoded
    end

    test "produces byte-identical output to legacy for empty panels" do
      legacy_binary = ProtocolGUI.encode_gui_extension_panels([])

      model = ExtensionPanelBuilder.build()

      assert model.encoded == legacy_binary,
             "Extension panel: new builder output does not match legacy output"
    end
  end
end
