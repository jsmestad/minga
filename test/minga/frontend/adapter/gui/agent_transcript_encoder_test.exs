defmodule Minga.Frontend.Adapter.GUI.AgentTranscriptEncoderTest do
  # async: false — one test mutates the global :agent_transcript_resident_max_bytes
  # config option and restores it, so it must not race other config readers.
  use ExUnit.Case, async: false

  alias Minga.Config
  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec, as: Codec
  alias Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder, as: Encoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI
  alias Minga.RenderModel.UI.AgentChat

  @op Opcodes.gui_agent_transcript()
  @mode_full_replace 0
  @mode_append 1

  defp model(epoch, messages, overrides \\ []) do
    struct(
      %AgentChat{visible?: true, resident_messages: messages, transcript_epoch: epoch},
      overrides
    )
  end

  defp user(id, text), do: {id, {:user, text}}

  # Decodes one gui_agent_transcript frame into a plain map for assertions.
  defp decode(<<@op, len::32, payload::binary>>) do
    assert byte_size(payload) == len
    <<version::8, mode::8, epoch::32, base::32, count::32, rest::binary>> = payload
    {entries, <<>>} = decode_entries(rest, count, [])
    %{version: version, mode: mode, epoch: epoch, base: base, count: count, entries: entries}
  end

  defp decode_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_entries(<<id::32, blen::32, body::binary-size(blen), rest::binary>>, n, acc) do
    decode_entries(rest, n - 1, [{id, body} | acc])
  end

  describe "encode/2 mode selection" do
    test "first emit is a full_replace carrying every message" do
      messages = [user(1, "a"), user(2, "b"), user(3, "c")]
      {frame, _caches} = Encoder.encode(model(7, messages), Caches.new())

      decoded = decode(frame)
      assert decoded.version == 1
      assert decoded.mode == @mode_full_replace
      assert decoded.epoch == 7
      assert decoded.base == 0
      assert decoded.count == 3
      assert Enum.map(decoded.entries, &elem(&1, 0)) == [1, 2, 3]
    end

    test "round-trips each message body byte-identically with the shared codec" do
      messages = [user(1, "hello"), {2, {:assistant, "world"}}]
      {frame, _} = Encoder.encode(model(1, messages), Caches.new())

      bodies = Enum.map(decode(frame).entries, fn {_id, body} -> body end)

      assert bodies == [
               Codec.encode_message_body({:user, "hello"}),
               Codec.encode_message_body({:assistant, "world"})
             ]
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
      assert decoded.base == 2
      assert decoded.count == 1
      assert Enum.map(decoded.entries, &elem(&1, 0)) == [3]
    end

    test "in-place patch of the streaming last message appends just that message" do
      m1 = [user(1, "a"), {2, {:assistant, "partial"}}]
      {_f, caches} = Encoder.encode(model(1, m1), Caches.new())

      m2 = [user(1, "a"), {2, {:assistant, "partial response"}}]
      {frame, _} = Encoder.encode(model(1, m2), caches)

      decoded = decode(frame)
      assert decoded.mode == @mode_append
      assert decoded.base == 1
      assert Enum.map(decoded.entries, &elem(&1, 0)) == [2]
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

    test "a changed leading message (compaction) forces a full_replace" do
      m1 = [user(1, "a"), user(2, "b"), user(3, "c")]
      {_f, caches} = Encoder.encode(model(1, m1), Caches.new())

      # Same epoch, but the front is dropped: not a pure id-prefix extension.
      m2 = [user(2, "b"), user(3, "c")]
      {frame, _} = Encoder.encode(model(1, m2), caches)

      decoded = decode(frame)
      assert decoded.mode == @mode_full_replace
      assert Enum.map(decoded.entries, &elem(&1, 0)) == [2, 3]
    end
  end

  describe "resident byte cap" do
    test "drops the oldest messages past the cap and sends a full_replace" do
      original = Config.get(:agent_transcript_resident_max_bytes)
      on_exit(fn -> Config.set_option(:agent_transcript_resident_max_bytes, original) end)

      # Each user body is 1 (opcode) + 4 (len) + text bytes; entry wire adds 8.
      big = String.duplicate("x", 200)
      messages = for i <- 1..50, do: user(i, big)

      # Cap that admits only a handful of the most recent messages.
      Config.set_option(:agent_transcript_resident_max_bytes, 1_000)
      {frame, _} = Encoder.encode(model(1, messages), Caches.new())

      decoded = decode(frame)
      assert decoded.mode == @mode_full_replace
      # Only the most recent messages survive the cap, and they are the tail ids.
      ids = Enum.map(decoded.entries, &elem(&1, 0))
      kept = decoded.count
      assert ids != []
      assert kept < 50
      assert ids == Enum.to_list((50 - kept + 1)..50)
    end
  end

  describe "visibility" do
    test "a hidden model emits nil and leaves caches untouched" do
      caches = Caches.new()
      assert {nil, ^caches} = Encoder.encode(%AgentChat{visible?: false}, caches)
    end
  end

  describe "dual-emit through the GUI adapter" do
    test "a visible agent chat emits both the 0x78 chrome and the 0x86 transcript" do
      messages = [user(1, "hi"), {2, {:assistant, "yo"}}]

      ui = %UI{
        agent_chat: model(1, messages, messages: messages)
      }

      {cmds, _caches} = GUI.encode_ui(ui, Caches.new())
      opcodes = Enum.map(cmds, fn <<op, _::binary>> -> op end)

      assert Opcodes.gui_agent_chat() in opcodes
      assert Opcodes.gui_agent_transcript() in opcodes
    end
  end
end
