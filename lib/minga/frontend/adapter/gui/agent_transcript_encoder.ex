defmodule Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder do
  @moduledoc """
  Pure GUI adapter encoder for the resident agent-chat transcript stream
  (`gui_agent_transcript`, 0x86).

  Carries the full, un-windowed conversation so a frontend can scroll the whole
  session from local data without a BEAM round-trip (#2654), decoupled from the
  small `gui_agent_chat` (0x78) chrome model whose u16 sectioned frame capped the
  transcript at ~65 KB. Reuses the shared per-message body codec
  (`Minga.Frontend.Adapter.GUI.AgentChatMessageCodec`) so a message encodes
  byte-identically on both transports.

  Adopts the #2652 resident-store lifecycle: full store replace only on
  structural change (`transcript_epoch` flip, or a divergence that is not a pure
  id-prefix extension, e.g. compaction/truncation), and id-keyed append/upsert
  deltas within an epoch for streaming growth and the last-message patch. State
  for the delta base lives in `Minga.Frontend.Adapter.GUI.Caches`
  (`last_agent_transcript_epoch`, `last_agent_transcript_keys`), never on the
  BEAM editor state.

  Wire payload (after the len32 opcode + u32 length framing):

      version:u8 = 1
      mode:u8            # 0 = full_replace, 1 = append
      epoch:u32
      base_count:u32     # append: resident count the suffix extends; full_replace: 0
      count:u32
      count * [ id:u32, body_len:u32, body:bytes ]

  `body` is the shared `AgentChatMessageCodec` message body. On `append` the
  frontend upserts each `id` (new message, or in-place patch of the streaming
  last message) after asserting its resident count equals `base_count`; a
  mismatch means a dropped frame and the frontend requests / waits for the next
  `full_replace`.
  """

  alias Minga.Config
  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec, as: Codec
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentChat

  @op_gui_agent_transcript Opcodes.gui_agent_transcript()

  @version 1
  @mode_full_replace 0
  @mode_append 1

  # Fallback cap when config is unavailable; mirrors the option default.
  @default_resident_max_bytes 8_388_608

  @typep entry :: {non_neg_integer(), binary()}
  @typep key :: {non_neg_integer(), non_neg_integer()}

  @spec encode(AgentChat.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%AgentChat{visible?: false}, %Caches{} = caches), do: {nil, caches}

  def encode(%AgentChat{visible?: true} = model, %Caches{} = caches) do
    epoch = model.transcript_epoch
    messages = model.resident_messages
    fp = :erlang.phash2({epoch, messages})

    if fp == caches.last_agent_transcript_fp do
      {nil, caches}
    else
      encode_changed(epoch, messages, fp, caches)
    end
  end

  @spec encode_changed(non_neg_integer(), [AgentChat.message()], integer(), Caches.t()) ::
          {binary() | nil, Caches.t()}
  defp encode_changed(epoch, messages, fp, %Caches{} = caches) do
    prev_epoch = caches.last_agent_transcript_epoch
    prev_keys = caches.last_agent_transcript_keys

    entries = messages |> Enum.map(&message_entry/1) |> cap_to_resident_bytes()
    keys = Enum.map(entries, &entry_key/1)

    new_caches = %{
      caches
      | last_agent_transcript_fp: fp,
        last_agent_transcript_epoch: epoch,
        last_agent_transcript_keys: keys
    }

    case select_delta(prev_epoch, prev_keys, epoch, keys, entries) do
      :nothing ->
        {nil, new_caches}

      {mode, base, out_entries} ->
        {build_frame(mode, epoch, base, out_entries), new_caches}
    end
  end

  # Full store replace on structural change (epoch flip) or any divergence that is
  # not a pure id-prefix extension (compaction, truncation, resident-cap drop from
  # the front). Otherwise an id-keyed append/upsert of the changed suffix: the
  # strict-equal prefix stays put, everything past it is (re)sent, which covers
  # both new messages and the in-place patch of the streaming last message.
  @spec select_delta(
          non_neg_integer() | nil,
          [key()],
          non_neg_integer(),
          [key()],
          [entry()]
        ) :: :nothing | {non_neg_integer(), non_neg_integer(), [entry()]}
  defp select_delta(prev_epoch, _prev_keys, epoch, _keys, entries) when epoch != prev_epoch do
    {@mode_full_replace, 0, entries}
  end

  defp select_delta(_prev_epoch, prev_keys, _epoch, keys, entries) do
    if id_prefix?(prev_keys, keys) do
      base = strict_prefix_len(prev_keys, keys)

      case Enum.drop(entries, base) do
        [] -> :nothing
        out -> {@mode_append, base, out}
      end
    else
      {@mode_full_replace, 0, entries}
    end
  end

  # True when `current` extends `previous` by message id: it is at least as long
  # and every id over the previous range matches positionally. Hashes may differ
  # (the last message streams in place), so this compares ids only.
  @spec id_prefix?([key()], [key()]) :: boolean()
  defp id_prefix?(previous, current) do
    length(current) >= length(previous) and
      current
      |> Enum.zip(previous)
      |> Enum.all?(fn {{cur_id, _}, {prev_id, _}} -> cur_id == prev_id end)
  end

  # Number of leading entries identical in both id and content hash.
  @spec strict_prefix_len([key()], [key()]) :: non_neg_integer()
  defp strict_prefix_len(previous, current) do
    previous
    |> Enum.zip(current)
    |> Enum.take_while(fn {p, c} -> p == c end)
    |> length()
  end

  @spec build_frame(non_neg_integer(), non_neg_integer(), non_neg_integer(), [entry()]) ::
          binary()
  defp build_frame(mode, epoch, base, entries) do
    body =
      Enum.map(entries, fn {id, body_bin} ->
        <<id::32, byte_size(body_bin)::32, body_bin::binary>>
      end)

    payload =
      IO.iodata_to_binary([
        <<@version::8, mode::8, epoch::32, base::32, Enum.count(entries)::32>>
        | body
      ])

    <<@op_gui_agent_transcript, byte_size(payload)::32, payload::binary>>
  end

  # ── Message entries ──

  @spec message_entry(AgentChat.message()) :: entry()
  defp message_entry(message) do
    bounded = Codec.bound_message_text(message)
    {Codec.message_id(bounded), Codec.encode_message_body(message_body(bounded))}
  end

  @spec message_body(AgentChat.message()) :: AgentChat.message_body()
  defp message_body({id, body}) when is_integer(id), do: body
  defp message_body(body), do: body

  @spec entry_key(entry()) :: key()
  defp entry_key({id, body_bin}), do: {id, :erlang.phash2(body_bin)}

  # Keep the most recent messages whose cumulative wire size fits the resident
  # byte cap. Dropping from the front shifts the resident head, which the delta
  # selector detects as a non-prefix divergence and resends as full_replace.
  @spec cap_to_resident_bytes([entry()]) :: [entry()]
  defp cap_to_resident_bytes(entries) do
    cap = resident_max_bytes()

    {kept, _used} =
      entries
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn {_id, body_bin} = e, {acc, used} ->
        size = 8 + byte_size(body_bin)
        next = used + size

        keep_entry(acc, e, next, used, cap)
      end)

    kept
  end

  # The newest entry is always kept (a single oversized message must still
  # ship); older entries accumulate until the resident byte cap is reached.
  @spec keep_entry([entry()], entry(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {[entry()], non_neg_integer()}
  defp keep_entry([], entry, next, _used, _cap), do: {[entry], next}
  defp keep_entry(acc, entry, next, _used, cap) when next <= cap, do: {[entry | acc], next}
  defp keep_entry(acc, _entry, _next, used, _cap), do: {acc, used}

  @spec resident_max_bytes() :: pos_integer()
  defp resident_max_bytes do
    case Config.get(:agent_transcript_resident_max_bytes) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_resident_max_bytes
    end
  catch
    :exit, _ -> @default_resident_max_bytes
  end
end
