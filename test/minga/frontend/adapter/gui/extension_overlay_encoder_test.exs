defmodule Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoder
  alias Minga.RenderModel.UI.ExtensionOverlay
  alias Minga.RenderModel.UI.ExtensionOverlay.Entry
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_extension_overlay Minga.Protocol.Opcodes.gui_extension_overlay()

  describe "encode/2" do
    test "encodes empty extension overlay" do
      model = %ExtensionOverlay{}
      caches = Caches.new()

      {cmd, _caches} = ExtensionOverlayEncoder.encode(model, caches)

      assert cmd == <<@op_gui_extension_overlay, 1::16, 0>>
    end

    test "returns nil on second call with same fingerprint" do
      model = %ExtensionOverlay{}
      caches = Caches.new()

      {cmd1, caches} = ExtensionOverlayEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = ExtensionOverlayEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when semantic entries change" do
      model1 = %ExtensionOverlay{}
      model2 = %ExtensionOverlay{entries: [entry()]}

      caches = Caches.new()
      {_, caches} = ExtensionOverlayEncoder.encode(model1, caches)
      {cmd2, _caches} = ExtensionOverlayEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == ExtensionOverlayEncoder.encode_command(model2)
    end

    test "produces byte-identical output to legacy ProtocolGUI for empty overlays" do
      assert ExtensionOverlayEncoder.encode_command(%ExtensionOverlay{}) ==
               ProtocolGUI.encode_gui_extension_overlays([])
    end

    test "produces byte-identical output to legacy ProtocolGUI for overlay entries" do
      model = %ExtensionOverlay{entries: [entry()]}

      legacy_entries = [
        %{
          extension: "demo",
          overlay_id: "cursor",
          window_id: 7,
          row: 2,
          col: 3,
          shape: ProtocolGUI.overlay_shape_byte(:cursor_with_label),
          fg: 0x51AFEF,
          opacity: 102,
          content: "AI"
        }
      ]

      assert ExtensionOverlayEncoder.encode_command(model) ==
               ProtocolGUI.encode_gui_extension_overlays(legacy_entries)
    end
  end

  defp entry do
    %Entry{
      extension: "demo",
      overlay_id: "cursor",
      window_id: 7,
      row: 2,
      col: 3,
      shape: :cursor_with_label,
      fg: 0x51AFEF,
      opacity: 102,
      content: "AI"
    }
  end
end
