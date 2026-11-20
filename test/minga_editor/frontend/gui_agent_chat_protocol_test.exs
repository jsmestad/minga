defmodule MingaEditor.Frontend.GUIAgentChatProtocolTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias MingaAgent.ToolApproval.Target
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Frontend.Protocol

  describe "decode_gui_action for agent_tool_toggle" do
    test "decodes stable message IDs" do
      assert {:ok, {:agent_tool_toggle, 0x01020304}} ==
               ProtocolGUI.decode_gui_action(0x15, <<0x01020304::32>>)

      assert {:ok, {:agent_tool_toggle, 0}} ==
               ProtocolGUI.decode_gui_action(0x15, <<0::32>>)

      assert {:ok, {:agent_tool_toggle, 0xFFFF_FFFF}} ==
               ProtocolGUI.decode_gui_action(0x15, <<0xFFFF_FFFF::32>>)
    end

    test "rejects old and malformed payload sizes" do
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<7::16>>)
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<7>>)
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<>>)
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<1, 2, 3>>)
    end

    test "decodes the full gui_action event with stable message ID" do
      assert {:ok, {:gui_action, {:agent_tool_toggle, 0x01020304}}} ==
               Protocol.decode_event(
                 <<Minga.Protocol.Opcodes.gui_action(), 0x15, 0x01, 0x02, 0x03, 0x04>>
               )
    end
  end

  test "retained output read requires the exact displayed offer and a nonzero tool identity" do
    offer = <<1::128>>

    assert {:ok,
            {:agent_read_retained_output,
             %MingaEditor.Agent.RetainedOutputTarget{offer: ^offer, message_id: 42}}} =
             ProtocolGUI.decode_gui_action(0x6A, <<42::32, offer::binary>>)

    assert :error == ProtocolGUI.decode_gui_action(0x6A, <<0::32, offer::binary>>)
    assert :error == ProtocolGUI.decode_gui_action(0x6A, <<42::32>>)
  end

  test "Stop carries both exact IDs and rejects empty, truncated, and trailing data" do
    target = <<1::16, "s", 2::16, "r2">>

    assert {:ok, {:gui_action, {:agent_stop_turn, {"s", "r2"}}}} =
             Protocol.decode_event(<<Minga.Protocol.Opcodes.gui_action(), 0x6D, target::binary>>)

    for payload <- [
          <<0::16, 1::16, "r">>,
          <<1::16, "s", 0::16>>,
          <<1::16, "s", 2::16, "r">>,
          <<target::binary, 0>>
        ] do
      assert :error = ProtocolGUI.decode_gui_action(0x6D, payload)
    end
  end

  describe "resident approval card to request-bound GUI action" do
    test "each approval decision preserves the exact displayed target" do
      target = Target.new("s", "r", "t")
      prefix = <<1::16, "s", 1::16, "r", 1::16, "t">>

      for {byte, decision} <- [
            {1, :approve},
            {2, :approve_session},
            {3, :approve_turn},
            {4, :reject}
          ] do
        assert {:ok, {:agent_tool_approval, ^target, ^decision}} =
                 ProtocolGUI.decode_gui_action(0x68, <<prefix::binary, byte>>)
      end
    end

    test "empty, truncated, unknown and trailing approval targets produce no operation" do
      prefix = <<1::16, "s", 1::16, "r", 1::16, "t">>

      invalid = [
        <<>>,
        prefix,
        <<prefix::binary, 0>>,
        <<prefix::binary, 5>>,
        <<prefix::binary, 255>>,
        <<0::16, 1::16, "r", 1::16, "t", 1>>,
        <<1::16, "s", 0::16, 1::16, "t", 1>>,
        <<1::16, "s", 1::16, "r", 0::16, 1>>,
        <<2::16, "s">>,
        <<1::16, "s", 2::16, "r">>,
        <<1::16, "s", 1::16, "r", 2::16, "t">>,
        <<prefix::binary, 1, 0>>
      ]

      for payload <- invalid do
        assert :error = ProtocolGUI.decode_gui_action(0x68, payload)
      end
    end

    test "roundtrips long UTF-8 identities, including the string16 byte limit" do
      identities = [
        {
          "session/" <> String.duplicate("会", 2_048),
          "request/" <> String.duplicate("é", 3_072),
          "tool/" <> String.duplicate("🛠", 2_048)
        },
        {
          String.duplicate("界", 21_845),
          String.duplicate("é", 32_767) <> "r",
          String.duplicate("🛠", 16_383) <> "id!"
        }
      ]

      for {session_id, request_id, tool_call_id} <- identities do
        approval = %ApprovalView{
          name: "edit_file",
          summary: "lib/é.ex",
          session_id: session_id,
          request_id: request_id,
          tool_call_id: tool_call_id,
          preview_kind: :diff,
          preview_lines: ["-旧", "+新"]
        }

        body = AgentChatMessageCodec.encode_message_body({:approval_tool_call, approval})

        # Resident cards order tool/session/request; actions order session/request/tool.
        # Lengths count UTF-8 bytes.
        assert <<0x09, 0, 9::16, "edit_file", 9::16, "lib/é.ex", tool_length::16,
                 card_tool::binary-size(tool_length), session_length::16,
                 card_session::binary-size(session_length), request_length::16,
                 card_request::binary-size(request_length), 1, 2::16, 4::16, "-旧", 4::16, "+新">> =
                 body

        assert card_tool == tool_call_id
        assert card_session == session_id
        assert card_request == request_id
        assert tool_length == byte_size(tool_call_id)
        assert session_length == byte_size(session_id)
        assert request_length == byte_size(request_id)

        payload =
          <<session_length::16, card_session::binary, request_length::16, card_request::binary,
            tool_length::16, card_tool::binary, 3>>

        target = Target.new(session_id, request_id, tool_call_id)

        assert {:ok, {:gui_action, {:agent_tool_approval, ^target, :approve_turn}}} =
                 Protocol.decode_event(
                   <<Minga.Protocol.Opcodes.gui_action(), 0x68, payload::binary>>
                 )
      end
    end
  end
end
