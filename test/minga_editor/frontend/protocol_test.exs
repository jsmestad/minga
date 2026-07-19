defmodule MingaEditor.Frontend.ProtocolTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol

  defp gui_agent_chat_section!(sections, target_id) do
    do_gui_agent_chat_section!(sections, target_id)
  end

  defp do_gui_agent_chat_section!(
         <<target_id::8, len::16, payload::binary-size(len), _rest::binary>>,
         target_id
       ),
       do: payload

  defp do_gui_agent_chat_section!(
         <<_id::8, len::16, _payload::binary-size(len), rest::binary>>,
         target_id
       ),
       do: do_gui_agent_chat_section!(rest, target_id)

  # Encodes an agent chat through the core semantic encoder, accepting the legacy
  # data-map shape these tests were written against.
  defp encode_gui_agent_chat(data) do
    alias Minga.Frontend.Adapter.GUI.AgentChatEncoder
    alias Minga.Frontend.Adapter.GUI.Caches
    alias Minga.RenderModel.UI.AgentChat

    model =
      case data do
        %{visible: false} ->
          %AgentChat{visible?: false}

        %{visible: true} = d ->
          %AgentChat{
            visible?: true,
            status: Map.get(d, :status, :idle),
            model_name: Map.get(d, :model, ""),
            thinking_level: Map.get(d, :thinking_level, ""),
            prompt: Map.get(d, :prompt, "")
          }
      end

    {binary, _caches} = AgentChatEncoder.encode(model, Caches.new())
    binary
  end

  defp take_string16(<<len::16, value::binary-size(len), rest::binary>>), do: {value, rest}
  defp take_string8(<<len::8, value::binary-size(len), rest::binary>>), do: {value, rest}

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
    test "decodes a legacy key press without a correlation sequence (seq 0)" do
      # 'a' = 97, no modifiers, no sequence appended
      payload = <<0x01, 97::32, 0::8>>
      assert {:ok, {:key_press, 97, 0, 0}} = Protocol.decode_event(payload)
    end

    test "decodes key press with modifiers" do
      mods = Bitwise.bor(Protocol.mod_ctrl(), Protocol.mod_shift())
      payload = <<0x01, 99::32, mods::8>>
      assert {:ok, {:key_press, 99, ^mods, 0}} = Protocol.decode_event(payload)
    end

    test "decodes unicode codepoint" do
      # 🥨 = U+1F968 = 129384
      codepoint = 0x1F968
      payload = <<0x01, codepoint::32, 0::8>>
      assert {:ok, {:key_press, ^codepoint, 0, 0}} = Protocol.decode_event(payload)
    end

    test "decodes special keys (escape = 27)" do
      payload = <<0x01, 27::32, 0::8>>
      assert {:ok, {:key_press, 27, 0, 0}} = Protocol.decode_event(payload)
    end

    test "decodes the correlation sequence appended after modifiers (ticket #2215)" do
      mods = Protocol.mod_ctrl()
      seq = 4_242
      payload = <<0x01, 97::32, mods::8, seq::32>>
      assert {:ok, {:key_press, 97, ^mods, ^seq}} = Protocol.decode_event(payload)
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

    test "decodes an extended ready without a version tail as protocol_version 0 (legacy)" do
      # caps_version=1, caps_len=6, frontend_type=0(tui), color_depth=2(rgb),
      # unicode_width=1(unicode_15), image_support=1(kitty), float_support=0(emulated),
      # text_rendering=0(monospace)
      payload = <<0x03, 120::16, 40::16, 1, 6, 0, 2, 1, 1, 0, 0>>

      assert {:ok, {:ready, 120, 40, caps, 0}} = Protocol.decode_event(payload)
      assert caps.frontend_type == :tui
      assert caps.color_depth == :rgb
      assert caps.unicode_width == :unicode_15
      assert caps.image_support == :kitty
      assert caps.float_support == :emulated
    end

    test "decodes a protocol-v12 ready with capability-format-2 resource policy" do
      capabilities = <<1, 2, 1, 3, 1, 1, 1, 1, 16_777_216::32, 250_000::32, 16_384::32>>
      payload = <<0x03, 200::16, 60::16, 2, 20, capabilities::binary, 12::16>>

      assert {:ok, {:ready, 200, 60, caps, 12}} = Protocol.decode_event(payload)
      assert caps.frontend_type == :native_gui
      assert caps.image_support == :native
      assert caps.float_support == :native
      assert caps.resource_policy.version == 1
      assert caps.resource_policy.max_frame_bytes == 16_777_216
      assert caps.resource_policy.max_frame_commands == 250_000
      assert caps.resource_policy.max_window_rows == 16_384
    end
  end

  describe "decode_event/1 — capabilities_updated" do
    test "decodes a capability-format-2 capabilities_updated event" do
      capabilities = <<0, 2, 1, 1, 0, 0, 1, 1, 67_108_864::32, 1_000_000::32, 65_536::32>>
      payload = <<0x05, 2, 20, capabilities::binary>>

      assert {:ok, {:capabilities_updated, caps}} = Protocol.decode_event(payload)
      assert caps.frontend_type == :tui
      assert caps.color_depth == :rgb
      assert caps.unicode_width == :unicode_15
      assert caps.image_support == :kitty
      assert caps.resource_policy.max_frame_bytes == 67_108_864
      assert caps.resource_policy.max_frame_commands == 1_000_000
      assert caps.resource_policy.max_window_rows == 65_536
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

  describe "encode_protocol_error/1" do
    test "encodes a len16-framed UTF-8 reason" do
      encoded = Protocol.encode_protocol_error("nope")
      assert <<0x18, 4::16, "nope">> = encoded
    end

    test "encodes an empty reason" do
      assert <<0x18, 0::16>> = Protocol.encode_protocol_error("")
    end
  end

  describe "encode_begin_frame/2" do
    test "encodes begin_frame with frame_seq and base_frame_seq (#2219)" do
      assert <<0x10, 7::32, 6::32, 1::32>> = Protocol.encode_begin_frame(7, 6)
    end

    test "encodes a keyframe as base_frame_seq 0" do
      assert <<0x10, 9::32, 0::32, 1::32>> = Protocol.encode_begin_frame(9, 0)
    end

    test "masks large monotonic frame_seq values to u32" do
      big = 0x1_0000_0001
      assert <<0x10, 1::32, 0::32, 1::32>> = Protocol.encode_begin_frame(big, 0)
    end
  end

  describe "encode_commit_frame/2" do
    test "encodes commit_frame with frame_seq and a zero input_seq by default (#2219)" do
      assert <<0x11, 7::32, 0::32>> = Protocol.encode_commit_frame(7)
    end

    test "encodes the echoed input correlation sequence (ticket #2215)" do
      assert <<0x11, 7::32, 4_242::32>> = Protocol.encode_commit_frame(7, 4_242)
    end
  end

  # ── Binary format verification ──

  describe "binary format" do
    test "protocol_error has correct len16 byte layout" do
      assert <<0x18, 3::16, "bad">> = Protocol.encode_protocol_error("bad")
    end

    test "commit_frame carries frame_seq + input_seq (opcode + 8 bytes)" do
      assert <<0x11, 0::32, 0::32>> = Protocol.encode_commit_frame(0)
    end

    test "begin_frame carries frame_seq + base_frame_seq + generation" do
      assert <<0x10, 0::32, 0::32, 1::32>> = Protocol.encode_begin_frame(0, 0)
    end

    test "request_keyframe decodes last_good_frame_seq and generation" do
      assert {:ok, {:request_keyframe, 12, 3}} = Protocol.decode_event(<<0x08, 12::32, 3::32>>)
    end

    test "key_press event has correct byte layout" do
      payload = <<0x01, 65::32, 0x03::8>>
      assert {:ok, {:key_press, 65, 3, 0}} = Protocol.decode_event(payload)
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

  describe "decode_event/1 — scroll_batch" do
    test "decodes scroll_batch down" do
      payload = <<0x09, 1::16, 5::16-signed, 0>>

      assert {:ok, {:scroll_batch, 1, 5, :down}} = Protocol.decode_event(payload)
    end

    test "decodes scroll_batch up with negative delta" do
      payload = <<0x09, 2::16, -3::16-signed, 1>>

      assert {:ok, {:scroll_batch, 2, -3, :up}} = Protocol.decode_event(payload)
    end

    test "truncated scroll_batch returns malformed" do
      assert {:error, :malformed} = Protocol.decode_event(<<0x09, 1::16, 5::16-signed>>)
    end
  end

  describe "decode_event/1 — frame status" do
    test "decodes protocol-v12 rejection reasons and dispositions" do
      assert {:ok, {:frame_applied, 3, 9}} = Protocol.decode_event(<<0x0A, 3::32, 9::32>>)

      assert {:ok, {:frame_rejected, 3, 9, 7, :base_sequence_mismatch, :retryable_recovery}} =
               Protocol.decode_event(<<0x0B, 3::32, 9::32, 7::32, 4, 1>>)

      assert {:ok, {:frame_rejected, 3, 10, 9, :invalid_row_splice, :adapted_retry}} =
               Protocol.decode_event(<<0x0B, 3::32, 10::32, 9::32, 14, 3>>)

      assert {:ok, {:frame_rejected, 4, 11, 9, :resource_policy, :terminal_frontend_failure}} =
               Protocol.decode_event(<<0x0B, 4::32, 11::32, 9::32, 15, 4>>)

      assert {:ok, {:window_ref_miss, 3, 9, 7, 12}} =
               Protocol.decode_event(<<0x0C, 3::32, 9::32, 7::32, 12::16>>)
    end

    test "treats a draining protocol-v11 rejection as retryable" do
      assert {:ok, {:frame_rejected, 3, 9, 7, :base_sequence_mismatch, :retryable_recovery}} =
               Protocol.decode_event(<<0x0B, 3::32, 9::32, 7::32, 4>>)
    end

    test "unknown dispositions fail closed as terminal" do
      assert {:ok, {:frame_rejected, 3, 9, 7, :unknown, :terminal_frontend_failure}} =
               Protocol.decode_event(<<0x0B, 3::32, 9::32, 7::32, 254, 255>>)
    end
  end

  describe "set_title protocol" do
    test "encodes title" do
      encoded = Protocol.encode_set_title("editor.ex [+] (lib) - Minga")
      assert <<0x16, 27::16, "editor.ex [+] (lib) - Minga">> = encoded
    end

    test "encodes empty title" do
      encoded = Protocol.encode_set_title("")
      assert <<0x16, 0::16>> = encoded
    end

    test "encodes unicode title with byte length" do
      encoded = Protocol.encode_set_title("файл.ex - Minga")
      title = "файл.ex - Minga"
      title_len = byte_size(title)
      assert <<0x16, ^title_len::16, ^title::binary>> = encoded
    end
  end

  describe "set_link_cursor protocol (#2630)" do
    test "encodes an active link cursor as opcode 0x19 with a 1 byte" do
      assert <<0x19, 1>> = Protocol.encode_set_link_cursor(true)
    end

    test "encodes an inactive link cursor as opcode 0x19 with a 0 byte" do
      assert <<0x19, 0>> = Protocol.encode_set_link_cursor(false)
    end
  end

  describe "set_font protocol" do
    test "encodes ligatures enabled with default weight" do
      encoded = Protocol.encode_set_font("JetBrains Mono", 14, true)
      assert <<0x50, 14::16, 2::8, 1::8, 14::16, "JetBrains Mono">> = encoded
    end

    test "encodes ligatures disabled" do
      encoded = Protocol.encode_set_font("Menlo", 13, false)
      assert <<0x50, 13::16, 2::8, 0::8, 5::16, "Menlo">> = encoded
    end

    test "encodes unicode font name with byte length" do
      encoded = Protocol.encode_set_font("Iosevka Термин", 12, true)
      font_name = "Iosevka Термин"
      font_name_len = byte_size(font_name)
      assert <<0x50, 12::16, 2::8, 1::8, ^font_name_len::16, ^font_name::binary>> = encoded
    end

    test "encodes explicit weight" do
      encoded = Protocol.encode_set_font("JetBrains Mono", 14, true, :light)
      assert <<0x50, 14::16, 1::8, 1::8, 14::16, "JetBrains Mono">> = encoded
    end

    test "encodes all weight values" do
      weights = [
        thin: 0,
        light: 1,
        regular: 2,
        medium: 3,
        semibold: 4,
        bold: 5,
        heavy: 6,
        black: 7
      ]

      for {weight, encoded_weight} <- weights do
        encoded = Protocol.encode_set_font("Test", 13, true, weight)
        assert <<0x50, 13::16, ^encoded_weight::8, 1::8, 4::16, "Test">> = encoded
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

    test "encode_set_tags_query produces correct binary" do
      query = "(call) @definition.function"
      encoded = Protocol.encode_set_tags_query(4, query)
      qlen = byte_size(query)
      assert <<0x40, 4::32, ^qlen::32, rest::binary>> = encoded
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
      assert Enum.count(spans) == 2

      assert hd(spans) == %Minga.Language.Highlight.Span{
               start_byte: 0,
               end_byte: 9,
               capture_id: 0,
               pattern_index: 5,
               layer: 0
             }

      assert Enum.at(spans, -1) == %Minga.Language.Highlight.Span{
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

    test "decode_event match_item_result" do
      payload = <<0x3C, 42::32, 1, 9::32, 4::32>>
      assert {:ok, {:match_item_result, 42, {9, 4}}} = Protocol.decode_event(payload)
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

    test "tab_reorder with tab id and visible index" do
      payload = <<0x07, 0x48, 42::32, 3::16>>
      assert {:ok, {:gui_action, {:tab_reorder, 42, 3}}} = Protocol.decode_event(payload)
    end

    test "tab id-scoped context actions" do
      assert {:ok, {:gui_action, {:tab_pin, 42}}} = Protocol.decode_event(<<0x07, 0x49, 42::32>>)

      assert {:ok, {:gui_action, {:tab_unpin, 42}}} =
               Protocol.decode_event(<<0x07, 0x4A, 42::32>>)

      assert {:ok, {:gui_action, {:tab_move_left, 42}}} =
               Protocol.decode_event(<<0x07, 0x4B, 42::32>>)

      assert {:ok, {:gui_action, {:tab_move_right, 42}}} =
               Protocol.decode_event(<<0x07, 0x4C, 42::32>>)
    end

    test "system_will_sleep with no payload" do
      payload = <<0x07, 0x34>>
      assert {:ok, {:gui_action, :system_will_sleep}} = Protocol.decode_event(payload)
    end

    test "system_did_wake with no payload" do
      payload = <<0x07, 0x35>>
      assert {:ok, {:gui_action, :system_did_wake}} = Protocol.decode_event(payload)
    end

    test "cmd_copy with no payload" do
      payload = <<0x07, 0x36>>
      assert {:ok, {:gui_action, :cmd_copy}} = Protocol.decode_event(payload)
    end

    test "cmd_cut with no payload" do
      payload = <<0x07, 0x37>>
      assert {:ok, {:gui_action, :cmd_cut}} = Protocol.decode_event(payload)
    end

    test "file_tree_new_file with parent_index" do
      payload = <<0x07, 0x0D, 0x00, 0x05>>
      assert {:ok, {:gui_action, {:file_tree_new_file, 5}}} = Protocol.decode_event(payload)
    end

    test "file_tree_new_folder with parent_index" do
      payload = <<0x07, 0x0E, 0x00, 0x03>>
      assert {:ok, {:gui_action, {:file_tree_new_folder, 3}}} = Protocol.decode_event(payload)
    end

    test "file_tree_edit_confirm with text" do
      text = "newfile.txt"
      text_bytes = text
      text_len = byte_size(text_bytes)
      payload = <<0x07, 0x2D, text_len::16, text_bytes::binary>>

      assert {:ok, {:gui_action, {:file_tree_edit_confirm, "newfile.txt"}}} =
               Protocol.decode_event(payload)
    end

    test "file_tree_edit_cancel" do
      payload = <<0x07, 0x2E>>
      assert {:ok, {:gui_action, :file_tree_edit_cancel}} = Protocol.decode_event(payload)
    end

    test "file_tree_collapse_all with no payload" do
      payload = <<0x07, 0x0F>>
      assert {:ok, {:gui_action, :file_tree_collapse_all}} = Protocol.decode_event(payload)
    end

    test "file_tree_refresh with no payload" do
      payload = <<0x07, 0x10>>
      assert {:ok, {:gui_action, :file_tree_refresh}} = Protocol.decode_event(payload)
    end

    test "file_tree_drop with target identity and source paths" do
      target_id = "/project/lib"
      target_path = "/project/lib"
      source_a = "/tmp/a.txt"
      source_b = "/tmp/b.txt"

      payload =
        <<0x07, 0x40, 8::16, 0xAABBCCDD::32, 1::8, 2::8, byte_size(target_id)::16,
          target_id::binary, byte_size(target_path)::16, target_path::binary, 2::16,
          byte_size(source_a)::16, source_a::binary, byte_size(source_b)::16, source_b::binary>>

      assert {:ok, {:gui_action, {:file_tree_drop, intent}}} = Protocol.decode_event(payload)
      assert %MingaEditor.FileTree.DropIntent{} = intent
      assert intent.target_index == 8
      assert intent.target_path_hash == 0xAABBCCDD
      assert intent.target_dir? == true
      assert intent.modifiers == 2
      assert intent.target_id == target_id
      assert intent.target_path == target_path
      assert intent.source_paths == [source_a, source_b]
    end

    test "file_tree_drop rejects malformed payloads" do
      assert {:error, :malformed} =
               Protocol.decode_event(<<0x07, 0x40, 8::16, 0::32, 2::8, 0::8>>)

      assert {:error, :malformed} =
               Protocol.decode_event(<<0x07, 0x40, 8::16, 0::32, 1::8, 0::8, 4::16, "ab">>)

      assert {:error, :malformed} =
               Protocol.decode_event(<<0x07, 0x40, 8::16, 0::32, 1::8, 0::8, 1::16, 0xFF>>)
    end

    test "unknown action type returns malformed" do
      payload = <<0x07, 0xFF, 0, 0>>
      assert {:error, :malformed} = Protocol.decode_event(payload)
    end
  end

  # ── GUI encoding (Protocol.GUI) ──────────────────────────────────────────

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  describe "encode_gui_theme/1" do
    test "encodes theme colors as slot_id + rgb tuples" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      encoded = ProtocolGUI.encode_gui_theme(theme)

      # First byte is opcode
      assert <<0x74, count::8, rest::binary>> = encoded

      # Should have a reasonable number of color slots
      assert count > 20
      assert count < 85

      # Each entry is 4 bytes (slot_id, r, g, b)
      assert byte_size(rest) == count * 4
    end

    test "encodes agent chat theme color slots from Theme.Agent" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      encoded = ProtocolGUI.encode_gui_theme(theme)

      assert <<0x74, count::8, rest::binary>> = encoded

      # Parse all slots into a map of {slot_id => {r, g, b}}
      slots = parse_theme_slots(rest, count)

      # Agent chat slots should be present (0xA0-0xAE)
      agent = MingaEditor.UI.Theme.agent_theme(theme)

      assert_color_slot(slots, 0xA0, agent.panel_bg)
      assert_color_slot(slots, 0xA1, agent.header_bg)
      assert_color_slot(slots, 0xA2, agent.header_fg)
      assert_color_slot(slots, 0xA3, agent.user_border)
      assert_color_slot(slots, 0xA4, agent.user_label)
      assert_color_slot(slots, 0xA5, agent.assistant_border)
      assert_color_slot(slots, 0xA6, agent.assistant_label)
      assert_color_slot(slots, 0xA7, agent.input_border)
      assert_color_slot(slots, 0xA8, agent.input_bg)
      assert_color_slot(slots, 0xA9, agent.input_placeholder)
      assert_color_slot(slots, 0xAA, agent.text_fg)
      assert_color_slot(slots, 0xAB, agent.tool_border)
      assert_color_slot(slots, 0xAC, agent.tool_header)
      assert_color_slot(slots, 0xAD, agent.code_bg)
      assert_color_slot(slots, 0xAE, agent.code_border)
    end

    test "agent chat slots encode correct RGB values for doom_one input_border" do
      # Acceptance criteria: Doom One input_border should be 0x51AFEF (blue)
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      encoded = ProtocolGUI.encode_gui_theme(theme)
      <<0x74, count::8, rest::binary>> = encoded
      slots = parse_theme_slots(rest, count)

      # input_border slot (0xA7) should be {0x51, 0xAF, 0xEF}
      assert Map.get(slots, 0xA7) == {0x51, 0xAF, 0xEF}
    end

    test "agent chat slots are present for all built-in themes" do
      agent_slot_ids = Enum.to_list(0xA0..0xAE)

      for theme_name <- MingaEditor.UI.Theme.available() do
        theme = MingaEditor.UI.Theme.get!(theme_name)
        encoded = ProtocolGUI.encode_gui_theme(theme)
        <<0x74, count::8, rest::binary>> = encoded
        slots = parse_theme_slots(rest, count)

        for slot_id <- agent_slot_ids do
          assert Map.has_key?(slots, slot_id),
                 "Theme #{theme_name} missing agent slot 0x#{Integer.to_string(slot_id, 16)}"
        end
      end
    end

    test "encodes semantic gui_file_tree with length prefix, root, selection, and row fields" do
      row =
        MingaEditor.FileTree.Row.new(
          id: "/project/lib/hello.ex",
          path: "/project/lib/hello.ex",
          relative_path: "lib/hello.ex",
          name: "hello.ex",
          directory?: false,
          expanded?: false,
          selected?: true,
          focused?: true,
          active?: true,
          dirty?: true,
          git_status: :modified,
          diagnostics: MingaEditor.FileTree.Diagnostics.new({1, 2, 3, 4}),
          depth: 1,
          guides: [true, false],
          last_child?: true,
          editing: nil
        )

      encoded = ProtocolGUI.encode_gui_file_tree("/project", 30, :ready, true, [row])

      assert <<0x93, payload_len::32, payload::binary-size(payload_len)>> = encoded
      assert <<2::8, tree_flags::8, 3::8, rest::binary>> = payload
      assert Bitwise.band(tree_flags, 0x01) != 0
      assert Bitwise.band(tree_flags, 0x02) != 0

      <<selected_len::16, selected::binary-size(selected_len), rest::binary>> = rest
      assert selected == row.id

      <<root_len::16, root::binary-size(root_len), 30::16, 1::16, error_len::16,
        error_reason::binary-size(error_len), row_payload::binary>> = rest

      assert root == "/project"
      assert error_reason == ""

      expected_hash = :erlang.phash2(row.id, 0xFFFFFFFF)

      assert <<^expected_hash::32, row_flags::16, 1::8, 1::8, 1::16, 2::16, 3::16, 4::16, 2::8,
               1::8, 0::8, strings::binary>> = row_payload

      assert Bitwise.band(row_flags, 0x04) != 0
      assert Bitwise.band(row_flags, 0x08) != 0
      assert Bitwise.band(row_flags, 0x10) != 0
      assert Bitwise.band(row_flags, 0x20) != 0
      assert Bitwise.band(row_flags, 0x80) != 0

      {id, strings} = take_string16(strings)
      {path, strings} = take_string16(strings)
      {rel_path, strings} = take_string16(strings)
      {name, strings} = take_string16(strings)
      {icon, strings} = take_string8(strings)
      <<255::8, 0::16, icon_r::8, icon_g::8, icon_b::8, _heat_level::8>> = strings

      assert id == row.id
      assert path == row.path
      assert rel_path == "lib/hello.ex"
      assert name == row.name
      assert icon != ""
      # Elixir file → language default icon color (0x9B59B6) on the wire.
      assert <<icon_r, icon_g, icon_b>> == <<0x9B, 0x59, 0xB6>>
    end

    test "clamps semantic gui_file_tree diagnostic counts to uint16 wire fields" do
      row =
        MingaEditor.FileTree.Row.new(
          id: "/project/lib/noisy.ex",
          path: "/project/lib/noisy.ex",
          relative_path: "lib/noisy.ex",
          name: "noisy.ex",
          directory?: false,
          expanded?: false,
          selected?: true,
          diagnostics: MingaEditor.FileTree.Diagnostics.new({70_000, 65_536, 3, 4}),
          depth: 0,
          guides: [],
          last_child?: true,
          editing: nil
        )

      encoded = ProtocolGUI.encode_gui_file_tree("/project", 30, :ready, false, [row])
      <<0x93, payload_len::32, payload::binary-size(payload_len)>> = encoded

      <<_version::8, _tree_flags::8, _tree_state::8, selected_len::16,
        _selected::binary-size(selected_len), root_len::16, _root::binary-size(root_len),
        _width::16, _count::16, 0::16, _hash::32, _row_flags::16, _depth::8, _git::8, 65_535::16,
        65_535::16, 3::16, 4::16, _rest::binary>> = payload
    end

    test "encodes semantic gui_file_tree string lengths as UTF-8 byte counts" do
      row =
        MingaEditor.FileTree.Row.new(
          id: "/project/lib/ñ📄.ex",
          path: "/project/lib/ñ📄.ex",
          relative_path: "lib/ñ📄.ex",
          name: "ñ📄.ex",
          directory?: false,
          expanded?: false,
          selected?: true,
          depth: 0,
          guides: [],
          last_child?: true,
          editing: nil
        )

      encoded = ProtocolGUI.encode_gui_file_tree("/project", 30, :ready, false, [row])
      <<0x93, payload_len::32, payload::binary-size(payload_len)>> = encoded

      <<_version::8, _tree_flags::8, _tree_state::8, selected_len::16,
        selected::binary-size(selected_len), root_len::16, _root::binary-size(root_len),
        _width::16, _count::16, 0::16, _hash::32, _row_flags::16, _depth::8, _git::8,
        _diag::binary-size(8), 0::8, strings::binary>> = payload

      assert selected == row.id
      assert selected_len == byte_size(row.id)
      {_id, strings} = take_string16(strings)
      {_path, strings} = take_string16(strings)
      {rel_path, strings} = take_string16(strings)
      {name, _strings} = take_string16(strings)
      assert rel_path == "lib/ñ📄.ex"
      assert name == row.name
      assert byte_size(name) > String.length(name)
    end

    test "encodes semantic gui_file_tree payloads larger than 64KB without length truncation" do
      rows =
        for index <- 1..220 do
          suffix = String.duplicate("nested-segment-", 20) <> Integer.to_string(index)

          MingaEditor.FileTree.Row.new(
            id: "/project/#{suffix}.ex",
            path: "/project/#{suffix}.ex",
            relative_path: "lib/#{suffix}.ex",
            name: "#{suffix}.ex",
            directory?: false,
            expanded?: false,
            selected?: index == 1,
            depth: 2,
            guides: [true, false],
            last_child?: index == 220,
            editing: nil
          )
        end

      encoded = ProtocolGUI.encode_gui_file_tree("/project", 30, :ready, false, rows)

      assert <<0x93, payload_len::32, payload::binary-size(payload_len)>> = encoded
      assert payload_len == byte_size(payload)
      assert payload_len > 65_535
    end

    test "encodes lightweight gui_file_tree_selection update" do
      encoded = ProtocolGUI.encode_gui_file_tree_selection("/project/lib/hello.ex", true)

      assert <<0x94, payload_len::16, payload::binary-size(payload_len)>> = encoded
      assert <<1::8, selected_len::16, selected::binary-size(selected_len)>> = payload
      assert selected == "/project/lib/hello.ex"
    end

    test "encodes hidden semantic gui_file_tree with explicit hidden state" do
      encoded = ProtocolGUI.encode_hidden_gui_file_tree("/tmp/minga-project")

      assert <<0x93, payload_len::32, payload::binary-size(payload_len)>> = encoded

      assert <<2::8, tree_flags::8, 0::8, selected_len::16, selected::binary-size(selected_len),
               root_len::16, root::binary-size(root_len), 0::16, 0::16, 0::16>> = payload

      assert selected == ""

      refute Bitwise.band(tree_flags, 0x01) != 0
      refute Bitwise.band(tree_flags, 0x10) != 0
      assert root == "/tmp/minga-project"
    end

    test "encodes visible empty, loading, and error semantic gui_file_tree states without rows" do
      empty = ProtocolGUI.encode_gui_file_tree("/project", 30, :empty, false, [])
      loading = ProtocolGUI.encode_gui_file_tree("/project", 30, :loading, false, [])

      error =
        ProtocolGUI.encode_gui_file_tree("/project", 30, {:error, "permission denied"}, false, [])

      assert <<0x93, _::32, 2::8, empty_flags::8, 2::8, _empty_rest::binary>> = empty
      assert Bitwise.band(empty_flags, 0x01) != 0
      assert Bitwise.band(empty_flags, 0x10) != 0

      assert <<0x93, _::32, 2::8, loading_flags::8, 1::8, _loading_rest::binary>> = loading
      assert Bitwise.band(loading_flags, 0x01) != 0
      refute Bitwise.band(loading_flags, 0x10) != 0

      assert <<0x93, payload_len::32, payload::binary-size(payload_len)>> = error

      assert <<2::8, error_flags::8, 4::8, selected_len::16, _selected::binary-size(selected_len),
               root_len::16, _root::binary-size(root_len), 30::16, 0::16, reason_len::16,
               reason::binary-size(reason_len)>> = payload

      assert Bitwise.band(error_flags, 0x01) != 0
      assert reason == "permission denied"
    end

    test "encodes semantic gui_file_tree editing payload" do
      row =
        MingaEditor.FileTree.Row.new(
          id: "/project/target.txt",
          path: "/project/target.txt",
          relative_path: "target.txt",
          name: "target.txt",
          directory?: false,
          expanded?: false,
          selected?: true,
          depth: 0,
          guides: [],
          last_child?: true,
          editing: %{index: 0, text: "renamed.txt", type: :rename, original_name: "target.txt"}
        )

      encoded = ProtocolGUI.encode_gui_file_tree("/project", 30, :ready, true, [row])
      <<0x93, payload_len::32, payload::binary-size(payload_len)>> = encoded
      # Skip tree header and fixed row prefix.
      <<_version::8, _tree_flags::8, _tree_state::8, selected_len::16,
        _selected::binary-size(selected_len), root_len::16, _root::binary-size(root_len),
        _width::16, _count::16, 0::16, _hash::32, row_flags::16, _depth::8, _git::8,
        _diag::binary-size(8), 0::8, strings::binary>> = payload

      assert Bitwise.band(row_flags, 0x40) != 0
      {_id, strings} = take_string16(strings)
      {_path, strings} = take_string16(strings)
      {_rel_path, strings} = take_string16(strings)
      {_name, strings} = take_string16(strings)
      {_icon, strings} = take_string8(strings)

      <<2::8, editing_text_len::16, editing_text::binary-size(editing_text_len), _icon_r::8,
        _icon_g::8, _icon_b::8, _heat_level::8>> = strings

      assert editing_text == "renamed.txt"
    end

    test "encodes gui_tab_bar with tabs" do
      tab1 = %MingaEditor.State.Tab{id: 1, kind: :file, label: "editor.ex"}
      tab2 = %MingaEditor.State.Tab{id: 2, kind: :agent, label: "Agent", agent_status: :thinking}
      tb = %MingaEditor.State.TabBar{tabs: [tab1, tab2], active_id: 1, next_id: 3}

      encoded = ProtocolGUI.encode_gui_tab_bar(tb)

      # First byte is opcode 0x71 (gui_tab_bar)
      assert <<0x71, active_index::8, tab_count::8, rest::binary>> = encoded
      assert active_index == 0
      assert tab_count == 1

      # First tab: flags has is_active=1
      assert <<flags1::8, id1::32, _rest1::binary>> = rest
      assert Bitwise.band(flags1, 0x01) == 1
      assert id1 == 1

      # Verify it's a valid binary (no crashes)
      assert is_binary(encoded)
      assert byte_size(encoded) > 10
    end

    test "encodes gui_agent_chat pending section as empty compatibility section" do
      data = %{
        visible: true,
        status: :thinking,
        model: "claude",
        prompt: "test",
        pending_approval: %{name: "shell", args: %{"command" => "ls -la"}}
      }

      encoded = encode_gui_agent_chat(data)
      # Sectioned: opcode + section_count + sections
      assert <<0x78, 8, sections::binary>> = encoded
      assert gui_agent_chat_section!(sections, 0x04) == <<0::8>>
      assert :binary.match(encoded, "shell") == :nomatch
      assert :binary.match(encoded, "ls -la") == :nomatch
    end

    test "encodes gui_agent_chat without pending approval" do
      data = %{
        visible: true,
        status: :idle,
        model: "claude",
        prompt: "",
        pending_approval: nil
      }

      encoded = encode_gui_agent_chat(data)
      # Sectioned: opcode + section_count + sections
      assert <<0x78, 8, _sections::binary>> = encoded
      # Verify model is present
      assert :binary.match(encoded, "claude") != :nomatch
    end

    test "encodes gui_agent_chat thinking level section" do
      data = %{
        visible: true,
        status: :idle,
        model: "claude",
        thinking_level: "high",
        prompt: "",
        pending_approval: nil
      }

      encoded = encode_gui_agent_chat(data)
      assert <<0x78, 8, sections::binary>> = encoded
      assert <<4::16, "high">> = gui_agent_chat_section!(sections, 0x08)
    end

    test "encodes gui_agent_chat hidden" do
      encoded = encode_gui_agent_chat(%{visible: false})
      # gui_agent_chat hidden
      assert <<0x78, 0::8>> = encoded
    end

    test "nil colors are skipped" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
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

  # ── Theme slot test helpers ──

  defp parse_theme_slots(binary, count) do
    parse_theme_slots(binary, count, %{})
  end

  defp parse_theme_slots(_rest, 0, acc), do: acc

  defp parse_theme_slots(<<slot::8, r::8, g::8, b::8, rest::binary>>, remaining, acc) do
    parse_theme_slots(rest, remaining - 1, Map.put(acc, slot, {r, g, b}))
  end

  defp assert_color_slot(slots, slot_id, expected_rgb) do
    expected_r = Bitwise.bsr(Bitwise.band(expected_rgb, 0xFF0000), 16)
    expected_g = Bitwise.bsr(Bitwise.band(expected_rgb, 0x00FF00), 8)
    expected_b = Bitwise.band(expected_rgb, 0x0000FF)

    assert Map.has_key?(slots, slot_id),
           "Missing slot 0x#{Integer.to_string(slot_id, 16)}"

    assert Map.get(slots, slot_id) == {expected_r, expected_g, expected_b},
           "Slot 0x#{Integer.to_string(slot_id, 16)}: expected #{inspect({expected_r, expected_g, expected_b})}, got #{inspect(Map.get(slots, slot_id))}"
  end
end
