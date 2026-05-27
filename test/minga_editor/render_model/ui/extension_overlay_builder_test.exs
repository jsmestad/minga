defmodule MingaEditor.RenderModel.UI.ExtensionOverlayBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.ExtensionOverlayBuilder
  alias Minga.RenderModel.UI.ExtensionOverlay
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  import MingaEditor.RenderPipeline.TestHelpers

  @op_gui_extension_overlay Minga.Protocol.Opcodes.gui_extension_overlay()

  describe "build/1" do
    test "builds extension overlay model with no overlays" do
      ctx = build_minimal_context()

      model = ExtensionOverlayBuilder.build(ctx)

      assert %ExtensionOverlay{} = model
      assert is_binary(model.encoded)
      assert is_integer(model.fingerprint)
      assert <<@op_gui_extension_overlay, _rest::binary>> = model.encoded
    end

    test "produces byte-identical output to legacy for empty overlays" do
      legacy_binary = ProtocolGUI.encode_gui_extension_overlays([])

      ctx = build_minimal_context()
      model = ExtensionOverlayBuilder.build(ctx)

      assert model.encoded == legacy_binary,
             "Empty extension overlay: new builder output does not match legacy output"
    end
  end

  defp build_minimal_context do
    state = gui_state()
    MingaEditor.Frontend.Emit.Context.from_editor_state(state)
  end
end
