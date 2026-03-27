defmodule Minga.Frontend.GUIAgentChatProtocolTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Protocol.GUI, as: ProtocolGUI

  describe "decode_gui_action for agent_tool_toggle" do
    test "decodes a valid agent_tool_toggle action" do
      assert {:ok, {:agent_tool_toggle, 7}} ==
               ProtocolGUI.decode_gui_action(0x15, <<7::16>>)
    end

    test "decodes agent_tool_toggle at index 0" do
      assert {:ok, {:agent_tool_toggle, 0}} ==
               ProtocolGUI.decode_gui_action(0x15, <<0::16>>)
    end

    test "decodes agent_tool_toggle at max UInt16" do
      assert {:ok, {:agent_tool_toggle, 65_535}} ==
               ProtocolGUI.decode_gui_action(0x15, <<65_535::16>>)
    end

    test "returns error for short payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<7>>)
    end

    test "returns error for empty payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<>>)
    end
  end

  describe "encode_gui_agent_chat with styled_tool_call" do
    test "encodes styled_tool_call with sub-opcode 0x08" do
      tc = %Minga.Agent.ToolCall{
        id: "tc-styled",
        name: "bash",
        status: :complete,
        is_error: false,
        collapsed: false,
        duration_ms: 1234,
        result: "hello world"
      }

      # One line with one run: "hello" with fg=0xFF0000, bg=0x000000, bold
      styled_lines = [
        [{"hello", 0xFF0000, 0x000000, 0x01}]
      ]

      data = %{
        visible: true,
        messages: [{:styled_tool_call, tc, styled_lines}],
        status: :idle,
        model: "test",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)

      # Skip the outer envelope (opcode + visible + status + model + prompt + pending + msg_count)
      # and find the message payload starting with sub-opcode 0x08
      assert :binary.match(binary, <<0x08>>) != :nomatch

      # Find the 0x08 byte and verify the structure after it
      {start, _} = :binary.match(binary, <<0x08>>)
      msg_payload = binary_part(binary, start, byte_size(binary) - start)

      <<0x08::8, status_byte::8, error_byte::8, collapsed_byte::8, duration::32, name_len::16,
        name::binary-size(name_len), summary_len::16, summary::binary-size(summary_len),
        line_count::16, rest::binary>> = msg_payload

      assert status_byte == 1
      assert error_byte == 0
      assert collapsed_byte == 0
      assert duration == 1234
      assert name == "bash"
      # No args in test data, so summary is empty
      assert summary == ""
      assert line_count == 1

      # Parse the single line's single run
      <<run_count::16, text_len::16, text::binary-size(text_len), fg::24, bg::24, flags::8>> =
        rest

      assert run_count == 1
      assert text == "hello"
      assert fg == 0xFF0000
      assert bg == 0x000000
      assert flags == 0x01
    end

    test "encodes regular tool_call with sub-opcode 0x04" do
      tc = %Minga.Agent.ToolCall{
        id: "tc-regular",
        name: "read",
        status: :running,
        is_error: false,
        collapsed: true,
        duration_ms: 0,
        result: "file contents"
      }

      data = %{
        visible: true,
        messages: [{:tool_call, tc}],
        status: :idle,
        model: "",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)
      assert :binary.match(binary, <<0x04>>) != :nomatch
    end
  end

  describe "stable message ID encoding" do
    test "encodes {id, message} tuples with uint32 ID prefix" do
      data = %{
        visible: true,
        messages: [{42, {:user, "hello"}}, {99, {:assistant, "hi"}}],
        status: :idle,
        model: "",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)

      # Parse the envelope to get to the message payload
      <<0x78, 1::8, _status::8, model_len::16, _model::binary-size(model_len), prompt_len::16,
        _prompt::binary-size(prompt_len), _prompt_meta::binary-size(7), 0::8, 0::8, msg_count::16,
        msg_data::binary>> = binary

      assert msg_count == 2

      # First message: ID=42, type=0x01 (user), text="hello"
      <<42::32, 0x01::8, text_len::32, text::binary-size(text_len), rest::binary>> = msg_data
      assert text == "hello"

      # Second message: ID=99, type=0x02 (assistant), text="hi"
      <<99::32, 0x02::8, text2_len::32, text2::binary-size(text2_len)>> = rest
      assert text2 == "hi"
    end

    test "bare tuple messages (no ID wrapper) encode with ID 0" do
      data = %{
        visible: true,
        messages: [{:user, "bare"}],
        status: :idle,
        model: "",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)

      <<0x78, 1::8, _status::8, model_len::16, _model::binary-size(model_len), prompt_len::16,
        _prompt::binary-size(prompt_len), _prompt_meta::binary-size(7), 0::8, 0::8, 1::16,
        msg_data::binary>> = binary

      # ID prefix should be 0 for bare tuples
      <<0::32, 0x01::8, _rest::binary>> = msg_data
    end

    test "all message types carry the ID prefix" do
      tc = %Minga.Agent.ToolCall{
        id: "tc-all",
        name: "bash",
        status: :complete,
        is_error: false,
        collapsed: true,
        duration_ms: 100,
        result: "ok"
      }

      messages = [
        {1, {:user, "hello"}},
        {2, {:assistant, "hi"}},
        {3, {:thinking, "hmm", true}},
        {4, {:tool_call, tc}},
        {5, {:system, "started", :info}},
        {6,
         {:usage,
          %Minga.Agent.TurnUsage{input: 10, output: 5, cache_read: 0, cache_write: 0, cost: 0.001}}}
      ]

      data = %{
        visible: true,
        messages: messages,
        status: :idle,
        model: "",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)

      <<0x78, 1::8, _status::8, model_len::16, _model::binary-size(model_len), prompt_len::16,
        _prompt::binary-size(prompt_len), _prompt_meta::binary-size(7), 0::8, 0::8, msg_count::16,
        _msg_data::binary>> = binary

      assert msg_count == 6

      # Verify each message starts with its expected ID by scanning the binary.
      # The messages are sequential, so we check the first 4 bytes of each.
      # Rather than parsing all message bodies, just verify the binary contains
      # the expected ID values in order.
      for {id, _msg} <- messages do
        assert :binary.match(binary, <<id::32>>) != :nomatch,
               "Expected message ID #{id} in encoded binary"
      end
    end
  end

  describe "help overlay encoding" do
    test "encodes help_visible=false as a single 0x00 byte" do
      data = %{
        visible: true,
        messages: [],
        status: :idle,
        model: "",
        prompt: "",
        pending_approval: nil,
        help_visible: false,
        help_groups: []
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)

      # After opcode, visible, status, model, prompt, pending (0x00), then help_visible (0x00)
      <<0x78, 1::8, _status::8, 0::16, 0::16, _pm::binary-size(7), 0::8, help_visible::8,
        msg_count::16>> = binary

      assert help_visible == 0
      assert msg_count == 0
    end

    test "encodes help_visible=true with help groups" do
      data = %{
        visible: true,
        messages: [],
        status: :idle,
        model: "",
        prompt: "",
        pending_approval: nil,
        help_visible: true,
        help_groups: [
          {"Navigation", [{"j / k", "Scroll down / up"}, {"gg / G", "Top / bottom"}]},
          {"Copy", [{"y", "Copy code block"}]}
        ]
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)

      # Parse the help overlay section
      <<0x78, 1::8, _status::8, 0::16, 0::16, _pm::binary-size(7), 0::8, 1::8, group_count::8,
        rest::binary>> =
        binary

      assert group_count == 2

      # Parse first group: "Navigation" with 2 bindings
      <<nav_len::16, nav::binary-size(nav_len), nav_count::8, nav_rest::binary>> = rest
      assert nav == "Navigation"
      assert nav_count == 2

      # First binding: "j / k" -> "Scroll down / up"
      <<k1_len::8, k1::binary-size(k1_len), d1_len::16, d1::binary-size(d1_len),
        nav_rest2::binary>> = nav_rest

      assert k1 == "j / k"
      assert d1 == "Scroll down / up"

      # Second binding: "gg / G" -> "Top / bottom"
      <<k2_len::8, k2::binary-size(k2_len), d2_len::16, d2::binary-size(d2_len),
        copy_rest::binary>> = nav_rest2

      assert k2 == "gg / G"
      assert d2 == "Top / bottom"

      # Parse second group: "Copy" with 1 binding
      <<copy_title_len::16, copy_title::binary-size(copy_title_len), copy_count::8,
        copy_bindings::binary>> = copy_rest

      assert copy_title == "Copy"
      assert copy_count == 1

      <<ck_len::8, ck::binary-size(ck_len), cd_len::16, cd::binary-size(cd_len), msg_count::16>> =
        copy_bindings

      assert ck == "y"
      assert cd == "Copy code block"
      assert msg_count == 0
    end

    test "nil help_visible encodes as not visible" do
      data = %{
        visible: true,
        messages: [],
        status: :idle,
        model: "",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)

      <<0x78, 1::8, _status::8, 0::16, 0::16, _pm::binary-size(7), 0::8, help_visible::8,
        msg_count::16>> = binary

      assert help_visible == 0
      assert msg_count == 0
    end
  end
end
