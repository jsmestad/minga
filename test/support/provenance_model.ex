defmodule Minga.Test.ProvenanceModel do
  @moduledoc """
  A byte-by-byte reference for `Minga.Buffer.Provenance` that never forgets anything.

  The model keeps one entry for every byte ever written, in document order, with its author, the group that inserted it, the groups that deleted it, its overlap marks, the replacement that made it (`made_by`) and the replacements that listed it as replaced (`replaced_by`). It never drops, absorbs or compacts a byte; a group that is discarded only becomes `final`, with its applied flag fixed. An untracked deletion is the pseudo group `:untracked`, always applied.

  ## Specification

  Each statement says what the model does and why, in terms of what you see in the document.

  1. A byte is visible when the group that wrote it is applied and no group that deleted it is applied. Undo, redo and reject only flip groups, so every one of them shows exactly the text those groups wrote or removed.
  2. An insertion goes immediately before the visible byte at its offset, after any deleted bytes there. Text typed at a spot lands after text that used to be there, so restoring that older text later puts it back before yours.
  3. A deletion marks every byte from its first to its last deleted visible byte, deleted bytes between them included. Text an older group removed from the middle of the range cannot come back inside text you deleted. Marking a byte that is already deleted is a sweep: it keeps the byte out, but the group never removed it.
  4. An edit that inserts text over a non-empty range is a replacement. It made the bytes it inserted. It replaced the visible bytes in its range and the deleted bytes strictly inside it that can still come back. A byte that can never come back (statement 9) is not replaced by anyone, though it gets the deleter: no later edit can stand for text no history can ever show again.
  5. A deletion consumes a replacement when none of the bytes the replacement made stays visible. It then deletes every deleted byte the replacement replaced as well, and the replacements that made those bytes are examined in turn, each once. When you delete what Minga wrote in place of some text, rejecting Minga must not bring that text back, because you removed its stand-in.
  6. A replacement that keeps a visible byte was only partly consumed. When it is a Minga step's and the deleter is another author, every byte it made gets an overlap mark naming the deleter. A part of a replacement cannot say which part of the replaced text it stands for, so rejecting the step must be refused (rule 8) until that deletion is undone.
  7. A change carries its replacement only while its group is applied. A reached replacement whose group is undone, or was discarded unapplied (it never happened), neither covers nor marks; the model logs it in `skipped`. Text a step that never happened replaced is visible again, and nothing anyone deletes later stands for it.
  8. Rejecting a set of groups is refused while a group outside the set marked one of their replacements (statement 6) and is applied, for good once it is final and applied. An inexact reject would change text you did not ask to change.
  9. A byte can never come back when the group that wrote it is final and unapplied, when it was deleted by the group that wrote it, by an untracked change, or by a final applied group. No undo, redo or reject can show it again.
  10. A cover adds a deleter only to bytes that are already deleted. A cover never changes the document at the moment of the edit; it only decides what later undo, redo or reject shows.
  11. `u` is refused when a later step rewrote the group's text: a group that is not yours, applied and not final, deleted (directly or by a sweep, not through a cover) a byte the undone group wrote or deleted while it was visible, after it did, and the byte can still come back. A byte the undone group only swept or covered is not text it removed. Undoing then would leave Minga's rewrite beside the text yours replaced, a document that never existed. A cover is derived, not a rewrite: deleting Minga's stand-in takes the replaced text along, and that never refuses anything. The same rule refuses a reject while another task that started later rewrote the task's text.

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

  # A direct deletion rewrote the byte; a cover only took it with the replacement it consumed. A direct deletion by a
  # group that covered the byte before makes that deletion direct.
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
    if deleter in entry.deletions,
      do: entry,
      else: %{
        entry
        | deletions: [deleter | entry.deletions],
          swept_by: [deleter | entry.swept_by]
      }
  end

  defp add_deleter(entry, deleter, :cover) do
    cond do
      # A group that only swept the byte and now covers it counts as covering it, in either order.
      deleter in entry.swept_by ->
        %{
          entry
          | swept_by: List.delete(entry.swept_by, deleter),
            covered_by: [deleter | entry.covered_by]
        }

      deleter in entry.deletions ->
        entry

      true ->
        %{
          entry
          | deletions: [deleter | entry.deletions],
            covered_by: [deleter | entry.covered_by]
        }
    end
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
  Returns the keys of the applied groups that are not final, that `blocks?` accepts (given author and key), and that directly deleted text group `id` wrote or removed after it did. A deletion a cover added does not count, and neither do bytes that can never come back.
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
