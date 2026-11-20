defmodule MingaAgent.Session.Transcript.Active do
  @moduledoc """
  Indexed active source order, owned exclusively by Transcript.

  The array is canonical. Identity and tool indexes contain ordered occurrences;
  the change tree contains exactly one `{latest_revision, ordinal}` key per entry
  and no payloads. Revisions replace that key, never retain old message versions.
  """

  alias MingaAgent.Session.Transcript.Entry
  alias MingaAgent.ToolCall
  alias MingaAgent.TranscriptEntry

  @enforce_keys [:entries, :ids, :tools, :changes]
  defstruct @enforce_keys

  @typep occurrences :: %{optional(term()) => :gb_sets.set(non_neg_integer())}
  @type message :: MingaAgent.Message.t()
  @opaque t :: %__MODULE__{
            entries: :array.array(Entry.t()),
            ids: occurrences(),
            tools: occurrences(),
            changes: :gb_trees.tree({non_neg_integer(), non_neg_integer()}, nil)
          }

  @doc "Builds active storage at an explicit snapshot/reset boundary."
  @spec new([TranscriptEntry.t()], non_neg_integer()) :: t()
  def new(entries, revision) do
    empty = %__MODULE__{entries: :array.new(), ids: %{}, tools: %{}, changes: :gb_trees.empty()}
    Enum.reduce(entries, empty, &append(&2, &1, revision))
  end

  @doc "Returns the number of active entries without enumeration."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: :array.size(entries)

  @doc "Fetches an ordinal, supporting the existing negative-index update semantics."
  @spec at(t(), integer()) :: Entry.t() | nil
  def at(%__MODULE__{} = active, ordinal) do
    ordinal = if ordinal < 0, do: size(active) + ordinal, else: ordinal
    fetch(active, ordinal)
  end

  defp fetch(active, ordinal) when ordinal >= 0 do
    if ordinal < size(active), do: :array.get(ordinal, active.entries), else: nil
  end

  defp fetch(_active, _ordinal), do: nil

  @doc "Appends one entry without visiting the retained prefix."
  @spec append(t(), TranscriptEntry.t(), non_neg_integer()) :: t()
  def append(%__MODULE__{} = active, %TranscriptEntry{} = payload, revision) do
    entry = Entry.new(payload, size(active), revision)

    %{
      active
      | entries: :array.set(entry.ordinal, entry, active.entries),
        ids: add_occurrence(active.ids, entry.id, entry.ordinal),
        tools: index_tool(active.tools, entry.message, entry.ordinal),
        changes: :gb_trees.insert({revision, entry.ordinal}, nil, active.changes)
    }
  end

  @doc "Revises an indexed entry and replaces its single live change-index record."
  @spec update_at(
          t(),
          integer(),
          (message() -> message()),
          non_neg_integer()
        ) :: t()
  def update_at(%__MODULE__{} = active, ordinal, transform, revision) do
    case at(active, ordinal) do
      nil -> active
      entry -> replace(active, entry, transform.(entry.message), revision)
    end
  end

  defp replace(active, %Entry{message: message}, message, _revision), do: active

  defp replace(active, entry, message, revision) do
    updated = Entry.revise(entry, message, revision)

    changes = :gb_trees.delete({entry.change_revision, entry.ordinal}, active.changes)

    %{
      active
      | entries: :array.set(entry.ordinal, updated, active.entries),
        tools: replace_tool_index(active.tools, entry.message, message, entry.ordinal),
        changes: :gb_trees.insert({revision, entry.ordinal}, nil, changes)
    }
  end

  @doc "Transforms active messages; only changed entries receive revision facts."
  @spec transform(t(), (message() -> message()), non_neg_integer()) :: t()
  def transform(%__MODULE__{} = active, transform, revision) do
    :array.foldl(
      fn ordinal, _entry, next -> update_at(next, ordinal, transform, revision) end,
      active,
      active.entries
    )
  end

  @doc "Returns matching tool occurrences in source order without scanning other entries."
  @spec tool_ordinals(t(), String.t()) :: [non_neg_integer()]
  def tool_ordinals(%__MODULE__{} = active, id), do: occurrences(active.tools, id)

  @doc "Returns the latest tool occurrence directly from its ordered index."
  @spec latest_tool_ordinal(t(), String.t()) :: non_neg_integer() | nil
  def latest_tool_ordinal(%__MODULE__{} = active, id) do
    case Map.fetch(active.tools, id) do
      :error -> nil
      {:ok, ordinals} -> :gb_sets.largest(ordinals)
    end
  end

  @doc "Returns matching stable-ID occurrences in source order."
  @spec id_ordinals(t(), pos_integer()) :: [non_neg_integer()]
  def id_ordinals(%__MODULE__{} = active, id), do: occurrences(active.ids, id)

  @doc "Reads up to `limit` active entries immediately before a unique message identity."
  @spec before(t(), pos_integer() | :tail, pos_integer()) ::
          {:ok, [Entry.t()], boolean()} | {:error, :anchor_unavailable}
  def before(%__MODULE__{} = active, :tail, limit),
    do: read_before(active.entries, size(active), limit)

  def before(%__MODULE__{entries: entries, ids: ids}, id, limit) do
    with {:ok, ordinals} <- Map.fetch(ids, id),
         1 <- :gb_sets.size(ordinals) do
      read_before(entries, :gb_sets.smallest(ordinals), limit)
    else
      _missing_or_ambiguous -> {:error, :anchor_unavailable}
    end
  end

  @spec read_before(:array.array(Entry.t()), non_neg_integer(), pos_integer()) ::
          {:ok, [Entry.t()], boolean()}
  defp read_before(entries, exclusive_end, limit) do
    start = max(exclusive_end - limit, 0)
    {:ok, collect_before(entries, start, exclusive_end, []), start > 0}
  end

  @spec collect_before(:array.array(Entry.t()), non_neg_integer(), non_neg_integer(), [Entry.t()]) ::
          [Entry.t()]
  defp collect_before(_entries, start, start, acc), do: acc

  defp collect_before(entries, start, exclusive_end, acc) do
    ordinal = exclusive_end - 1
    collect_before(entries, start, ordinal, [:array.get(ordinal, entries) | acc])
  end

  @doc "Materializes messages directly at the provider/persistence list boundary."
  @spec messages(t()) :: [message()]
  def messages(%__MODULE__{entries: entries}) do
    :array.foldr(fn _ordinal, entry, acc -> [entry.message | acc] end, [], entries)
  end

  @doc "Materializes ordered messages and their aligned stable IDs in one traversal."
  @spec messages_and_ids(t()) :: {[message()], [pos_integer()]}
  def messages_and_ids(%__MODULE__{entries: entries}) do
    :array.foldr(
      fn _ordinal, entry, {messages, ids} -> {[entry.message | messages], [entry.id | ids]} end,
      {[], []},
      entries
    )
  end

  @doc "Materializes identified messages directly at the explicit list boundary."
  @spec messages_with_ids(t()) :: [{pos_integer(), message()}]
  def messages_with_ids(%__MODULE__{entries: entries}) do
    :array.foldr(fn _ordinal, entry, acc -> [{entry.id, entry.message} | acc] end, [], entries)
  end

  @doc "Materializes current ordered entries at an explicit snapshot boundary."
  @spec snapshot(t()) :: [Entry.t()]
  def snapshot(%__MODULE__{} = active), do: :array.to_list(active.entries)

  @doc "Freezes current identified messages at the branch list boundary."
  @spec freeze(t()) :: [TranscriptEntry.t()]
  def freeze(%__MODULE__{entries: entries}) do
    :array.foldr(fn _ordinal, entry, acc -> [Entry.freeze(entry) | acc] end, [], entries)
  end

  @doc """
  Fetches only current entries changed after revision, ordered by ordinal.

  Discovery is O(log M + K); ordinal sorting is O(K log K), indexed payload
  fetches are O(K log M). Processing the returned changed payloads is additional.
  """
  @spec changed_since(t(), non_neg_integer()) :: [Entry.t()]
  def changed_since(%__MODULE__{} = active, revision) do
    :gb_trees.iterator_from({revision + 1, 0}, active.changes)
    |> changed_ordinals([])
    |> Enum.sort()
    |> Enum.map(&:array.get(&1, active.entries))
  end

  @doc "Returns retained change-record count without materializing entries."
  @spec change_count(t()) :: non_neg_integer()
  def change_count(%__MODULE__{} = active), do: :gb_trees.size(active.changes)

  defp changed_ordinals(iterator, ordinals) do
    case :gb_trees.next(iterator) do
      :none -> ordinals
      {{_revision, ordinal}, nil, next} -> changed_ordinals(next, [ordinal | ordinals])
    end
  end

  defp occurrences(index, key) do
    case Map.fetch(index, key) do
      :error -> []
      {:ok, ordinals} -> :gb_sets.to_list(ordinals)
    end
  end

  defp add_occurrence(index, key, ordinal) do
    Map.update(index, key, :gb_sets.singleton(ordinal), &:gb_sets.add(ordinal, &1))
  end

  defp index_tool(index, {:tool_call, %ToolCall{id: id}}, ordinal),
    do: add_occurrence(index, id, ordinal)

  defp index_tool(index, _message, _ordinal), do: index

  defp replace_tool_index(
         index,
         {:tool_call, %ToolCall{id: id}},
         {:tool_call, %ToolCall{id: id}},
         _ordinal
       ),
       do: index

  defp replace_tool_index(index, old, new, ordinal) do
    index |> remove_tool(old, ordinal) |> index_tool(new, ordinal)
  end

  defp remove_tool(index, {:tool_call, %ToolCall{id: id}}, ordinal) do
    ordinals = :gb_sets.delete(ordinal, Map.fetch!(index, id))
    if :gb_sets.is_empty(ordinals), do: Map.delete(index, id), else: Map.put(index, id, ordinals)
  end

  defp remove_tool(index, _message, _ordinal), do: index
end
