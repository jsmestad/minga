defmodule Minga.Frontend.Adapter.GUI.AgentTranscriptEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec, as: Codec
  alias Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder, as: Encoder
  alias Minga.Frontend.Adapter.GUI.AgentTranscriptSentState
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI
  alias Minga.RenderModel.UI.AgentChat

  @op Opcodes.gui_agent_transcript()
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.MarkdownBlock
  alias Minga.RenderModel.UI.AgentChat.ToolCallView
  alias Minga.RenderModel.UI.AgentChat.Usage
  @mode_full_replace 0
  @mode_append 1

  defp model(epoch, messages, overrides \\ []) do
    struct(
      %AgentChat{visible?: true, resident_messages: messages, transcript_epoch: epoch},
      overrides
    )
  end

  defp user(id, text), do: {id, {:user, text}}

  # A user message whose encoded body is exactly `body_bytes` (>= 5): body is
  # 0x01 + len:u32 + text, so text length = body_bytes - 5. Entry wire size is
  # 8 + body_bytes.
  defp sized(id, body_bytes) when body_bytes >= 5 do
    user(id, String.duplicate("x", body_bytes - 5))
  end

  # Decodes one gui_agent_transcript frame into a plain map for assertions.
  defp decode(<<@op, len::32, payload::binary>>) do
    assert byte_size(payload) == len
    <<version::8, mode::8, epoch::32, truncated::8, rest::binary>> = payload
    decode_mode(%{version: version, mode: mode, epoch: epoch, truncated: truncated == 1}, rest)
  end

  defp decode_mode(%{mode: @mode_full_replace} = acc, <<count::32, rest::binary>>) do
    {entries, <<>>} = decode_entries(rest, count, [])
    Map.merge(acc, %{trim_front: 0, base: 0, count: count, entries: entries})
  end

  defp decode_mode(%{mode: @mode_append} = acc, <<trim::32, base::32, count::32, rest::binary>>) do
    {entries, <<>>} = decode_entries(rest, count, [])
    Map.merge(acc, %{trim_front: trim, base: base, count: count, entries: entries})
  end

  defp decode_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_entries(<<id::32, blen::32, body::binary-size(blen), rest::binary>>, n, acc) do
    decode_entries(rest, n - 1, [{id, body} | acc])
  end

  defp ids(decoded), do: Enum.map(decoded.entries, &elem(&1, 0))

  defp section(<<op, count::8, sections::binary>>, target_id) do
    find_section(sections, count, target_id, op)
  end

  defp find_section(
         <<target_id::8, len::16, payload::binary-size(len), _rest::binary>>,
         _remaining,
         target_id,
         _op
       ),
       do: payload

  defp find_section(
         <<_id::8, len::16, _payload::binary-size(len), rest::binary>>,
         remaining,
         target_id,
         op
       )
       when remaining > 0,
       do: find_section(rest, remaining - 1, target_id, op)

  defp find_section(<<>>, _remaining, _target_id, _op), do: nil

  describe "encode/2 mode selection" do
    test "first emit is a full_replace carrying every message" do
      messages = [user(1, "a"), user(2, "b"), user(3, "c")]
      {frame, _caches} = Encoder.encode(model(7, messages), Caches.new())

      decoded = decode(frame)
      assert decoded.version == 1
      assert decoded.mode == @mode_full_replace
      assert decoded.epoch == 7
      refute decoded.truncated
      assert decoded.count == 3
      assert ids(decoded) == [1, 2, 3]
    end

    test "round-trips message bodies at the 0x86 boundary" do
      messages = [user(1, "hello"), {2, {:assistant, "world"}}]
      {frame, _} = Encoder.encode(model(1, messages), Caches.new())

      bodies = Enum.map(decode(frame).entries, fn {_id, body} -> body end)

      assert bodies == [
               <<0x01, 5::32, "hello">>,
               <<0x02, 5::32, "world">>
             ]
    end

    test "keeps bare ID0 and elides user attachments at the 0x86 boundary" do
      messages = [{:user, "hi", [%{name: "ignored"}]}]
      {frame, _} = Encoder.encode(model(1, messages), Caches.new())

      assert [{0, <<0x01, 2::32, "hi">>}] = decode(frame).entries
    end

    test "encodes every live body kind with retained kind bytes and key fields" do
      tool = %ToolCallView{
        name: "read",
        summary: "lib.ex",
        status: :running,
        result: "ok",
        collapsed: true,
        auto_approved_scope: :session,
        preview_kind: :target,
        preview_lines: ["lib.ex"]
      }

      approval = %ApprovalView{
        name: "edit",
        summary: "demo.ex",
        tool_call_id: "tc",
        preview_kind: :diff,
        preview_lines: ["+new"]
      }

      usage = %Usage{input: 10, output: 20, cache_read: 3, cache_write: 4, cost: 0.0005}
      styled = [[{"docs", 0x61AFFE, 0, 0x08, "https://example.com"}]]

      block = %MarkdownBlock{
        kind: :code_block,
        id: 7,
        lines: styled,
        flags: 1,
        language: "elixir",
        label: "Elixir",
        target_path: "lib.ex"
      }

      messages = [
        {1, {:thinking, "thinking", true}},
        {2, {:system, "oops", :error}},
        {3, {:usage, usage}},
        {4, {:tool_call, tool}},
        {5, {:approval_tool_call, approval}},
        {6, {:styled_tool_call, tool, styled}},
        {7, {:styled_assistant, styled}},
        {8, {:assistant_markdown, [block]}}
      ]

      {frame, _} = Encoder.encode(model(1, messages), Caches.new())
      bodies = for {_id, body} <- decode(frame).entries, do: body

      assert Enum.map(bodies, &:binary.first/1) == [
               0x03,
               0x05,
               0x06,
               0x04,
               0x09,
               0x08,
               0x07,
               0x0A
             ]

      assert Enum.at(bodies, 0) == <<0x03, 1, 8::32, "thinking">>
      assert Enum.at(bodies, 1) == <<0x05, 1, 4::32, "oops">>
      assert Enum.at(bodies, 2) == <<0x06, 10::32, 20::32, 3::32, 4::32, 500::32>>
      assert Enum.at(bodies, 3) =~ "read"
      assert Enum.at(bodies, 4) =~ "tc"
      assert Enum.at(bodies, 5) =~ "lib.ex"
      assert Enum.at(bodies, 6) =~ "https://example.com"
      assert Enum.at(bodies, 7) =~ "elixir"
    end

    test "direct codec preserves exact tool, approval, styled, markdown, and bounds contracts" do
      tool = %ToolCallView{
        name: "read",
        summary: "lib.ex",
        status: :error,
        is_error: true,
        collapsed: false,
        duration_ms: 42,
        result: "ok",
        auto_approved_scope: :turn,
        preview_kind: :diff,
        preview_lines: ["-old", "+new"]
      }

      approval = %ApprovalView{
        name: "edit",
        summary: "demo.ex",
        tool_call_id: "tc",
        preview_kind: :command,
        preview_lines: ["mix test"]
      }

      linked = {"docs", 0x61AFFE, 0, 0, "https://example.com"}
      plain = {"plain", 0x61AFFE, 0, 0x08}

      block = %MarkdownBlock{
        kind: :code_block,
        id: 7,
        flags: 1,
        lines: [[linked]],
        language: "elixir",
        label: "Elixir",
        target_path: "lib.ex",
        capability_flags: 1
      }

      assert <<0x01, 2::32, "hi">> =
               Codec.encode_message_body({:user, "hi", [%{name: "ignored"}]})

      assert <<0x02, 5::32, "hello">> = Codec.encode_message_body({:assistant, "hello"})

      assert <<0x03, 1, 8::32, "thinking">> =
               Codec.encode_message_body({:thinking, "thinking", true})

      assert <<0x05, 1, 4::32, "oops">> = Codec.encode_message_body({:system, "oops", :error})

      assert <<0x06, 10::32, 20::32, 3::32, 4::32, 500::32>> =
               Codec.encode_message_body(
                 {:usage,
                  %Usage{input: 10, output: 20, cache_read: 3, cache_write: 4, cost: 0.0005}}
               )

      assert <<0x04, 2, 1, 0, 42::32, 4::16, "read", 6::16, "lib.ex", 2::32, "ok", 2, 1, 2::16,
               4::16, "-old", 4::16, "+new">> = Codec.encode_message_body({:tool_call, tool})

      assert <<0x08, 2, 1, 0, 42::32, 4::16, "read", 6::16, "lib.ex", 1::16, 1::16, 4::16, "docs",
               _sfg::24, _sbg::24, styled_flags, 19::16, "https://example.com", 2, 1, 2::16,
               4::16, "-old", 4::16, "+new">> =
               Codec.encode_message_body({:styled_tool_call, tool, [[linked]]})

      assert Bitwise.band(styled_flags, 0x08) == 0x08

      assert <<0x09, 0, 4::16, "edit", 7::16, "demo.ex", 2::16, "tc", 2, 1::16, 8::16,
               "mix test">> = Codec.encode_message_body({:approval_tool_call, approval})

      assert <<0x07, 1::16, 2::16, 4::16, "docs", _fg::24, _bg::24, linked_flags, 19::16,
               "https://example.com", 5::16, "plain", _fg2::24, _bg2::24, plain_flags>> =
               Codec.encode_message_body({:styled_assistant, [[linked, plain]]})

      assert Bitwise.band(linked_flags, 0x08) == 0x08
      assert Bitwise.band(plain_flags, 0x08) == 0

      assert <<0x0A, 1::16, 7::32, 0x07, 1, 6::16, "elixir", 6::16, "Elixir", 6::16, "lib.ex", 1,
               _::binary>> = Codec.encode_message_body({:assistant_markdown, [block]})
    end

    test "direct codec reports exact EncodingError fields for retained bounds" do
      assert %{command: :gui_agent_chat_message, field: :run_flags, actual: 256, min: 0, max: 255} =
               assert_raise(EncodingError, fn ->
                 Codec.encode_message_body({:styled_assistant, [[{"bad", 0, 0, 256}]]})
               end)

      assert %{
               command: :gui_agent_chat_message,
               field: :run_url,
               actual: 65_536,
               min: 0,
               max: 65_535
             } =
               assert_raise(EncodingError, fn ->
                 Codec.encode_message_body(
                   {:styled_assistant, [[{"bad", 0, 0, 0, String.duplicate("u", 65_536)}]]}
                 )
               end)

      tool = %ToolCallView{name: "shell", summary: String.duplicate("é", 40_000)}

      assert %{
               command: :gui_agent_chat_message,
               field: :summary,
               actual: 80_000,
               min: 0,
               max: 65_535
             } =
               assert_raise(EncodingError, fn -> Codec.encode_message_body({:tool_call, tool}) end)
    end

    test "no change between frames emits nil" do
      messages = [user(1, "a"), user(2, "b")]
      {_frame, caches} = Encoder.encode(model(1, messages), Caches.new())
      assert {nil, ^caches} = Encoder.encode(model(1, messages), caches)
    end

    test "appending a new message emits an append of only the new suffix" do
      m1 = [user(1, "a"), user(2, "b")]
      {_f, caches} = Encoder.encode(model(1, m1), Caches.new())

      m2 = [user(1, "a"), user(2, "b"), user(3, "c")]
      {frame, _} = Encoder.encode(model(1, m2), caches)

      decoded = decode(frame)
      assert decoded.mode == @mode_append
      assert decoded.trim_front == 0
      assert decoded.base == 2
      assert decoded.count == 1
      assert ids(decoded) == [3]
    end

    test "in-place patch of the streaming last message appends just that message" do
      m1 = [user(1, "a"), {2, {:assistant, "partial"}}]
      {_f, caches} = Encoder.encode(model(1, m1), Caches.new())

      m2 = [user(1, "a"), {2, {:assistant, "partial response"}}]
      {frame, _} = Encoder.encode(model(1, m2), caches)

      decoded = decode(frame)
      assert decoded.mode == @mode_append
      assert decoded.trim_front == 0
      assert decoded.base == 1
      assert ids(decoded) == [2]
    end

    test "epoch flip forces a full_replace even when messages are unchanged" do
      messages = [user(1, "a"), user(2, "b")]
      {_f, caches} = Encoder.encode(model(1, messages), Caches.new())

      {frame, _} = Encoder.encode(model(2, messages), caches)
      decoded = decode(frame)
      assert decoded.mode == @mode_full_replace
      assert decoded.epoch == 2
      assert decoded.count == 2
    end

    test "epoch stays stable across streaming, so deltas stay appends (never full_replace)" do
      m1 = [user(1, "a"), {2, {:assistant, "p"}}]
      {_f, c1} = Encoder.encode(model(9, m1), Caches.new())

      m2 = [user(1, "a"), {2, {:assistant, "pa"}}]
      {f2, c2} = Encoder.encode(model(9, m2), c1)

      m3 = [user(1, "a"), {2, {:assistant, "par"}}, user(3, "next")]
      {f3, _c3} = Encoder.encode(model(9, m3), c2)

      assert decode(f2).mode == @mode_append
      assert decode(f3).mode == @mode_append
    end

    test "rejects an out-of-range transcript epoch with command metadata" do
      error =
        assert_raise EncodingError, fn ->
          Encoder.encode(model(4_294_967_296, [user(1, "a")]), Caches.new())
        end

      assert %{
               command: :gui_agent_transcript,
               field: :epoch,
               actual: 4_294_967_296,
               min: 0,
               max: 4_294_967_295
             } = error
    end

    test "rejects an out-of-range resident message id" do
      error =
        assert_raise EncodingError, fn ->
          Encoder.encode(model(1, [user(4_294_967_296, "a")]), Caches.new())
        end

      assert %{
               command: :gui_agent_transcript,
               field: :message_id,
               actual: 4_294_967_296,
               min: 0,
               max: 4_294_967_295
             } = error
    end

    test "a changed leading message (compaction) forces a full_replace" do
      m1 = [user(1, "a"), user(2, "b"), user(3, "c")]
      {_f, caches} = Encoder.encode(model(1, m1), Caches.new())

      # Same epoch, but the front id changes and is absent from the prior keys:
      # a non-prefix divergence, not a cap eviction.
      m2 = [user(9, "x"), user(2, "b"), user(3, "c")]
      {frame, _} = Encoder.encode(model(1, m2), caches)

      decoded = decode(frame)
      assert decoded.mode == @mode_full_replace
      assert ids(decoded) == [9, 2, 3]
    end
  end

  describe "resident selection" do
    test "encodes every resident message without selecting a suffix" do
      messages = for i <- 1..50, do: sized(i, 300)

      {frame, _} = Encoder.encode(model(1, messages), Caches.new())
      decoded = decode(frame)

      assert decoded.mode == @mode_full_replace
      refute decoded.truncated
      assert decoded.count == 50
      assert ids(decoded) == Enum.to_list(1..50)
    end

    test "serializes the model-owned resident truncation flag without selecting a suffix" do
      messages = [user(2, "newest"), user(3, "latest")]
      {frame, _} = Encoder.encode(model(1, messages, resident_truncated?: true), Caches.new())

      assert decode(frame).truncated
      assert ids(decode(frame)) == [2, 3]
    end

    test "emits an append when only the model-owned truncation flag changes" do
      messages = [user(1, "one"), user(2, "two")]
      {_frame, caches} = Encoder.encode(model(1, messages), Caches.new())
      {frame, _} = Encoder.encode(model(1, messages, resident_truncated?: true), caches)
      decoded = decode(frame)

      assert decoded.mode == @mode_append
      assert decoded.base == 2
      assert decoded.count == 0
      assert decoded.truncated
    end

    test "sets truncated on an append after the semantic resident suffix evicts older messages" do
      initial = [user(1, "one"), user(2, "two"), user(3, "three"), user(4, "four")]
      {_frame, caches} = Encoder.encode(model(1, initial), Caches.new())

      suffix = [user(3, "three"), user(4, "four"), user(5, "five"), user(6, "six")]
      {frame, _} = Encoder.encode(model(1, suffix, resident_truncated?: true), caches)
      decoded = decode(frame)

      assert decoded.mode == @mode_append
      assert decoded.trim_front == 2
      assert decoded.base == 2
      assert decoded.truncated
      assert ids(decoded) == [5, 6]
    end
  end

  describe "duplicate ids" do
    test "rejects duplicate ids instead of silently dropping entries" do
      messages = [
        {1, {:user, "a"}},
        {2, {:user, "b"}},
        {1, {:user, "c"}}
      ]

      error =
        assert_raise EncodingError, fn ->
          Encoder.encode(model(1, messages), Caches.new())
        end

      assert %{
               command: :gui_agent_transcript,
               field: :message_id_occurrences,
               actual: 2,
               min: 0,
               max: 1
             } = error
    end
  end

  describe "visibility" do
    test "a hidden model emits nil and resets the transcript delta base" do
      messages = [user(1, "a"), user(2, "b")]
      {_frame, caches} = Encoder.encode(model(1, messages), Caches.new())
      refute caches.last_agent_transcript == %AgentTranscriptSentState{}

      assert {nil, reset} = Encoder.encode(%AgentChat{visible?: false}, caches)
      assert reset.last_agent_transcript == %AgentTranscriptSentState{}
    end

    test "reopening the panel re-emits a full_replace for an unchanged transcript" do
      # The frontend clears its local transcript on hide, so a reopen with the
      # same transcript must resend everything rather than be suppressed by an
      # unchanged fingerprint.
      messages = [user(1, "a"), user(2, "b")]
      {_f1, c1} = Encoder.encode(model(1, messages), Caches.new())
      {nil, c2} = Encoder.encode(%AgentChat{visible?: false}, c1)
      {frame, _c3} = Encoder.encode(model(1, messages), c2)

      decoded = decode(frame)
      assert decoded.mode == @mode_full_replace
      assert ids(decoded) == [1, 2]
    end
  end

  describe "dual-emit through the GUI adapter" do
    test "a visible agent chat emits both the 0x78 chrome and the 0x86 transcript" do
      messages = [user(1, "hi"), {2, {:assistant, "yo"}}]

      ui = %UI{
        agent_chat: model(1, messages)
      }

      {cmds, _caches} = GUI.encode_ui(ui, Caches.new())
      opcodes = Enum.map(cmds, fn <<op, _::binary>> -> op end)
      chat = Enum.find(cmds, fn <<op, _::binary>> -> op == Opcodes.gui_agent_chat() end)

      transcript =
        Enum.find(cmds, fn <<op, _::binary>> -> op == Opcodes.gui_agent_transcript() end)

      assert Opcodes.gui_agent_chat() in opcodes
      assert Opcodes.gui_agent_transcript() in opcodes
      assert section(chat, 0x06) == nil
      assert ids(decode(transcript)) == [1, 2]
    end
  end
end
