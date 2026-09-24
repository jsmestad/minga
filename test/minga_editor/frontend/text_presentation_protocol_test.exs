defmodule MingaEditor.Frontend.TextPresentationProtocolTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.Window
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Mouse.TextEvent

  test "decodes a fixed-width editor text event without screen coordinates" do
    packet =
      <<Opcodes.editor_text_event(), 7::16, 91::unsigned-64, 42::32, 99::unsigned-64, 6::32, 0::8,
        0x09::8, 3::8, 2::8, -1::8-signed, 1::8-signed>>

    assert byte_size(packet) == 33

    assert {:ok,
            {:editor_text_event,
             %TextEvent{
               window_id: 7,
               presentation_id: 91,
               row_index: 42,
               row_id: 99,
               utf16_offset: 6,
               button: :left,
               mods: 0x09,
               event_type: :drag,
               click_count: 2,
               scroll_x: -1,
               scroll_y: 1
             }}} = Protocol.decode_event(packet)
  end

  test "decodes ordered presentation lifecycle states" do
    active = <<Opcodes.text_presentation_state(), 2::16, 55::unsigned-64, 1::8>>
    discarded = <<Opcodes.text_presentation_state(), 2::16, 55::unsigned-64, 0::8>>

    assert byte_size(active) == 12
    assert {:ok, {:text_presentation_state, 2, 55, :active}} = Protocol.decode_event(active)

    assert {:ok, {:text_presentation_state, 2, 55, :discarded}} =
             Protocol.decode_event(discarded)
  end

  test "rejects malformed text event directions and lifecycle values" do
    bad_scroll =
      <<Opcodes.editor_text_event(), 7::16, 91::unsigned-64, 42::32, 99::unsigned-64, 6::32, 0::8,
        0::8, 0::8, 1::8, 2::8-signed, 0::8-signed>>

    bad_lifecycle = <<Opcodes.text_presentation_state(), 2::16, 55::unsigned-64, 2::8>>

    assert {:error, :malformed} = Protocol.decode_event(bad_scroll)
    assert {:error, :malformed} = Protocol.decode_event(bad_lifecycle)
  end

  test "encodes the fixed-width GUI text presentation metadata" do
    window = %Window{
      window_id: 12,
      text_presentation_id: 1234,
      content_kind: :buffer,
      rect: {0, 0, 80, 24},
      rows: [],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block
    }

    encoded = WindowEncoder.encode_text_presentation(window)

    assert byte_size(encoded) == 11
    assert encoded == <<Opcodes.gui_text_presentation(), 12::16, 1234::unsigned-64>>
  end

  test "does not advertise text presentation ids for non-buffer windows" do
    window = %Window{
      window_id: 12,
      text_presentation_id: 0,
      content_kind: :agent_chat,
      rect: {0, 0, 80, 24},
      rows: [],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block
    }

    assert WindowEncoder.encode_text_presentation(window) == nil
  end
end
