defmodule Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.ExtensionOverlayEncoder
  alias Minga.RenderModel.UI.ExtensionOverlay
  alias Minga.RenderModel.UI.ExtensionOverlay.Entry

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

    test "encodes empty overlay command directly" do
      assert ExtensionOverlayEncoder.encode_command(%ExtensionOverlay{}) ==
               <<@op_gui_extension_overlay, 1::16, 0>>
    end

    test "encodes overlay entry fields directly" do
      model = %ExtensionOverlay{entries: [entry()]}

      assert <<@op_gui_extension_overlay, payload_length::16, payload::binary>> =
               ExtensionOverlayEncoder.encode_command(model)

      assert payload_length == byte_size(payload)

      assert <<1, 4, "demo", 6, "cursor", 7::16, 2::16, 3::16, 1, 0x51, 0xAF, 0xEF, 102, 2::16,
               "AI">> = payload
    end

    test "rejects extension-controlled counts before truncating the command" do
      long_text = String.duplicate("å", 300)

      entries =
        for index <- 1..300,
            do: entry(extension: long_text, overlay_id: "overlay-#{index}-#{long_text}")

      error =
        assert_raise EncodingError, fn ->
          ExtensionOverlayEncoder.encode_command(%ExtensionOverlay{entries: entries})
        end

      assert %{command: :gui_extension_overlay, field: :entry_count, actual: 300} = error
    end

    test "rejects out-of-range numeric overlay fields" do
      error =
        assert_raise EncodingError, fn ->
          ExtensionOverlayEncoder.encode_command(%ExtensionOverlay{
            entries: [
              entry(
                extension: "e",
                overlay_id: "o",
                window_id: 99_999,
                row: 99_999,
                col: 99_999,
                opacity: 999,
                content: "abc"
              )
            ]
          })
        end

      assert %{field: :window_id, actual: 99_999} = error
    end

    test "rejects oversized overlay content" do
      long_content = String.duplicate("a", 70_000)

      error =
        assert_raise EncodingError, fn ->
          ExtensionOverlayEncoder.encode_command(%ExtensionOverlay{
            entries: [
              entry(
                extension: "e",
                overlay_id: "o",
                content: long_content
              )
            ]
          })
        end

      assert %{field: :content_length, actual: 70_000} = error
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
