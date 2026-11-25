defmodule Minga.Test.ProvenanceModel do
  @moduledoc """
  A byte-by-byte reference for `Minga.Buffer.Provenance` that never forgets anything.

  The model keeps one entry for every byte ever written, in document order, with its author, the group that inserted it, the groups that deleted it, its overlap marks, the replacement that made it (`made_by`) and the replacements that listed it as replaced (`replaced_by`). It never drops, absorbs or compacts a byte; a group that is discarded only becomes `final`, with its applied flag fixed. An untracked deletion is the pseudo group `:untracked`, always applied.

  ## Specification

  Five rules and one invariant. Each says what the model does and why, in terms of what you see in the document.

  1. **Visibility.** A byte is visible when the group that wrote it is applied and no group that deleted it is applied. Undo, redo and reject only flip groups, so each shows exactly the text those groups wrote or removed.
  2. **Placement.** An insertion goes immediately before the visible byte at its offset, after any deleted bytes there; a deletion marks every byte from its first to its last deleted visible byte. Text typed at a spot lands after text that used to be there, and text an older group removed from the middle of a range cannot come back inside text you deleted. Deleting a visible byte is a direct deletion; marking a byte that is already deleted is a sweep.
  3. **Replacement.** An edit that inserts text over a non-empty range is a replacement: it made the bytes it inserted, and it replaced the visible bytes in its range and the deleted bytes strictly inside it that can still come back. A byte can never come back when the group that wrote it is final and unapplied, or it was deleted by the group that wrote it, by an untracked change, or by a final applied group; it gets the deleter but no replacement lists it. No later edit can stand for text no history can ever show again.
  4. **Consumption.** A deletion that leaves none of an applied replacement's text visible covers what it replaced: every deleted byte the replacement replaced gets the deleter (a cover), and the replacements that made those bytes are examined in turn, each once. When some of the replacement's text stays visible and the deleter is another author than the replacement's Minga step, every byte the replacement made is marked with the deleter instead. A replacement whose group is not applied (undone, or discarded unapplied: it never happened) neither covers nor marks; the model logs it in `skipped`. When you delete what Minga wrote in place of some text, rejecting Minga must not bring that text back; when you delete only part of it, no one can say which part of the replaced text your edit stands for.
  5. **Exactness refusal.** No undo, redo or reject may show text beside a later rewrite of it. An undo or redo of a group is refused while a group that is not yours, applied and not final, deleted a byte the group wrote or deleted while it was visible, after it did, directly or by a sweep (a cover never counts), and the byte can still come back; a reject of a task is refused the same way by a task that started later, or while a group outside it that marked one of its replacements (rule 4) is applied, for good once that group is final and applied. Groups that revert together (a task's reject, a press's steps, a merged class) are checked as one set: a later deletion of a byte that a group in the set wrote and a group in the set deleted does not refuse them, since the byte stays dead when the set reverts, whoever else deleted it; a single group's undo or redo is checked alone. Undoing your replacement after Minga rewrote part of it would leave Minga's rewrite beside the text yours replaced, a document that never existed.

  **Invariant.** Steps that compaction merged never differ in applied or final state: they flip and finalize together. The group of a replacement is read from its first made run, and compaction can leave one replacement's made runs under both steps.

  A consequence, tested on its own: a cover only adds a deleter to bytes that are already deleted, so it never changes the document at the moment of the edit.

  `replay/2` applies a trace from `Minga.Buffer.Provenance.start_trace/1`, so a history driven through `Minga.Buffer.UndoHistory` can be checked against the model.
  """

  alias Minga.Buffer.Provenance

  defstruct entries: [], groups: %{}, next_change: 1, skipped: []

  @type deleter :: pos_integer() | :untracked

  @type entry :: %{
          byte: byte(),
          author: Provenance.author(),
          group: pos_integer() | nil,
          deletions: [deleter()],
          overlaps: [{pos_integer(), pos_integer()}],
          made_by: pos_integer() | nil,
          replaced_by: [pos_integer()],
          covered_by: [deleter()],
          swept_by: [deleter()]
        }

  @type group :: %{
          author: Provenance.author(),
          key: Provenance.group_key(),
          applied: boolean(),
          final: boolean()
        }

  @type t :: %__MODULE__{
          entries: [entry()],
          groups: %{pos_integer() => group()},
          next_change: pos_integer(),
          skipped: [{pos_integer(), pos_integer()}]
        }

  @doc "Returns a model of `text`, all of it unattributed."
  @spec new(binary()) :: t()
  def new(text),
    do: %__MODULE__{entries: for(<<byte <- text>>, do: entry(byte, :unattributed, nil, nil))}

  @doc "Registers a group under the id the provenance gave it."
  @spec open_group(t(), pos_integer(), Provenance.author(), Provenance.group_key()) :: t()
  def open_group(model, id, author, key) do
    group = %{author: author, key: key, applied: true, final: false}
    %{model | groups: Map.put(model.groups, id, group)}
  end

  @doc "Replaces `removed_bytes` live bytes at `start` with `inserted`, written by `group`."
  @spec edit(t(), pos_integer() | :untracked, non_neg_integer(), non_neg_integer(), binary()) ::
          t()
  def edit(model, group, start, removed_bytes, inserted) do
    live = live_indexes(model)
    insert_at = Enum.at(live, start, length(model.entries))

    {group_id, author} =
      case group do
        :untracked -> {nil, :unattributed}
        id -> {id, Map.fetch!(model.groups, id).author}
      end

    {model, made_by} =
      if removed_bytes > 0,
        do: delete(model, group, live, start, removed_bytes, inserted),
        else: {model, nil}

    new_entries = for <<byte <- inserted>>, do: entry(byte, author, group_id, made_by)
    {before, rest} = Enum.split(model.entries, insert_at)
    %{model | entries: before ++ new_entries ++ rest}
  end

  defp entry(byte, author, group, made_by) do
    %{
      byte: byte,
      author: author,
      group: group,
      deletions: [],
      overlaps: [],
      made_by: made_by,
      replaced_by: [],
      covered_by: [],
      swept_by: []
    }
  end

  defp delete(model, group, live, start, removed_bytes, inserted) do
    first = Enum.at(live, start)
    last = Enum.at(live, start + removed_bytes - 1)
    live_set = MapSet.new(live)

    seeds =
      for index <- first..last//1,
          MapSet.member?(live_set, index),
          made_by = Enum.at(model.entries, index).made_by,
          made_by != nil,
          uniq: true,
          do: made_by

    change = if inserted != "" and group != :untracked, do: model.next_change

    entries =
      model.entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        if index >= first and index <= last do
          # Text that can never come back is not replaced by anyone, though it gets the deleter.
          listed? = change != nil and not dead_forever?(model, entry)
          kind = if MapSet.member?(live_set, index), do: :direct, else: :sweep
          entry = add_deleter(entry, group, kind)
          if listed?, do: %{entry | replaced_by: [change | entry.replaced_by]}, else: entry
        else
          entry
        end
      end)

    model = consume(%{model | entries: entries}, group, seeds, MapSet.new(seeds))
    if change, do: {%{model | next_change: change + 1}, change}, else: {model, nil}
  end

  # A direct deletion rewrote the byte; a sweep kept a deleted byte out; a cover only took it with the replacement it
  # consumed. A group's strongest kind wins: direct over sweep over cover, in either order.
  defp add_deleter(entry, deleter, :direct) do
    entry = %{
      entry
      | covered_by: List.delete(entry.covered_by, deleter),
        swept_by: List.delete(entry.swept_by, deleter)
    }

    if deleter in entry.deletions,
      do: entry,
      else: %{entry | deletions: [deleter | entry.deletions]}
  end

  defp add_deleter(entry, deleter, :sweep) do
    cond do
      # A sweep counts over an earlier cover by the same group, as it does in either order.
      deleter in entry.covered_by ->
        %{
          entry
          | covered_by: List.delete(entry.covered_by, deleter),
            swept_by: [deleter | entry.swept_by]
        }

      deleter in entry.deletions ->
        entry

      true ->
        %{entry | deletions: [deleter | entry.deletions], swept_by: [deleter | entry.swept_by]}
    end
  end

  # A group that deleted the byte before, directly or by a sweep, keeps that kind when it covers it too.
  defp add_deleter(entry, deleter, :cover) do
    if deleter in entry.deletions,
      do: entry,
      else: %{
        entry
        | deletions: [deleter | entry.deletions],
          covered_by: [deleter | entry.covered_by]
      }
  end

  # The cover worklist over bytes: each replacement once, in the order reached.
  defp consume(model, _deleter, [], _seen), do: model

  defp consume(model, deleter, [change | rest], seen) do
    indexed = Enum.with_index(model.entries)
    made = for {entry, _index} <- indexed, entry.made_by == change, do: entry
    owner = Enum.find_value(made, & &1.group)

    cond do
      # A change carries its replacement only while it is applied.
      owner != nil and not Map.fetch!(model.groups, owner).applied ->
        model = %{model | skipped: [{change, owner} | model.skipped]}
        consume(model, deleter, rest, seen)

      Enum.any?(made, &live?(model, &1)) ->
        consume(mark_part(model, deleter, owner, change), deleter, rest, seen)

      true ->
        cover(model, deleter, change, indexed, rest, seen)
    end
  end

  defp cover(model, deleter, change, indexed, rest, seen) do
    covered =
      for {entry, index} <- indexed,
          change in entry.replaced_by,
          not live?(model, entry),
          into: MapSet.new(),
          do: index

    reached =
      for index <- Enum.sort(covered),
          maker = Enum.at(model.entries, index).made_by,
          maker != nil,
          not MapSet.member?(seen, maker),
          uniq: true,
          do: maker

    entries =
      model.entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        if MapSet.member?(covered, index), do: add_deleter(entry, deleter, :cover), else: entry
      end)

    consume(%{model | entries: entries}, deleter, reached ++ rest, Enum.into(reached, seen))
  end

  # A partly consumed replacement of another author's Minga step: every byte it made is marked.
  defp mark_part(model, :untracked, _owner, _change), do: model
  defp mark_part(model, _deleter, nil, _change), do: model

  defp mark_part(model, deleter, owner, change) do
    owner_author = Map.fetch!(model.groups, owner).author

    if match?({:minga, _task}, owner_author) and
         owner_author != Map.fetch!(model.groups, deleter).author do
      entries =
        Enum.map(model.entries, fn entry ->
          if entry.made_by == change and {owner, deleter} not in entry.overlaps,
            do: %{entry | overlaps: [{owner, deleter} | entry.overlaps]},
            else: entry
        end)

      %{model | entries: entries}
    else
      model
    end
  end

  @doc "Sets whether a group is applied. A final group cannot change."
  @spec set_applied(t(), pos_integer(), boolean()) :: t()
  def set_applied(model, id, applied) do
    group = Map.fetch!(model.groups, id)
    if group.final, do: raise(ArgumentError, "group #{id} is final")
    %{model | groups: %{model.groups | id => %{group | applied: applied}}}
  end

  @doc "Makes a group final, keeping every byte: its applied flag never changes again."
  @spec discard(t(), pos_integer()) :: t()
  def discard(model, id),
    do: %{model | groups: Map.update!(model.groups, id, &%{&1 | final: true})}

  @doc "Returns whether a group is final."
  @spec final?(t(), pos_integer()) :: boolean()
  def final?(model, id), do: Map.fetch!(model.groups, id).final

  @doc """
  Returns the keys of the groups that make rejecting `ids` together inexact: groups outside `ids` that partly consumed one of their replacements and are applied (a final applied group counts for good). Your groups are `:you`.
  """
  @spec overlaps_among(t(), [pos_integer()]) :: MapSet.t()
  def overlaps_among(model, ids) do
    for entry <- model.entries,
        entry.group in ids or Enum.any?(entry.deletions, &(&1 in ids)),
        {owner, overlap} <- entry.overlaps,
        owner in ids,
        overlap not in ids,
        group = Map.fetch!(model.groups, overlap),
        group.applied,
        into: MapSet.new(),
        do: if(group.author == :you, do: :you, else: group.key)
  end

  @doc """
  Returns the keys of the applied groups that are not final, that `blocks?` accepts (given author and key), and that deleted text group `id` wrote or removed while it was visible, after it did, directly or by a sweep. A deletion a cover added does not count, and neither do bytes that can never come back.
  """
  @spec blockers(t(), pos_integer(), (Provenance.author(), Provenance.group_key() -> boolean())) ::
          MapSet.t()
  def blockers(model, id, blocks? \\ fn author, _key -> author != :you end) do
    for entry <- model.entries,
        removed_by?(entry, id),
        not dead_forever?(model, entry),
        deleter <- later_deleters(entry, id),
        deleter != id and deleter != :untracked,
        deleter not in entry.covered_by,
        group = Map.fetch!(model.groups, deleter),
        group.applied and not group.final and blocks?.(group.author, group.key),
        into: MapSet.new(),
        do: group.key
  end

  @doc """
  Returns the blockers of reverting the groups in `ids` together: `blockers/3` of each, except that a later deletion of a byte one of them wrote and one of them deleted does not count, since the byte stays dead when they revert, whoever else deleted it.
  """
  @spec blockers_among(t(), [pos_integer()], (Provenance.author(), Provenance.group_key() ->
                                                boolean())) ::
          MapSet.t()
  def blockers_among(model, ids, blocks?) do
    set = MapSet.new(ids)

    for id <- ids,
        entry <- model.entries,
        not internal?(entry, set),
        removed_by?(entry, id),
        not dead_forever?(model, entry),
        deleter <- later_deleters(entry, id),
        deleter != id and deleter != :untracked,
        deleter not in entry.covered_by,
        group = Map.fetch!(model.groups, deleter),
        group.applied and not group.final and blocks?.(group.author, group.key),
        into: MapSet.new(),
        do: group.key
  end

  defp internal?(entry, set),
    do: MapSet.member?(set, entry.group) and Enum.any?(entry.deletions, &MapSet.member?(set, &1))

  # The group wrote the byte or deleted it while it was visible; a sweep or a cover never removed it.
  defp removed_by?(%{group: id}, id), do: true

  defp removed_by?(entry, id),
    do: id in entry.deletions and id not in entry.covered_by and id not in entry.swept_by

  # Deletions are prepended, so the groups that deleted an entry after `id` did come before it.
  defp later_deleters(%{group: id, deletions: deletions}, id), do: deletions
  defp later_deleters(entry, id), do: Enum.take_while(entry.deletions, &(&1 != id))

  @doc "Returns whether a byte can never be live again, whatever is undone or rejected from now on."
  @spec dead_forever?(t(), entry()) :: boolean()
  def dead_forever?(model, entry) do
    writer = entry.group && Map.fetch!(model.groups, entry.group)

    (writer != nil and writer.final and not writer.applied) or
      Enum.any?(entry.deletions, fn
        :untracked -> true
        id when id == entry.group -> true
        id -> match?(%{final: true, applied: true}, Map.fetch!(model.groups, id))
      end)
  end

  @doc "Returns the live text."
  @spec text(t()) :: binary()
  def text(model), do: for(entry <- live_entries(model), into: <<>>, do: <<entry.byte>>)

  @doc "Returns the author of every live byte, in order."
  @spec authors(t()) :: [Provenance.author()]
  def authors(model), do: Enum.map(live_entries(model), & &1.author)

  @doc "Returns whether an entry is live."
  @spec live?(t(), entry()) :: boolean()
  def live?(model, entry) do
    inserted? = entry.group == nil or Map.fetch!(model.groups, entry.group).applied

    inserted? and
      not Enum.any?(entry.deletions, fn
        :untracked -> true
        id -> Map.fetch!(model.groups, id).applied
      end)
  end

  @doc "Replays a `Minga.Buffer.Provenance` trace, oldest operation first, and returns the model after it."
  @spec replay(t(), [tuple()]) :: t()
  def replay(model, operations), do: Enum.reduce(operations, model, &apply_operation(&2, &1))

  defp apply_operation(model, {:open_group, id, author, key}),
    do: open_group(model, id, author, key)

  defp apply_operation(model, {:edit, group, start, removed, inserted}),
    do: edit(model, group, start, byte_size(removed), inserted)

  defp apply_operation(model, {:edit_all, group, changes}) do
    changes
    |> Enum.reverse()
    |> Enum.reduce(model, fn {start, removed, inserted}, acc ->
      edit(acc, group, start, byte_size(removed), inserted)
    end)
  end

  defp apply_operation(model, {:set_applied, ids, applied}),
    do: Enum.reduce(ids, model, &set_applied(&2, &1, applied))

  defp apply_operation(model, {:discard, ids}), do: Enum.reduce(ids, model, &discard(&2, &1))

  # A merge keeps every byte; it changes nothing for histories in which the two steps always move together.
  defp apply_operation(model, {:absorb, _old, _new}), do: model

  @spec live_indexes(t()) :: [non_neg_integer()]
  defp live_indexes(model) do
    for {entry, index} <- Enum.with_index(model.entries), live?(model, entry), do: index
  end

  @spec live_entries(t()) :: [entry()]
  defp live_entries(model), do: Enum.filter(model.entries, &live?(model, &1))
end
