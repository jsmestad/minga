defmodule Minga.Frontend.Adapter.GUI.AgentTranscriptEncoderTest do
  # async: false — several tests mutate the global :agent_transcript_resident_max_bytes
  # config option and restore it, so they must not race other config readers.
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

  # A user message whose encoded body is exactly `body_bytes` (>= 5): body is
  # 0x01 + len:u32 + text, so text length = body_bytes - 5. Entry wire size is
  # 8 + body_bytes.
  defp sized(id, body_bytes) when body_bytes >= 5 do
    user(id, String.duplicate("x", body_bytes - 5))
  end

  defp with_cap(bytes, fun) do
    original = Config.get(:agent_transcript_resident_max_bytes)
    Config.set_option(:agent_transcript_resident_max_bytes, bytes)

    try do
      fun.()
    after
      Config.set_option(:agent_transcript_resident_max_bytes, original)
    end
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

  describe "resident byte cap" do
    test "keeps a contiguous most-recent suffix and marks the stream truncated" do
      with_cap(1_000, fn ->
        big = String.duplicate("x", 200)
        messages = for i <- 1..50, do: user(i, big)

        {frame, _} = Encoder.encode(model(1, messages), Caches.new())
        decoded = decode(frame)

        assert decoded.mode == @mode_full_replace
        assert decoded.truncated
        # Contiguous suffix of the tail ids, at least one, fewer than all.
        assert ids(decoded) == Enum.to_list((51 - decoded.count)..50)
        assert decoded.count < 50 and decoded.count > 0
      end)
    end

    test "does not leapfrog a small older message past a large one (no holes)" do
      # cap 1000; entries oldest→newest with a large id2 that must halt eviction.
      # Contiguous suffix keeps [3,4,5]; a buggy non-halting reduce would grab the
      # small id1 back in, producing [1,3,4,5] with a hole where id2 was.
      with_cap(1_000, fn ->
        messages = [
          sized(1, 20),
          sized(2, 300),
          sized(3, 300),
          sized(4, 300),
          sized(5, 300)
        ]

        {frame, _} = Encoder.encode(model(1, messages), Caches.new())
        decoded = decode(frame)

        assert ids(decoded) == [3, 4, 5]
        refute 1 in ids(decoded)
        assert decoded.truncated
      end)
    end

    test "a single message larger than the cap still ships" do
      with_cap(500, fn ->
        messages = [sized(1, 2_000)]
        {frame, _} = Encoder.encode(model(1, messages), Caches.new())
        decoded = decode(frame)

        assert ids(decoded) == [1]
        refute decoded.truncated
      end)
    end

    test "over-cap streaming steady state emits bounded appends, never full_replace" do
      with_cap(1_000, fn ->
        # Each message body 300 bytes (wire 308); ~3 fit under 1000. Grow the
        # transcript one message at a time and encode each frame in sequence.
        frames =
          Enum.reduce(1..8, {Caches.new(), []}, fn n, {caches, acc} ->
            messages = for i <- 1..n, do: sized(i, 300)
            {frame, caches2} = Encoder.encode(model(1, messages), caches)
            {caches2, [frame | acc]}
          end)
          |> elem(1)
          |> Enum.reverse()

        [first | rest] = frames

        # First frame is the initial full_replace; every later frame is an append.
        assert decode(first).mode == @mode_full_replace

        assert Enum.all?(rest, fn f -> decode(f).mode == @mode_append end),
               "over-cap streaming must not degrade to full_replace"

        # Once the window is full, appends carry a nonzero trim_front (eviction).
        assert Enum.any?(rest, fn f -> decode(f).trim_front > 0 end)

        # Each delta frame stays bounded (a handful of entries, well under the cap).
        assert Enum.all?(rest, fn f -> byte_size(f) < 1_000 end)
      end)
    end
  end

  describe "duplicate ids" do
    test "deduplicates by id last-wins, preserving order" do
      messages = [
        {1, {:user, "a"}},
        {2, {:user, "b"}},
        {1, {:user, "c"}}
      ]

      {frame, _} = Encoder.encode(model(1, messages), Caches.new())
      decoded = decode(frame)

      # id 1's earlier occurrence is dropped; the last one ("c") survives at its
      # position, so order is [2, 1].
      assert ids(decoded) == [2, 1]
      assert decoded.count == 2

      assert [_first, {1, body}] = decoded.entries
      assert body == Codec.encode_message_body({:user, "c"})
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
