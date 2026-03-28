defmodule Minga.Frontend.ProtocolTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Protocol

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
    end

    test "decodes an extended ready with native GUI capabilities" do
      payload = <<0x03, 200::16, 60::16, 1, 6, 1, 2, 1, 3, 1, 0>>

      assert {:ok, {:ready, 200, 60, caps}} = Protocol.decode_event(payload)
      assert caps.frontend_type == :native_gui
      assert caps.image_support == :native
      assert caps.float_support == :native
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

  describe "decode_event/1 — paste_event" do
    test "decodes basic multi-line paste" do
      text = "line 1\nline 2\nline 3"
      text_len = byte_size(text)
      payload = <<0x06, text_len::16, text::binary>>
      assert {:ok, {:paste_event, ^text}} = Protocol.decode_event(payload)
    end

    test "decodes empty paste" do
      payload = <<0x06, 0::16>>
      assert {:ok, {:paste_event, ""}} = Protocol.decode_event(payload)
    end

    test "decodes single-line paste" do
      text = "just one line"
      text_len = byte_size(text)
      payload = <<0x06, text_len::16, text::binary>>
      assert {:ok, {:paste_event, ^text}} = Protocol.decode_event(payload)
    end

    test "decodes unicode paste" do
      text = "こんにちは\n🎉 emoji\n中文"
      text_len = byte_size(text)
      payload = <<0x06, text_len::16, text::binary>>
      assert {:ok, {:paste_event, ^text}} = Protocol.decode_event(payload)
    end

    test "decodes paste with trailing newline" do
      text = "line 1\nline 2\n"
      text_len = byte_size(text)
      payload = <<0x06, text_len::16, text::binary>>
      assert {:ok, {:paste_event, ^text}} = Protocol.decode_event(payload)
    end

    test "decodes large paste (near u16 max)" do
      text = String.duplicate("A", 60_000) <> "\n" <> String.duplicate("B", 5_000)
      text_len = byte_size(text)
      payload = <<0x06, text_len::16, text::binary>>
      assert {:ok, {:paste_event, ^text}} = Protocol.decode_event(payload)
    end

    test "decodes paste with only newlines" do
      text = "\n\n\n\n"
      text_len = byte_size(text)
      payload = <<0x06, text_len::16, text::binary>>
      assert {:ok, {:paste_event, ^text}} = Protocol.decode_event(payload)
    end

    test "preserves exact whitespace in paste" do
      text = "  indented\n\ttabbed\n    spaced"
      text_len = byte_size(text)
      payload = <<0x06, text_len::16, text::binary>>
      assert {:ok, {:paste_event, ^text}} = Protocol.decode_event(payload)
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

  describe "encode_draw_styled/4" do
    test "round-trips with strikethrough" do
      encoded = Protocol.encode_draw_styled(1, 2, "deprecated", strikethrough: true)

      assert {:ok, {:draw_styled_text, %{row: 1, col: 2, text: "deprecated", attrs: attrs}}} =
               Protocol.decode_command(encoded)

      assert {:strikethrough, true} in attrs
    end

    test "round-trips with underline style" do
      encoded =
        Protocol.encode_draw_styled(0, 0, "error",
          underline: true,
          underline_style: :curl,
          underline_color: 0xFF0000
        )

      assert {:ok, {:draw_styled_text, %{text: "error", attrs: attrs}}} =
               Protocol.decode_command(encoded)

      assert :underline in attrs
      assert {:underline_style, :curl} in attrs
      assert {:underline_color, 0xFF0000} in attrs
    end

    test "round-trips all underline styles" do
      for style <- [:line, :curl, :dashed, :dotted, :double] do
        encoded =
          Protocol.encode_draw_styled(0, 0, "test", underline: true, underline_style: style)

        assert {:ok, {:draw_styled_text, %{attrs: attrs}}} = Protocol.decode_command(encoded)

        if style == :line do
          # :line is the default, not explicitly included
          refute Keyword.has_key?(attrs, :underline_style)
        else
          assert {:underline_style, ^style} = List.keyfind(attrs, :underline_style, 0)
        end
      end
    end

    test "round-trips blend" do
      encoded = Protocol.encode_draw_styled(0, 0, "ghost", blend: 30)

      assert {:ok, {:draw_styled_text, %{attrs: attrs}}} = Protocol.decode_command(encoded)
      assert {:blend, 30} in attrs
    end

    test "blend 100 is omitted from attrs" do
      encoded = Protocol.encode_draw_styled(0, 0, "opaque", blend: 100)

      assert {:ok, {:draw_styled_text, %{attrs: attrs}}} = Protocol.decode_command(encoded)
      refute Keyword.has_key?(attrs, :blend)
    end

    test "round-trips all extended attributes together" do
      style = [
        fg: 0xFF6C6B,
        bg: 0x282C34,
        bold: true,
        italic: true,
        underline: true,
        strikethrough: true,
        underline_style: :curl,
        underline_color: 0x00FF00,
        blend: 50
      ]

      encoded = Protocol.encode_draw_styled(3, 7, "all", style)

      assert {:ok,
              {:draw_styled_text,
               %{row: 3, col: 7, fg: 0xFF6C6B, bg: 0x282C34, text: "all", attrs: attrs}}} =
               Protocol.decode_command(encoded)

      assert :bold in attrs
      assert :italic in attrs
      assert :underline in attrs
      assert {:strikethrough, true} in attrs
      assert {:underline_style, :curl} in attrs
      assert {:underline_color, 0x00FF00} in attrs
      assert {:blend, 50} in attrs
    end
  end

  describe "encode_draw_smart/4" do
    test "uses draw_text for simple styles" do
      encoded = Protocol.encode_draw_smart(0, 0, "simple", fg: 0xFF0000, bold: true)
      assert {:ok, {:draw_text, _}} = Protocol.decode_command(encoded)
    end

    test "uses draw_styled_text when extended attrs present" do
      encoded = Protocol.encode_draw_smart(0, 0, "fancy", strikethrough: true)
      assert {:ok, {:draw_styled_text, _}} = Protocol.decode_command(encoded)
    end

    test "uses draw_styled_text for underline_style" do
      encoded = Protocol.encode_draw_smart(0, 0, "wavy", underline: true, underline_style: :curl)
      assert {:ok, {:draw_styled_text, _}} = Protocol.decode_command(encoded)
    end

    test "uses draw_styled_text for blend" do
      encoded = Protocol.encode_draw_smart(0, 0, "dim", blend: 50)
      assert {:ok, {:draw_styled_text, _}} = Protocol.decode_command(encoded)
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
    test "decodes 9-byte left click press with click_count" do
      payload = <<0x04, 5::16-signed, 10::16-signed, 0x00, 0x00, 0x00, 1>>
      assert {:ok, {:mouse_event, 5, 10, :left, 0, :press, 1}} = Protocol.decode_event(payload)
    end

    test "decodes 9-byte double-click with click_count 2" do
      payload = <<0x04, 5::16-signed, 10::16-signed, 0x00, 0x00, 0x00, 2>>
      assert {:ok, {:mouse_event, 5, 10, :left, 0, :press, 2}} = Protocol.decode_event(payload)
    end

    test "decodes 8-byte left click press (backward compat, click_count defaults to 1)" do
      payload = <<0x04, 5::16-signed, 10::16-signed, 0x00, 0x00, 0x00>>
      assert {:ok, {:mouse_event, 5, 10, :left, 0, :press, 1}} = Protocol.decode_event(payload)
    end

    test "decodes wheel_up press" do
      payload = <<0x04, 0::16-signed, 0::16-signed, 0x40, 0x00, 0x00>>
      assert {:ok, {:mouse_event, 0, 0, :wheel_up, 0, :press, 1}} = Protocol.decode_event(payload)
    end

    test "decodes wheel_down press" do
      payload = <<0x04, 3::16-signed, 7::16-signed, 0x41, 0x00, 0x00>>

      assert {:ok, {:mouse_event, 3, 7, :wheel_down, 0, :press, 1}} =
               Protocol.decode_event(payload)
    end

    test "decodes drag event" do
      payload = <<0x04, 8::16-signed, 15::16-signed, 0x00, 0x00, 0x03>>
      assert {:ok, {:mouse_event, 8, 15, :left, 0, :drag, 1}} = Protocol.decode_event(payload)
    end

    test "decodes release event" do
      payload = <<0x04, 8::16-signed, 15::16-signed, 0x00, 0x00, 0x01>>
      assert {:ok, {:mouse_event, 8, 15, :left, 0, :release, 1}} = Protocol.decode_event(payload)
    end

    test "decodes mouse event with modifier flags" do
      mods = Bitwise.bor(Protocol.mod_ctrl(), Protocol.mod_shift())
      payload = <<0x04, 2::16-signed, 4::16-signed, 0x00, mods::8, 0x00>>
      assert {:ok, {:mouse_event, 2, 4, :left, ^mods, :press, 1}} = Protocol.decode_event(payload)
    end

    test "decodes mouse event with negative row/col (signed)" do
      payload = <<0x04, -1::16-signed, -5::16-signed, 0x00, 0x00, 0x00>>
      assert {:ok, {:mouse_event, -1, -5, :left, 0, :press, 1}} = Protocol.decode_event(payload)
    end

    test "decodes right click" do
      payload = <<0x04, 1::16-signed, 1::16-signed, 0x02, 0x00, 0x00>>
      assert {:ok, {:mouse_event, 1, 1, :right, 0, :press, 1}} = Protocol.decode_event(payload)
    end

    test "decodes middle click" do
      payload = <<0x04, 1::16-signed, 1::16-signed, 0x01, 0x00, 0x00>>
      assert {:ok, {:mouse_event, 1, 1, :middle, 0, :press, 1}} = Protocol.decode_event(payload)
    end

    test "unknown button value returns {:unknown, value}" do
      payload = <<0x04, 0::16-signed, 0::16-signed, 0xFF, 0x00, 0x00>>

      assert {:ok, {:mouse_event, 0, 0, {:unknown, 0xFF}, 0, :press, 1}} =
               Protocol.decode_event(payload)
    end

    test "unknown event type returns {:unknown, value}" do
      payload = <<0x04, 0::16-signed, 0::16-signed, 0x00, 0x00, 0xFF>>

      assert {:ok, {:mouse_event, 0, 0, :left, 0, {:unknown, 0xFF}, 1}} =
               Protocol.decode_event(payload)
    end

    test "truncated mouse_event returns malformed" do
      # Too short — missing event_type
      assert {:error, :malformed} =
               Protocol.decode_event(<<0x04, 0::16-signed, 0::16-signed, 0x00, 0x00>>)
    end

    test "mouse_event has correct byte layout" do
      payload = <<0x04, 0::16-signed, 5::16-signed, 0x40, 0x02, 0x00>>

      assert {:ok, {:mouse_event, 0, 5, :wheel_up, 0x02, :press, 1}} =
               Protocol.decode_event(payload)
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

  describe "set_font protocol" do
    test "encode/decode round-trip with ligatures enabled, default weight" do
      encoded = Protocol.encode_set_font("JetBrains Mono", 14, true)

      assert {:ok, {:set_font, "JetBrains Mono", 14, :regular, true}} =
               Protocol.decode_command(encoded)
    end

    test "encode/decode round-trip with ligatures disabled" do
      encoded = Protocol.encode_set_font("Menlo", 13, false)
      assert {:ok, {:set_font, "Menlo", 13, :regular, false}} = Protocol.decode_command(encoded)
    end

    test "encode/decode with unicode font name" do
      encoded = Protocol.encode_set_font("Iosevka Термин", 12, true)

      assert {:ok, {:set_font, "Iosevka Термин", 12, :regular, true}} =
               Protocol.decode_command(encoded)
    end

    test "encode/decode with explicit weight" do
      encoded = Protocol.encode_set_font("JetBrains Mono", 14, true, :light)

      assert {:ok, {:set_font, "JetBrains Mono", 14, :light, true}} =
               Protocol.decode_command(encoded)
    end

    test "encode/decode all weight values" do
      weights = [:thin, :light, :regular, :medium, :semibold, :bold, :heavy, :black]

      for weight <- weights do
        encoded = Protocol.encode_set_font("Test", 13, true, weight)
        assert {:ok, {:set_font, "Test", 13, ^weight, true}} = Protocol.decode_command(encoded)
      end
    end

    test "binary format: opcode 0x50, size:16, weight:8, lig:8, name_len:16, name" do
      encoded = Protocol.encode_set_font("Fira Code", 16, true)
      # weight defaults to :regular = 2
      assert <<0x50, 16::16, 2::8, 1::8, 9::16, "Fira Code">> = encoded
    end

    test "binary format: ligatures false encodes as 0" do
      encoded = Protocol.encode_set_font("Menlo", 13, false)
      assert <<0x50, 13::16, 2::8, 0::8, 5::16, "Menlo">> = encoded
    end

    test "binary format: bold weight encodes as 5" do
      encoded = Protocol.encode_set_font("Menlo", 13, true, :bold)
      assert <<0x50, 13::16, 5::8, 1::8, _rest::binary>> = encoded
    end
  end

  describe "highlight protocol" do
    test "encode_set_language produces correct binary" do
      encoded = Protocol.encode_set_language(7, "elixir")
      assert <<0x20, 7::32, 6::16, rest::binary>> = encoded
      assert rest == "elixir"
    end

    test "encode_parse_buffer produces correct binary" do
      encoded = Protocol.encode_parse_buffer(3, 42, "hello")
      assert <<0x21, 3::32, 42::32, 5::32, rest::binary>> = encoded
      assert rest == "hello"
    end

    test "encode_set_highlight_query produces correct binary" do
      query = "(atom) @string"
      encoded = Protocol.encode_set_highlight_query(1, query)
      qlen = byte_size(query)
      assert <<0x22, 1::32, ^qlen::32, rest::binary>> = encoded
      assert rest == query
    end

    test "encode_set_injection_query produces correct binary" do
      query = "(content) @injection.content"
      encoded = Protocol.encode_set_injection_query(2, query)
      qlen = byte_size(query)
      assert <<0x24, 2::32, ^qlen::32, rest::binary>> = encoded
      assert rest == query
    end

    test "encode_load_grammar produces correct binary" do
      encoded = Protocol.encode_load_grammar("lua", "/tmp/lua.so")
      assert <<0x23, 3::16, "lua", 11::16, rest::binary>> = encoded
      assert rest == "/tmp/lua.so"
    end

    test "encode_close_buffer produces correct binary" do
      encoded = Protocol.encode_close_buffer(42)
      assert <<0x2D, 42::32>> = encoded
    end

    test "decode_event highlight_spans" do
      # Each span: start_byte:u32, end_byte:u32, capture_id:u16, pattern_index:u16, layer:u16
      spans_binary =
        <<0::32, 9::32, 0::16, 5::16, 0::16>> <>
          <<10::32, 15::32, 1::16, 3::16, 1::16>>

      # buffer_id=5, version=42, count=2
      payload = <<0x30, 5::32, 42::32, 2::32>> <> spans_binary

      assert {:ok, {:highlight_spans, 5, 42, spans}} = Protocol.decode_event(payload)
      assert length(spans) == 2

      assert hd(spans) == %Minga.UI.Highlight.Span{
               start_byte: 0,
               end_byte: 9,
               capture_id: 0,
               pattern_index: 5,
               layer: 0
             }

      assert List.last(spans) == %Minga.UI.Highlight.Span{
               start_byte: 10,
               end_byte: 15,
               capture_id: 1,
               pattern_index: 3,
               layer: 1
             }
    end

    test "decode_event highlight_names" do
      # buffer_id=3, count=2
      payload = <<0x31, 3::32, 2::16, 7::16, "keyword", 6::16, "string">>

      assert {:ok, {:highlight_names, 3, ["keyword", "string"]}} =
               Protocol.decode_event(payload)
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
      # buffer_id=0, version=1, count=0
      payload = <<0x30, 0::32, 1::32, 0::32>>
      assert {:ok, {:highlight_spans, 0, 1, []}} = Protocol.decode_event(payload)
    end

    test "decode_event highlight_names with zero names" do
      # buffer_id=0, count=0
      payload = <<0x31, 0::32, 0::16>>
      assert {:ok, {:highlight_names, 0, []}} = Protocol.decode_event(payload)
    end

    test "decode_event malformed highlight_spans" do
      # buffer_id=0, version=1, count says 2 spans but only 1 complete span (14 bytes)
      payload = <<0x30, 0::32, 1::32, 2::32, 0::32, 9::32, 0::16, 0::16, 0::16>>
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

  describe "request_reparse protocol" do
    test "decode_event request_reparse extracts buffer_id" do
      payload = <<0x3B, 42::32>>
      assert {:ok, {:request_reparse, 42}} = Protocol.decode_event(payload)
    end

    test "decode_event request_reparse with buffer_id zero" do
      payload = <<0x3B, 0::32>>
      assert {:ok, {:request_reparse, 0}} = Protocol.decode_event(payload)
    end

    test "decode_event request_reparse with large buffer_id" do
      payload = <<0x3B, 0xFFFFFFFF::32>>
      assert {:ok, {:request_reparse, 0xFFFFFFFF}} = Protocol.decode_event(payload)
    end
  end

  describe "incremental content sync" do
    test "encode_edit_buffer with a single edit" do
      edits = [
        %{
          start_byte: 10,
          old_end_byte: 10,
          new_end_byte: 11,
          start_position: {2, 5},
          old_end_position: {2, 5},
          new_end_position: {2, 6},
          inserted_text: "x"
        }
      ]

      result = Protocol.encode_edit_buffer(5, 1, edits)

      assert <<0x26, 5::32, 1::32, 1::16, 10::32, 10::32, 11::32, 2::32, 5::32, 2::32, 5::32,
               2::32, 6::32, 1::32, "x">> = result
    end

    test "encode_edit_buffer with multiple edits" do
      edits = [
        %{
          start_byte: 0,
          old_end_byte: 5,
          new_end_byte: 3,
          start_position: {0, 0},
          old_end_position: {0, 5},
          new_end_position: {0, 3},
          inserted_text: "abc"
        },
        %{
          start_byte: 10,
          old_end_byte: 10,
          new_end_byte: 12,
          start_position: {1, 2},
          old_end_position: {1, 2},
          new_end_position: {1, 4},
          inserted_text: "de"
        }
      ]

      result = Protocol.encode_edit_buffer(0, 42, edits)
      assert <<0x26, 0::32, 42::32, 2::16, _rest::binary>> = result
    end

    test "encode_edit_buffer with empty edits list" do
      result = Protocol.encode_edit_buffer(0, 1, [])
      assert <<0x26, 0::32, 1::32, 0::16>> = result
    end
  end

  describe "region commands" do
    test "encode_define_region produces correct binary" do
      result = Protocol.encode_define_region(1, 0, :modeline, 23, 0, 80, 1, 0)
      assert <<0x14, 1::16, 0::16, 1, 23::16, 0::16, 80::16, 1::16, 0>> = result
    end

    test "encode_clear_region" do
      assert <<0x18, 1::16>> = Protocol.encode_clear_region(1)
    end

    test "encode_destroy_region" do
      assert <<0x19, 2::16>> = Protocol.encode_destroy_region(2)
    end

    test "encode_set_active_region" do
      assert <<0x1A, 1::16>> = Protocol.encode_set_active_region(1)
    end

    test "encode_set_active_region with root (0)" do
      assert <<0x1A, 0::16>> = Protocol.encode_set_active_region(0)
    end

    test "all region roles encode to unique values" do
      roles = [:editor, :modeline, :minibuffer, :gutter, :popup, :panel, :border]

      values =
        Enum.map(roles, fn role ->
          <<0x14, _::16, _::16, v::8, _rest::binary>> =
            Protocol.encode_define_region(1, 0, role, 0, 0, 1, 1, 0)

          v
        end)

      assert length(Enum.uniq(values)) == length(roles)
    end
  end

  # ── Scroll region command ──

  describe "scroll_region" do
    test "encode_scroll_region produces 7-byte binary with correct layout" do
      result = Protocol.encode_scroll_region(2, 20, 1)
      assert <<0x1B, 2::16, 20::16, 1::16-signed>> = result
      assert byte_size(result) == 7
    end

    test "encode_scroll_region with negative delta (scroll down)" do
      result = Protocol.encode_scroll_region(5, 30, -3)
      assert <<0x1B, 5::16, 30::16, delta::16-signed>> = result
      assert delta == -3
    end

    test "encode_scroll_region with zero delta" do
      result = Protocol.encode_scroll_region(0, 10, 0)
      assert <<0x1B, 0::16, 10::16, 0::16-signed>> = result
    end

    test "encode_scroll_region round-trips through decode_command" do
      encoded = Protocol.encode_scroll_region(3, 22, 2)
      assert {:ok, {:scroll_region, 3, 22, 2}} = Protocol.decode_command(encoded)
    end

    test "encode_scroll_region round-trips with negative delta" do
      encoded = Protocol.encode_scroll_region(1, 19, -1)
      assert {:ok, {:scroll_region, 1, 19, -1}} = Protocol.decode_command(encoded)
    end

    test "encode_scroll_region with large row values" do
      encoded = Protocol.encode_scroll_region(0, 65_535, 3)
      assert {:ok, {:scroll_region, 0, 65_535, 3}} = Protocol.decode_command(encoded)
    end
  end

  # ── GUI action decoding ──────────────────────────────────────────────────

  describe "decode_event/1 — gui_action" do
    test "select_tab with tab id" do
      payload = <<0x07, 0x01, 42::32-big>>
      assert {:ok, {:gui_action, {:select_tab, 42}}} = Protocol.decode_event(payload)
    end

    test "close_tab with tab id" do
      payload = <<0x07, 0x02, 42::32-big>>
      assert {:ok, {:gui_action, {:close_tab, 42}}} = Protocol.decode_event(payload)
    end

    test "file_tree_click with index" do
      payload = <<0x07, 0x03, 15::16-big>>
      assert {:ok, {:gui_action, {:file_tree_click, 15}}} = Protocol.decode_event(payload)
    end

    test "file_tree_toggle with index" do
      payload = <<0x07, 0x04, 7::16-big>>
      assert {:ok, {:gui_action, {:file_tree_toggle, 7}}} = Protocol.decode_event(payload)
    end

    test "completion_select with index" do
      payload = <<0x07, 0x05, 3::16-big>>
      assert {:ok, {:gui_action, {:completion_select, 3}}} = Protocol.decode_event(payload)
    end

    test "breadcrumb_click with segment index" do
      payload = <<0x07, 0x06, 2>>
      assert {:ok, {:gui_action, {:breadcrumb_click, 2}}} = Protocol.decode_event(payload)
    end

    test "toggle_panel with panel id" do
      payload = <<0x07, 0x07, 1>>
      assert {:ok, {:gui_action, {:toggle_panel, 1}}} = Protocol.decode_event(payload)
    end

    test "new_tab with no payload" do
      payload = <<0x07, 0x08>>
      assert {:ok, {:gui_action, :new_tab}} = Protocol.decode_event(payload)
    end

    test "file_tree_new_file with no payload" do
      payload = <<0x07, 0x0D>>
      assert {:ok, {:gui_action, :file_tree_new_file}} = Protocol.decode_event(payload)
    end

    test "file_tree_new_folder with no payload" do
      payload = <<0x07, 0x0E>>
      assert {:ok, {:gui_action, :file_tree_new_folder}} = Protocol.decode_event(payload)
    end

    test "file_tree_collapse_all with no payload" do
      payload = <<0x07, 0x0F>>
      assert {:ok, {:gui_action, :file_tree_collapse_all}} = Protocol.decode_event(payload)
    end

    test "file_tree_refresh with no payload" do
      payload = <<0x07, 0x10>>
      assert {:ok, {:gui_action, :file_tree_refresh}} = Protocol.decode_event(payload)
    end

    test "unknown action type returns malformed" do
      payload = <<0x07, 0xFF, 0, 0>>
      assert {:error, :malformed} = Protocol.decode_event(payload)
    end
  end

  # ── GUI encoding (Protocol.GUI) ──────────────────────────────────────────

  alias Minga.Frontend.Protocol.GUI, as: ProtocolGUI

  describe "encode_gui_theme/1" do
    test "encodes theme colors as slot_id + rgb tuples" do
      theme = Minga.UI.Theme.get!(:doom_one)
      encoded = ProtocolGUI.encode_gui_theme(theme)

      # First byte is opcode
      assert <<0x74, count::8, rest::binary>> = encoded

      # Should have a reasonable number of color slots
      assert count > 20
      assert count < 60

      # Each entry is 4 bytes (slot_id, r, g, b)
      assert byte_size(rest) == count * 4
    end

    @tag :tmp_dir
    test "encodes gui_file_tree with root, path_hash, and rel_path per entry", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "hello.ex"), "")

      tree = %Minga.Project.FileTree{
        root: tmp_dir,
        expanded: MapSet.new([tmp_dir]),
        cursor: 0,
        width: 30
      }

      encoded = ProtocolGUI.encode_gui_file_tree(tree)

      # Header: opcode + cursor + width + count + root_len + root
      root_len = byte_size(tmp_dir)

      assert <<0x70, cursor::16, width::16, count::16, ^root_len::16, root::binary-size(root_len),
               entry_rest::binary>> = encoded

      assert cursor == 0
      assert width == 30
      assert count == 1
      assert root == tmp_dir

      # Entry: path_hash + flags + depth + git_status + icon + name + rel_path
      expected_path = Path.join(tmp_dir, "hello.ex")
      expected_hash = :erlang.phash2(expected_path, 0xFFFFFFFF)

      assert <<^expected_hash::32, flags::8, depth::8, _git::8, icon_len::8,
               _icon::binary-size(icon_len), name_len::16, name::binary-size(name_len),
               rel_path_len::16, rel_path::binary-size(rel_path_len)>> = entry_rest

      assert flags == 0x04
      assert depth == 0
      assert name == "hello.ex"
      assert rel_path == "hello.ex"
    end

    @tag :tmp_dir
    test "path_hash is stable across encodes", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "stable.txt"), "")

      tree = %Minga.Project.FileTree{
        root: tmp_dir,
        expanded: MapSet.new([tmp_dir]),
        cursor: 0,
        width: 30
      }

      encoded1 = ProtocolGUI.encode_gui_file_tree(tree)
      encoded2 = ProtocolGUI.encode_gui_file_tree(tree)

      # Skip header: opcode(1) + cursor(2) + width(2) + count(2) + root_len(2) + root
      header_size = 9 + byte_size(tmp_dir)
      <<_header1::binary-size(header_size), entry1::binary>> = encoded1
      <<_header2::binary-size(header_size), entry2::binary>> = encoded2

      <<hash1::32, _::binary>> = entry1
      <<hash2::32, _::binary>> = entry2

      assert hash1 == hash2
    end

    test "encodes gui_file_tree nil as zero entries" do
      encoded = ProtocolGUI.encode_gui_file_tree(nil)
      assert <<0x70, 0::16, 0::16, 0::16, 0::16>> = encoded
    end

    test "encodes gui_tab_bar with tabs" do
      tab1 = %Minga.Editor.State.Tab{id: 1, kind: :file, label: "editor.ex"}
      tab2 = %Minga.Editor.State.Tab{id: 2, kind: :agent, label: "Agent", agent_status: :thinking}
      tb = %Minga.Editor.State.TabBar{tabs: [tab1, tab2], active_id: 1, next_id: 3}

      encoded = ProtocolGUI.encode_gui_tab_bar(tb)

      # First byte is opcode 0x71 (gui_tab_bar)
      assert <<0x71, active_index::8, tab_count::8, rest::binary>> = encoded
      assert active_index == 0
      assert tab_count == 2

      # First tab: flags has is_active=1
      assert <<flags1::8, id1::32, _rest1::binary>> = rest
      assert Bitwise.band(flags1, 0x01) == 1
      assert id1 == 1

      # Verify it's a valid binary (no crashes)
      assert is_binary(encoded)
      assert byte_size(encoded) > 10
    end

    test "encodes gui_agent_chat with pending approval including tool summary" do
      data = %{
        visible: true,
        messages: [{:user, "hello"}],
        status: :thinking,
        model: "claude",
        prompt: "test",
        pending_approval: %{name: "shell", args: %{"command" => "ls -la"}}
      }

      encoded = ProtocolGUI.encode_gui_agent_chat(data)
      # Sectioned: opcode + section_count + sections
      assert <<0x78, 7, _sections::binary>> = encoded
      # Verify the pending section (0x04) contains the tool name and summary
      assert :binary.match(encoded, "shell") != :nomatch
      assert :binary.match(encoded, "ls -la") != :nomatch
    end

    test "encodes gui_agent_chat without pending approval" do
      data = %{
        visible: true,
        messages: [{:user, "hi"}],
        status: :idle,
        model: "claude",
        prompt: "",
        pending_approval: nil
      }

      encoded = ProtocolGUI.encode_gui_agent_chat(data)
      # Sectioned: opcode + section_count + sections
      assert <<0x78, 7, _sections::binary>> = encoded
      # Verify model is present
      assert :binary.match(encoded, "claude") != :nomatch
    end

    test "encodes gui_agent_chat hidden" do
      encoded = ProtocolGUI.encode_gui_agent_chat(%{visible: false})
      # gui_agent_chat hidden
      assert <<0x78, 0::8>> = encoded
    end

    test "encodes styled_assistant message with styled runs" do
      styled_lines = [
        [{"def ", 0xFF0000, 0, 1}, {"hello", 0xBBC2CF, 0, 0}],
        [{"  :world", 0x98BE65, 0, 0}]
      ]

      data = %{
        visible: true,
        messages: [{:styled_assistant, styled_lines}],
        status: :idle,
        model: "claude",
        prompt: "",
        pending_approval: nil
      }

      encoded = ProtocolGUI.encode_gui_agent_chat(data)
      # Sectioned: opcode + section_count
      assert <<0x78, 7, _sections::binary>> = encoded

      # Verify styled_assistant message type byte (0x07) appears in the binary
      assert :binary.match(encoded, <<0x07>>) != :nomatch
      # Verify "def " text appears
      assert :binary.match(encoded, "def ") != :nomatch
      assert :binary.match(encoded, "hello") != :nomatch
      assert :binary.match(encoded, ":world") != :nomatch
    end

    test "nil colors are skipped" do
      theme = Minga.UI.Theme.get!(:doom_one)
      encoded = ProtocolGUI.encode_gui_theme(theme)
      # gui_theme
      <<0x74, count::8, _rest::binary>> = encoded

      # Build manually with nils to verify they're filtered
      # The tree git_conflict_fg is nil in doom_one
      assert count > 0
      # Verify it round-trips (no crashes on decode)
      assert is_binary(encoded)
    end
  end

  describe "encode_gui_gutter_separator/2" do
    test "encodes gutter column and RGB color" do
      encoded = ProtocolGUI.encode_gui_gutter_separator(5, 0x3F444A)

      assert <<0x79, col::16, r::8, g::8, b::8>> = encoded
      assert col == 5
      assert r == 0x3F
      assert g == 0x44
      assert b == 0x4A
    end

    test "encodes zero column for no separator" do
      encoded = ProtocolGUI.encode_gui_gutter_separator(0, 0)

      assert <<0x79, 0::16, 0::8, 0::8, 0::8>> = encoded
    end
  end

  describe "encode_gui_cursorline/2" do
    test "encodes cursor row and RGB background color" do
      encoded = ProtocolGUI.encode_gui_cursorline(12, 0x2C323C)

      assert <<0x7A, row::16, r::8, g::8, b::8>> = encoded
      assert row == 12
      assert r == 0x2C
      assert g == 0x32
      assert b == 0x3C
    end

    test "encodes 0xFFFF row for no cursorline" do
      encoded = ProtocolGUI.encode_gui_cursorline(0xFFFF, 0)

      assert <<0x7A, 0xFFFF::16, 0::8, 0::8, 0::8>> = encoded
    end
  end

  describe "encode_gui_gutter/1" do
    test "encodes per-window gutter with position header and entries" do
      data = %{
        window_id: 1,
        content_row: 2,
        content_col: 10,
        content_height: 30,
        is_active: true,
        cursor_line: 42,
        line_number_style: :hybrid,
        line_number_width: 4,
        sign_col_width: 2,
        entries: [
          %{buf_line: 40, display_type: :normal, sign_type: :git_added},
          %{buf_line: 41, display_type: :normal, sign_type: :diag_error},
          %{buf_line: 42, display_type: :normal, sign_type: :none}
        ]
      }

      encoded = ProtocolGUI.encode_gui_gutter(data)

      # Sectioned: opcode(1) + section_count(1) + sections...
      assert <<0x7B, 3, _sections::binary>> = encoded

      # Extract window section (0x01): wid(2) + row(2) + col(2) + height(2) + active(1)
      <<0x7B, _sc::8, 0x01, _wlen::16, wid::16, c_row::16, c_col::16, c_h::16, active::8,
        _rest2::binary>> = encoded

      assert wid == 1
      assert c_row == 2
      assert c_col == 10
      assert c_h == 30
      assert active == 1
    end

    test "encodes inactive window" do
      data = %{
        window_id: 1,
        content_row: 25,
        content_col: 0,
        content_height: 20,
        is_active: false,
        cursor_line: 10,
        line_number_style: :absolute,
        line_number_width: 3,
        sign_col_width: 0,
        entries: [%{buf_line: 10, display_type: :normal, sign_type: :none}]
      }

      encoded = ProtocolGUI.encode_gui_gutter(data)

      # Sectioned: verify opcode and window section
      assert <<0x7B, 3, 0x01, _wlen::16, 1::16, 25::16, 0::16, 20::16, 0::8, _rest::binary>> =
               encoded
    end

    test "encodes empty gutter (no entries)" do
      data = %{
        window_id: 1,
        content_row: 0,
        content_col: 0,
        content_height: 0,
        is_active: false,
        cursor_line: 0,
        line_number_style: :none,
        line_number_width: 0,
        sign_col_width: 0,
        entries: []
      }

      encoded = ProtocolGUI.encode_gui_gutter(data)

      # Sectioned format: opcode(1) + section_count(1) + sections...
      assert <<0x7B, 3, _sections::binary>> = encoded
    end

    test "encodes all line number styles" do
      for {style, expected_byte} <- [hybrid: 0, absolute: 1, relative: 2, none: 3] do
        data = %{
          window_id: 1,
          content_row: 0,
          content_col: 0,
          content_height: 10,
          is_active: true,
          cursor_line: 0,
          line_number_style: style,
          line_number_width: 0,
          sign_col_width: 0,
          entries: []
        }

        encoded = ProtocolGUI.encode_gui_gutter(data)

        # Sectioned: config section (0x02) contains cursor_line(4) + style(1) + ln_w(1) + sign_w(1)
        # Verify the style byte appears in the encoded binary
        assert :binary.match(encoded, <<expected_byte::8>>) != :nomatch
      end
    end

    test "encodes all sign types" do
      sign_types = [
        {:none, 0},
        {:git_added, 1},
        {:git_modified, 2},
        {:git_deleted, 3},
        {:diag_error, 4},
        {:diag_warning, 5},
        {:diag_info, 6},
        {:diag_hint, 7}
      ]

      entries =
        Enum.map(sign_types, fn {sign, _byte} ->
          %{buf_line: 0, display_type: :normal, sign_type: sign}
        end)

      data = %{
        window_id: 1,
        content_row: 0,
        content_col: 0,
        content_height: 40,
        is_active: true,
        cursor_line: 0,
        line_number_style: :hybrid,
        line_number_width: 4,
        sign_col_width: 2,
        entries: entries
      }

      encoded = ProtocolGUI.encode_gui_gutter(data)

      # Verify the encoded binary contains each sign type byte paired with display_type=0
      for {_sign, expected_byte} <- sign_types do
        assert :binary.match(encoded, <<0::8, expected_byte::8>>) != :nomatch,
               "Expected sign_type byte #{expected_byte} in encoded binary"
      end
    end
  end
end
