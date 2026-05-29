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

    test "bounds extension-controlled counts and 8-bit strings" do
      long_text = String.duplicate("å", 300)

      entries =
        for index <- 1..300,
            do: entry(extension: long_text, overlay_id: "overlay-#{index}-#{long_text}")

      command = ExtensionOverlayEncoder.encode_command(%ExtensionOverlay{entries: entries})

      <<@op_gui_extension_overlay, payload_len::16, payload::binary-size(payload_len)>> = command
      <<entry_count::8, first_entry::binary>> = payload

      <<ext_len::8, ext::binary-size(ext_len), overlay_id_len::8,
        overlay_id::binary-size(overlay_id_len), _rest::binary>> = first_entry

      assert entry_count <= 255
      assert ext_len <= 255
      assert overlay_id_len <= 255
      assert String.valid?(ext)
      assert String.valid?(overlay_id)
    end
  end

  defp entry(opts \\ []) do
    %Entry{
      extension: Keyword.get(opts, :extension, "demo"),
      overlay_id: Keyword.get(opts, :overlay_id, "cursor"),
      window_id: Keyword.get(opts, :window_id, 7),
      row: Keyword.get(opts, :row, 2),
      col: Keyword.get(opts, :col, 3),
      shape: Keyword.get(opts, :shape, :cursor_with_label),
      fg: Keyword.get(opts, :fg, 0x51AFEF),
      opacity: Keyword.get(opts, :opacity, 102),
      content: Keyword.get(opts, :content, "AI")
    }
  end
end
