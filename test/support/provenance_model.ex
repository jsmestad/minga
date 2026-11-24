defmodule Minga.Test.ProvenanceModel do
  @moduledoc """
  A byte-by-byte reference for `Minga.Buffer.Provenance`.

  The model keeps one entry for every byte ever written, in document order, each with its author, the group that inserted it, and the groups that deleted it. It applies the same rules as the provenance tree with plain list scans, so property tests can compare the tree against it: an insertion goes immediately before the live byte at its offset, a deletion marks every entry from the first to the last deleted live byte (and removes the ones its own group wrote, which can never be live again), and a byte is live when its inserting group is applied and none of its deleting groups is.
  """

  alias Minga.Buffer.Provenance

  defstruct entries: [], groups: %{}

  @type entry :: %{
          byte: byte(),
          author: Provenance.author(),
          group: pos_integer() | nil,
          deletions: [pos_integer()]
        }

  @type group :: %{author: Provenance.author(), key: Provenance.group_key(), applied: boolean()}

  @type t :: %__MODULE__{entries: [entry()], groups: %{pos_integer() => group()}}

  @doc "Returns a model of `text`, all of it unattributed."
  @spec new(binary()) :: t()
  def new(text) do
    entries =
      for <<byte <- text>>, do: %{byte: byte, author: :unattributed, group: nil, deletions: []}

    %__MODULE__{entries: entries}
  end

  @doc "Registers a group under the id the provenance gave it."
  @spec open_group(t(), pos_integer(), Provenance.author(), Provenance.group_key()) :: t()
  def open_group(model, id, author, key) do
    %{model | groups: Map.put(model.groups, id, %{author: author, key: key, applied: true})}
  end

  @doc "Replaces `removed_bytes` live bytes at `start` with `inserted`, written by `group`."
  @spec edit(t(), pos_integer() | :untracked, non_neg_integer(), non_neg_integer(), binary()) ::
          t()
  def edit(model, group, start, removed_bytes, inserted) do
    live = live_indexes(model)
    insert_at = Enum.at(live, start, length(model.entries))

    entries =
      if removed_bytes > 0 do
        first = Enum.at(live, start)
        last = Enum.at(live, start + removed_bytes - 1)

        model.entries
        |> Enum.with_index()
        |> Enum.flat_map(fn {entry, index} ->
          if index in first..last//1, do: mark(entry, group), else: [entry]
        end)
      else
        model.entries
      end

    {group_id, author} =
      case group do
        :untracked -> {nil, :unattributed}
        id -> {id, Map.fetch!(model.groups, id).author}
      end

    new_entries =
      for <<byte <- inserted>>, do: %{byte: byte, author: author, group: group_id, deletions: []}

    {before, rest} = Enum.split(entries, insert_at)
    %{model | entries: before ++ new_entries ++ rest}
  end

  @doc "Sets whether a group is applied."
  @spec set_applied(t(), pos_integer(), boolean()) :: t()
  def set_applied(model, id, applied) do
    %{model | groups: Map.update!(model.groups, id, &%{&1 | applied: applied})}
  end

  @doc "Forgets a group whose state is final, keeping the live text unchanged."
  @spec discard(t(), pos_integer()) :: t()
  def discard(model, id) do
    {group, groups} = Map.pop!(model.groups, id)

    entries =
      Enum.flat_map(model.entries, fn entry ->
        cond do
          id in entry.deletions and group.applied -> []
          entry.group == id and group.applied -> [%{entry | group: nil}]
          entry.group == id -> []
          true -> [%{entry | deletions: List.delete(entry.deletions, id)}]
        end
      end)

    %{model | entries: entries, groups: groups}
  end

  @doc "Returns the live text."
  @spec text(t()) :: binary()
  def text(model), do: for(entry <- live_entries(model), into: <<>>, do: <<entry.byte>>)

  @doc "Returns the author of every live byte, in order."
  @spec authors(t()) :: [Provenance.author()]
  def authors(model), do: Enum.map(live_entries(model), & &1.author)

  @doc "Returns the keys of every applied group not authored by you that deleted text this group wrote or removed, after this group did."
  @spec blockers(t(), pos_integer()) :: MapSet.t()
  def blockers(model, id) do
    for entry <- model.entries,
        entry.group == id or id in entry.deletions,
        deleter <- later_deleters(entry, id),
        group = Map.fetch!(model.groups, deleter),
        group.applied and group.author != :you,
        into: MapSet.new(),
        do: group.key
  end

  # Deletions are prepended, so the groups that deleted an entry after `id` did come before it.
  defp later_deleters(%{group: id, deletions: deletions}, id), do: deletions
  defp later_deleters(entry, id), do: Enum.take_while(entry.deletions, &(&1 != id))

  @spec mark(entry(), pos_integer() | :untracked) :: [entry()]
  defp mark(_entry, :untracked), do: []

  # A group deleting text it wrote leaves text that can never be live again; it is gone.
  defp mark(%{group: id}, id), do: []

  defp mark(entry, id) do
    if id in entry.deletions, do: [entry], else: [%{entry | deletions: [id | entry.deletions]}]
  end

  @spec live_indexes(t()) :: [non_neg_integer()]
  defp live_indexes(model) do
    for {entry, index} <- Enum.with_index(model.entries), live?(model, entry), do: index
  end

  @spec live_entries(t()) :: [entry()]
  defp live_entries(model), do: Enum.filter(model.entries, &live?(model, &1))

  @spec live?(t(), entry()) :: boolean()
  defp live?(model, entry) do
    inserted? = entry.group == nil or Map.fetch!(model.groups, entry.group).applied
    inserted? and not Enum.any?(entry.deletions, &Map.fetch!(model.groups, &1).applied)
  end
end
