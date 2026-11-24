defmodule Minga.Test.ProvenanceModel do
  @moduledoc """
  A byte-by-byte reference for `Minga.Buffer.Provenance`.

  The model keeps one entry for every byte ever written, in document order, each with its author, the group that inserted it, the groups that deleted it, and the groups whose partial deletion of its replacement makes a reject inexact. It applies the same rules as the provenance tree with plain list scans, so property tests can compare the tree against it: an insertion goes immediately before the live byte at its offset, a deletion marks every entry from the first to the last deleted live byte and the text a replacement it consumed had replaced (and removes the ones its own group wrote, which can never be live again), and a byte is live when its inserting group is applied and none of its deleting groups is.
  """

  alias Minga.Buffer.Provenance

  defstruct entries: [], groups: %{}

  @type entry :: %{
          byte: byte(),
          author: Provenance.author(),
          group: pos_integer() | nil,
          deletions: [pos_integer()],
          overlaps: [{pos_integer(), pos_integer() | {:permanent, term()}}]
        }

  @type group :: %{author: Provenance.author(), key: Provenance.group_key(), applied: boolean()}

  @type t :: %__MODULE__{entries: [entry()], groups: %{pos_integer() => group()}}

  @doc "Returns a model of `text`, all of it unattributed."
  @spec new(binary()) :: t()
  def new(text) do
    entries =
      for <<byte <- text>>,
        do: %{byte: byte, author: :unattributed, group: nil, deletions: [], overlaps: []}

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
        left = if start > 0, do: Enum.at(live, start - 1)
        marked = MapSet.union(MapSet.new(first..last//1), covered(model, live, first, last, left))
        {owner, overlapped} = overlapped(model, group, live, marked, left, first, last)

        model.entries
        |> Enum.with_index()
        |> Enum.flat_map(fn {entry, index} ->
          entry =
            if MapSet.member?(overlapped, index) and {owner, group} not in entry.overlaps,
              do: %{entry | overlaps: [{owner, group} | entry.overlaps]},
              else: entry

          if MapSet.member?(marked, index), do: mark(entry, group), else: [entry]
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
      for <<byte <- inserted>>,
        do: %{byte: byte, author: author, group: group_id, deletions: [], overlaps: []}

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
    settled = if group.author == :you, do: {:permanent, :you}, else: {:permanent, group.key}

    entries =
      Enum.flat_map(model.entries, fn entry ->
        overlaps =
          Enum.flat_map(entry.overlaps, fn
            {^id, _overlap} -> []
            {owner, ^id} -> if group.applied, do: [{owner, settled}], else: []
            mark -> [mark]
          end)

        entry = %{entry | overlaps: overlaps}

        cond do
          id in entry.deletions and group.applied -> []
          entry.group == id and group.applied -> [%{entry | group: nil}]
          entry.group == id -> []
          true -> [%{entry | deletions: List.delete(entry.deletions, id)}]
        end
      end)

    %{model | entries: entries, groups: groups}
  end

  @doc """
  Returns the keys of the groups that make rejecting `ids` together inexact: groups outside `ids` that partly deleted one of their replacements, while applied or once permanent. Your groups are `:you`.
  """
  @spec overlaps_among(t(), [pos_integer()]) :: MapSet.t()
  def overlaps_among(model, ids) do
    for entry <- model.entries,
        entry.group in ids or Enum.any?(entry.deletions, &(&1 in ids)),
        {owner, overlap} <- entry.overlaps,
        owner in ids,
        key = overlap_key(model, ids, overlap),
        into: MapSet.new(),
        do: key
  end

  defp overlap_key(_model, _ids, {:permanent, key}), do: key

  defp overlap_key(model, ids, id) do
    group = Map.fetch!(model.groups, id)

    cond do
      id in ids -> nil
      not group.applied -> nil
      group.author == :you -> :you
      true -> group.key
    end
  end

  @doc "Returns every draft byte as `{group, index}`: a tombstone a Minga step wrote that a newer applied step of the same task deleted, both applied."
  @spec drafts(t()) :: [{pos_integer(), non_neg_integer()}]
  def drafts(model) do
    for {entry, index} <- Enum.with_index(model.entries),
        draft?(model, entry),
        do: {entry.group, index}
  end

  defp draft?(model, entry) do
    owner = entry.group && Map.fetch!(model.groups, entry.group)

    owner != nil and owner.applied and match?({:minga, task} when task != :untasked, owner.author) and
      not live?(model, entry) and
      Enum.any?(entry.deletions, &(&1 > entry.group and newer?(model, &1, owner.author)))
  end

  defp newer?(model, id, author) do
    group = Map.fetch!(model.groups, id)
    group.applied and group.author == author
  end

  @doc """
  Merges the oldest draft's group into the oldest newer step of the same task that deleted it, across the longest stretch of bytes around it that name either group, and drops bytes the newer step both wrote and deleted. Returns the model unchanged when there are no drafts.
  """
  @spec compact_oldest(t()) :: t()
  def compact_oldest(model) do
    case model |> drafts() |> Enum.min(fn -> nil end) do
      nil ->
        model

      {old, index} ->
        draft = Enum.at(model.entries, index)
        author = Map.fetch!(model.groups, old).author

        new =
          draft.deletions |> Enum.filter(&(&1 > old and newer?(model, &1, author))) |> Enum.min()

        names? = &(&1.group in [old, new] or old in &1.deletions or new in &1.deletions)
        indexed = Enum.with_index(model.entries)

        before =
          indexed
          |> Enum.take(index + 1)
          |> Enum.reverse()
          |> Enum.take_while(&names?.(elem(&1, 0)))

        after_draft = indexed |> Enum.drop(index) |> Enum.take_while(&names?.(elem(&1, 0)))
        from = before |> List.last() |> elem(1)
        to = after_draft |> List.last() |> elem(1)

        entries =
          Enum.flat_map(indexed, fn {entry, at} ->
            if at < from or at > to do
              [entry]
            else
              group = if entry.group == old, do: new, else: entry.group
              deletions = substitute(entry.deletions, old, new)

              if group == new and deletions == [new],
                do: [],
                else: [
                  %{
                    entry
                    | group: group,
                      deletions: deletions,
                      overlaps: rename_marks(entry.overlaps, old, new)
                  }
                ]
            end
          end)

        model = %{model | entries: entries}

        if Enum.any?(entries, &(&1.group == old or old in &1.deletions)) do
          model
        else
          entries = Enum.map(entries, &%{&1 | overlaps: rename_marks(&1.overlaps, old, new)})
          %{model | entries: entries, groups: Map.delete(model.groups, old)}
        end
    end
  end

  defp rename_marks(marks, old, new) do
    marks
    |> Enum.map(fn {owner, overlap} ->
      {if(owner == old, do: new, else: owner), if(overlap == old, do: new, else: overlap)}
    end)
    |> Enum.uniq()
  end

  defp substitute(list, old, new) do
    cond do
      old not in list -> list
      new in list -> List.delete(list, old)
      true -> Enum.map(list, &if(&1 == old, do: new, else: &1))
    end
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
        deleter != id,
        group = Map.fetch!(model.groups, deleter),
        group.applied and group.author != :you,
        into: MapSet.new(),
        do: group.key
  end

  # Deletions are prepended, so the groups that deleted an entry after `id` did come before it.
  defp later_deleters(%{group: id, deletions: deletions}, id), do: deletions
  defp later_deleters(entry, id), do: Enum.take_while(entry.deletions, &(&1 != id))

  # A deletion by another author that starts or ends strictly inside a Minga group's replacement marks that
  # replacement's tombstones: from the first deleted byte, over dead bytes and the owner's or the deleter's live text, to
  # the first tombstone the owner deleted, then every such tombstone in a row.
  defp overlapped(_model, :untracked, _live, _marked, _left, _first, _last),
    do: {nil, MapSet.new()}

  defp overlapped(model, group, live, marked, left, first, last) do
    author = Map.fetch!(model.groups, group).author
    live_after = MapSet.difference(MapSet.new(live), marked)
    right = Enum.find(live, &(&1 > last and MapSet.member?(live_after, &1)))

    owner =
      cond do
        same_replacement?(model, author, left, first) -> Enum.at(model.entries, first).group
        same_replacement?(model, author, last, right) -> Enum.at(model.entries, last).group
        true -> nil
      end

    # Bytes this group wrote and now deletes are gone, so the walk passes straight over them.
    dropped = MapSet.filter(marked, &(Enum.at(model.entries, &1).group == group))

    if owner,
      do: {owner, overlap_block(model, author, owner, live_after, dropped, first)},
      else: {nil, MapSet.new()}
  end

  defp same_replacement?(_model, _author, nil, _later), do: false
  defp same_replacement?(_model, _author, _before, nil), do: false

  defp same_replacement?(model, author, before, later) do
    owner = Enum.at(model.entries, before).group
    owner_group = owner && Map.fetch!(model.groups, owner)

    owner != nil and Enum.at(model.entries, later).group == owner and
      match?({:minga, _task}, owner_group.author) and
      owner_group.author != author and
      not (model.entries
           |> Enum.slice((before + 1)..(later - 1)//1)
           |> Enum.any?(&(owner in &1.deletions)))
  end

  defp overlap_block(model, author, owner, live_after, dropped, first) do
    rest =
      model.entries
      |> Enum.with_index()
      |> Enum.drop(first)
      |> Enum.reject(fn {_entry, index} -> MapSet.member?(dropped, index) end)

    walked =
      Enum.drop_while(rest, fn {entry, index} ->
        if MapSet.member?(live_after, index) do
          entry.group == owner or
            (entry.group != nil and Map.fetch!(model.groups, entry.group).author == author)
        else
          owner not in entry.deletions or entry.group == owner
        end
      end)

    case walked do
      [{entry, index} | _] = tombstones ->
        if MapSet.member?(live_after, index) or owner not in entry.deletions do
          MapSet.new()
        else
          tombstones
          |> Enum.take_while(fn {entry, index} ->
            not MapSet.member?(live_after, index) and owner in entry.deletions and
              entry.group != owner
          end)
          |> MapSet.new(&elem(&1, 1))
        end

      [] ->
        MapSet.new()
    end
  end

  # A deletion that consumes a replacement also covers the text it replaced. A replacement is one edit's inserted text
  # followed by the tombstones its group made, so the deletion consumes one when it ends with the group's text and does
  # not start inside the same replacement. It then marks the dead bytes right after it that the group deleted, up to the
  # first byte that is live, inserted by the group, or not deleted by it.
  defp covered(model, live, first, last, left_index) do
    owner = Enum.at(model.entries, last).group

    if owner == nil or inside?(model, left_index, first, owner) do
      MapSet.new()
    else
      live = MapSet.new(live)

      model.entries
      |> Enum.with_index()
      |> Enum.drop(last + 1)
      |> Enum.take_while(fn {entry, index} ->
        not MapSet.member?(live, index) and entry.group != owner and owner in entry.deletions
      end)
      |> MapSet.new(fn {_entry, index} -> index end)
    end
  end

  defp inside?(_model, nil, _first, _owner), do: false

  defp inside?(model, left_index, first, owner) do
    Enum.at(model.entries, left_index).group == owner and
      not (model.entries
           |> Enum.slice((left_index + 1)..(first - 1)//1)
           |> Enum.any?(&(owner in &1.deletions)))
  end

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
