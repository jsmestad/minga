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

  test "Stop and Continue carry distinct intents and both reject invalid turn identities" do
    target = <<1::16, "s", 2::16, "r2">>

    for {opcode, action} <- [{0x6D, :agent_stop_turn}, {0x75, :agent_continue_turn}] do
      assert {:ok, {:gui_action, {^action, {"s", "r2"}}}} =
               Protocol.decode_event(
                 <<Minga.Protocol.Opcodes.gui_action(), opcode, target::binary>>
               )

      for payload <- [
            <<0::16, 1::16, "r">>,
            <<1::16, "s", 0::16>>,
            <<1::16, "s", 2::16, "r">>,
            <<target::binary, 0>>
          ] do
        assert :error = ProtocolGUI.decode_gui_action(opcode, payload)
      end
    end
  end

  test "queue clicks require the exact conversation and any identities used by the action" do
    target = <<42::32, 1::16, "s">>
    row = <<0x1_0000_0000::64, 2::64>>
    removed = <<3::64, 1::64>>
    absent = <<0::128>>

    for {opcode, action, row_bytes, source_bytes, shown, source} <- [
          {0, :select, row, absent, {0x1_0000_0000, 2}, nil},
          {1, :remove, row, absent, {0x1_0000_0000, 2}, nil},
          {2, :paste_after, row, removed, {0x1_0000_0000, 2}, {3, 1}},
          {3, :paste_before, row, removed, {0x1_0000_0000, 2}, {3, 1}},
          {4, :edit, row, absent, {0x1_0000_0000, 2}, nil},
          {5, :close, absent, absent, nil, nil},
          {6, :composer, absent, absent, nil, nil}
        ] do
      payload = <<opcode, target::binary, row_bytes::binary, source_bytes::binary>>

      assert {:ok, {:agent_queue_action, {42, "s"}, ^action, ^shown, ^source}} =
               ProtocolGUI.decode_gui_action(0x76, payload)
    end

    for payload <- [
          <<2, target::binary, row::binary, absent::binary>>,
          <<1, target::binary, 23::64, 0::64, absent::binary>>,
          <<5, target::binary, row::binary, absent::binary>>,
          <<0, target::binary, row::binary>>,
          <<0, target::binary, row::binary, absent::binary, 1>>,
          <<255, target::binary, row::binary, absent::binary>>
        ] do
      assert :error = ProtocolGUI.decode_gui_action(0x76, payload)
    end
  end

  test "a start remedy click carries only a known remedy" do
    assert {:ok, {:gui_action, {:agent_start_remedy, :retry}}} =
             Protocol.decode_event(<<Minga.Protocol.Opcodes.gui_action(), 0x6F, 1>>)

    assert {:ok, {:agent_start_remedy, :set_up_provider}} =
             ProtocolGUI.decode_gui_action(0x6F, <<2>>)

    for payload <- [<<>>, <<0>>, <<3>>, <<1, 0>>] do
      assert :error = ProtocolGUI.decode_gui_action(0x6F, payload)
    end
  end

  describe "failed-start lifecycle section" do
    alias Minga.Frontend.Adapter.GUI.AgentChatEncoder
    alias Minga.Frontend.Adapter.GUI.Caches
    alias Minga.RenderModel.UI.AgentChat
    alias Minga.RenderModel.UI.AgentChat.StartRemedy

    test "appends the remedy, its label and its key hint after the reason" do
      for {lifecycle, expected} <- [
            {:starting, <<1, 0::16, 0, 0::16, 0::16, 0::16, 0::16>>},
            {:unavailable, <<3, 0::16, 0, 0::16, 0::16, 0::16, 0::16>>},
            {{:failed, "Composer gone.", nil},
             <<2, 14::16, "Composer gone.", 0, 0::16, 0::16, 0::16, 0::16>>},
            {{:failed, "Too slow.", %StartRemedy{kind: :retry, label: "Retry", key_hint: "r"}},
             <<2, 9::16, "Too slow.", 1, 5::16, "Retry", 1::16, "r", 0::16, 0::16>>},
            {{:failed, "No provider.",
              %StartRemedy{kind: :set_up_provider, label: "Set up provider", key_hint: "s"}},
             <<2, 12::16, "No provider.", 2, 15::16, "Set up provider", 1::16, "s", 0::16, 0::16>>}
          ] do
        {binary, _caches} =
          AgentChatEncoder.encode(
            %AgentChat{visible?: true, lifecycle: lifecycle},
            Caches.new()
          )

        assert lifecycle_section(binary) == expected
      end
    end

    test "appends the notice headline and the draft note after the key hint" do
      {binary, _caches} =
        AgentChatEncoder.encode(
          %AgentChat{
            visible?: true,
            lifecycle: {:failed, "Gone.", nil},
            lifecycle_headline: "Agent session stopped",
            draft_note: "Your draft is saved."
          },
          Caches.new()
        )

      assert lifecycle_section(binary) ==
               <<2, 5::16, "Gone.", 0, 0::16, 0::16, 21::16, "Agent session stopped", 20::16,
                 "Your draft is saved.">>
    end

    test "a live conversation sends no lifecycle section" do
      {binary, _caches} =
        AgentChatEncoder.encode(
          %AgentChat{visible?: true, lifecycle: :conversation},
          Caches.new()
        )

      assert lifecycle_section(binary) == nil
    end

    defp lifecycle_section(<<_opcode, count, rest::binary>>), do: find_section(rest, count)

    defp find_section(_rest, 0), do: nil
    defp find_section(<<0x0F, len::16, body::binary-size(len), _::binary>>, _count), do: body

    defp find_section(<<_id, len::16, _body::binary-size(len), rest::binary>>, count),
      do: find_section(rest, count - 1)
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
