defmodule MingaAgent.Session.Transcript do
  @moduledoc """
  Owns the ordered, identified agent transcript and its branch snapshots.

  Every active message is carried by a `TranscriptEntry`, so message content and
  identity cannot be reordered independently. Branches freeze those same entry
  values. The identity high-water mark includes active and branched entries, so
  truncation and branch switching never permit ID reuse.

  ## Transition contract

  Total transitions return the next transcript directly. Rejectable branch
  operations return `{:ok, next}` or `{:error, reason}`. All transitions are
  pure: callers provide timestamps, and this module performs no persistence,
  timer, broadcast, provider, or tool effects.

  Compaction keeps the requested active entry IDs in their existing order and
  preserves every branch snapshot and pin relationship unchanged. Retained
  entries and every branch entry keep their IDs.
  """

  alias MingaAgent.Branch
  alias MingaAgent.Message
  alias MingaAgent.TranscriptEntry
  alias MingaAgent.ToolCall
  alias MingaAgent.TurnUsage

  @typedoc "The streaming message kind that may replace the active tail."
  @type stream_kind :: :assistant | :thinking

  @typedoc "Decoded branch fields accepted by the canonical restore transition."
  @type restore_branch ::
          {name :: String.t(), messages :: [Message.t()], message_ids :: [term()],
           created_at :: DateTime.t()}

  @typedoc "Canonical transcript state owned by one Session process."
  @type t :: %__MODULE__{
          entries: [TranscriptEntry.t()],
          next_id: pos_integer(),
          branches: [Branch.t()],
          usage: TurnUsage.t(),
          pinned_ids: MapSet.t(pos_integer()),
          revision: non_neg_integer(),
          last_changed_at: DateTime.t()
        }

  @enforce_keys [
    :entries,
    :next_id,
    :branches,
    :usage,
    :pinned_ids,
    :revision,
    :last_changed_at
  ]
  defstruct @enforce_keys

  @doc "Creates a live transcript with freshly allocated stable IDs."
  @spec new([Message.t()], DateTime.t()) :: t()
  def new(messages, %DateTime{} = changed_at) when is_list(messages) do
    entries = identified(messages, 1)

    %__MODULE__{
      entries: entries,
      next_id: Enum.count(entries) + 1,
      branches: [],
      usage: TurnUsage.new(),
      pinned_ids: MapSet.new(),
      revision: 0,
      last_changed_at: changed_at
    }
  end

  @doc "Restores active and branched entries through the canonical identity allocator."
  @spec restore(
          [Message.t()],
          term(),
          [Branch.t() | restore_branch()],
          TurnUsage.t(),
          MapSet.t(pos_integer()),
          DateTime.t()
        ) :: t()
  def restore(
        messages,
        message_ids,
        branches,
        %TurnUsage{} = usage,
        %MapSet{} = pinned_ids,
        %DateTime{} = changed_at
      )
      when is_list(messages) and is_list(branches) do
    message_ids = restore_legacy_message_ids(messages, message_ids)
    branches = restore_legacy_branch_ids(branches)

    {entries, next_id} =
      normalize_messages(messages, message_ids, highest_candidate_id(message_ids, branches) + 1)

    {branches, next_id} = normalize_branches(branches, next_id)

    %__MODULE__{
      entries: entries,
      next_id: next_id,
      branches: branches,
      usage: usage,
      pinned_ids: pinned_ids,
      revision: 0,
      last_changed_at: changed_at
    }
  end

  @doc "Returns active messages in transcript order."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{} = transcript), do: Enum.map(transcript.entries, & &1.message)

  @doc "Returns the active tail message, or nil for an empty transcript."
  @spec last_message(t()) :: Message.t() | nil
  def last_message(%__MODULE__{} = transcript), do: last_entry_message(transcript.entries)

  @doc "Returns active stable-ID/message pairs in transcript order."
  @spec messages_with_ids(t()) :: [{pos_integer(), Message.t()}]
  def messages_with_ids(%__MODULE__{} = transcript) do
    Enum.map(transcript.entries, &{&1.id, &1.message})
  end

  @doc "Returns the immutable branch snapshots."
  @spec branches(t()) :: [Branch.t()]
  def branches(%__MODULE__{} = transcript), do: transcript.branches

  @doc "Returns cumulative transcript usage."
  @spec usage(t()) :: TurnUsage.t()
  def usage(%__MODULE__{} = transcript), do: transcript.usage

  @doc "Returns pinned active entry IDs."
  @spec pinned_ids(t()) :: MapSet.t(pos_integer())
  def pinned_ids(%__MODULE__{} = transcript), do: transcript.pinned_ids

  @doc "Returns the transcript mutation revision."
  @spec revision(t()) :: non_neg_integer()
  def revision(%__MODULE__{} = transcript), do: transcript.revision

  @doc "Returns the last externally published transcript timestamp."
  @spec last_changed_at(t()) :: DateTime.t()
  def last_changed_at(%__MODULE__{} = transcript), do: transcript.last_changed_at

  @doc "Appends one newly identified message."
  @spec append(t(), Message.t()) :: t()
  def append(%__MODULE__{} = transcript, message) do
    entry = TranscriptEntry.new(transcript.next_id, message)

    # Transcript entries stay in publication order and grow at human interaction speed.
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    entries = transcript.entries ++ [entry]

    %{
      transcript
      | entries: entries,
        next_id: transcript.next_id + 1,
        revision: transcript.revision + 1
    }
  end

  @doc "Appends a batch of messages and allocates one stable ID per message."
  @spec append_many(t(), [Message.t()]) :: t()
  def append_many(%__MODULE__{} = transcript, []), do: transcript

  def append_many(%__MODULE__{} = transcript, messages) when is_list(messages) do
    entries = identified(messages, transcript.next_id)

    %{
      transcript
      | entries: transcript.entries ++ entries,
        next_id: transcript.next_id + Enum.count(entries),
        revision: transcript.revision + 1
    }
  end

  @doc "Replaces or appends one streaming tail from a whole batch of chunks."
  @spec append_stream_tail(t(), stream_kind(), iodata()) :: t()
  def append_stream_tail(%__MODULE__{} = transcript, kind, chunks)
      when kind in [:assistant, :thinking] do
    fragment = IO.iodata_to_binary(chunks)

    case replace_stream_tail(transcript.entries, kind, fragment) do
      {:ok, entries} -> %{transcript | entries: entries, revision: transcript.revision + 1}
      :append -> append(transcript, stream_message(kind, fragment))
    end
  end

  @doc "Transforms every message while preserving entry identity and order."
  @spec transform_messages(t(), (Message.t() -> Message.t())) :: t()
  def transform_messages(%__MODULE__{} = transcript, transform) when is_function(transform, 1) do
    entries = Enum.map(transcript.entries, &TranscriptEntry.replace(&1, transform.(&1.message)))
    replace_entries_if_changed(transcript, entries)
  end

  @doc "Transforms one message by active transcript index while preserving its identity."
  @spec update_at(t(), integer(), (Message.t() -> Message.t())) :: t()
  def update_at(%__MODULE__{} = transcript, index, transform)
      when is_integer(index) and is_function(transform, 1) do
    entries =
      List.update_at(transcript.entries, index, fn entry ->
        TranscriptEntry.replace(entry, transform.(entry.message))
      end)

    replace_entries_if_changed(transcript, entries)
  end

  @doc "Updates the matching tool-call entry while preserving its stable identity."
  @spec update_tool_call(t(), String.t(), (ToolCall.t() -> ToolCall.t())) :: t()
  def update_tool_call(%__MODULE__{} = transcript, tool_call_id, update)
      when is_binary(tool_call_id) and is_function(update, 1) do
    transform_messages(transcript, fn
      {:tool_call, %ToolCall{id: ^tool_call_id} = tool_call} ->
        {:tool_call, update.(tool_call)}

      other ->
        other
    end)
  end

  @doc "Collapses every expanded thinking entry without changing identity."
  @spec collapse_thinking(t()) :: t()
  def collapse_thinking(%__MODULE__{} = transcript) do
    transform_messages(transcript, fn
      {:thinking, text, false} -> {:thinking, text, true}
      other -> other
    end)
  end

  @doc "Adds one turn's usage to the transcript aggregate."
  @spec add_usage(t(), TurnUsage.t()) :: t()
  def add_usage(%__MODULE__{} = transcript, %TurnUsage{} = usage) do
    %{
      transcript
      | usage: TurnUsage.add(transcript.usage, usage),
        revision: transcript.revision + 1
    }
  end

  @doc "Toggles a pin relationship for one stable transcript ID."
  @spec toggle_pin(t(), pos_integer()) :: t()
  def toggle_pin(%__MODULE__{} = transcript, message_id)
      when is_integer(message_id) and message_id > 0 do
    pinned_ids = toggle_member(transcript.pinned_ids, message_id)
    %{transcript | pinned_ids: pinned_ids, revision: transcript.revision + 1}
  end

  @doc "Creates a frozen branch snapshot and truncates the active transcript."
  @spec branch_at(t(), integer(), DateTime.t()) ::
          {:ok, t(), Branch.t()} | {:error, String.t()}
  def branch_at(%__MODULE__{} = transcript, turn_index, %DateTime{} = created_at)
      when is_integer(turn_index) and turn_index >= 0 do
    if turn_index >= Enum.count(transcript.entries) do
      {:error,
       "Turn index #{turn_index} is beyond the conversation length (#{Enum.count(transcript.entries)})"}
    else
      branch =
        Branch.new(
          "branch-#{Enum.count(transcript.branches) + 1}",
          transcript.entries,
          created_at
        )

      entries = Enum.take(transcript.entries, turn_index + 1)

      # Branches are immutable user-created checkpoints and remain in creation order.
      # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
      branches = transcript.branches ++ [branch]

      next =
        %{
          transcript
          | entries: entries,
            branches: branches,
            revision: transcript.revision + 1
        }

      {:ok, next, branch}
    end
  end

  def branch_at(%__MODULE__{}, turn_index, %DateTime{})
      when is_integer(turn_index) do
    {:error, "Turn index #{turn_index} is invalid."}
  end

  @doc "Switches to a one-based branch snapshot without renumbering its entries."
  @spec switch_branch(t(), integer()) :: {:ok, t()} | {:error, String.t()}
  def switch_branch(%__MODULE__{} = transcript, branch_index)
      when is_integer(branch_index) and branch_index >= 0 do
    case Enum.at(transcript.branches, branch_index - 1) do
      nil ->
        {:error, "Branch #{branch_index} not found. Use /branches to list."}

      %Branch{} = branch ->
        {:ok,
         %{
           transcript
           | entries: branch.entries,
             revision: transcript.revision + 1
         }}
    end
  end

  def switch_branch(%__MODULE__{}, branch_index) when is_integer(branch_index) do
    {:error, "Branch #{branch_index} not found. Use /branches to list."}
  end

  @doc "Compacts the active transcript to retained stable IDs and preserves branches."
  @spec compact(t(), [pos_integer()]) :: t()
  def compact(%__MODULE__{} = transcript, retained_ids) when is_list(retained_ids) do
    retained = MapSet.new(retained_ids)
    entries = Enum.filter(transcript.entries, &MapSet.member?(retained, &1.id))

    if entries == transcript.entries do
      transcript
    else
      %{transcript | entries: entries, revision: transcript.revision + 1}
    end
  end

  @doc "Resets the active transcript and usage for a new logical session."
  @spec reset(t(), [Message.t()]) :: t()
  def reset(%__MODULE__{} = transcript, messages) when is_list(messages) do
    entries = identified(messages, 1)

    %{
      transcript
      | entries: entries,
        next_id: Enum.count(entries) + 1,
        branches: [],
        usage: TurnUsage.new(),
        pinned_ids: MapSet.new(),
        revision: transcript.revision + 1
    }
  end

  @doc "Records the timestamp at which Session published transcript changes."
  @spec touch(t(), DateTime.t()) :: t()
  def touch(%__MODULE__{} = transcript, %DateTime{} = changed_at) do
    %{transcript | last_changed_at: changed_at}
  end

  @spec identified([Message.t()], pos_integer()) :: [TranscriptEntry.t()]
  defp identified(messages, first_id) do
    messages
    |> Enum.with_index(first_id)
    |> Enum.map(fn {message, id} -> TranscriptEntry.new(id, message) end)
  end

  @spec last_entry_message([TranscriptEntry.t()]) :: Message.t() | nil
  defp last_entry_message([]), do: nil
  defp last_entry_message([%TranscriptEntry{message: message}]), do: message
  defp last_entry_message([_entry | rest]), do: last_entry_message(rest)

  @spec replace_stream_tail([TranscriptEntry.t()], stream_kind(), String.t()) ::
          {:ok, [TranscriptEntry.t()]} | :append
  defp replace_stream_tail([], _kind, _fragment), do: :append

  defp replace_stream_tail(
         [%TranscriptEntry{message: {:assistant, text}} = entry],
         :assistant,
         fragment
       ) do
    {:ok, [TranscriptEntry.replace(entry, Message.assistant(text <> fragment))]}
  end

  defp replace_stream_tail(
         [%TranscriptEntry{message: {:thinking, text, _collapsed}} = entry],
         :thinking,
         fragment
       ) do
    {:ok, [TranscriptEntry.replace(entry, Message.thinking(text <> fragment))]}
  end

  defp replace_stream_tail([_entry], _kind, _fragment), do: :append

  defp replace_stream_tail([entry | rest], kind, fragment) do
    case replace_stream_tail(rest, kind, fragment) do
      {:ok, updated} -> {:ok, [entry | updated]}
      :append -> :append
    end
  end

  @spec replace_entries_if_changed(t(), [TranscriptEntry.t()]) :: t()
  defp replace_entries_if_changed(%{entries: entries} = transcript, entries), do: transcript

  defp replace_entries_if_changed(transcript, entries) do
    %{transcript | entries: entries, revision: transcript.revision + 1}
  end

  @spec stream_message(stream_kind(), String.t()) :: Message.t()
  defp stream_message(:assistant, text), do: Message.assistant(text)
  defp stream_message(:thinking, text), do: Message.thinking(text)

  @spec toggle_member(MapSet.t(pos_integer()), pos_integer()) :: MapSet.t(pos_integer())
  defp toggle_member(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  @spec restore_legacy_message_ids([Message.t()], term()) :: [term()]
  defp restore_legacy_message_ids([], _ids), do: []
  defp restore_legacy_message_ids(_messages, ids) when is_list(ids) and ids != [], do: ids

  defp restore_legacy_message_ids(messages, _ids) do
    messages |> Enum.with_index(1) |> Enum.map(&elem(&1, 1))
  end

  @spec restore_legacy_branch_ids([Branch.t() | restore_branch()]) ::
          [Branch.t() | restore_branch()]
  defp restore_legacy_branch_ids(branches) do
    Enum.map(branches, fn
      {name, messages, [], created_at} ->
        ids = messages |> Enum.with_index(1) |> Enum.map(&elem(&1, 1))
        {name, messages, ids, created_at}

      branch ->
        branch
    end)
  end

  @spec highest_candidate_id([term()], [Branch.t() | restore_branch()]) ::
          non_neg_integer()
  defp highest_candidate_id(message_ids, branches) do
    branch_ids =
      Enum.flat_map(branches, fn
        %Branch{} = branch -> Branch.entry_ids(branch)
        {_name, _messages, ids, _created_at} -> ids
      end)

    message_ids
    |> Enum.concat(branch_ids)
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.max(fn -> 0 end)
  end

  @spec normalize_messages([Message.t()], [term()], pos_integer()) ::
          {[TranscriptEntry.t()], pos_integer()}
  defp normalize_messages(messages, ids, next_id) do
    messages
    |> Enum.with_index()
    |> Enum.map_reduce({next_id, MapSet.new()}, fn {message, index}, {next, local_ids} ->
      {id, next} = normalize_id(Enum.at(ids, index), local_ids, next)
      {TranscriptEntry.new(id, message), {next, MapSet.put(local_ids, id)}}
    end)
    |> then(fn {entries, {next, _local_ids}} -> {entries, next} end)
  end

  @spec normalize_branches([Branch.t() | restore_branch()], pos_integer()) ::
          {[Branch.t()], pos_integer()}
  defp normalize_branches(branches, next_id) do
    Enum.map_reduce(branches, next_id, fn
      %Branch{} = branch, next ->
        normalize_branch(
          branch.name,
          Branch.messages(branch),
          Branch.entry_ids(branch),
          branch.created_at,
          next
        )

      {name, messages, ids, created_at}, next ->
        normalize_branch(name, messages, ids, created_at, next)
    end)
  end

  @spec normalize_branch(String.t(), [Message.t()], [term()], DateTime.t(), pos_integer()) ::
          {Branch.t(), pos_integer()}
  defp normalize_branch(name, messages, ids, created_at, next_id) do
    {entries, next_id} = normalize_messages(messages, ids, next_id)
    {Branch.new(name, entries, created_at), next_id}
  end

  @spec normalize_id(term(), MapSet.t(pos_integer()), pos_integer()) ::
          {pos_integer(), pos_integer()}
  defp normalize_id(candidate, local_ids, next_id)
       when is_integer(candidate) and candidate > 0 do
    if MapSet.member?(local_ids, candidate),
      do: {next_id, next_id + 1},
      else: {candidate, next_id}
  end

  defp normalize_id(_candidate, _local_ids, next_id), do: {next_id, next_id + 1}
end
