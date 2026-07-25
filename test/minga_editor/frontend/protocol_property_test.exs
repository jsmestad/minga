defmodule MingaEditor.Frontend.ProtocolPropertyTest do
  @moduledoc """
  Property-based tests for the Port protocol encoder/decoder.

  Verifies that decode_event produces valid structures for all
  generated binary inputs, and that encode functions produce
  valid binary output.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaEditor.Frontend.Protocol

  import Minga.Test.Generators

  # ── Decode produces valid structures ────────────────────────────────────

  property "decode_event produces valid key_press for any codepoint and modifiers" do
    check all(event <- key_press_event()) do
      assert {:ok, {:key_press, codepoint, modifiers, seq}} = Protocol.decode_event(event)
      assert is_integer(codepoint) and codepoint > 0
      assert is_integer(modifiers) and modifiers >= 0
      assert is_integer(seq) and seq >= 0
    end
  end

  property "decode_event produces valid resize for any dimensions" do
    check all(event <- resize_event()) do
      assert {:ok, {:resize, width, height}} = Protocol.decode_event(event)
      assert is_integer(width) and width > 0
      assert is_integer(height) and height > 0
    end
  end

  property "decode_event produces valid ready for any dimensions" do
    check all(event <- ready_event()) do
      assert {:ok, {:ready, width, height, caps, version}} = Protocol.decode_event(event)
      assert is_integer(width) and width > 0
      assert is_integer(height) and height > 0
      assert caps.resource_policy.max_frame_bytes == 64 * 1024 * 1024
      assert version == Minga.Protocol.Opcodes.protocol_version()
    end
  end

  property "decode_event produces valid paste_event for any text" do
    check all(event <- paste_event()) do
      assert {:ok, {:paste_event, text}} = Protocol.decode_event(event)
      assert is_binary(text)
    end
  end

  # ── Encode produces valid binary ───────────────────────────────────────

  property "encode_protocol_error produces a len16-framed binary for any message" do
    check all(message <- string(:utf8, min_length: 0, max_length: 200)) do
      result = Protocol.encode_protocol_error(message)
      len = byte_size(message)
      assert <<0x18, ^len::16, ^message::binary>> = result
    end
  end

  property "encode_set_title produces valid binary for any title" do
    check all(title <- string(:ascii, min_length: 0, max_length: 100)) do
      result = Protocol.encode_set_title(title)
      assert is_binary(result)
      assert <<0x16, _rest::binary>> = result
    end
  end

  property "encode_set_window_bg produces valid binary for any RGB" do
    check all(rgb <- integer(0..0xFFFFFF)) do
      result = Protocol.encode_set_window_bg(rgb)
      assert <<0x17, ^rgb::24>> = result
    end
  end
end
