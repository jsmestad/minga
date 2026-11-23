defmodule Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder do
  @moduledoc """
  Pure GUI adapter encoder for the resident agent-chat transcript stream
  (`gui_agent_transcript`, 0x86).

  Owns the `gui_agent_transcript` (0x86) resident framing so a frontend can
  scroll the session from local data without a BEAM round-trip (#2654),
  decoupled from the small `gui_agent_chat` (0x78) chrome model owned by
  `Minga.Frontend.Adapter.GUI.AgentChatEncoder`. The render model owns resident
  selection. This adapter encodes its `resident_messages` exactly and never
  selects a suffix, marks content truncated, or drops entries. It uses
  `Minga.Frontend.Adapter.GUI.AgentChatMessageCodec` for the shared per-message
  bodies.

  Adopts the #2652 resident-store lifecycle: a full store replace only on genuine
  structural change (`transcript_epoch` flip or a non-prefix divergence such as
  compaction), and id-keyed append/upsert deltas within an epoch for streaming
  growth, the in-place last-message patch, and upstream resident eviction. The
  append delta carries `trim_front`, the number of leading messages removed by
  the model. State for the delta base lives in a
  `Minga.Frontend.Adapter.GUI.AgentTranscriptSentState` inside
  `Minga.Frontend.Adapter.GUI.Caches`, never on the BEAM editor state.

  ## Wire payload (after the len32 opcode + u32 length framing)

      version:u8 = 1
      mode:u8            # 0 = full_replace, 1 = append
      epoch:u32
      truncated:u8       # model-owned resident suffix omitted older messages
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

  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec, as: Codec
  alias Minga.Frontend.Adapter.GUI.AgentTranscriptSentState, as: SentState
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentChat

  # Within one epoch, a streamed tail is resent only when its hash changes, so use the full 32-bit
  # range rather than phash2's default 2^27.
  @hash_range 4_294_967_296

  @op_gui_agent_transcript Opcodes.gui_agent_transcript()

  @version 1
  @mode_full_replace 0
  @mode_append 1

  @command :gui_agent_transcript

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
    truncated? = model.resident_truncated?
    fp = :erlang.phash2({epoch, messages, truncated?}, @hash_range)

    if fp == caches.last_agent_transcript.fp do
      {nil, caches}
    else
      encode_changed(epoch, messages, truncated?, fp, caches)
    end
  end

  @spec encode_changed(non_neg_integer(), [AgentChat.message()], boolean(), integer(), Caches.t()) ::
          {binary() | nil, Caches.t()}
  defp encode_changed(epoch, messages, truncated?, fp, %Caches{} = caches) do
    prev = caches.last_agent_transcript

    validate_unique_message_ids!(messages)
    entries = Enum.map(messages, &message_entry/1)
    keys = Enum.map(entries, &entry_key/1)

    new_caches = %{caches | last_agent_transcript: SentState.emitted(fp, epoch, keys, truncated?)}

    case select_delta(prev.epoch, prev.keys, epoch, keys, entries) do
      :nothing ->
        emit_truncation_transition(prev.truncated?, truncated?, epoch, entries, new_caches)

      {:full_replace, out} ->
        {build_full_replace(epoch, truncated?, out), new_caches}

      {:append, trim_front, base_count, out} ->
        {build_append(epoch, truncated?, trim_front, base_count, out), new_caches}
    end
  end

  @spec emit_truncation_transition(boolean(), boolean(), non_neg_integer(), [entry()], Caches.t()) ::
          {binary() | nil, Caches.t()}
  defp emit_truncation_transition(truncated?, truncated?, _epoch, _entries, caches),
    do: {nil, caches}

  defp emit_truncation_transition(_previous_truncated?, truncated?, epoch, entries, caches) do
    {build_append(epoch, truncated?, 0, Enum.count(entries), []), caches}
  end

  # ── Delta selection ──

  # A full store replace only on genuine structural change: epoch flip, no prior
  # base, an emptied transcript, or a non-prefix divergence. Otherwise an
  # eviction-aware append: `trim_front` accounts for upstream removal from the store
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

  @typep alignment :: :diverged | {non_neg_integer(), non_neg_integer()}

  # Count leading evictions by id, then count the unchanged keys of the
  # retained prefix. After a body changes, the rest of the old ids must still
  # match in order: a revision changes what we resend, not what can align.
  @spec align([key()], [key()]) :: alignment()
  defp align(prev_keys, keys), do: align_head(prev_keys, keys, 0)

  @spec align_head([key()], [key()], non_neg_integer()) :: alignment()
  defp align_head([{id, _} | _] = prev_keys, [{id, _} | _] = keys, trim_front),
    do: align_keys(prev_keys, keys, trim_front, 0)

  defp align_head([_ | prev_keys], keys, trim_front),
    do: align_head(prev_keys, keys, trim_front + 1)

  defp align_head([], _keys, _trim_front), do: :diverged

  @spec align_keys([key()], [key()], non_neg_integer(), non_neg_integer()) :: alignment()
  defp align_keys([key | prev_keys], [key | keys], trim_front, base_count),
    do: align_keys(prev_keys, keys, trim_front, base_count + 1)

  defp align_keys([{id, _} | prev_keys], [{id, _} | keys], trim_front, base_count),
    do: align_ids(prev_keys, keys, trim_front, base_count)

  defp align_keys([], _keys, trim_front, base_count), do: {trim_front, base_count}
  defp align_keys(_prev_keys, _keys, _trim_front, _base_count), do: :diverged

  @spec align_ids([key()], [key()], non_neg_integer(), non_neg_integer()) :: alignment()
  defp align_ids([{id, _} | prev_keys], [{id, _} | keys], trim_front, base_count),
    do: align_ids(prev_keys, keys, trim_front, base_count)

  defp align_ids([], _keys, trim_front, base_count), do: {trim_front, base_count}
  defp align_ids(_prev_keys, _keys, _trim_front, _base_count), do: :diverged

  # ── Frame building ──

  @spec build_full_replace(non_neg_integer(), boolean(), [entry()]) :: binary()
  defp build_full_replace(epoch, truncated?, entries) do
    payload =
      Writer.new(@command)
      |> Writer.uint8(:version, @version)
      |> Writer.uint8(:mode, @mode_full_replace)
      |> Writer.uint32(:epoch, epoch)
      |> Writer.uint8(:truncated, if(truncated?, do: 1, else: 0))
      |> Writer.uint32(:message_count, Enum.count(entries))
      |> Writer.append(entries_body(entries))
      |> Writer.finish()

    frame(payload)
  end

  @spec build_append(non_neg_integer(), boolean(), non_neg_integer(), non_neg_integer(), [entry()]) ::
          binary()
  defp build_append(epoch, truncated?, trim_front, base_count, entries) do
    payload =
      Writer.new(@command)
      |> Writer.uint8(:version, @version)
      |> Writer.uint8(:mode, @mode_append)
      |> Writer.uint32(:epoch, epoch)
      |> Writer.uint8(:truncated, if(truncated?, do: 1, else: 0))
      |> Writer.uint32(:trim_front, trim_front)
      |> Writer.uint32(:base_count, base_count)
      |> Writer.uint32(:message_count, Enum.count(entries))
      |> Writer.append(entries_body(entries))
      |> Writer.finish()

    frame(payload)
  end

  @spec entries_body([entry()]) :: iodata()
  defp entries_body(entries), do: Enum.map(entries, &encode_entry/1)

  @spec encode_entry(entry()) :: binary()
  defp encode_entry({id, body}) do
    Writer.new(@command)
    |> Writer.uint32(:message_id, id)
    |> Writer.payload32(:message_body, body)
    |> Writer.finish()
  end

  @spec frame(binary()) :: binary()
  defp frame(payload) do
    Writer.new(@command)
    |> Writer.uint8(:opcode, @op_gui_agent_transcript)
    |> Writer.payload32(:payload, payload)
    |> Writer.finish()
  end

  # ── Message entries ──

  @spec validate_unique_message_ids!([AgentChat.message()]) :: :ok
  defp validate_unique_message_ids!(messages) do
    messages
    |> Enum.map(&Codec.message_id/1)
    |> Enum.frequencies()
    |> Enum.each(fn
      {_id, 1} ->
        :ok

      {_id, occurrences} ->
        raise EncodingError,
          command: @command,
          field: :message_id_occurrences,
          actual: occurrences,
          min: 0,
          max: 1
    end)
  end

  @spec message_entry(AgentChat.message()) :: entry()
  defp message_entry(message) do
    {Codec.message_id(message), Codec.encode_message_body(message_body(message))}
  end

  @spec message_body(AgentChat.message()) :: AgentChat.message_body()
  defp message_body({id, body}) when is_integer(id), do: body
  defp message_body(body), do: body

  @spec entry_key(entry()) :: key()
  defp entry_key({id, body_bin}), do: {id, :erlang.phash2(body_bin, @hash_range)}
end
