defmodule Minga.Port.ProtocolTest do
  use ExUnit.Case, async: true

  alias Minga.Port.Protocol

  # ── Modifier helpers ──

  describe "modifier flags" do
    test "individual modifier values" do
      assert Protocol.mod_shift() == 0x01
      assert Protocol.mod_ctrl() == 0x02
      assert Protocol.mod_alt() == 0x04
      assert Protocol.mod_super() == 0x08
    end

    test "has_modifier? checks flag bits" do
      mods = Bitwise.bor(Protocol.mod_ctrl(), Protocol.mod_shift())
      assert Protocol.has_modifier?(mods, Protocol.mod_ctrl())
      assert Protocol.has_modifier?(mods, Protocol.mod_shift())
      refute Protocol.has_modifier?(mods, Protocol.mod_alt())
      refute Protocol.has_modifier?(mods, Protocol.mod_super())
    end

    test "has_modifier? with zero modifiers" do
      refute Protocol.has_modifier?(0, Protocol.mod_ctrl())
    end
  end

  # ── Input event encoding/decoding round-trips ──

  describe "decode_event/1 — key_press" do
    test "decodes a simple key press" do
      # 'a' = 97, no modifiers
      payload = <<0x01, 97::32, 0::8>>
      assert {:ok, {:key_press, 97, 0}} = Protocol.decode_event(payload)
    end

    test "decodes key press with modifiers" do
      mods = Bitwise.bor(Protocol.mod_ctrl(), Protocol.mod_shift())
      payload = <<0x01, 99::32, mods::8>>
      assert {:ok, {:key_press, 99, ^mods}} = Protocol.decode_event(payload)
    end

    test "decodes unicode codepoint" do
      # 🥨 = U+1F968 = 129384
      codepoint = 0x1F968
      payload = <<0x01, codepoint::32, 0::8>>
      assert {:ok, {:key_press, ^codepoint, 0}} = Protocol.decode_event(payload)
    end

    test "decodes special keys (escape = 27)" do
      payload = <<0x01, 27::32, 0::8>>
      assert {:ok, {:key_press, 27, 0}} = Protocol.decode_event(payload)
    end
  end

  describe "decode_event/1 — resize" do
    test "decodes a resize event" do
      payload = <<0x02, 120::16, 40::16>>
      assert {:ok, {:resize, 120, 40}} = Protocol.decode_event(payload)
    end

    test "decodes large terminal size" do
      payload = <<0x02, 400::16, 200::16>>
      assert {:ok, {:resize, 400, 200}} = Protocol.decode_event(payload)
    end
  end

  describe "decode_event/1 — ready" do
    test "decodes a ready event" do
      payload = <<0x03, 80::16, 24::16>>
      assert {:ok, {:ready, 80, 24}} = Protocol.decode_event(payload)
    end
  end

  describe "decode_event/1 — errors" do
    test "returns error for unknown opcode" do
      assert {:error, :unknown_opcode} = Protocol.decode_event(<<0xFF, 0, 0, 0>>)
    end

    test "returns error for malformed key_press (too short)" do
      assert {:error, :malformed} = Protocol.decode_event(<<0x01, 97::32>>)
    end

    test "returns error for empty payload" do
      assert {:error, :malformed} = Protocol.decode_event(<<>>)
    end
  end

  # ── Render command encoding ──

  describe "encode_draw/4" do
    test "encodes draw_text with default style" do
      encoded = Protocol.encode_draw(5, 10, "hello")

      assert {:ok,
              {:draw_text,
               %{row: 5, col: 10, fg: 0xFFFFFF, bg: 0x000000, attrs: [], text: "hello"}}} =
               Protocol.decode_command(encoded)
    end

    test "encodes draw_text with custom colors" do
      encoded = Protocol.encode_draw(0, 0, "hi", fg: 0xFF0000, bg: 0x00FF00)

      assert {:ok, {:draw_text, %{fg: 0xFF0000, bg: 0x00FF00, text: "hi"}}} =
               Protocol.decode_command(encoded)
    end

    test "encodes draw_text with style attributes" do
      encoded = Protocol.encode_draw(0, 0, "bold", bold: true, italic: true)

      assert {:ok, {:draw_text, %{attrs: [:bold, :italic], text: "bold"}}} =
               Protocol.decode_command(encoded)
    end

    test "encodes draw_text with all attributes" do
      encoded =
        Protocol.encode_draw(0, 0, "all",
          bold: true,
          underline: true,
          italic: true,
          reverse: true
        )

      assert {:ok, {:draw_text, %{attrs: [:bold, :underline, :italic, :reverse]}}} =
               Protocol.decode_command(encoded)
    end

    test "encodes unicode text" do
      encoded = Protocol.encode_draw(0, 0, "🥨 München")

      assert {:ok, {:draw_text, %{text: "🥨 München"}}} =
               Protocol.decode_command(encoded)
    end

    test "encodes empty text" do
      encoded = Protocol.encode_draw(0, 0, "")
      assert {:ok, {:draw_text, %{text: ""}}} = Protocol.decode_command(encoded)
    end
  end

  describe "encode_cursor/2" do
    test "encodes set_cursor" do
      encoded = Protocol.encode_cursor(10, 25)
      assert {:ok, {:set_cursor, 10, 25}} = Protocol.decode_command(encoded)
    end

    test "encodes cursor at origin" do
      encoded = Protocol.encode_cursor(0, 0)
      assert {:ok, {:set_cursor, 0, 0}} = Protocol.decode_command(encoded)
    end
  end

  describe "encode_clear/0" do
    test "encodes clear" do
      encoded = Protocol.encode_clear()
      assert {:ok, :clear} = Protocol.decode_command(encoded)
    end
  end

  describe "encode_batch_end/0" do
    test "encodes batch_end" do
      encoded = Protocol.encode_batch_end()
      assert {:ok, :batch_end} = Protocol.decode_command(encoded)
    end
  end

  describe "decode_command/1 — errors" do
    test "returns error for unknown command opcode" do
      assert {:error, :unknown_opcode} = Protocol.decode_command(<<0xFE>>)
    end

    test "returns error for empty binary" do
      assert {:error, :malformed} = Protocol.decode_command(<<>>)
    end
  end

  # ── Binary format verification ──

  describe "binary format" do
    test "draw_text has correct byte layout" do
      encoded = Protocol.encode_draw(1, 2, "ab", fg: 0xAABBCC, bg: 0x112233, bold: true)

      assert <<0x10, 1::16, 2::16, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33, 0x01, 2::16, "ab">> =
               encoded
    end

    test "set_cursor has correct byte layout" do
      assert <<0x11, 0::16, 5::16>> = Protocol.encode_cursor(0, 5)
    end

    test "clear is a single byte" do
      assert <<0x12>> = Protocol.encode_clear()
    end

    test "batch_end is a single byte" do
      assert <<0x13>> = Protocol.encode_batch_end()
    end

    test "key_press event has correct byte layout" do
      payload = <<0x01, 65::32, 0x03::8>>
      assert {:ok, {:key_press, 65, 3}} = Protocol.decode_event(payload)
    end
  end
end
