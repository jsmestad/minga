defmodule MingaAgent.Session.Transcript do
  @moduledoc """
  Canonical ordered, identified agent transcript and frozen branch snapshots.

  Active order is indexed by `:array`; derived occurrence indexes target IDs and
  tool calls. A latest-change tree retains one ordinal record per current entry,
  never historical payloads. Append and targeted updates do not visit unchanged
  history. Explicit message/branch/snapshot list boundaries remain O(M).

  `since/2` atomically returns current entries, pins and source metadata. Equal
  cursors enumerate nothing. Changed discovery is O(log M + K), followed by
  O(K log K) ordering and indexed fetches, plus changed-payload processing.
  Structural replacement advances an exact reset generation. Runtime supplies
  the incarnation nonce; all transitions here are pure, including restore/reset.
  """

  alias MingaAgent.Branch
  alias MingaAgent.Message
  alias MingaAgent.TranscriptEntry
  alias MingaAgent.ToolCall
  alias MingaAgent.TurnUsage
  alias MingaAgent.Session.Transcript.Active
  alias MingaAgent.Session.Transcript.Changes
  alias MingaAgent.Session.Transcript.Cursor
  alias MingaAgent.Session.Transcript.Entry
  alias MingaAgent.Session.Transcript.Snapshot
  alias MingaAgent.Session.Transcript.Entry
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Reference

  @typedoc "The streaming message kind that may replace the active tail."
  @type stream_kind :: :assistant | :thinking

  @typedoc "Decoded branch fields accepted by the canonical restore transition."
  @type restore_branch ::
          {name :: String.t(), messages :: [Message.t()], message_ids :: [term()],
           created_at :: DateTime.t()}

  @typedoc "Canonical transcript state owned by one Session process."
  @type t :: %__MODULE__{
          active: Active.t(),
          incarnation: reference(),
          generation: non_neg_integer(),
          next_id: pos_integer(),
          branches: [Branch.t()],
          usage: TurnUsage.t(),
          pinned_ids: MapSet.t(pos_integer()),
          revision: non_neg_integer(),
          pins_revision: non_neg_integer(),
          usage_revision: non_neg_integer(),
          timestamp_revision: non_neg_integer(),
          last_changed_at: DateTime.t()
        }

  @enforce_keys [
    :active,
    :incarnation,
    :generation,
    :next_id,
    :branches,
    :usage,
    :pinned_ids,
    :revision,
    :pins_revision,
    :usage_revision,
    :timestamp_revision,
    :last_changed_at
  ]
  defstruct @enforce_keys

  @type reset_reason :: Cursor.reset_reason()
  @type query_result ::
          {:snapshot, Snapshot.t()}
          | {:unchanged, Cursor.t()}
          | {:changes, Changes.t()}
          | {:reset, reset_reason(), Snapshot.t()}
          | {:error, :invalid_cursor}

  @doc "Creates a transcript using an incarnation minted by the Session runtime."
  @spec new([Message.t()], DateTime.t(), reference()) :: t()
  def new(messages, %DateTime{} = changed_at, incarnation)
      when is_list(messages) and is_reference(incarnation) do
    entries = identified(messages)

    %__MODULE__{
      active: Active.new(entries, 0),
      incarnation: incarnation,
      generation: 0,
      next_id: Enum.count(entries) + 1,
      branches: [],
      usage: TurnUsage.new(),
      pinned_ids: MapSet.new(),
      revision: 0,
      pins_revision: 0,
      usage_revision: 0,
      timestamp_revision: 0,
      last_changed_at: changed_at
    }
  end

  @doc "Restores identified snapshots, invalidating all prior cursors on this incarnation."
  @spec restore(
          t(),
          [Message.t()],
          term(),
          [Branch.t() | restore_branch()],
          TurnUsage.t(),
          MapSet.t(pos_integer()),
          DateTime.t()
        ) :: t()
  def restore(
        %__MODULE__{} = transcript,
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
    first_id = max(transcript.next_id, highest_candidate_id(message_ids, branches) + 1)
    {entries, next_id} = normalize_messages(messages, message_ids, first_id)
    {branches, next_id} = normalize_branches(branches, next_id)
    next = reset_active(transcript, entries)

    %{
      next
      | next_id: next_id,
        branches: branches,
        usage: usage,
        pinned_ids: pinned_ids,
        last_changed_at: changed_at,
        pins_revision: next.revision,
        usage_revision: next.revision,
        timestamp_revision: next.revision
    }
  end

  @doc "Returns an exact runtime-only source cursor without traversing entries."
  @spec cursor(t()) :: Cursor.t()
  def cursor(%__MODULE__{} = transcript) do
    Cursor.new(transcript.incarnation, transcript.generation, transcript.revision)
  end

  @type history_result ::
          {:ok, Cursor.t(), [Entry.t()], boolean()}
          | {:error, :invalid_range | :invalid_cursor | :anchor_unavailable}
          | {:reset, Cursor.reset_reason()}

  @doc """
  Reads an ordered page before an identified entry in the same transcript generation.

  Appends may advance the requested revision. The returned cursor identifies the
  actual read. A reset or missing anchor never falls back to another conversation.
  """
  @spec history_before(t(), Cursor.t(), pos_integer() | :tail, 1..64) :: history_result()
  def history_before(%__MODULE__{} = transcript, previous, anchor, limit)
      when (anchor == :tail or (is_integer(anchor) and anchor > 0)) and
             is_integer(limit) and limit in 1..64 do
    case Cursor.compare(
           previous,
           transcript.incarnation,
           transcript.generation,
           transcript.revision
         ) do
      {:unchanged, _cursor} -> read_history_before(transcript, anchor, limit)
      {:changes_since, _revision} -> read_history_before(transcript, anchor, limit)
      rejected -> rejected
    end
  end

  def history_before(%__MODULE__{}, _previous, _anchor, _limit), do: {:error, :invalid_range}

  @spec read_history_before(t(), pos_integer() | :tail, 1..64) ::
          {:ok, Cursor.t(), [Entry.t()], boolean()} | {:error, :anchor_unavailable}
  defp read_history_before(transcript, anchor, limit) do
    case Active.before(transcript.active, anchor, limit) do
      {:ok, entries, earlier?} -> {:ok, cursor(transcript), entries, earlier?}
      unavailable -> unavailable
    end
  end

  @doc """
  Returns one atomic snapshot, coalesced current changes, or unchanged outcome.

  Foreign, reset-generation and future cursors explicitly reset with a snapshot;
  malformed cursors are rejected without enumerating entries. This pure query
  does not catch runtime failures; Session preserves normal GenServer exits/timeouts.
  """
  @spec since(t(), :snapshot | Cursor.t() | term()) :: query_result()
  def since(%__MODULE__{} = transcript, :snapshot), do: {:snapshot, snapshot(transcript)}

  def since(%__MODULE__{} = transcript, previous) do
    case Cursor.compare(
           previous,
           transcript.incarnation,
           transcript.generation,
           transcript.revision
         ) do
      {:unchanged, _cursor} = unchanged -> unchanged
      {:changes_since, revision} -> {:changes, changes_since(transcript, revision)}
      {:reset, reason} -> {:reset, reason, snapshot(transcript)}
      {:error, :invalid_cursor} = error -> error
    end
  end

  defp changes_since(transcript, revision) do
    Changes.new(
      cursor(transcript),
      Active.changed_since(transcript.active, revision),
      transcript.pinned_ids,
      transcript.usage,
      transcript.last_changed_at,
      transcript.next_id,
      Active.size(transcript.active),
      %{
        pins_changed?: transcript.pins_revision > revision,
        usage_changed?: transcript.usage_revision > revision,
        timestamp_changed?: transcript.timestamp_revision > revision
      }
    )
  end

  defp snapshot(transcript) do
    Snapshot.new(
      cursor(transcript),
      Active.snapshot(transcript.active),
      transcript.pinned_ids,
      transcript.usage,
      transcript.last_changed_at,
      transcript.next_id,
      Active.size(transcript.active)
    )
  end

  @doc "Returns active messages in transcript order."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{} = transcript),
    do: Active.messages(transcript.active)

  @doc "Returns ordered active messages and their aligned stable IDs for saving."
  @spec messages_and_ids(t()) :: {[Message.t()], [pos_integer()]}
  def messages_and_ids(%__MODULE__{} = transcript),
    do: Active.messages_and_ids(transcript.active)

  @doc "Returns the active tail message, or nil for an empty transcript."
  @spec last_message(t()) :: Message.t() | nil
  def last_message(%__MODULE__{} = transcript) do
    case Active.at(transcript.active, -1) do
      nil -> nil
      entry -> entry.message
    end
  end

  @doc "Returns active stable-ID/message pairs in transcript order."
  @spec messages_with_ids(t()) :: [{pos_integer(), Message.t()}]
  def messages_with_ids(%__MODULE__{} = transcript) do
    Active.messages_with_ids(transcript.active)
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

  @doc "Appends one newly identified message without traversing retained entries."
  @spec append(t(), Message.t()) :: t()
  def append(%__MODULE__{} = transcript, message), do: append_many(transcript, [message])

  @doc "Appends a batch at one revision, allocating one stable ID per message."
  @spec append_many(t(), [Message.t()]) :: t()
  def append_many(%__MODULE__{} = transcript, []), do: transcript

  def append_many(%__MODULE__{} = transcript, messages) when is_list(messages) do
    revision = transcript.revision + 1

    {active, next_id} =
      Enum.reduce(messages, {transcript.active, transcript.next_id}, fn message, {active, id} ->
        {Active.append(active, TranscriptEntry.new(id, message), revision), id + 1}
      end)

    %{transcript | active: active, next_id: next_id, revision: revision}
  end

  @doc "Replaces or appends the indexed streaming tail from a whole batch of chunks."
  @spec append_stream_tail(t(), stream_kind(), iodata()) :: t()
  def append_stream_tail(%__MODULE__{} = transcript, kind, chunks)
      when kind in [:assistant, :thinking] do
    stream_tail(transcript, kind, :erlang.iolist_to_binary(chunks), last_message(transcript))
  end

  defp stream_tail(transcript, :assistant, fragment, {:assistant, text}) do
    update_at(transcript, -1, fn _ -> Message.assistant(text <> fragment) end)
  end

  defp stream_tail(transcript, :thinking, fragment, {:thinking, text, _collapsed}) do
    update_at(transcript, -1, fn _ -> Message.thinking(text <> fragment) end)
  end

  defp stream_tail(transcript, kind, fragment, _tail),
    do: append(transcript, stream_message(kind, fragment))

  @doc "Transforms every message while preserving entry identity and order."
  @spec transform_messages(t(), (Message.t() -> Message.t())) :: t()
  def transform_messages(%__MODULE__{} = transcript, transform) when is_function(transform, 1) do
    active = Active.transform(transcript.active, transform, transcript.revision + 1)
    install_active(transcript, active)
  end

  @doc "Transforms one indexed message while preserving its stable identity."
  @spec update_at(t(), integer(), (Message.t() -> Message.t())) :: t()
  def update_at(%__MODULE__{} = transcript, index, transform)
      when is_integer(index) and is_function(transform, 1) do
    active = Active.update_at(transcript.active, index, transform, transcript.revision + 1)
    install_active(transcript, active)
  end

  @doc "Toggles the first collapsible occurrence of a stable transcript ID."
  @spec toggle_message_collapse(t(), non_neg_integer()) :: t()
  def toggle_message_collapse(%__MODULE__{} = transcript, message_id)
      when is_integer(message_id) and message_id > 0 do
    index =
      transcript.active
      |> Active.id_ordinals(message_id)
      |> Enum.find(fn ordinal -> collapsible?(Active.at(transcript.active, ordinal).message) end)

    toggle_collapse_at(transcript, index)
  end

  def toggle_message_collapse(%__MODULE__{} = transcript, _message_id), do: transcript

  defp collapsible?({:tool_call, %ToolCall{}}), do: true
  defp collapsible?({:thinking, _, _}), do: true
  defp collapsible?(_message), do: false

  defp toggle_collapse_at(transcript, nil), do: transcript

  defp toggle_collapse_at(transcript, index) do
    update_at(transcript, index, fn
      {:tool_call, %ToolCall{} = tool_call} ->
        {:tool_call, ToolCall.toggle_collapsed(tool_call)}

      {:thinking, text, collapsed} ->
        {:thinking, text, !collapsed}
    end)
  end

  @doc "Checks that one exact current tool message still owns the displayed retained output."
  @spec retained_output(t(), pos_integer(), Reference.t()) ::
          {:ok, Reference.t()} | {:error, :output_unavailable | :output_changed}
  def retained_output(%__MODULE__{} = transcript, id, %Reference{} = expected)
      when is_integer(id) and id > 0 do
    case Active.id_ordinals(transcript.active, id) do
      [ordinal] -> retained_output_at(Active.at(transcript.active, ordinal), expected)
      _missing_or_ambiguous -> {:error, :output_unavailable}
    end
  end

  @spec retained_output_at(Entry.t() | nil, Reference.t()) ::
          {:ok, Reference.t()} | {:error, :output_unavailable | :output_changed}
  defp retained_output_at(
         %Entry{
           message: {:tool_call, %ToolCall{output: %Output{reference: %Reference{} = reference}}}
         },
         expected
       ) do
    if reference == expected, do: {:ok, reference}, else: {:error, :output_changed}
  end

  defp retained_output_at(_entry, _expected), do: {:error, :output_unavailable}

  @doc "Fetches the current/latest tool occurrence without traversing retained history."
  @spec current_tool_call(t(), String.t()) :: ToolCall.t() | nil
  def current_tool_call(%__MODULE__{} = transcript, id) when is_binary(id) do
    case Active.latest_tool_ordinal(transcript.active, id) do
      nil ->
        nil

      ordinal ->
        {:tool_call, tool} = Active.at(transcript.active, ordinal).message
        tool
    end
  end

  @doc "Updates only the current/latest indexed occurrence of a tool-call ID."
  @spec update_tool_call(t(), String.t(), (ToolCall.t() -> ToolCall.t())) :: t()
  def update_tool_call(%__MODULE__{} = transcript, tool_call_id, update)
      when is_binary(tool_call_id) and is_function(update, 1) do
    case Active.latest_tool_ordinal(transcript.active, tool_call_id) do
      nil ->
        transcript

      ordinal ->
        update_at(transcript, ordinal, fn {:tool_call, tool} ->
          {:tool_call, update.(tool)}
        end)
    end
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
    replace_usage(transcript, TurnUsage.add(transcript.usage, usage))
  end

  defp replace_usage(%{usage: usage} = transcript, usage), do: transcript

  defp replace_usage(transcript, usage) do
    revision = transcript.revision + 1
    %{transcript | usage: usage, revision: revision, usage_revision: revision}
  end

  @doc "Toggles a pin relationship for one stable transcript ID."
  @spec toggle_pin(t(), pos_integer()) :: t()
  def toggle_pin(%__MODULE__{} = transcript, message_id)
      when is_integer(message_id) and message_id > 0 do
    pinned_ids = toggle_member(transcript.pinned_ids, message_id)
    revision = transcript.revision + 1
    %{transcript | pinned_ids: pinned_ids, revision: revision, pins_revision: revision}
  end

  @doc "Creates a frozen branch snapshot and truncates the active transcript."
  @spec branch_at(t(), integer(), DateTime.t()) ::
          {:ok, t(), Branch.t()} | {:error, String.t()}
  def branch_at(%__MODULE__{} = transcript, turn_index, %DateTime{} = created_at)
      when is_integer(turn_index) and turn_index >= 0 do
    count = Active.size(transcript.active)

    if turn_index >= count do
      {:error, "Turn index #{turn_index} is beyond the conversation length (#{count})"}
    else
      frozen = Active.freeze(transcript.active)
      branch = Branch.new("branch-#{Enum.count(transcript.branches) + 1}", frozen, created_at)
      entries = Enum.take(frozen, turn_index + 1)

      # Branches are immutable user-created checkpoints in creation order.
      # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
      branches = transcript.branches ++ [branch]
      next = reset_active(transcript, entries)
      {:ok, %{next | branches: branches}, branch}
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
        pins = retain_branch_pins(transcript.pinned_ids, transcript.branches)
        next = reset_active(transcript, branch.entries)

        {:ok, %{next | pinned_ids: pins, pins_revision: next.revision}}
    end
  end

  def switch_branch(%__MODULE__{}, branch_index) when is_integer(branch_index) do
    {:error, "Branch #{branch_index} not found. Use /branches to list."}
  end

  @doc "Compacts the active transcript to retained stable IDs and preserves branches."
  @spec compact(t(), [pos_integer()]) :: t()
  def compact(%__MODULE__{} = transcript, retained_ids) when is_list(retained_ids) do
    retained = MapSet.new(retained_ids)
    entries = Enum.filter(Active.freeze(transcript.active), &MapSet.member?(retained, &1.id))

    if Enum.count(entries) == Active.size(transcript.active) do
      transcript
    else
      reset_active(transcript, entries)
    end
  end

  @doc "Resets the active transcript and usage for a new logical session."
  @spec reset(t(), [Message.t()]) :: t()
  def reset(%__MODULE__{} = transcript, messages) when is_list(messages) do
    entries = identified(messages)
    next = reset_active(transcript, entries)

    %{
      next
      | next_id: Enum.count(entries) + 1,
        branches: [],
        usage: TurnUsage.new(),
        pinned_ids: MapSet.new(),
        pins_revision: next.revision,
        usage_revision: next.revision
    }
  end

  @doc "Records the timestamp at which Session published transcript changes."
  @spec touch(t(), DateTime.t()) :: t()
  def touch(%__MODULE__{} = transcript, %DateTime{} = changed_at) do
    touch_at(transcript, changed_at)
  end

  defp touch_at(%{last_changed_at: changed_at} = transcript, changed_at), do: transcript

  defp touch_at(transcript, changed_at) do
    revision = transcript.revision + 1
    %{transcript | last_changed_at: changed_at, revision: revision, timestamp_revision: revision}
  end

  @spec identified([Message.t()]) :: [TranscriptEntry.t()]
  defp identified(messages) do
    Enum.with_index(messages, fn message, index -> TranscriptEntry.new(index + 1, message) end)
  end

  defp install_active(%{active: active} = transcript, active), do: transcript

  defp install_active(transcript, active) do
    %{transcript | active: active, revision: transcript.revision + 1}
  end

  defp reset_active(transcript, entries) do
    revision = transcript.revision + 1

    %{
      transcript
      | active: Active.new(entries, revision),
        generation: transcript.generation + 1,
        revision: revision
    }
  end

  @spec stream_message(stream_kind(), String.t()) :: Message.t()
  defp stream_message(:assistant, text), do: Message.assistant(text)
  defp stream_message(:thinking, text), do: Message.thinking(text)

  @spec toggle_member(MapSet.t(pos_integer()), pos_integer()) :: MapSet.t(pos_integer())
  defp toggle_member(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  @spec retain_branch_pins(MapSet.t(pos_integer()), [Branch.t()]) :: MapSet.t(pos_integer())
  defp retain_branch_pins(pins, branches) do
    if MapSet.size(pins) == 0 do
      pins
    else
      for branch <- branches,
          entry <- branch.entries,
          MapSet.member?(pins, entry.id),
          reduce: MapSet.new() do
        kept -> MapSet.put(kept, entry.id)
      end
    end
  end

  @spec restore_legacy_message_ids([Message.t()], term()) :: [term()]
  defp restore_legacy_message_ids([], _ids), do: []
  defp restore_legacy_message_ids(_messages, ids) when is_list(ids) and ids != [], do: ids

  defp restore_legacy_message_ids(messages, _ids), do: structural_ids(messages)

  @spec restore_legacy_branch_ids([Branch.t() | restore_branch()]) ::
          [Branch.t() | restore_branch()]
  defp restore_legacy_branch_ids(branches) do
    Enum.map(branches, fn
      {name, messages, [], created_at} ->
        {name, messages, structural_ids(messages), created_at}

      branch ->
        branch
    end)
  end

  @spec structural_ids([Message.t()]) :: [pos_integer()]
  defp structural_ids(messages), do: Enum.with_index(messages, fn _, index -> index + 1 end)

  @spec highest_candidate_id([term()], [Branch.t() | restore_branch()]) ::
          non_neg_integer()
  defp highest_candidate_id(message_ids, branches) do
    highest = Enum.reduce(message_ids, 0, &higher_id/2)
    Enum.reduce(branches, highest, &highest_branch_id/2)
  end

  @spec highest_branch_id(Branch.t() | restore_branch(), non_neg_integer()) :: non_neg_integer()
  defp highest_branch_id(%Branch{entries: entries}, highest) do
    Enum.reduce(entries, highest, fn entry, highest -> higher_id(entry.id, highest) end)
  end

  defp highest_branch_id({_name, _messages, ids, _created_at}, highest) do
    Enum.reduce(ids, highest, &higher_id/2)
  end

  @spec higher_id(term(), non_neg_integer()) :: non_neg_integer()
  defp higher_id(id, highest) when is_integer(id) and id > highest, do: id
  defp higher_id(_id, highest), do: highest

  @spec normalize_messages([Message.t()], [term()], pos_integer()) ::
          {[TranscriptEntry.t()], pos_integer()}
  defp normalize_messages(messages, ids, next_id) do
    {entries, next_id, _seen} =
      normalize_message_entries(messages, ids, next_id, %{}, [])

    {Enum.reverse(entries), next_id}
  end

  @spec normalize_message_entries(
          [Message.t()],
          [term()],
          pos_integer(),
          %{optional(pos_integer()) => true},
          [TranscriptEntry.t()]
        ) ::
          {[TranscriptEntry.t()], pos_integer(), %{optional(pos_integer()) => true}}
  defp normalize_message_entries([], _ids, next_id, seen, entries),
    do: {entries, next_id, seen}

  defp normalize_message_entries([message | messages], [candidate | ids], next_id, seen, entries) do
    {id, next_id} = normalize_id(candidate, seen, next_id)
    seen = Map.put(seen, id, true)
    entry = TranscriptEntry.new(id, message)
    normalize_message_entries(messages, ids, next_id, seen, [entry | entries])
  end

  defp normalize_message_entries([message | messages], [], next_id, seen, entries) do
    {id, next_id} = normalize_id(nil, seen, next_id)
    seen = Map.put(seen, id, true)
    entry = TranscriptEntry.new(id, message)
    normalize_message_entries(messages, [], next_id, seen, [entry | entries])
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

  @spec normalize_id(term(), %{optional(pos_integer()) => true}, pos_integer()) ::
          {pos_integer(), pos_integer()}
  defp normalize_id(candidate, local_ids, next_id)
       when is_integer(candidate) and candidate > 0 do
    if Map.has_key?(local_ids, candidate),
      do: {next_id, next_id + 1},
      else: {candidate, next_id}
  end

  defp normalize_id(_candidate, _local_ids, next_id), do: {next_id, next_id + 1}
end
