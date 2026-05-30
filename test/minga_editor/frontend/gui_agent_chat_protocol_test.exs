defmodule MingaEditor.Frontend.GUIAgentChatProtocolTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  # Extracts a section payload by ID from a sectioned binary.
  # Message sections are normalized to the legacy count + concatenated messages shape.
  defp extract_section(binary, target_id) do
    payload = extract_raw_section(binary, target_id)

    if target_id == 0x06 do
      normalize_messages_payload(payload)
    else
      payload
    end
  end

  defp extract_raw_section(binary, target_id) do
    <<_opcode::8, section_count::8, rest::binary>> = binary
    find_section(rest, section_count, target_id)
  end

  defp find_section(_rest, 0, _target_id), do: nil

  defp find_section(
         <<section_id::8, section_len::16, payload::binary-size(section_len), rest::binary>>,
         remaining,
         target_id
       ) do
    if section_id == target_id do
      payload
    else
      find_section(rest, remaining - 1, target_id)
    end
  end

  defp normalize_messages_payload(<<0xFF::8, 1::8, count::16, frames::binary>>) do
    messages = unwrap_message_frames(frames, count, [])
    IO.iodata_to_binary([<<count::16>> | messages])
  end

  defp normalize_messages_payload(payload), do: payload

  defp unwrap_message_frames(<<>>, 0, acc), do: Enum.reverse(acc)

  defp unwrap_message_frames(
         <<message_len::32, message::binary-size(message_len), rest::binary>>,
         remaining,
         acc
       )
       when remaining > 0 do
    unwrap_message_frames(rest, remaining - 1, [message | acc])
  end

  defp parse_prompt_candidates(<<>>, 0, acc), do: Enum.reverse(acc)

  defp parse_prompt_candidates(
         <<name_len::16, name::binary-size(name_len), desc_len::16, _desc::binary-size(desc_len),
           rest::binary>>,
         remaining,
         acc
       )
       when remaining > 0 do
    parse_prompt_candidates(rest, remaining - 1, [name | acc])
  end

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

  describe "prompt completion encoding" do
    test "encodes all prompt completion candidates" do
      candidates =
        for index <- 1..25 do
          name = "candidate-#{Integer.to_string(index) |> String.pad_leading(2, "0")}."
          {name, "desc #{index}"}
        end

      data = %{
        visible: true,
        messages: [],
        status: :idle,
        model: "test",
        prompt: "",
        prompt_completion: %{
          type: 1,
          selected: 0,
          anchor_line: 0,
          anchor_col: 0,
          candidates: candidates
        },
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)
      completion_payload = extract_section(binary, 0x07)

      <<1::8, _type::8, _selected::8, _line::16, _col::16, count::8, rest::binary>> =
        completion_payload

      assert count == 25
      assert parse_prompt_candidates(rest, count, []) == Enum.map(candidates, &elem(&1, 0))
    end
  end

  describe "encode_gui_agent_chat with styled_tool_call" do
    test "encodes styled_tool_call with sub-opcode 0x08" do
      tc = %MingaAgent.ToolCall{
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

      messages_payload = extract_section(binary, 0x06)
      assert <<1::16, 0::32, msg_payload::binary>> = messages_payload

      <<0x08::8, status_byte::8, error_byte::8, collapsed_byte::8, duration::32, name_len::16,
        name::binary-size(name_len), summary_len::16, summary::binary-size(summary_len),
        line_count::16, run_count::16, text_len::16, text::binary-size(text_len), fg::24, bg::24,
        flags::8, auto_approved_byte::8>> = msg_payload

      assert status_byte == 1
      assert error_byte == 0
      assert collapsed_byte == 0
      assert auto_approved_byte == 0
      assert duration == 1234
      assert name == "bash"
      # No args in test data, so summary is empty
      assert summary == ""
      assert line_count == 1

      # Parse the single line's single run
      assert run_count == 1
      assert text == "hello"
      assert fg == 0xFF0000
      assert bg == 0x000000
      assert flags == 0x01
    end

    test "frames chat messages with deterministic v1 message lengths" do
      data = %{
        visible: true,
        messages: [{1, {:user, "hello"}}, {2, {:assistant, "hi"}}],
        status: :idle,
        model: "test",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)
      messages_payload = extract_raw_section(binary, 0x06)

      assert <<0xFF::8, 1::8, 2::16, first_len::32, first::binary-size(first_len), second_len::32,
               second::binary-size(second_len)>> = messages_payload

      assert <<1::32, 0x01::8, 5::32, "hello">> = first
      assert <<2::32, 0x02::8, 2::32, "hi">> = second
    end

    test "encodes styled assistant link runs with url metadata" do
      styled_lines = [
        [{"docs", 0x61AFEF, 0, 0x0C, "https://example.com/docs"}]
      ]

      data = %{
        visible: true,
        messages: [{:styled_assistant, styled_lines}],
        status: :idle,
        model: "test",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)
      messages_payload = extract_section(binary, 0x06)

      <<1::16, 0::32, 0x07::8, 1::16, 1::16, text_len::16, text::binary-size(text_len), fg::24,
        bg::24, flags::8, url_len::16, url::binary-size(url_len)>> = messages_payload

      assert text == "docs"
      assert fg == 0x61AFEF
      assert bg == 0
      assert Bitwise.band(flags, 0x08) != 0
      assert url == "https://example.com/docs"
    end

    test "masks link flag on styled runs without url metadata" do
      styled_lines = [
        [{"not a link", 0xBBC2CF, 0, 0x08}]
      ]

      data = %{
        visible: true,
        messages: [{:styled_assistant, styled_lines}],
        status: :idle,
        model: "test",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)
      messages_payload = extract_section(binary, 0x06)

      <<1::16, 0::32, 0x07::8, 1::16, 1::16, text_len::16, _text::binary-size(text_len), _fg::24,
        _bg::24, flags::8>> = messages_payload

      assert Bitwise.band(flags, 0x08) == 0
    end

    test "downgrades overlong link urls instead of corrupting styled run framing" do
      for url <- [String.duplicate("a", 65_535), String.duplicate("a", 65_536)] do
        styled_lines = [
          [{"docs", 0x61AFEF, 0, 0x0C, url}]
        ]

        data = %{
          visible: true,
          messages: [{:styled_assistant, styled_lines}],
          status: :idle,
          model: "test",
          prompt: "",
          pending_approval: nil
        }

        binary = ProtocolGUI.encode_gui_agent_chat(data)
        messages_payload = extract_section(binary, 0x06)

        <<1::16, 0::32, 0x07::8, 1::16, 1::16, text_len::16, text::binary-size(text_len), _fg::24,
          _bg::24, flags::8>> = messages_payload

        assert text == "docs"
        assert Bitwise.band(flags, 0x08) == 0
        assert Bitwise.band(flags, 0x04) == 0
      end
    end

    test "truncates oversized plain chat text before section encoding" do
      text = String.duplicate("x", 70_000)

      data = %{
        visible: true,
        messages: [{:assistant, text}],
        status: :idle,
        model: "test",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)
      messages_payload = extract_section(binary, 0x06)

      assert byte_size(messages_payload) <= 65_535

      <<1::16, 0::32, 0x02::8, text_len::32, encoded_text::binary-size(text_len)>> =
        messages_payload

      assert byte_size(encoded_text) == 60_000
      assert String.ends_with?(encoded_text, "… [truncated]")
    end

    test "omits older chat messages instead of overflowing the messages section" do
      text = String.duplicate("x", 70_000)

      data = %{
        visible: true,
        messages: [{1, {:assistant, text}}, {2, {:assistant, text}}],
        status: :idle,
        model: "test",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)
      messages_payload = extract_section(binary, 0x06)

      assert byte_size(messages_payload) <= 65_535

      <<2::16, 0::32, 0x05::8, 0::8, notice_len::32, notice::binary-size(notice_len), 2::32,
        0x02::8, _rest::binary>> = messages_payload

      assert notice =~ "omitted"
    end

    test "encodes regular tool_call with sub-opcode 0x04" do
      tc = %MingaAgent.ToolCall{
        id: "tc-regular",
        name: "read",
        status: :running,
        is_error: false,
        collapsed: true,
        auto_approved_scope: :session,
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
      messages_payload = extract_section(binary, 0x06)

      <<1::16, 0::32, 0x04::8, 0::8, 0::8, 1::8, 0::32, name_len::16, name::binary-size(name_len),
        summary_len::16, summary::binary-size(summary_len), result_len::32,
        result::binary-size(result_len), auto_approved_byte::8>> = messages_payload

      assert name == "read"
      assert summary == ""
      assert result == "file contents"
      assert auto_approved_byte == 1
    end

    test "encodes command approval summaries without the short preview cap" do
      command = String.duplicate("echo long ", 40)
      tc = MingaAgent.ToolCall.new("tc-approval", "shell", %{"command" => command})

      approval =
        MingaAgent.ToolApproval.public(
          MingaAgent.ToolApproval.new(
            tool_call_id: "tc-approval",
            name: "shell",
            args: %{"command" => command}
          )
        )

      data = %{
        visible: true,
        messages: [{:approval_tool_call, tc, approval}],
        status: :tool_executing,
        model: "",
        prompt: "",
        pending_approval: nil
      }

      binary = ProtocolGUI.encode_gui_agent_chat(data)
      messages_payload = extract_section(binary, 0x06)

      <<1::16, 0::32, 0x09::8, 0::8, name_len::16, _name::binary-size(name_len), summary_len::16,
        summary::binary-size(summary_len), _rest::binary>> = messages_payload

      assert summary == command
    end

    test "encodes long multibyte shell summaries within UTF-8 byte limits" do
      command = String.duplicate("🚀", 20_000)
      tc = MingaAgent.ToolCall.new("tc-multi", "shell", %{"command" => command})

      approval =
        MingaAgent.ToolApproval.public(
          MingaAgent.ToolApproval.new(
            tool_call_id: "tc-multi",
            name: "shell",
            args: %{"command" => command}
          )
        )

      tool_binary =
        ProtocolGUI.encode_gui_agent_chat(%{
          visible: true,
          messages: [{:tool_call, tc}],
          status: :idle,
          model: "",
          prompt: "",
          pending_approval: nil
        })

      approval_binary =
        ProtocolGUI.encode_gui_agent_chat(%{
          visible: true,
          messages: [{:approval_tool_call, tc, approval}],
          status: :tool_executing,
          model: "",
          prompt: "",
          pending_approval: nil
        })

      tool_payload = extract_section(tool_binary, 0x06)
      approval_payload = extract_section(approval_binary, 0x06)

      <<1::16, 0::32, 0x04::8, _status::8, _error::8, _collapsed::8, _duration::32, name_len::16,
        _name::binary-size(name_len), tool_summary_len::16,
        tool_summary::binary-size(tool_summary_len), result_len::32,
        _result::binary-size(result_len), _auto::8>> = tool_payload

      assert tool_summary_len <= 65_535
      assert String.valid?(tool_summary)
      assert String.ends_with?(tool_summary, "… [truncated]")

      <<1::16, 0::32, 0x09::8, 0::8, name_len::16, _name::binary-size(name_len),
        approval_summary_len::16, approval_summary::binary-size(approval_summary_len),
        _rest::binary>> = approval_payload

      assert approval_summary_len <= 65_535
      assert String.valid?(approval_summary)
      assert String.ends_with?(approval_summary, "… [truncated]")
    end

    test "encodes long multibyte styled tool summaries within UTF-8 byte limits" do
      command = String.duplicate("🚀", 20_000)

      tc = %MingaAgent.ToolCall{
        id: "tc-styled-multi",
        name: "shell",
        args: %{"command" => command},
        status: :complete,
        is_error: false,
        collapsed: false,
        duration_ms: 42,
        result: "ok"
      }

      styled_lines = [
        [{"result", 0x61AFEF, 0x000000, 0x01}]
      ]

      binary =
        ProtocolGUI.encode_gui_agent_chat(%{
          visible: true,
          messages: [{:styled_tool_call, tc, styled_lines}],
          status: :idle,
          model: "",
          prompt: "",
          pending_approval: nil
        })

      messages_payload = extract_section(binary, 0x06)

      <<1::16, 0::32, 0x08::8, _status::8, _error::8, _collapsed::8, _duration::32, name_len::16,
        _name::binary-size(name_len), summary_len::16, summary::binary-size(summary_len),
        line_count::16, run_count::16, text_len::16, _text::binary-size(text_len), _fg::24,
        _bg::24, _flags::8, _auto_approved::8>> = messages_payload

      assert line_count == 1
      assert run_count == 1
      assert summary_len <= 60_000
      assert String.valid?(summary)
      assert String.ends_with?(summary, "… [truncated]")
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

      # Extract messages section (0x06)
      messages_payload = extract_section(binary, 0x06)
      assert messages_payload != nil
      <<msg_count::16, msg_data::binary>> = messages_payload

      assert msg_count == 2

      # First message: ID=42, type=0x01 (user), text="hello"
      <<42::32, 0x01::8, text_len::32, text::binary-size(text_len), rest::binary>> = msg_data
      assert text == "hello"

      # Second message: ID=99, type=0x02 (assistant), text="hi"
      <<99::32, 0x02::8, text2_len::32, text2::binary-size(text2_len), _::binary>> = rest
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

      messages_payload = extract_section(binary, 0x06)
      <<1::16, msg_data::binary>> = messages_payload

      # ID prefix should be 0 for bare tuples
      <<0::32, 0x01::8, _rest::binary>> = msg_data
    end

    test "all message types carry the ID prefix" do
      tc = %MingaAgent.ToolCall{
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
          %MingaAgent.TurnUsage{input: 10, output: 5, cache_read: 0, cache_write: 0, cost: 0.001}}}
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

      messages_payload = extract_section(binary, 0x06)
      <<msg_count::16, _msg_data::binary>> = messages_payload

      assert msg_count == 6

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

      # Help section (0x05) should contain a single 0x00 byte (not visible)
      help_payload = extract_section(binary, 0x05)
      assert help_payload == <<0x00>>
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

      # Extract help section (0x05) and parse
      help_payload = extract_section(binary, 0x05)
      <<1::8, group_count::8, rest::binary>> = help_payload

      assert group_count == 2

      # Parse first group: "Navigation" with 2 bindings
      <<nav_len::16, nav::binary-size(nav_len), nav_count::8, nav_rest::binary>> = rest
      assert nav == "Navigation"
      assert nav_count == 2

      <<k1_len::8, k1::binary-size(k1_len), d1_len::16, d1::binary-size(d1_len),
        nav_rest2::binary>> = nav_rest

      assert k1 == "j / k"
      assert d1 == "Scroll down / up"

      <<k2_len::8, k2::binary-size(k2_len), d2_len::16, d2::binary-size(d2_len),
        copy_rest::binary>> = nav_rest2

      assert k2 == "gg / G"
      assert d2 == "Top / bottom"

      # Parse second group: "Copy" with 1 binding
      <<copy_title_len::16, copy_title::binary-size(copy_title_len), copy_count::8,
        copy_bindings::binary>> = copy_rest

      assert copy_title == "Copy"
      assert copy_count == 1

      <<ck_len::8, ck::binary-size(ck_len), cd_len::16, cd::binary-size(cd_len)>> =
        copy_bindings

      assert ck == "y"
      assert cd == "Copy code block"
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

      help_payload = extract_section(binary, 0x05)
      assert help_payload == <<0x00>>
    end
  end
end
