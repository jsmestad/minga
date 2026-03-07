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
    test "decodes a short ready event (backward compat)" do
      payload = <<0x03, 80::16, 24::16>>
      assert {:ok, {:ready, 80, 24}} = Protocol.decode_event(payload)
    end

    test "decodes an extended ready event with capabilities" do
      # caps_version=1, caps_len=6, frontend_type=0(tui), color_depth=2(rgb),
      # unicode_width=1(unicode_15), image_support=1(kitty), float_support=0(emulated),
      # text_rendering=0(monospace)
      payload = <<0x03, 120::16, 40::16, 1, 6, 0, 2, 1, 1, 0, 0>>

      assert {:ok, {:ready, 120, 40, caps}} = Protocol.decode_event(payload)
      assert caps.frontend_type == :tui
      assert caps.color_depth == :rgb
      assert caps.unicode_width == :unicode_15
      assert caps.image_support == :kitty
      assert caps.float_support == :emulated
      assert caps.text_rendering == :monospace
    end

    test "decodes an extended ready with native GUI capabilities" do
      payload = <<0x03, 200::16, 60::16, 1, 6, 1, 2, 1, 3, 1, 1>>

      assert {:ok, {:ready, 200, 60, caps}} = Protocol.decode_event(payload)
      assert caps.frontend_type == :native_gui
      assert caps.image_support == :native
      assert caps.float_support == :native
      assert caps.text_rendering == :proportional
    end
  end

  describe "decode_event/1 — capabilities_updated" do
    test "decodes a capabilities_updated event" do
      payload = <<0x05, 1, 6, 0, 2, 1, 1, 0, 0>>

      assert {:ok, {:capabilities_updated, caps}} = Protocol.decode_event(payload)
      assert caps.frontend_type == :tui
      assert caps.color_depth == :rgb
      assert caps.unicode_width == :unicode_15
      assert caps.image_support == :kitty
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

    test "set_cursor_shape has correct byte layout" do
      assert <<0x15, 0x00>> = Protocol.encode_cursor_shape(:block)
      assert <<0x15, 0x01>> = Protocol.encode_cursor_shape(:beam)
      assert <<0x15, 0x02>> = Protocol.encode_cursor_shape(:underline)
    end
  end

  # ── Mouse event encoding/decoding ──

  describe "decode_event/1 — mouse_event" do
    test "decodes left click press" do
      # opcode 0x04, row=5, col=10, button=left(0x00), mods=0, type=press(0x00)
      payload = <<0x04, 5::16-signed, 10::16-signed, 0x00, 0x00, 0x00>>
      assert {:ok, {:mouse_event, 5, 10, :left, 0, :press}} = Protocol.decode_event(payload)
    end

    test "decodes wheel_up press" do
      payload = <<0x04, 0::16-signed, 0::16-signed, 0x40, 0x00, 0x00>>
      assert {:ok, {:mouse_event, 0, 0, :wheel_up, 0, :press}} = Protocol.decode_event(payload)
    end

    test "decodes wheel_down press" do
      payload = <<0x04, 3::16-signed, 7::16-signed, 0x41, 0x00, 0x00>>
      assert {:ok, {:mouse_event, 3, 7, :wheel_down, 0, :press}} = Protocol.decode_event(payload)
    end

    test "decodes drag event" do
      payload = <<0x04, 8::16-signed, 15::16-signed, 0x00, 0x00, 0x03>>
      assert {:ok, {:mouse_event, 8, 15, :left, 0, :drag}} = Protocol.decode_event(payload)
    end

    test "decodes release event" do
      payload = <<0x04, 8::16-signed, 15::16-signed, 0x00, 0x00, 0x01>>
      assert {:ok, {:mouse_event, 8, 15, :left, 0, :release}} = Protocol.decode_event(payload)
    end

    test "decodes mouse event with modifier flags" do
      mods = Bitwise.bor(Protocol.mod_ctrl(), Protocol.mod_shift())
      payload = <<0x04, 2::16-signed, 4::16-signed, 0x00, mods::8, 0x00>>
      assert {:ok, {:mouse_event, 2, 4, :left, ^mods, :press}} = Protocol.decode_event(payload)
    end

    test "decodes mouse event with negative row/col (signed)" do
      payload = <<0x04, -1::16-signed, -5::16-signed, 0x00, 0x00, 0x00>>
      assert {:ok, {:mouse_event, -1, -5, :left, 0, :press}} = Protocol.decode_event(payload)
    end

    test "decodes right click" do
      payload = <<0x04, 1::16-signed, 1::16-signed, 0x02, 0x00, 0x00>>
      assert {:ok, {:mouse_event, 1, 1, :right, 0, :press}} = Protocol.decode_event(payload)
    end

    test "decodes middle click" do
      payload = <<0x04, 1::16-signed, 1::16-signed, 0x01, 0x00, 0x00>>
      assert {:ok, {:mouse_event, 1, 1, :middle, 0, :press}} = Protocol.decode_event(payload)
    end

    test "unknown button value returns {:unknown, value}" do
      payload = <<0x04, 0::16-signed, 0::16-signed, 0xFF, 0x00, 0x00>>

      assert {:ok, {:mouse_event, 0, 0, {:unknown, 0xFF}, 0, :press}} =
               Protocol.decode_event(payload)
    end

    test "unknown event type returns {:unknown, value}" do
      payload = <<0x04, 0::16-signed, 0::16-signed, 0x00, 0x00, 0xFF>>

      assert {:ok, {:mouse_event, 0, 0, :left, 0, {:unknown, 0xFF}}} =
               Protocol.decode_event(payload)
    end

    test "truncated mouse_event returns malformed" do
      # Too short — missing event_type
      assert {:error, :malformed} =
               Protocol.decode_event(<<0x04, 0::16-signed, 0::16-signed, 0x00, 0x00>>)
    end

    test "mouse_event has correct byte layout" do
      payload = <<0x04, 0::16-signed, 5::16-signed, 0x40, 0x02, 0x00>>
      assert {:ok, {:mouse_event, 0, 5, :wheel_up, 0x02, :press}} = Protocol.decode_event(payload)
    end
  end

  describe "cursor shape round-trip" do
    test "encode/decode block cursor" do
      encoded = Protocol.encode_cursor_shape(:block)
      assert {:ok, {:set_cursor_shape, :block}} = Protocol.decode_command(encoded)
    end

    test "encode/decode beam cursor" do
      encoded = Protocol.encode_cursor_shape(:beam)
      assert {:ok, {:set_cursor_shape, :beam}} = Protocol.decode_command(encoded)
    end

    test "encode/decode underline cursor" do
      encoded = Protocol.encode_cursor_shape(:underline)
      assert {:ok, {:set_cursor_shape, :underline}} = Protocol.decode_command(encoded)
    end
  end

  describe "set_title protocol" do
    test "encode/decode round-trip" do
      encoded = Protocol.encode_set_title("editor.ex [+] (lib) - Minga")
      assert {:ok, {:set_title, "editor.ex [+] (lib) - Minga"}} = Protocol.decode_command(encoded)
    end

    test "encode/decode empty title" do
      encoded = Protocol.encode_set_title("")
      assert {:ok, {:set_title, ""}} = Protocol.decode_command(encoded)
    end

    test "encode/decode unicode title" do
      encoded = Protocol.encode_set_title("файл.ex - Minga")
      assert {:ok, {:set_title, "файл.ex - Minga"}} = Protocol.decode_command(encoded)
    end
  end

  describe "highlight protocol" do
    test "encode_set_language produces correct binary" do
      encoded = Protocol.encode_set_language("elixir")
      assert <<0x20, 6::16, rest::binary>> = encoded
      assert rest == "elixir"
    end

    test "encode_parse_buffer produces correct binary" do
      encoded = Protocol.encode_parse_buffer(42, "hello")
      assert <<0x21, 42::32, 5::32, rest::binary>> = encoded
      assert rest == "hello"
    end

    test "encode_set_highlight_query produces correct binary" do
      query = "(atom) @string"
      encoded = Protocol.encode_set_highlight_query(query)
      qlen = byte_size(query)
      assert <<0x22, ^qlen::32, rest::binary>> = encoded
      assert rest == query
    end

    test "encode_set_injection_query produces correct binary" do
      query = "(content) @injection.content"
      encoded = Protocol.encode_set_injection_query(query)
      qlen = byte_size(query)
      assert <<0x24, ^qlen::32, rest::binary>> = encoded
      assert rest == query
    end

    test "encode_load_grammar produces correct binary" do
      encoded = Protocol.encode_load_grammar("lua", "/tmp/lua.so")
      assert <<0x23, 3::16, "lua", 11::16, rest::binary>> = encoded
      assert rest == "/tmp/lua.so"
    end

    test "decode_event highlight_spans" do
      spans_binary =
        <<0::32, 9::32, 0::16>> <>
          <<10::32, 15::32, 1::16>>

      payload = <<0x30, 42::32, 2::32>> <> spans_binary

      assert {:ok, {:highlight_spans, 42, spans}} = Protocol.decode_event(payload)
      assert length(spans) == 2
      assert hd(spans) == %{start_byte: 0, end_byte: 9, capture_id: 0}
      assert List.last(spans) == %{start_byte: 10, end_byte: 15, capture_id: 1}
    end

    test "decode_event highlight_names" do
      payload = <<0x31, 2::16, 7::16, "keyword", 6::16, "string">>

      assert {:ok, {:highlight_names, ["keyword", "string"]}} = Protocol.decode_event(payload)
    end

    test "decode_event grammar_loaded success" do
      payload = <<0x32, 1, 6::16, "elixir">>
      assert {:ok, {:grammar_loaded, true, "elixir"}} = Protocol.decode_event(payload)
    end

    test "decode_event grammar_loaded failure" do
      payload = <<0x32, 0, 3::16, "lua">>
      assert {:ok, {:grammar_loaded, false, "lua"}} = Protocol.decode_event(payload)
    end

    test "decode_event highlight_spans with zero spans" do
      payload = <<0x30, 1::32, 0::32>>
      assert {:ok, {:highlight_spans, 1, []}} = Protocol.decode_event(payload)
    end

    test "decode_event highlight_names with zero names" do
      payload = <<0x31, 0::16>>
      assert {:ok, {:highlight_names, []}} = Protocol.decode_event(payload)
    end

    test "decode_event malformed highlight_spans" do
      # Count says 2 spans but only 1 provided
      payload = <<0x30, 1::32, 2::32, 0::32, 9::32, 0::16>>
      assert {:error, :malformed} = Protocol.decode_event(payload)
    end
  end

  describe "log_message protocol" do
    test "decode_event log_message with err level" do
      payload = <<0x60, 0, 10::16, "test error">>
      assert {:ok, {:log_message, "ERR", "test error"}} = Protocol.decode_event(payload)
    end

    test "decode_event log_message with warn level" do
      payload = <<0x60, 1, 12::16, "test warning">>
      assert {:ok, {:log_message, "WARN", "test warning"}} = Protocol.decode_event(payload)
    end

    test "decode_event log_message with info level" do
      payload = <<0x60, 2, 9::16, "test info">>
      assert {:ok, {:log_message, "INFO", "test info"}} = Protocol.decode_event(payload)
    end

    test "decode_event log_message with debug level" do
      payload = <<0x60, 3, 10::16, "test debug">>
      assert {:ok, {:log_message, "DEBUG", "test debug"}} = Protocol.decode_event(payload)
    end

    test "decode_event log_message with unknown level" do
      payload = <<0x60, 99, 4::16, "test">>
      assert {:ok, {:log_message, "UNKNOWN", "test"}} = Protocol.decode_event(payload)
    end

    test "decode_event log_message with empty message" do
      payload = <<0x60, 2, 0::16>>
      assert {:ok, {:log_message, "INFO", ""}} = Protocol.decode_event(payload)
    end

    test "decode_event log_message with unicode text" do
      text = "Zig says: Ü"
      payload = <<0x60, 2, byte_size(text)::16, text::binary>>
      assert {:ok, {:log_message, "INFO", ^text}} = Protocol.decode_event(payload)
    end
  end
end
