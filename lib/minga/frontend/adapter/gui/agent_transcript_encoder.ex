defmodule Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder do
  @moduledoc """
  Pure GUI adapter encoder for the resident agent-chat transcript stream
  (`gui_agent_transcript`, 0x86).

  Carries the resident transcript so a frontend can scroll the session from local
  data without a BEAM round-trip (#2654), decoupled from the small
  `gui_agent_chat` (0x78) chrome model whose u16 sectioned frame capped the
  transcript at ~65 KB. The resident set is the conversation **bounded by
  `:agent_transcript_resident_max_bytes` (a contiguous most-recent suffix) and
  scoped by `display_start_index`** — not necessarily the whole history. The
  `truncated` header flag tells the frontend when older messages sit outside the
  resident window. Reuses the shared per-message body codec
  (`Minga.Frontend.Adapter.GUI.AgentChatMessageCodec`) so a message encodes
  byte-identically on both transports.

  Adopts the #2652 resident-store lifecycle: a full store replace only on genuine
  structural change (`transcript_epoch` flip or a non-prefix divergence such as
  compaction), and id-keyed append/upsert deltas within an epoch for streaming
  growth, the in-place last-message patch, and cap eviction. Cap eviction never
  degrades to full_replace-per-frame: the append delta carries `trim_front`, the
  number of already-evicted leading messages, so over-cap streaming stays bounded
  and incremental. State for the delta base lives in a
  `Minga.Frontend.Adapter.GUI.AgentTranscriptSentState` inside
  `Minga.Frontend.Adapter.GUI.Caches`, never on the BEAM editor state.

  ## Wire payload (after the len32 opcode + u32 length framing)

      version:u8 = 1
      mode:u8            # 0 = full_replace, 1 = append
      epoch:u32
      truncated:u8       # 1 when older messages sit outside the resident window
      # full_replace (mode 0):
      count:u32
      # append (mode 1):
      trim_front:u32     # leading messages evicted from the store front this delta
      base_count:u32     # unchanged leading messages of the remainder to keep
      count:u32
      # both modes:
      count * [ id:u32, body_len:u32, body:bytes ]

  `body` is the shared `AgentChatMessageCodec` message body.

  ## Decoder contract

  - `full_replace`: clear the store, then set it to the `count` entries in order.
  - `append`: drop `trim_front` messages from the **front** of the store; of the
    remainder, keep the first `base_count` messages unchanged; then upsert each of
    the `count` entries by `id` (a new message appends, a matching `id` patches
    the streaming last message in place). `base_count` is the count of unchanged
    leading messages of the remainder — keep `[0, base_count)` and upsert entries
    from there. It is **not** the client's resident count; it is strictly `<= the
    remainder length` and is normally less than the resident count on every
    streaming patch. Desync (drop and await the next `full_replace`) is only
    warranted when the store's resident count is **less than** `trim_front +
    base_count`, i.e. the delta cannot be applied against what the store holds.
  """

  alias Minga.Config
  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec, as: Codec
  alias Minga.Frontend.Adapter.GUI.AgentTranscriptSentState, as: SentState
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentChat

  @op_gui_agent_transcript Opcodes.gui_agent_transcript()

  @version 1
  @mode_full_replace 0
  @mode_append 1

  # Fallback cap when config is unavailable; mirrors the option default.
  @default_resident_max_bytes 8_388_608

  # Per-entry wire overhead: id:u32 + body_len:u32.
  @entry_overhead 8

  @typep entry :: {non_neg_integer(), binary()}
  @typep key :: SentState.key()
  @typep delta ::
           :nothing
           | {:full_replace, [entry()]}
           | {:append, non_neg_integer(), non_neg_integer(), [entry()]}

  @spec encode(AgentChat.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  # When the panel hides, reset the delta base. A frontend clears its local
  # transcript on the 0x78 hide signal, so on reopen the store is empty; without
  # this reset an unchanged transcript keeps the same fingerprint and no frame is
  # sent, leaving the reopened panel blank. Clearing the cache forces the next
  # visible frame to re-emit a full_replace (mirrors the 0x78 encoder, whose
  # fingerprint includes visibility).
  def encode(%AgentChat{visible?: false}, %Caches{} = caches),
    do: {nil, %{caches | last_agent_transcript: %SentState{}}}

  def encode(%AgentChat{visible?: true} = model, %Caches{} = caches) do
    epoch = model.transcript_epoch
    messages = model.resident_messages
    fp = :erlang.phash2({epoch, messages})

    if fp == caches.last_agent_transcript.fp do
      {nil, caches}
    else
      encode_changed(epoch, messages, fp, caches)
    end
  end

  @spec encode_changed(non_neg_integer(), [AgentChat.message()], integer(), Caches.t()) ::
          {binary() | nil, Caches.t()}
  defp encode_changed(epoch, messages, fp, %Caches{} = caches) do
    prev = caches.last_agent_transcript

    full_entries = messages |> Enum.map(&message_entry/1) |> dedupe_last_wins()
    {entries, dropped} = cap_to_resident_bytes(full_entries)
    truncated? = dropped > 0
    keys = Enum.map(entries, &entry_key/1)

    new_caches = %{caches | last_agent_transcript: %SentState{fp: fp, epoch: epoch, keys: keys}}

    case select_delta(prev.epoch, prev.keys, epoch, keys, entries) do
      :nothing ->
        {nil, new_caches}

      {:full_replace, out} ->
        {build_full_replace(epoch, truncated?, out), new_caches}

      {:append, trim_front, base_count, out} ->
        log_eviction(trim_front, length(entries), dropped)
        {build_append(epoch, truncated?, trim_front, base_count, out), new_caches}
    end
  end

  # ── Delta selection ──

  # A full store replace only on genuine structural change: epoch flip, no prior
  # base, an emptied transcript, or a non-prefix divergence. Otherwise an
  # eviction-aware append: `trim_front` accounts for cap eviction of the store
  # front, `base_count` is the unchanged leading count of the remainder, and the
  # suffix from `base_count` is upserted (new messages plus the last-message
  # streaming patch).
  @spec select_delta(non_neg_integer() | nil, [key()], non_neg_integer(), [key()], [entry()]) ::
          delta()
  defp select_delta(prev_epoch, _prev_keys, epoch, _keys, entries) when epoch != prev_epoch,
    do: {:full_replace, entries}

  defp select_delta(_prev_epoch, [], _epoch, _keys, entries), do: {:full_replace, entries}
  defp select_delta(_prev_epoch, _prev_keys, _epoch, [], entries), do: {:full_replace, entries}

  defp select_delta(_prev_epoch, prev_keys, _epoch, keys, entries) do
    case align(prev_keys, keys) do
      :diverged ->
        {:full_replace, entries}

      {trim_front, base_count} ->
        case Enum.drop(entries, base_count) do
          [] when trim_front == 0 -> :nothing
          out -> {:append, trim_front, base_count, out}
        end
    end
  end

  # Aligns the previously-sent keys against the new resident keys. The new head
  # id is located in the previous keys; everything before it was evicted from the
  # store front (`trim_front`). The remainder must be an id-prefix of the new keys
  # (pure forward growth); otherwise the transcript diverged (reorder/compaction)
  # and a full_replace is required. Returns the strict `{id, hash}` prefix length
  # of the remainder as `base_count`.
  @spec align([key()], [key()]) :: :diverged | {non_neg_integer(), non_neg_integer()}
  defp align(prev_keys, [{head_id, _} | _] = keys) do
    case Enum.find_index(prev_keys, fn {id, _} -> id == head_id end) do
      nil ->
        :diverged

      trim_front ->
        remainder = Enum.drop(prev_keys, trim_front)

        if id_prefix?(remainder, keys) do
          {trim_front, strict_prefix_len(remainder, keys)}
        else
          :diverged
        end
    end
  end

  # True when `current` extends `previous` by id: at least as long, ids matching
  # positionally over the previous range. Hashes may differ (last-message patch).
  @spec id_prefix?([key()], [key()]) :: boolean()
  defp id_prefix?(previous, current) do
    length(current) >= length(previous) and
      previous
      |> Enum.zip(current)
      |> Enum.all?(fn {{prev_id, _}, {cur_id, _}} -> prev_id == cur_id end)
  end

  # Number of leading entries identical in both id and content hash.
  @spec strict_prefix_len([key()], [key()]) :: non_neg_integer()
  defp strict_prefix_len(previous, current) do
    previous
    |> Enum.zip(current)
    |> Enum.take_while(fn {p, c} -> p == c end)
    |> length()
  end

  # ── Frame building ──

  @spec build_full_replace(non_neg_integer(), boolean(), [entry()]) :: binary()
  defp build_full_replace(epoch, truncated?, entries) do
    header = <<@version::8, @mode_full_replace::8, epoch::32, bool(truncated?)::8>>
    frame([header, <<Enum.count(entries)::32>>, entries_body(entries)])
  end

  @spec build_append(non_neg_integer(), boolean(), non_neg_integer(), non_neg_integer(), [entry()]) ::
          binary()
  defp build_append(epoch, truncated?, trim_front, base_count, entries) do
    header = <<@version::8, @mode_append::8, epoch::32, bool(truncated?)::8>>

    frame([
      header,
      <<trim_front::32, base_count::32, Enum.count(entries)::32>>,
      entries_body(entries)
    ])
  end

  @spec entries_body([entry()]) :: iodata()
  defp entries_body(entries) do
    Enum.map(entries, fn {id, body_bin} ->
      <<id::32, byte_size(body_bin)::32, body_bin::binary>>
    end)
  end

  @spec frame(iodata()) :: binary()
  defp frame(payload_iodata) do
    payload = IO.iodata_to_binary(payload_iodata)
    <<@op_gui_agent_transcript, byte_size(payload)::32, payload::binary>>
  end

  @spec bool(boolean()) :: 0 | 1
  defp bool(true), do: 1
  defp bool(false), do: 0

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

  # Upsert semantics make duplicate ids silent data loss (a later entry clobbers
  # an earlier one on the frontend), and session ids and enrichment ids have no
  # cross-generator uniqueness guarantee. Drop earlier duplicates deterministically
  # (last-wins, preserving order) and log a warning so the collision is visible.
  @spec dedupe_last_wins([entry()]) :: [entry()]
  defp dedupe_last_wins(entries) do
    {kept, _seen, dropped} =
      entries
      |> Enum.reverse()
      |> Enum.reduce({[], MapSet.new(), 0}, fn {id, _} = entry, {acc, seen, dropped} ->
        if MapSet.member?(seen, id) do
          {acc, seen, dropped + 1}
        else
          {[entry | acc], MapSet.put(seen, id), dropped}
        end
      end)

    if dropped > 0 do
      Minga.Log.warning(
        :render,
        "agent transcript: dropped #{dropped} duplicate-id message(s) (last-wins)"
      )
    end

    kept
  end

  # Keep the most recent messages whose cumulative wire size fits the resident
  # byte cap as a **contiguous suffix**: iterate newest to oldest and halt at the
  # first entry that does not fit, so a small older message can never leapfrog a
  # large one back into the resident window and punch a hole. The newest message
  # is always kept, even if it alone exceeds the cap. Returns the kept suffix (in
  # order) and the count dropped from the front.
  @spec cap_to_resident_bytes([entry()]) :: {[entry()], non_neg_integer()}
  defp cap_to_resident_bytes(entries) do
    cap = resident_max_bytes()

    {kept, _used} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn {_id, body_bin} = entry, {acc, used} ->
        next = used + @entry_overhead + byte_size(body_bin)

        cond do
          acc == [] -> {:cont, {[entry], next}}
          next <= cap -> {:cont, {[entry | acc], next}}
          true -> {:halt, {acc, used}}
        end
      end)

    {kept, length(entries) - length(kept)}
  end

  @spec log_eviction(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: :ok
  defp log_eviction(0, _resident, _dropped), do: :ok

  defp log_eviction(trim_front, resident, dropped) do
    Minga.Log.debug(
      :render,
      "agent transcript cap evicted #{trim_front} front message(s) this frame " <>
        "(resident #{resident}, #{dropped} older not shown)"
    )
  end

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
