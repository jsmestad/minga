defmodule Minga.Port.GUIAgentChatProtocolTest do
  use ExUnit.Case, async: true

  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

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
      tc = %{
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
        name::binary-size(name_len), line_count::16, rest::binary>> = msg_payload

      assert status_byte == 1
      assert error_byte == 0
      assert collapsed_byte == 0
      assert duration == 1234
      assert name == "bash"
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
      tc = %{
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
end
