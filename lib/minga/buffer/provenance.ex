defmodule Minga.Buffer.Provenance do
  @moduledoc """
  Who wrote each byte of a buffer, and the history that can take each author's work back out.

  The document is a sequence of authorship runs (`Minga.Buffer.Provenance.Run`) held in a balanced sum tree in document order. Each run names its author and the history group that inserted it, and lists the groups that deleted it. A run is live, and its text is in the document, when the group that inserted it is applied and no group that deleted it is applied. Deleted text stays in the tree as a tombstone that keeps its text, so it can be restored exactly where it was.

  A history group (`Minga.Buffer.Provenance.Group`) is one of your undo steps or one Minga step. Undoing, redoing, or rejecting a group flips whether it is applied (`revert/3`, `reapply/3`); every run it touched then turns live or dead on its own, and the document changes by exactly the text of that group. Because a group finds its runs by locator, not by byte offset, edits made by anyone else after it, above or inside it, never make it point at the wrong text.

  ## Edit order

  An insertion at byte `p` goes immediately before the live byte that was at `p`, so it lands after any tombstones that sit at `p`. A deletion kills the live runs in its range and also marks every tombstone strictly inside the range, so restoring that older text later cannot reappear in the middle of text a later edit removed.

  ## Replacements

  An edit that inserts text over a non-empty range is a replacement, recorded by identity as a `Minga.Buffer.Provenance.Change`. It made the runs it inserted. It replaced the live runs in its range and the tombstones strictly inside it that can still come back; text already gone for good (deleted by its own writer, by an untracked change or by a kept group, or written by a group discarded unapplied) is dropped from the tree and replaced by no one.

  A deletion consumes a replacement when none of its made runs stays live. It then deletes the dead runs the replacement replaced too, and examines each replacement that made those runs, or that the replacement pulls, each once. A replacement that keeps live text is only partly consumed: when it is another author's Minga step, its runs get an overlap mark, and rejecting that step is refused while the deleting group is applied. A cover only adds a deleter to dead runs, so it never changes the document. A change carries its replacement only while its group is applied: a reached change whose group is undone, or was discarded unapplied (it never happened), neither covers nor marks.

  ## Record lifecycle

  A record is in one of three states.

  1. **With text.** Created by an edit that inserted text over a non-empty range, unless it could never cover, pull or mark (it replaced nothing, pulls nothing, and is not a Minga step's). `made` lists its runs; a split adds the new piece. Its group is the writer of its first made run (`owner: :runs`). It retires to nothing when it has nothing replaced, pulls nothing, and its runs belong to no Minga step: its runs forget it.
  2. **Run-less, pulled.** When its last made run is dropped, the record keeps that run's group as `owner` (listed in the group-to-records index) and stays while another record pulls it. A record `p` pulls `q` when a run `q` made, which `p` had replaced, is dropped: consuming `p` still reaches `q`. Compaction that removes the owner renames it to the step that absorbed it. Discarding the owner kept makes the owner `:permanent`, which counts as applied.
  3. **Gone.** A run-less record that nothing pulls, or that has nothing replaced and pulls nothing, is removed; so is every record its owner's discard unapplied leaves behind, with its pull edges. Removing a record removes it from its runs' `replaced_by` and from every link.

  A run-less record that replaced nothing only links: it is spliced out, its pullers pulling its targets directly, when it belongs to the same group as each puller or is permanent. So records and pull edges stay bounded by the runs.

  **Invariant.** Steps that `absorb/4` merged never differ in applied or final state: the owner (`Minga.Buffer.UndoHistory`) flips and discards a merge class together. A change's group is read from its first made run, and a stretch can leave one change's made runs under both steps; that is harmless only under this invariant.

  Records settle at the end of each operation. `made` and `replaced` always equal a recomputation from the runs' `made_by` and `replaced_by`; `pulls`, `pulled_by` and `owner` record dropped runs and cannot be recomputed, so the never-drop reference model in the tests checks what they do.

  ## Lines

  Runs measure bytes only. A live run's text is in the document, not in the run, so splitting a run cannot count newlines without reading the document. Callers convert lines to bytes through the document's line index (`Minga.Buffer.Lines.start_of/2`) and query byte ranges here.

  ## Cost

  For n runs: applying an edit that touches k runs costs O((k + 1) log n); finding the author at a byte costs O(log n); listing the runs in a byte range costs O(log n + k); reverting or reapplying a group with k runs costs O(k log n) plus one pass over the document to apply its changes together.

  This module is pure. `Minga.Buffer.UndoHistory` owns the value and decides which groups exist; `Minga.Buffer.Process` keeps it in step with every change to the document.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Provenance.Change
  alias Minga.Buffer.Provenance.Group
  alias Minga.Buffer.Provenance.Locator
  alias Minga.Buffer.Provenance.Run
  alias Minga.Buffer.Provenance.RunTree
  alias Minga.Core.Unicode

  defstruct tree: nil,
            groups: %{},
            next_group: 1,
            deep: false,
            recent: [],
            fresh: [],
            overlap_runs: %{},
            drafts: :gb_sets.new(),
            next_change: 1,
            changes: %{},
            stale: [],
            faults: %{},
            group_marks: %{},
            owned: %{},
            trace: nil

  @opaque t :: %__MODULE__{
            tree: RunTree.t(),
            groups: %{Run.group_id() => Group.t()},
            next_group: pos_integer(),
            deep: boolean(),
            recent: [Locator.t()],
            fresh: [Locator.t()],
            overlap_runs: %{group_id() => [Locator.t()]},
            drafts: :gb_sets.set({group_id(), Locator.t()}),
            next_change: pos_integer(),
            changes: %{Change.id() => Change.t()},
            stale: [Change.id()],
            faults: %{(group_id() | :all) => true},
            group_marks: %{group_id() => [group_id() | {:permanent, term()}]},
            owned: %{group_id() => MapSet.t(Change.id())},
            trace: [tuple()] | nil
          }

  @type author :: Run.author()
  @type group_id :: Run.group_id()
  @type group_key :: Group.key()

  @typedoc "A byte range of the document, as start offset and end offset."
  @type byte_range :: {non_neg_integer(), non_neg_integer()}

  @typedoc "A live stretch of text with one author, and the key of the Minga step that wrote it, if any."
  @type span :: {non_neg_integer(), non_neg_integer(), author(), group_key()}

  @typep change :: {non_neg_integer(), non_neg_integer(), binary()}

  @doc "Returns provenance for a document of `size` bytes that all predates tracking."
  @spec new(non_neg_integer()) :: t()
  def new(size) when is_integer(size) and size >= 0 do
    tree =
      if size == 0,
        do: RunTree.new(),
        else:
          RunTree.insert(RunTree.new(), %Run{
            id: Locator.between(nil, nil),
            bytes: size,
            author: :unattributed
          })

    %__MODULE__{tree: tree}
  end

  @doc "Returns the document size in bytes that this provenance describes."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{tree: tree}), do: RunTree.size(tree)

  @doc "Opens a new applied group for edits by `author`, named `key` to callers, and returns its id."
  @spec open_group(t(), author(), group_key()) :: {group_id(), t()}
  def open_group(%__MODULE__{} = prov, author, key) do
    id = prov.next_group
    group = %Group{author: author, key: key}
    prov = %{prov | groups: Map.put(prov.groups, id, group), next_group: id + 1}
    {id, traced(prov, {:open_group, id, author, key})}
  end

  @doc """
  Starts recording every operation that changes what a reference model would hold: groups opened, edits, flips and discards, oldest first in `take_trace/1`. Tests replay the trace into a model that never forgets a byte; nothing records by default.
  """
  @spec start_trace(t()) :: t()
  def start_trace(%__MODULE__{} = prov), do: %{prov | trace: []}

  @doc "Returns the operations recorded since the last call, oldest first, or `nil` when not recording."
  @spec take_trace(t()) :: {[tuple()] | nil, t()}
  def take_trace(%__MODULE__{trace: nil} = prov), do: {nil, prov}
  def take_trace(%__MODULE__{trace: trace} = prov), do: {Enum.reverse(trace), %{prov | trace: []}}

  @spec traced(t(), tuple()) :: t()
  defp traced(%__MODULE__{trace: nil} = prov, _operation), do: prov

  defp traced(%__MODULE__{trace: trace} = prov, operation),
    do: %{prov | trace: [operation | trace]}

  @spec traced_flip(
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8},
          [group_id()],
          boolean()
        ) :: {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  defp traced_flip({:ok, document, first, prov}, ids, applied),
    do: {:ok, document, first, traced(prov, {:set_applied, ids, applied})}

  defp traced_flip(error, _ids, _applied), do: error

  @doc "Returns whether the group is applied."
  @spec applied?(t(), group_id()) :: boolean()
  def applied?(%__MODULE__{groups: groups}, id), do: Map.fetch!(groups, id).applied

  @doc "Returns the author of a group's text."
  @spec group_author(t(), group_id()) :: author()
  def group_author(%__MODULE__{groups: groups}, id), do: Map.fetch!(groups, id).author

  @doc "Returns the key the group was opened with."
  @spec group_key(t(), group_id()) :: group_key()
  def group_key(%__MODULE__{groups: groups}, id), do: Map.fetch!(groups, id).key

  @doc """
  Records that `group` replaced the bytes `removed` at `start` with `inserted`.

  `removed` must be exactly the document's bytes at `start` before the edit; its pieces become the tombstones' text. `group` must be applied. Pass `:untracked` for a change that no history can take back, such as text appended to a log buffer: its text is unattributed and the bytes it removes are forgotten.

  Raises `ArgumentError` when the removed range is outside the document.
  """
  @spec edit(t(), group_id() | :untracked, non_neg_integer(), binary(), binary()) :: t()
  def edit(%__MODULE__{} = prov, group, start, removed, inserted)
      when is_integer(start) and start >= 0 and is_binary(removed) and is_binary(inserted) do
    prov
    |> apply_edit(group, start, removed, inserted)
    |> traced({:edit, group, start, removed, inserted})
  end

  @spec apply_edit(t(), group_id() | :untracked, non_neg_integer(), binary(), binary()) :: t()
  defp apply_edit(prov, group, start, removed, inserted) do
    removed_bytes = byte_size(removed)

    if start + removed_bytes > size(prov) do
      raise ArgumentError,
            "edit at #{start} removes #{removed_bytes} bytes from a #{size(prov)}-byte document"
    end

    {group_id, author} = writer(prov, group)
    inserted_bytes = byte_size(inserted)

    cond do
      removed_bytes == 0 and inserted_bytes == 0 ->
        prov

      removed_bytes == 0 and inside_own_run?(prov, group_id, author, start) ->
        grow_run_at(prov, start, inserted_bytes)

      replacing_inside_run?(prov, group_id, start, removed_bytes) ->
        prov
        |> replace_inside_run(group_id, author, start, removed, inserted_bytes)
        |> renumber_when_deep()
        |> remember_fresh()
        |> settle_changes()

      true ->
        prov = prov |> split_at(start) |> split_at(start + removed_bytes)
        following = run_starting_at(prov.tree, start)
        preceding = preceding_run(prov.tree, following)

        change =
          if inserted_bytes > 0 and removed_bytes > 0 and group_id != nil, do: prov.next_change

        {prov, {killed, replaced, pulled}} =
          delete_from(prov, group_id, change, following, removed, 0, {[], [], []})

        {prov, made_by} = open_change(prov, change, replaced, pulled, author)

        prov
        |> consume(group_id, seeds(killed), fn _change, made -> any_live(made) end)
        |> insert_between(group_id, author, preceding, following, inserted_bytes, made_by)
        |> renumber_when_deep()
        |> remember_fresh()
        |> settle_changes()
    end
  end

  @doc """
  Applies several changes by one group, as `edit/5` would one at a time from the last to the first.

  `changes` are `{start, removed, inserted}`, in document order and disjoint, with offsets valid when the changes are applied from the last to the first. When they touch a large share of the runs (`mode` `:auto`, the default), one pass over every run applies them all and rebuilds the record in O(n), instead of O(log n) per change. `mode` `:batch` or `:each` forces one way, for tests. Both give the same text, authors, blockers, overlap marks and drafts.
  """
  @spec edit_all(
          t(),
          group_id() | :untracked,
          [{non_neg_integer(), binary(), binary()}],
          :auto | :batch | :each
        ) ::
          t()
  def edit_all(%__MODULE__{} = prov, group, changes, mode \\ :auto) when is_list(changes) do
    batch? =
      case mode do
        :auto -> length(changes) * 8 > RunTree.count(prov.tree)
        :batch -> changes != []
        :each -> false
      end

    edited =
      if batch?,
        do: edit_in_one_pass(prov, group, changes),
        else:
          changes
          |> Enum.reverse()
          |> Enum.reduce(prov, fn {start, removed, inserted}, acc ->
            apply_edit(acc, group, start, removed, inserted)
          end)

    traced(edited, {:edit_all, group, changes})
  end

  @doc """
  Unapplies a group and returns the document without its text.

  The group's inserted text leaves the document and the text it deleted comes back, unless another applied group deleted that text too. Returns the new document, with its cursor at the start, and the lowest byte offset that changed, or `nil` when the document did not change.

  Every change is located in `document` and all of them are applied together in one pass, so only the result must be valid UTF-8: a group whose edit split a code point restores it whole. When the result would not be valid UTF-8, because other groups' edits meet this group's inside one code point, returns `{:error, :invalid_utf8}` and nothing changes.
  """
  @spec revert(t(), group_id(), Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  def revert(%__MODULE__{} = prov, id, %Document{} = document),
    do: prov |> set_applied(id, false, document) |> traced_flip([id], false)

  @doc "Unapplies every group in `ids` together, in one pass over the document. See `revert/3`."
  @spec revert_all(t(), [group_id()], Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  def revert_all(%__MODULE__{} = prov, ids, %Document{} = document) when is_list(ids),
    do: prov |> set_applied_all(ids, false, document) |> traced_flip(ids, false)

  @doc "Applies a reverted group again and returns the document with its text. See `revert/3`."
  @spec reapply(t(), group_id(), Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  def reapply(%__MODULE__{} = prov, id, %Document{} = document),
    do: prov |> set_applied(id, true, document) |> traced_flip([id], true)

  @doc """
  Returns the key of an applied group that is not yours and deleted text this group wrote or removed after this group did, or `nil`.

  A step that deleted the same text earlier does not block: flipping this group leaves that text deleted by the earlier step either way.

  When it returns a key, flipping this group would change text that the other group rewrote, so your undo or redo must not happen.
  """
  @spec blocker(t(), group_id()) :: group_key() | nil
  def blocker(%__MODULE__{} = prov, id),
    do: blocker(prov, id, fn author, _key -> author != :you end)

  @doc """
  Returns the key of an applied group that `blocks?` accepts and that deleted text this group wrote or removed after this group did, or `nil`.

  Only text this group wrote, or deleted while it was visible, counts: a tombstone this group only swept (it lay strictly inside the group's deleted range) or covered is bookkeeping, not text the group removed. The later group counts when it deleted that text directly or by a sweep; a deletion a cover added (the group consumed a replacement, and the text that replacement replaced went with it) never blocks. `blocks?` receives the deleting group's author and key. `blocker/2` counts every group that is not yours; a reject counts the groups of other tasks.
  """
  @spec blocker(t(), group_id(), (author(), group_key() -> boolean())) :: group_key() | nil
  def blocker(%__MODULE__{groups: groups, tree: tree}, id, blocks?)
      when is_function(blocks?, 2) do
    Map.fetch!(groups, id).runs
    |> :gb_sets.to_list()
    |> Enum.find_value(fn run_id ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      run_blocker(run, id, groups, blocks?)
    end)
  end

  @spec run_blocker(
          Run.t(),
          group_id(),
          %{group_id() => Group.t()},
          (author(), group_key() -> boolean())
        ) :: group_key() | nil
  defp run_blocker(run, id, groups, blocks?) do
    if removed_by?(run, id) do
      run
      |> later_deleters(id)
      |> Enum.reject(&(&1 in run.covered_by))
      |> Enum.find_value(&blocking_key(groups, &1, id, blocks?))
    end
  end

  # Whether `id` wrote the run or deleted it while it was visible.
  # Sweeping it as a tombstone inside a range, or covering it with a consumed replacement, never makes a group the one
  # who removed it.
  @spec removed_by?(Run.t(), group_id()) :: boolean()
  defp removed_by?(%Run{group: id}, id), do: true

  defp removed_by?(run, id),
    do: id in run.deletions and id not in run.covered_by and id not in run.swept_by

  @doc """
  Returns every applied group not yours that deleted text group `id` wrote or removed after it did, as group ids.
  """
  @spec later_deleters_of(t(), group_id()) :: [group_id()]
  def later_deleters_of(%__MODULE__{groups: groups, tree: tree}, id) do
    groups
    |> Map.fetch!(id)
    |> Map.fetch!(:runs)
    |> :gb_sets.to_list()
    |> Enum.flat_map(fn run_id ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)

      for deleter <- later_deleters(run, id),
          deleter != id,
          deleting = Map.fetch!(groups, deleter),
          deleting.applied and deleting.author != :you,
          do: deleter
    end)
    |> Enum.uniq()
  end

  @doc """
  Returns a key that `blocker/3` would return for one of the groups in `ids`, or `nil` when none is blocked.

  When the groups hold a large share of the runs, one pass over every run answers in O(n) instead of looking each run up.
  """
  @spec blocker_among(t(), [group_id()], (author(), group_key() -> boolean())) ::
          group_key() | nil
  def blocker_among(%__MODULE__{} = prov, ids, blocks?)
      when is_list(ids) and is_function(blocks?, 2) do
    touched = Enum.reduce(ids, 0, &(:gb_sets.size(Map.fetch!(prov.groups, &1).runs) + &2))

    if touched * 8 > RunTree.count(prov.tree),
      do: blocker_in_one_pass(prov, MapSet.new(ids), blocks?),
      else: Enum.find_value(ids, &blocker(prov, &1, blocks?))
  end

  @spec blocker_in_one_pass(t(), MapSet.t(group_id()), (author(), group_key() -> boolean())) ::
          group_key() | nil
  defp blocker_in_one_pass(prov, ids, blocks?) do
    prov.tree
    |> RunTree.to_list()
    |> Enum.find_value(fn run ->
      run
      |> run_groups()
      |> Enum.filter(&MapSet.member?(ids, &1))
      |> Enum.find_value(&run_blocker(run, &1, prov.groups, blocks?))
    end)
  end

  @doc """
  Returns the groups whose text this group deleted after them, so this group blocks flipping them.

  It is the reverse of `blocker/2`: a group in the list whose flip `blocker/2` checks finds this group among its later deleters.
  """
  @spec blocked_groups(t(), group_id()) :: [group_id()]
  def blocked_groups(%__MODULE__{groups: groups, tree: tree}, id) do
    Map.fetch!(groups, id).runs
    |> :gb_sets.to_list()
    |> Enum.flat_map(fn run_id ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      earlier_groups(run, id)
    end)
    |> Enum.uniq()
  end

  @doc """
  Forgets a group whose state is final, keeping the document as it is.

  An applied group's text becomes permanent and keeps its author; the text it deleted is dropped. An unapplied group's text is dropped and it no longer counts as a deletion of anyone's text. Use it when a group leaves every history: your oldest undo step falls off the stack, your redo steps are replaced by a new edit, or a Minga step is reverted for good.
  """
  @spec discard(t(), group_id()) :: t()
  def discard(%__MODULE__{} = prov, id), do: prov |> discard_one(id) |> traced({:discard, [id]})

  @spec discard_one(t(), group_id()) :: t()
  defp discard_one(prov, id) do
    {group, groups} = Map.pop!(prov.groups, id)
    marked = Map.get(prov.overlap_runs, id, [])

    prov =
      %{prov | groups: groups} |> settle_overlaps(id, group) |> settle_group_marks(%{id => group})

    group.runs
    |> :gb_sets.to_list()
    |> Enum.reduce(prov, fn run_id, prov -> settle_run(prov, run_id, %{id => group}) end)
    |> refresh_runs(marked)
    |> settle_owners(%{id => group})
    |> settle_changes()
  end

  # Settled marks can change whether a run is a draft; the runs are refreshed once the group is gone everywhere.
  @spec refresh_runs(t(), [Locator.t()]) :: t()
  defp refresh_runs(prov, run_ids) do
    Enum.reduce(run_ids, prov, fn run_id, prov ->
      case RunTree.fetch(prov.tree, run_id) do
        {:ok, run, _offset} -> refresh_draft(prov, run, run)
        :error -> prov
      end
    end)
  end

  # A discarded group's overlap marks either go (it never happened) or become permanent (it always will have).
  @spec settle_overlaps(t(), group_id(), Group.t()) :: t()
  defp settle_overlaps(prov, id, group) do
    {run_ids, overlap_runs} = Map.pop(prov.overlap_runs, id, [])
    settled = settled_overlap(id, group)

    tree =
      Enum.reduce(run_ids, prov.tree, fn run_id, tree ->
        case RunTree.fetch(tree, run_id) do
          {:ok, run, _offset} ->
            RunTree.update(tree, %{run | overlaps: replace_overlap(run.overlaps, id, settled)})

          :error ->
            tree
        end
      end)

    %{prov | tree: tree, overlap_runs: overlap_runs}
  end

  @spec settled_overlap(group_id(), Group.t()) :: Run.overlap() | nil
  defp settled_overlap(_id, %Group{applied: false}), do: nil
  defp settled_overlap(_id, %Group{author: :you}), do: {:permanent, :you}
  defp settled_overlap(_id, %Group{key: key}), do: {:permanent, key}

  @spec replace_overlap([Run.overlap()], group_id(), {:permanent, term()} | nil) :: [
          Run.overlap()
        ]
  defp replace_overlap(overlaps, id, nil), do: Enum.reject(overlaps, &match?({_owner, ^id}, &1))

  defp replace_overlap(overlaps, id, settled) do
    Enum.map(overlaps, fn
      {owner, ^id} -> {owner, settled}
      mark -> mark
    end)
  end

  @doc """
  Returns every group that makes rejecting the groups in `ids` together inexact, because it deleted part of one of their replacements, each once with the byte offset where that happened. A group counts while it is applied, or for good once it is permanent; groups in `ids` never count. Each is named by its key, or `:you` for your groups.
  """
  @spec overlaps_among(t(), [group_id()]) :: [{group_key() | :you, non_neg_integer()}]
  def overlaps_among(%__MODULE__{} = prov, ids) when is_list(ids) do
    prov
    |> overlapping_groups(ids)
    |> Enum.map(fn
      {{:permanent, key}, offset} -> {key, offset}
      {id, offset} -> {overlap_name(Map.fetch!(prov.groups, id)), offset}
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc """
  Returns the same groups as `overlaps_among/2`, by group id, or as `{:permanent, key}` once permanent (`key` is `:you` for your groups), each once with the byte offset where it deleted part of a replacement.
  """
  @spec overlapping_groups(t(), [group_id()]) :: [
          {group_id() | {:permanent, group_key() | :you}, non_neg_integer()}
        ]
  def overlapping_groups(%__MODULE__{} = prov, ids) when is_list(ids) do
    members = MapSet.new(ids)

    faulted =
      if Map.has_key?(prov.faults, :all) or Enum.any?(ids, &Map.has_key?(prov.faults, &1)),
        do: [{{:permanent, :inconsistent}, 0}],
        else: []

    ids
    |> Enum.flat_map(fn id -> :gb_sets.to_list(Map.fetch!(prov.groups, id).runs) end)
    |> Enum.uniq()
    |> Enum.flat_map(fn run_id ->
      {:ok, run, offset} = RunTree.fetch(prov.tree, run_id)

      for {owner, overlap} <- run.overlaps,
          MapSet.member?(members, owner),
          counts?(prov.groups, members, overlap),
          do: {overlap, offset}
    end)
    |> Enum.concat(
      for id <- ids,
          overlap <- Map.get(prov.group_marks, id, []),
          counts?(prov.groups, members, overlap),
          do: {overlap, group_offset(prov, id)}
    )
    |> Enum.concat(faulted)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc """
  Returns whether a replacement record was found missing or inconsistent. Every reject is then refused, as `{:permanent, :inconsistent}` in `overlapping_groups/2`, so no reject guesses; the owner logs it.
  """
  @spec faulted?(t()) :: boolean()
  def faulted?(%__MODULE__{faults: faults}), do: faults != %{}

  @doc """
  Returns every replacement record as plain data, for tests: the locators it made and replaced, and the replacements it pulls and that pull it.
  """
  @spec change_records(t()) :: %{
          Change.id() => %{
            made: [Locator.t()],
            replaced: [Locator.t()],
            pulls: [Change.id()],
            pulled_by: [Change.id()],
            owner: Change.owner()
          }
        }
  def change_records(%__MODULE__{changes: changes}) do
    Map.new(changes, fn {id, change} ->
      {id,
       %{
         made: :gb_sets.to_list(change.made),
         replaced: :gb_sets.to_list(change.replaced),
         pulls: :gb_sets.to_list(change.pulls),
         pulled_by: :gb_sets.to_list(change.pulled_by),
         owner: change.owner
       }}
    end)
  end

  @doc "Returns the replacement records with no made runs left, by the group that owns them, for tests."
  @spec owned_changes(t()) :: %{group_id() => [Change.id()]}
  def owned_changes(%__MODULE__{owned: owned}),
    do: Map.new(owned, fn {group, changes} -> {group, Enum.sort(changes)} end)

  @doc "Returns the id the next replacement record will get."
  @spec next_change(t()) :: Change.id()
  def next_change(%__MODULE__{next_change: next_change}), do: next_change

  @spec counts?(%{group_id() => Group.t()}, MapSet.t(group_id()), Run.overlap()) :: boolean()
  defp counts?(_groups, _members, {:permanent, _key}), do: true

  defp counts?(groups, members, id),
    do: not MapSet.member?(members, id) and Map.fetch!(groups, id).applied

  @spec overlap_name(Group.t()) :: group_key() | :you
  defp overlap_name(%Group{author: :you}), do: :you
  defp overlap_name(%Group{key: key}), do: key

  @doc "Returns the keys of the Minga groups whose text group `id` deleted, each once."
  @spec deleted_writers(t(), group_id()) :: [group_key()]
  def deleted_writers(%__MODULE__{groups: groups, tree: tree}, id) do
    groups
    |> Map.fetch!(id)
    |> Map.fetch!(:runs)
    |> :gb_sets.to_list()
    |> Enum.flat_map(fn run_id ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      deleted_writer_key(groups, run, id)
    end)
    |> Enum.uniq()
  end

  @spec deleted_writer_key(%{group_id() => Group.t()}, Run.t(), group_id()) :: [group_key()]
  defp deleted_writer_key(groups, %Run{group: writer} = run, id)
       when writer != nil and writer != id do
    if id in run.deletions, do: List.wrap(Map.fetch!(groups, writer).key), else: []
  end

  defp deleted_writer_key(_groups, _base_or_own, _id), do: []

  @doc """
  Returns whether reverting the groups in `reverted` (which hold `id`) would bring back text `id` deleted: a tombstone `id` made that no other applied group outside them deletes and whose writer stays applied.
  """
  @spec revives_deleted?(t(), group_id(), [group_id()]) :: boolean()
  def revives_deleted?(%__MODULE__{groups: groups, tree: tree}, id, reverted)
      when is_list(reverted) do
    reverted = MapSet.new(reverted)
    applied? = &(Map.fetch!(groups, &1).applied and not MapSet.member?(reverted, &1))

    groups
    |> Map.fetch!(id)
    |> Map.fetch!(:runs)
    |> :gb_sets.to_list()
    |> Enum.any?(fn run_id ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)

      run.group != id and id in run.deletions and (run.group == nil or applied?.(run.group)) and
        not Enum.any?(run.deletions, applied?)
    end)
  end

  @doc "Returns how many bytes of the group's own text are live."
  @spec live_bytes_of(t(), group_id()) :: non_neg_integer()
  def live_bytes_of(%__MODULE__{groups: groups, tree: tree}, id) do
    groups
    |> Map.fetch!(id)
    |> Map.fetch!(:runs)
    |> :gb_sets.to_list()
    |> Enum.reduce(0, fn run_id, bytes ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      if run.group == id, do: bytes + Run.live_bytes(run), else: bytes
    end)
  end

  @doc """
  Forgets several groups whose state is final; see `discard/2`.

  When the groups hold a large share of the runs, as when a long task is rejected, one pass over every run settles them all and rebuilds the tree and every group's run set, in O(n), instead of looking each run up.
  """
  @spec discard_all(t(), [group_id()]) :: t()
  def discard_all(%__MODULE__{} = prov, ids) when is_list(ids) do
    touched = Enum.reduce(ids, 0, &(:gb_sets.size(Map.fetch!(prov.groups, &1).runs) + &2))

    discarded =
      if touched * 8 > RunTree.count(prov.tree),
        do: discard_in_one_pass(prov, ids),
        else: Enum.reduce(ids, prov, &discard_one(&2, &1))

    traced(discarded, {:discard, ids})
  end

  @doc "Returns how many runs the record holds, tombstones included, in O(1)."
  @spec run_count(t()) :: non_neg_integer()
  def run_count(%__MODULE__{tree: tree}), do: RunTree.count(tree)

  @doc "Returns how many bytes of deleted text the record keeps, in O(1)."
  @spec dead_bytes(t()) :: non_neg_integer()
  def dead_bytes(%__MODULE__{tree: tree}), do: RunTree.dead_bytes(tree)

  @doc "Returns every draft as `{group, locator}`, oldest group first. See `compact_oldest/1`."
  @spec drafts(t()) :: [{group_id(), Locator.t()}]
  def drafts(%__MODULE__{drafts: drafts}), do: :gb_sets.to_list(drafts)

  @doc "Returns how many drafts the record holds, in O(1)."
  @spec draft_count(t()) :: non_neg_integer()
  def draft_count(%__MODULE__{drafts: drafts}), do: :gb_sets.size(drafts)

  @doc "Returns whether `id` is the group opened last."
  @spec newest_group?(t(), group_id()) :: boolean()
  def newest_group?(%__MODULE__{next_group: next_group}, id), do: id == next_group - 1

  @doc "Returns whether the group still exists."
  @spec group?(t(), group_id()) :: boolean()
  def group?(%__MODULE__{groups: groups}, id), do: Map.has_key?(groups, id)

  @doc """
  Merges the oldest draft's step into the newer step of the same task that overwrote it, across the stretch around that draft, with `absorb/4`.

  A draft is a tombstone a Minga step wrote that a newer step of the same task deleted, both still applied: text the task wrote and then rewrote itself. Returns `{:ok, provenance, {old_group, new_group}, runs_examined}`, or `:none` when there are no drafts.
  """
  @spec compact_oldest(t()) :: {:ok, t(), {group_id(), group_id()}, pos_integer()} | :none
  def compact_oldest(%__MODULE__{} = prov) do
    if :gb_sets.is_empty(prov.drafts) do
      :none
    else
      {old, draft_id} = :gb_sets.smallest(prov.drafts)
      {:ok, draft, _offset} = RunTree.fetch(prov.tree, draft_id)
      new = draft_partner(draft, prov.groups)

      {first, last} =
        RunTree.stretch(
          prov.tree,
          draft_id,
          &(names?(&1, old, new) and merge_safe?(&1, old, new))
        )

      {prov, examined} = absorb_stretch(prov, old, new, first, last)
      {:ok, prov, {old, new}, examined}
    end
  end

  @doc """
  Merges step `old` into the newer step `new` of the same task across the stretch from locator `first` to locator `last`: every run there that names `old` as its writer or a deleter names `new` instead, and text `new` now both wrote and deleted is dropped, since it can never be live again.

  The document is unchanged for every choice of applied groups in which `old` and `new` agree. Reverting `new` alone afterwards restores the text from before `old` in the stretch, and reverting `old` alone no longer touches it. When `old` names no runs afterwards, the group is removed and any marks it left elsewhere name `new`. Costs O(m + log n) for m runs in the stretch.
  """
  @spec absorb(t(), group_id(), group_id(), {Locator.t(), Locator.t()}) :: t()
  def absorb(%__MODULE__{} = prov, old, new, {first, last}) do
    {prov, _examined} = absorb_stretch(prov, old, new, first, last)
    prov
  end

  @spec absorb_stretch(t(), group_id(), group_id(), Locator.t(), Locator.t()) ::
          {t(), pos_integer()}
  defp absorb_stretch(prov, old, new, first, last) do
    {tree, {before, kept}} =
      RunTree.rebuild_range(prov.tree, first, last, fn runs ->
        kept =
          for run <- runs,
              mapped = relabel(run, old, new),
              not self_deleted?(mapped, new),
              do: mapped

        {kept, {runs, kept}}
      end)

    kept_ids = MapSet.new(kept, & &1.id)
    dropped = Enum.reject(before, &MapSet.member?(kept_ids, &1.id))
    prov = Enum.reduce(dropped, prov, &forget_changes(&2, &1))

    # A replacement whose runs changed group may now share its group with what it pulls: look at those again.
    relabeled =
      for run <- before, run.group == old, run.made_by != nil, uniq: true, do: run.made_by

    prov = %{
      prov
      | stale:
          Enum.flat_map(relabeled, fn change ->
            case prov.changes do
              %{^change => record} -> :gb_sets.to_list(record.pulls)
              _gone -> []
            end
          end) ++ prov.stale
    }

    named_old = for run <- before, old in run_groups(run), do: run.id
    named_new = for run <- kept, new in run_groups(run), do: run.id

    groups =
      Enum.reduce(dropped, prov.groups, fn run, groups ->
        run
        |> run_groups()
        |> Enum.reject(&(&1 in [old, new]))
        |> Enum.reduce(groups, &remove_run(&2, &1, run.id))
      end)

    groups =
      groups
      |> Map.update!(old, &%{&1 | runs: remove_all(&1.runs, named_old)})
      |> Map.update!(new, fn group ->
        runs = remove_all(group.runs, Enum.map(dropped, & &1.id))
        %{group | runs: add_all(runs, named_new)}
      end)

    drafts =
      prov.drafts
      |> remove_all(Enum.map(before, &{&1.group, &1.id}))
      |> add_all(for run <- kept, key = draft_key(run, groups), do: key)

    marked = for run <- kept, Enum.any?(run.overlaps, &match?({_owner, ^new}, &1)), do: run.id

    prov = %{
      prov
      | tree: tree,
        groups: groups,
        drafts: drafts,
        overlap_runs: Map.update(prov.overlap_runs, new, marked, &(marked ++ &1))
    }

    prov = prov |> remove_when_empty(old, new) |> settle_changes() |> traced({:absorb, old, new})
    {prov, length(before)}
  end

  # A small change to a large set goes one element at a time, O(m log k); a change about the size of the set rebuilds
  # it, O(m + k). Either way a stretch costs what it touches.
  @spec remove_all(:gb_sets.set(term()), [term()]) :: :gb_sets.set(term())
  defp remove_all(set, items) do
    if length(items) * 8 > :gb_sets.size(set),
      do: :gb_sets.subtract(set, :gb_sets.from_list(items)),
      else: Enum.reduce(items, set, &:gb_sets.delete_any/2)
  end

  @spec add_all(:gb_sets.set(term()), [term()]) :: :gb_sets.set(term())
  defp add_all(set, items) do
    if length(items) * 8 > :gb_sets.size(set),
      do: :gb_sets.union(set, :gb_sets.from_list(items)),
      else: Enum.reduce(items, set, &:gb_sets.add/2)
  end

  @spec names?(Run.t(), group_id(), group_id()) :: boolean()
  defp names?(run, old, new),
    do: run.group in [old, new] or old in run.deletions or new in run.deletions

  @spec relabel(Run.t(), group_id(), group_id()) :: Run.t()
  defp relabel(run, old, new) do
    group = if run.group == old, do: new, else: run.group

    # The merged step deleted the run directly when either step did.
    direct? = Enum.any?([old, new], &removed_by?(%{run | group: nil}, &1))
    swept? = old in run.swept_by or new in run.swept_by
    swept_by = substitute(run.swept_by, old, new)
    covered_by = substitute(run.covered_by, old, new)

    # The merged step deleted the run in the strongest way either step did: directly, else by a sweep, else by a cover.
    # A sweep can block and a cover cannot, so the merge keeps who blocks.
    covered_by = if swept?, do: List.delete(covered_by, new), else: covered_by

    %{
      run
      | group: group,
        deletions: substitute(run.deletions, old, new),
        covered_by: if(direct?, do: List.delete(covered_by, new), else: covered_by),
        swept_by: if(direct?, do: List.delete(swept_by, new), else: swept_by),
        overlaps: substitute_marks(run.overlaps, old, new)
    }
  end

  # Puts `new` in `old`'s place, or drops `old` when `new` is already there.
  @spec substitute(list(), group_id(), group_id()) :: list()
  defp substitute(list, old, new) do
    cond do
      old not in list -> list
      new in list -> List.delete(list, old)
      true -> Enum.map(list, &if(&1 == old, do: new, else: &1))
    end
  end

  # Renames `old` to `new` as owner and as overlapper in every mark, keeping each mark once.
  @spec substitute_marks([Run.overlap()], group_id(), group_id()) :: [Run.overlap()]
  defp substitute_marks(marks, old, new) do
    marks
    |> Enum.map(fn {owner, overlap} -> {rename(owner, old, new), rename(overlap, old, new)} end)
    |> Enum.uniq()
  end

  @spec rename(term(), group_id(), group_id()) :: term()
  defp rename(old, old, new), do: new
  defp rename(other, _old, _new), do: other

  # Text the newer step both wrote and deleted can never be live again. It is dropped unless another group deleted it
  # too, or it carries overlap marks: that group's undo or the task's reject is blocked by it, so the inert run stays
  # to keep that answer unchanged.
  @spec self_deleted?(Run.t(), group_id()) :: boolean()
  defp self_deleted?(%Run{group: new, deletions: [new], overlaps: []}, new), do: true
  defp self_deleted?(_run, _new), do: false

  @spec rename_marks_in(RunTree.t(), Locator.t(), group_id(), group_id()) :: RunTree.t()
  defp rename_marks_in(tree, run_id, old, new) do
    case RunTree.fetch(tree, run_id) do
      {:ok, run, _offset} ->
        RunTree.update(tree, %{run | overlaps: substitute_marks(run.overlaps, old, new)})

      :error ->
        tree
    end
  end

  # A step left with no runs is gone; overlap marks it made elsewhere now name the step that absorbed it.
  @spec remove_when_empty(t(), group_id(), group_id()) :: t()
  defp remove_when_empty(prov, old, new) do
    if :gb_sets.is_empty(Map.fetch!(prov.groups, old).runs) do
      {marked, overlap_runs} = Map.pop(prov.overlap_runs, old, [])

      tree = Enum.reduce(marked, prov.tree, &rename_marks_in(&2, &1, old, new))

      %{
        prov
        | tree: tree,
          groups: Map.delete(prov.groups, old),
          overlap_runs: Map.update(overlap_runs, new, marked, &(marked ++ &1))
      }
      |> refresh_runs(marked)
      |> rename_group_marks(old, new)
      |> rename_owner(old, new)
    else
      prov
    end
  end

  @doc "Returns the author of the byte at `offset`, or `nil` when `offset` is at or past the end of the document."
  @spec author_at(t(), non_neg_integer()) :: author() | nil
  def author_at(%__MODULE__{tree: tree}, offset) when is_integer(offset) and offset >= 0 do
    case RunTree.at_offset(tree, offset) do
      {run, _start} -> run.author
      nil -> nil
    end
  end

  @doc """
  Returns the authorship of the bytes from `from` up to `to`, in document order.

  Each span is a maximal stretch of live text with one author and one Minga step, clipped to the range. Costs O(log n + k) for k runs in the range.
  """
  @spec spans(t(), non_neg_integer(), non_neg_integer()) :: [span()]
  def spans(%__MODULE__{tree: tree, groups: groups}, from, to)
      when is_integer(from) and is_integer(to) and from >= 0 do
    tree
    |> RunTree.live_between(from, to)
    |> Enum.reduce([], fn {run, start}, acc ->
      span_start = max(start, from)
      span_end = min(start + run.bytes, to)
      key = run_key(groups, run)

      case acc do
        [{previous_start, ^span_start, author, ^key} | rest] when author == run.author ->
          [{previous_start, span_end, author, key} | rest]

        _ ->
          [{span_start, span_end, run.author, key} | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Returns the regions of the document a group touched, in document order.

  A region is a byte range of the group's live text with the places it deleted text; a deletion with no live text around it is an empty range at the place the text was. Adjacent pieces form one region.
  """
  @spec regions(t(), group_id()) :: [byte_range()]
  def regions(%__MODULE__{groups: groups, tree: tree}, id) do
    Map.fetch!(groups, id).runs
    |> :gb_sets.to_list()
    |> Enum.reduce([], fn run_id, acc ->
      {:ok, run, start} = RunTree.fetch(tree, run_id)
      stop = start + Run.live_bytes(run)

      case acc do
        [{region_start, ^start} | rest] -> [{region_start, stop} | rest]
        _ -> [{start, stop} | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc "Returns every run in document order, tombstones included. Meant for tests and diagnostics."
  @spec runs(t()) :: [Run.t()]
  def runs(%__MODULE__{tree: tree}), do: RunTree.to_list(tree)

  # ── Editing ─────────────────────────────────────────────────────────

  @spec writer(t(), group_id() | :untracked) :: {group_id() | nil, author()}
  defp writer(_prov, :untracked), do: {nil, :unattributed}

  defp writer(%__MODULE__{groups: groups}, id) do
    case Map.fetch!(groups, id) do
      %Group{applied: true, author: author} -> {id, author}
      %Group{} -> raise ArgumentError, "group #{id} is not applied and cannot edit"
    end
  end

  # Typing inside your own fresh text grows that run instead of splitting it.
  @spec inside_own_run?(t(), group_id() | nil, author(), non_neg_integer()) :: boolean()
  defp inside_own_run?(prov, group_id, author, start) do
    case RunTree.at_offset(prov.tree, start) do
      {run, run_start} -> run_start < start and extendable?(run, group_id, author)
      nil -> false
    end
  end

  # Replacing bytes strictly inside another group's live run is the most common edit: every line of a whole-file rewrite
  # makes one. It gives the same runs as the general path (left piece, inserted text, tombstone, right piece) with one
  # lookup instead of several. The deletion starts inside the run, so it never covers a replacement.
  @spec replacing_inside_run?(t(), group_id() | nil, non_neg_integer(), non_neg_integer()) ::
          boolean()
  defp replacing_inside_run?(_prov, nil, _start, _removed_bytes), do: false
  defp replacing_inside_run?(_prov, _group_id, _start, 0), do: false

  defp replacing_inside_run?(prov, group_id, start, removed_bytes) do
    case RunTree.at_offset(prov.tree, start) do
      {%Run{group: group} = run, run_start} when group != group_id ->
        run_start < start and start + removed_bytes <= run_start + run.bytes and
          not foreign_replacement_text?(prov, run, group_id)

      _other ->
        false
    end
  end

  # Another author's Minga text: a partial deletion of it may need an overlap mark, which only the general path makes.
  @spec foreign_replacement_text?(t(), Run.t(), group_id()) :: boolean()
  defp foreign_replacement_text?(prov, run, group_id), do: foreign?(prov.groups, run, group_id)

  @spec replace_inside_run(
          t(),
          group_id(),
          author(),
          non_neg_integer(),
          binary(),
          non_neg_integer()
        ) ::
          t()
  defp replace_inside_run(prov, group_id, author, start, removed, inserted_bytes) do
    {run, run_start} = RunTree.at_offset(prov.tree, start)
    removed_bytes = byte_size(removed)
    rest = run_start + run.bytes - start - removed_bytes
    following = RunTree.next(prov.tree, run.id)
    {dead_id, prov} = allocate(prov, run, following)
    dead = %{run | id: dead_id, bytes: removed_bytes}

    {right, prov} =
      if rest > 0 do
        {right_id, prov} = allocate(prov, dead, following)
        {%{run | id: right_id, bytes: rest}, prov}
      else
        {nil, prov}
      end

    left = %{run | bytes: start - run_start}
    tree = RunTree.update(prov.tree, left)
    tree = if right, do: RunTree.insert(tree, right), else: tree
    groups = Enum.reduce(run_groups(run), prov.groups, &add_run(&2, &1, dead_id))

    groups =
      if right, do: Enum.reduce(run_groups(run), groups, &add_run(&2, &1, right.id)), else: groups

    change = if inserted_bytes > 0, do: prov.next_change

    {prov, replaced, pulled} =
      %{prov | tree: RunTree.insert(tree, dead), groups: groups}
      |> index_overlaps(dead)
      |> index_overlaps(right)
      |> index_changes(dead)
      |> index_changes(right)
      |> replace_run(group_id, change, dead, removed, true)

    {prov, made_by} = open_change(prov, change, replaced, pulled, author)
    insert_between(prov, group_id, author, left, dead, inserted_bytes, made_by)
  end

  @spec grow_run_at(t(), non_neg_integer(), pos_integer()) :: t()
  defp grow_run_at(prov, start, bytes) do
    {run, _run_start} = RunTree.at_offset(prov.tree, start)
    %{prov | tree: RunTree.update(prov.tree, %{run | bytes: run.bytes + bytes})}
  end

  # Only text with no replacement record grows: a replacement's own text stays its own run, so a later deletion can tell
  # whether all of it is gone.
  @spec extendable?(Run.t() | nil, group_id() | nil, author()) :: boolean()
  defp extendable?(
         %Run{
           live: true,
           deletions: [],
           group: group,
           author: author,
           made_by: nil,
           replaced_by: []
         },
         group,
         author
       ),
       do: true

  defp extendable?(_run, _group_id, _author), do: false

  # Splits the live run that holds `offset` so a run starts exactly there.
  @spec split_at(t(), non_neg_integer()) :: t()
  defp split_at(prov, offset) do
    case RunTree.at_offset(prov.tree, offset) do
      {run, run_start} when run_start < offset ->
        following = RunTree.next(prov.tree, run.id)
        {right_id, prov} = allocate(prov, run, following)
        left = %{run | bytes: offset - run_start}
        right = %{run | id: right_id, bytes: run_start + run.bytes - offset}
        tree = prov.tree |> RunTree.update(left) |> RunTree.insert(right)
        groups = Enum.reduce(run_groups(right), prov.groups, &add_run(&2, &1, right_id))

        %{prov | tree: tree, groups: groups}
        |> index_overlaps(right)
        |> index_changes(right)

      _boundary_or_end ->
        prov
    end
  end

  @spec run_starting_at(RunTree.t(), non_neg_integer()) :: Run.t() | nil
  defp run_starting_at(tree, offset) do
    case RunTree.at_offset(tree, offset) do
      {run, ^offset} -> run
      nil -> nil
    end
  end

  @spec preceding_run(RunTree.t(), Run.t() | nil) :: Run.t() | nil
  defp preceding_run(tree, nil), do: RunTree.last(tree)
  defp preceding_run(tree, %Run{id: id}), do: RunTree.previous(tree, id)

  # Kills the live runs that hold `removed`, starting at `run`, and marks the tombstones between them.
  # Returns the live runs it killed, as they were, the locators of the runs it marked and kept, which `change` (when
  # not `nil`) now lists as replaced, and the replacements that made the runs it dropped.
  @spec delete_from(
          t(),
          group_id() | nil,
          Change.id() | nil,
          Run.t() | nil,
          binary(),
          non_neg_integer(),
          {[Run.t()], [Locator.t()], [Change.id()]}
        ) ::
          {t(), {[Run.t()], [Locator.t()], [Change.id()]}}
  defp delete_from(prov, _group_id, _change, _run, removed, consumed, acc)
       when consumed == byte_size(removed),
       do: {prov, acc}

  defp delete_from(prov, group_id, change, %Run{} = run, removed, consumed, acc) do
    # A dropped run's marks may have moved onto this one since it was looked up.
    run = current(prov.tree, run)
    following = RunTree.next(prov.tree, run.id)
    {killed, replaced, pulled} = acc

    {text, killed, consumed_after} =
      if run.live,
        do: {binary_part(removed, consumed, run.bytes), [run | killed], consumed + run.bytes},
        else: {run.text, killed, consumed}

    {prov, kept, makers} = replace_run(prov, group_id, change, run, text, run.live)
    acc = {killed, kept ++ replaced, makers ++ pulled}
    delete_from(prov, group_id, change, following, removed, consumed_after, acc)
  end

  @spec current(RunTree.t(), Run.t()) :: Run.t()
  defp current(tree, run) do
    case RunTree.fetch(tree, run.id) do
      {:ok, now, _offset} -> now
      :error -> run
    end
  end

  # Marks one run in an edit's range dead (an untracked deletion, or one by the run's own writer, forgets it) and lists
  # it under `change` when it stays.
  # A run it drops names the replacement that made it instead, which `change` then pulls.
  @spec replace_run(t(), group_id() | nil, Change.id() | nil, Run.t(), binary(), boolean()) ::
          {t(), [Locator.t()], [Change.id()]}
  defp replace_run(prov, group_id, change, run, text, visible?) do
    case deleted(run, group_id, text) do
      nil ->
        {drop_run(prov, run), [], List.wrap(run.made_by)}

      dead ->
        dead = how_deleted(dead, run, group_id, visible?)

        {dead, kept} =
          if change,
            do: {%{dead | replaced_by: [change | dead.replaced_by]}, [run.id]},
            else: {dead, []}

        {if(dead == run, do: prov, else: kill_run(prov, group_id, run, dead)), kept, []}
    end
  end

  # Deleting visible text is direct: it clears any earlier cover or sweep by the group.
  # Newly deleting a tombstone inside the range is a sweep.
  @spec how_deleted(Run.t(), Run.t(), group_id(), boolean()) :: Run.t()
  defp how_deleted(dead, _run, group_id, true),
    do: %{
      dead
      | covered_by: List.delete(dead.covered_by, group_id),
        swept_by: List.delete(dead.swept_by, group_id)
    }

  defp how_deleted(dead, run, group_id, false) do
    cond do
      # A sweep counts over an earlier cover by the same group, as it does in either order.
      group_id in run.covered_by ->
        %{
          dead
          | covered_by: List.delete(dead.covered_by, group_id),
            swept_by: [group_id | dead.swept_by]
        }

      group_id in run.deletions ->
        dead

      true ->
        %{dead | swept_by: [group_id | dead.swept_by]}
    end
  end

  # The record of a replacement whose edit marked `replaced` and dropped runs made by `pulled`. An edit that can neither
  # cover nor mark gets none: it replaced nothing, pulls nothing and is no Minga step's. Returns the id its text names.
  @spec open_change(t(), Change.id() | nil, [Locator.t()], [Change.id()], author()) ::
          {t(), Change.id() | nil}
  defp open_change(prov, nil, _replaced, _pulled, _author), do: {prov, nil}

  defp open_change(prov, change, replaced, pulled, author) do
    if replaced == [] and pulled == [] and not minga?(author) do
      {prov, nil}
    else
      record = %Change{replaced: :gb_sets.from_list(replaced)}
      prov = %{prov | changes: Map.put(prov.changes, change, record), next_change: change + 1}
      {pulled |> Enum.uniq() |> Enum.reduce(prov, &pull(&2, change, &1)), change}
    end
  end

  # ── Replacements ────────────────────────────────────────────────────
  #
  # An edit that inserted text and marked earlier text dead has a record (`Change`): the runs it made and the runs it
  # replaced. A deletion consumes a replacement when none of its made runs stays live; the replaced text then goes
  # with it, and every replacement whose text that covered is examined in turn, each once. A replacement that keeps
  # live text was only partly consumed: when it is another author's Minga step, its runs get an overlap mark, so its
  # reject is refused until that deletion is undone. Nothing is inferred from where tombstones sit.

  # The replacements whose live text an edit killed, each once.
  @spec seeds([Run.t()]) :: [Change.id()]
  defp seeds(killed),
    do: for(%Run{made_by: change} <- Enum.reverse(killed), change != nil, uniq: true, do: change)

  @spec any_live([Run.t()]) :: :partial | :whole
  defp any_live(made), do: if(Enum.any?(made, & &1.live), do: :partial, else: :whole)

  @typep consumption :: (Change.id(), [Run.t()] -> :partial | :whole)

  # Covers what the replacements in `seeds` replaced, and what they reach in turn, for a deletion by `group_id`.
  # `consumption` says whether a replacement keeps live text as of this edit. Costs the records and runs it reaches.
  @spec consume(t(), group_id() | nil, [Change.id()], consumption()) :: t()
  defp consume(prov, group_id, seeds, consumption),
    do: consume_each(prov, group_id, seeds, MapSet.new(seeds), consumption)

  @spec consume_each(t(), group_id() | nil, [Change.id()], MapSet.t(), consumption()) :: t()
  defp consume_each(prov, _group_id, [], _seen, _consumption), do: prov

  defp consume_each(prov, group_id, [change | rest], seen, consumption) do
    {prov, reached} = consume_change(prov, group_id, change, consumption)
    reached = reached |> Enum.uniq() |> Enum.reject(&MapSet.member?(seen, &1))
    consume_each(prov, group_id, reached ++ rest, Enum.into(reached, seen), consumption)
  end

  @spec consume_change(t(), group_id() | nil, Change.id(), consumption()) :: {t(), [Change.id()]}
  defp consume_change(prov, group_id, change, consumption) do
    with {:ok, record} <- Map.fetch(prov.changes, change),
         {:ok, made} <- fetch_runs(prov.tree, record.made) do
      owner = owner_of(record, made)

      cond do
        is_integer(owner) and not Map.has_key?(prov.groups, owner) ->
          {fault(prov, :all), []}

        # A change carries its replacement only while it is applied.
        is_integer(owner) and not Map.fetch!(prov.groups, owner).applied ->
          {prov, []}

        consumption.(change, made) == :partial ->
          {mark_consumed_part(prov, group_id, owner, made), []}

        true ->
          cover(prov, group_id, record)
      end
    else
      :error -> {fault(prov, :all), []}
    end
  end

  # The group a change belongs to: the writer of its first made run, or the owner it kept once they were all gone.
  # `nil` is permanent text, which counts as applied.
  @spec owner_of(Change.t(), [Run.t()]) :: group_id() | nil
  defp owner_of(%Change{owner: :runs}, [first | _rest]), do: first.group
  defp owner_of(%Change{owner: owner}, _made) when is_integer(owner), do: owner
  defp owner_of(_record, _made), do: nil

  @spec fetch_runs(RunTree.t(), :gb_sets.set(Locator.t())) :: {:ok, [Run.t()]} | :error
  defp fetch_runs(tree, ids) do
    ids
    |> :gb_sets.to_list()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, runs} ->
      case RunTree.fetch(tree, id) do
        {:ok, run, _offset} -> {:cont, {:ok, [run | runs]}}
        :error -> {:halt, :error}
      end
    end)
    |> then(fn
      {:ok, runs} -> {:ok, Enum.reverse(runs)}
      :error -> :error
    end)
  end

  # Marks every run of a partly consumed replacement when the deleter is another author than its Minga step.
  @spec mark_consumed_part(t(), group_id() | nil, group_id() | nil, [Run.t()]) :: t()
  defp mark_consumed_part(prov, group_id, owner, made) do
    if group_id != nil and owner != nil and foreign_owner?(prov.groups, owner, group_id),
      do: Enum.reduce(made, prov, &put_mark(&2, owner, group_id, &1)),
      else: prov
  end

  # Deletes every dead run the replacement replaced, and returns the replacements that made those runs and the ones it
  # pulls. A live run stays: a cover never changes the document.
  @spec cover(t(), group_id() | nil, Change.t()) :: {t(), [Change.id()]}
  defp cover(prov, group_id, record) do
    record.replaced
    |> :gb_sets.to_list()
    |> Enum.reduce({prov, :gb_sets.to_list(record.pulls)}, fn run_id, {prov, reached} ->
      case RunTree.fetch(prov.tree, run_id) do
        {:ok, %Run{live: false} = run, _offset} ->
          {cover_run(prov, group_id, run), List.wrap(run.made_by) ++ reached}

        {:ok, _live, _offset} ->
          {prov, reached}

        :error ->
          {fault(prov, :all), reached}
      end
    end)
  end

  # A cover deletes as an edit does (an untracked one, or one by the run's own writer, forgets the run), and records
  # that the deletion is derived, so it never blocks.
  @spec cover_run(t(), group_id() | nil, Run.t()) :: t()
  defp cover_run(prov, group_id, run) do
    case deleted(run, group_id, run.text) do
      nil ->
        drop_run(prov, run)

      # A group that deleted the run before, directly or by a sweep, keeps that kind.
      ^run ->
        prov

      dead ->
        kill_run(prov, group_id, run, %{dead | covered_by: [group_id | dead.covered_by]})
    end
  end

  # Something the records promise is missing. Every reject that could depend on it is refused from now on.
  @spec fault(t(), group_id() | :all) :: t()
  defp fault(prov, key), do: %{prov | faults: Map.put(prov.faults, key, true)}

  # Lists a new run under the replacement that made it and every replacement that marked it.
  @spec index_changes(t(), Run.t() | nil) :: t()
  defp index_changes(prov, nil), do: prov

  defp index_changes(prov, run) do
    prov = update_change(prov, run.made_by, &%{&1 | made: :gb_sets.add(run.id, &1.made)})

    Enum.reduce(run.replaced_by, prov, fn change, prov ->
      update_change(prov, change, &%{&1 | replaced: :gb_sets.add(run.id, &1.replaced)})
    end)
  end

  @spec update_change(t(), Change.id() | nil, (Change.t() -> Change.t())) :: t()
  defp update_change(prov, nil, _fun), do: prov

  defp update_change(prov, change, fun) do
    case prov.changes do
      %{^change => record} -> %{prov | changes: %{prov.changes | change => fun.(record)}}
      _missing -> fault(prov, :all)
    end
  end

  # A dropped run leaves its replacements' sets. When it linked a replacement that marked it (`p`) to the one that
  # made it (`q`), `p` pulls `q` from now on: consuming `p` still reaches `q`.
  @spec forget_changes(t(), Run.t()) :: t()
  defp forget_changes(prov, run) do
    prov = update_change(prov, run.made_by, &%{&1 | made: :gb_sets.delete_any(run.id, &1.made)})
    prov = keep_owner(prov, run)

    prov =
      Enum.reduce(run.replaced_by, prov, fn change, prov ->
        update_change(prov, change, &%{&1 | replaced: :gb_sets.delete_any(run.id, &1.replaced)})
      end)

    link_dropped(prov, run)
  end

  # What a dropped run leaves behind once it is out of every set: its records are looked at again when the operation
  # settles, and the replacements that marked it pull the one that made it.
  @spec link_dropped(t(), Run.t()) :: t()
  defp link_dropped(prov, run) do
    prov = keep_owner(prov, run)
    made_by = run.made_by
    prov = %{prov | stale: List.wrap(made_by) ++ run.replaced_by ++ prov.stale}

    if made_by == nil,
      do: prov,
      else: Enum.reduce(run.replaced_by, prov, &pull(&2, &1, made_by))
  end

  # When `run` was the last made run of its record, the record keeps the run's group as its owner.
  @spec keep_owner(t(), Run.t()) :: t()
  defp keep_owner(prov, %Run{made_by: nil}), do: prov

  defp keep_owner(prov, %Run{made_by: change} = run) do
    case prov.changes do
      %{^change => %Change{owner: :runs} = record} ->
        if :gb_sets.is_empty(record.made), do: own(prov, change, record, run.group), else: prov

      _owned_or_gone ->
        prov
    end
  end

  @spec pull(t(), Change.id(), Change.id()) :: t()
  defp pull(prov, same, same), do: prov

  defp pull(prov, puller, pulled) do
    prov
    |> update_change(puller, &%{&1 | pulls: :gb_sets.add(pulled, &1.pulls)})
    |> update_change(pulled, &%{&1 | pulled_by: :gb_sets.add(puller, &1.pulled_by)})
  end

  # Retires the replacements an operation left with nothing to do. One with no made runs left is consumed for good:
  # every replacement that pulls it takes over what it replaced and pulls. One
  # with nothing replaced, nothing pulled and no Minga step to mark is inert: its runs forget it.
  @spec settle_changes(t()) :: t()
  defp settle_changes(%__MODULE__{stale: []} = prov), do: prov

  defp settle_changes(prov), do: retire(%{prov | stale: []}, Enum.uniq(prov.stale))

  @spec retire(t(), [Change.id()]) :: t()
  defp retire(prov, []), do: prov

  defp retire(prov, [change | rest]) do
    {prov, more} =
      case prov.changes do
        %{^change => record} -> retire_one(prov, change, record)
        _gone -> {prov, []}
      end

    retire(prov, more ++ rest)
  end

  @spec retire_one(t(), Change.id(), Change.t()) :: {t(), [Change.id()]}
  defp retire_one(prov, change, record) do
    linked = :gb_sets.to_list(record.pulls) ++ :gb_sets.to_list(record.pulled_by)

    cond do
      # Nothing reaches it, or reaching it does nothing: it has no text to mark and nothing to cover or pull.
      :gb_sets.is_empty(record.made) and
          (:gb_sets.is_empty(record.pulled_by) or
             (:gb_sets.is_empty(record.replaced) and :gb_sets.is_empty(record.pulls))) ->
        {remove_change(prov, change, record), linked}

      :gb_sets.is_empty(record.made) and :gb_sets.is_empty(record.replaced) and
          spliceable?(prov, record) ->
        {splice(prov, change, record), linked}

      :gb_sets.is_empty(record.made) ->
        {prov, []}

      :gb_sets.is_empty(record.replaced) and :gb_sets.is_empty(record.pulls) and
          inert_change?(prov, record) ->
        prov = clear_made(prov, record.made)
        {remove_change(prov, change, record), :gb_sets.to_list(record.pulled_by)}

      true ->
        {prov, []}
    end
  end

  # A run-less record that replaced nothing only links its pullers to its targets. When it belongs to the same group as
  # every puller (or is permanent), reaching it adds no applied check of its own, so the pullers can pull its targets
  # directly. Without this, a spot renamed once per step would keep one record per step after compaction.
  @spec spliceable?(t(), Change.t()) :: boolean()
  defp spliceable?(_prov, %Change{owner: :permanent}), do: true

  defp spliceable?(prov, record) do
    record.pulled_by
    |> :gb_sets.to_list()
    |> Enum.all?(fn puller ->
      case prov.changes do
        %{^puller => puller_record} -> record_owner(prov, puller_record) == record.owner
        _gone -> false
      end
    end)
  end

  # The group a record belongs to, read from its first made run while it has runs.
  @spec record_owner(t(), Change.t()) :: Change.owner() | group_id() | nil
  defp record_owner(prov, %Change{owner: :runs} = record) do
    case first_run(prov.tree, record.made) do
      %Run{group: group} -> group
      nil -> nil
    end
  end

  defp record_owner(_prov, %Change{owner: owner}), do: owner

  @spec splice(t(), Change.id(), Change.t()) :: t()
  defp splice(prov, change, record) do
    pullers = :gb_sets.to_list(record.pulled_by)
    targets = :gb_sets.to_list(record.pulls)

    prov =
      for puller <- pullers, target <- targets, puller != target, reduce: prov do
        acc -> pull(acc, puller, target)
      end

    remove_change(prov, change, record)
  end

  # Forgets a record: its runs stop naming it, and the records it pulls or that pull it stop linking it.
  @spec remove_change(t(), Change.id(), Change.t()) :: t()
  defp remove_change(prov, change, record) do
    prov = disown(prov, change, record.owner)

    tree =
      record.replaced
      |> :gb_sets.to_list()
      |> Enum.reduce(prov.tree, fn run_id, tree ->
        case RunTree.fetch(tree, run_id) do
          {:ok, run, _offset} ->
            RunTree.update(tree, %{run | replaced_by: List.delete(run.replaced_by, change)})

          :error ->
            tree
        end
      end)

    prov = %{prov | tree: tree, changes: Map.delete(prov.changes, change)}

    prov =
      record.pulls
      |> :gb_sets.to_list()
      |> Enum.reduce(prov, fn pulled, prov ->
        update_known(prov, pulled, &%{&1 | pulled_by: :gb_sets.delete_any(change, &1.pulled_by)})
      end)

    record.pulled_by
    |> :gb_sets.to_list()
    |> Enum.reduce(prov, fn puller, prov ->
      update_known(prov, puller, &%{&1 | pulls: :gb_sets.delete_any(change, &1.pulls)})
    end)
  end

  # Like `update_change/3`, for links whose other end may already be gone in the same retirement.
  @spec update_known(t(), Change.id(), (Change.t() -> Change.t())) :: t()
  defp update_known(prov, change, fun) do
    case prov.changes do
      %{^change => record} -> %{prov | changes: %{prov.changes | change => fun.(record)}}
      _gone -> prov
    end
  end

  # A record whose made runs are all gone keeps the group that made them, listed under that group so compaction and
  # discard can find it.
  @spec own(t(), Change.id(), Change.t(), group_id() | nil) :: t()
  defp own(prov, change, record, group) do
    owner = group || :permanent
    prov = %{prov | changes: %{prov.changes | change => %{record | owner: owner}}}

    if is_integer(owner),
      do: %{
        prov
        | owned: Map.update(prov.owned, owner, MapSet.new([change]), &MapSet.put(&1, change))
      },
      else: prov
  end

  @spec disown(t(), Change.id(), Change.owner()) :: t()
  defp disown(prov, change, owner) when is_integer(owner) do
    case prov.owned do
      %{^owner => changes} ->
        rest = MapSet.delete(changes, change)

        owned =
          if MapSet.size(rest) == 0,
            do: Map.delete(prov.owned, owner),
            else: %{prov.owned | owner => rest}

        %{prov | owned: owned}

      _none ->
        prov
    end
  end

  defp disown(prov, _change, _owner), do: prov

  # Compaction removed `old` into `new`: the records it owned belong to `new`.
  @spec rename_owner(t(), group_id(), group_id()) :: t()
  defp rename_owner(prov, old, new) do
    case Map.pop(prov.owned, old) do
      {nil, _owned} ->
        prov

      {changes, owned} ->
        records =
          Enum.reduce(changes, prov.changes, fn change, records ->
            Map.update!(records, change, &%{&1 | owner: new})
          end)

        %{
          prov
          | changes: records,
            owned: Map.update(owned, new, changes, &MapSet.union(&1, changes)),
            stale: MapSet.to_list(changes) ++ prov.stale
        }
    end
  end

  # Discarded groups that owned records: one discarded unapplied never happened, so its records go with every link to
  # them; one discarded applied is permanent, so its records count as applied from now on.
  @spec settle_owners(t(), %{group_id() => Group.t()}) :: t()
  defp settle_owners(prov, discarded) do
    Enum.reduce(discarded, prov, fn {id, group}, prov ->
      case Map.pop(prov.owned, id) do
        {nil, _owned} ->
          prov

        {changes, owned} ->
          prov = %{prov | owned: owned}
          Enum.reduce(changes, prov, &settle_owned(&2, &1, group))
      end
    end)
  end

  @spec settle_owned(t(), Change.id(), Group.t()) :: t()
  defp settle_owned(prov, change, %Group{applied: true}),
    do: update_known(prov, change, &%{&1 | owner: :permanent})

  defp settle_owned(prov, change, %Group{applied: false}) do
    case prov.changes do
      %{^change => record} ->
        prov = remove_change(prov, change, %{record | owner: :permanent})

        %{
          prov
          | stale:
              :gb_sets.to_list(record.pulls) ++ :gb_sets.to_list(record.pulled_by) ++ prov.stale
        }

      _gone ->
        prov
    end
  end

  # A record that can neither cover nor mark: its runs belong to no Minga step.
  @spec inert_change?(t(), Change.t()) :: boolean()
  defp inert_change?(prov, record) do
    case first_run(prov.tree, record.made) do
      %Run{group: nil} -> true
      %Run{group: group} -> not minga?(Map.get(prov.groups, group, %{author: nil}).author)
      nil -> false
    end
  end

  @spec minga?(author()) :: boolean()
  defp minga?({:minga, _task}), do: true
  defp minga?(_author), do: false

  @spec clear_made(t(), :gb_sets.set(Locator.t())) :: t()
  defp clear_made(prov, made) do
    tree =
      made
      |> :gb_sets.to_list()
      |> Enum.reduce(prov.tree, fn run_id, tree ->
        case RunTree.fetch(tree, run_id) do
          {:ok, run, _offset} -> RunTree.update(tree, %{run | made_by: nil})
          :error -> tree
        end
      end)

    %{prov | tree: tree}
  end

  # A new piece of a run with overlap marks is listed under each marking group, so discarding it finds the piece.
  @spec index_overlaps(t(), Run.t() | nil) :: t()
  defp index_overlaps(prov, %Run{overlaps: [_ | _] = overlaps, id: id}) do
    overlap_runs =
      for {_owner, group} when is_integer(group) <- overlaps, reduce: prov.overlap_runs do
        acc -> Map.update(acc, group, [id], &[id | &1])
      end

    %{prov | overlap_runs: overlap_runs}
  end

  defp index_overlaps(prov, _run), do: prov

  @spec put_mark(t(), group_id(), group_id() | {:permanent, term()}, Run.t()) :: t()
  defp put_mark(prov, owner, overlapper, run) do
    case with_overlap(run, owner, overlapper) do
      ^run ->
        prov

      marked ->
        overlap_runs =
          if is_integer(overlapper),
            do: Map.update(prov.overlap_runs, overlapper, [run.id], &[run.id | &1]),
            else: prov.overlap_runs

        refresh_draft(
          %{prov | tree: RunTree.update(prov.tree, marked), overlap_runs: overlap_runs},
          run,
          marked
        )
    end
  end

  # A dropped run's overlap marks move to its owner group, so the refusal they stand for outlives the run. Keeping them
  # on the group, not on another run, leaves every other run as it was whatever order runs drop in.
  @spec transfer_marks(t(), [Run.overlap()]) :: t()
  defp transfer_marks(prov, marks) do
    Enum.reduce(marks, prov, fn {owner, overlapper}, prov ->
      if is_map_key(prov.groups, owner) do
        group_marks =
          Map.update(prov.group_marks, owner, [overlapper], &Enum.uniq([overlapper | &1]))

        %{prov | group_marks: group_marks}
      else
        prov
      end
    end)
  end

  # Marks a group keeps for itself once discarded groups are final: about a discarded owner they go, and a discarded
  # overlapper's settle as on runs.
  @spec settle_group_marks(t(), %{group_id() => Group.t()}) :: t()
  defp settle_group_marks(%__MODULE__{group_marks: group_marks} = prov, _discarded)
       when group_marks == %{},
       do: prov

  defp settle_group_marks(prov, discarded) do
    group_marks =
      for {owner, overlaps} <- Map.drop(prov.group_marks, Map.keys(discarded)),
          settled = settle_kept_marks(overlaps, discarded),
          settled != [],
          into: %{},
          do: {owner, settled}

    %{prov | group_marks: group_marks}
  end

  @spec settle_kept_marks([group_id() | {:permanent, term()}], %{group_id() => Group.t()}) :: [
          group_id() | {:permanent, term()}
        ]
  defp settle_kept_marks(overlaps, discarded) do
    overlaps
    |> Enum.flat_map(fn
      id when is_map_key(discarded, id) ->
        List.wrap(settled_overlap(id, Map.fetch!(discarded, id)))

      overlap ->
        [overlap]
    end)
    |> Enum.uniq()
  end

  @spec rename_group_marks(t(), group_id(), group_id()) :: t()
  defp rename_group_marks(%__MODULE__{group_marks: group_marks} = prov, _old, _new)
       when group_marks == %{},
       do: prov

  defp rename_group_marks(prov, old, new) do
    group_marks =
      Enum.reduce(prov.group_marks, %{}, fn {owner, overlaps}, acc ->
        renamed =
          overlaps
          |> Enum.map(&rename(&1, old, new))
          |> Enum.reject(&(&1 == new and owner in [old, new]))

        Map.update(acc, rename(owner, old, new), renamed, &Enum.uniq(renamed ++ &1))
      end)

    %{prov | group_marks: Map.reject(group_marks, fn {_owner, overlaps} -> overlaps == [] end)}
  end

  # Where a group's marks kept on the group point: the first of its runs, or the start of the document.
  @spec group_offset(t(), group_id()) :: non_neg_integer()
  defp group_offset(prov, id) do
    with %Group{runs: runs} <- Map.get(prov.groups, id),
         false <- :gb_sets.is_empty(runs),
         {:ok, _run, offset} <- RunTree.fetch(prov.tree, :gb_sets.smallest(runs)) do
      offset
    else
      _none -> 0
    end
  end

  @spec first_run(RunTree.t(), :gb_sets.set(Locator.t())) :: Run.t() | nil
  defp first_run(tree, ids) do
    with false <- :gb_sets.is_empty(ids),
         {:ok, run, _offset} <- RunTree.fetch(tree, :gb_sets.smallest(ids)) do
      run
    else
      _none -> nil
    end
  end

  # A new locator between two runs hugs whichever neighbour the previous edit or this one just created.
  # Insertions that keep landing beside the last one, as in typing forward or replaying a batch from the end, then take
  # small steps away from it and leave the rest of the gap free. Any other insertion takes the middle of the gap.
  @spec allocate(t(), Run.t() | nil, Run.t() | nil) :: {Locator.t(), t()}
  defp allocate(prov, lower, upper) do
    bias =
      cond do
        upper != nil and recent?(prov, upper.id) -> :high
        lower != nil and recent?(prov, lower.id) -> :low
        true -> :middle
      end

    id = Locator.between(lower && lower.id, upper && upper.id, bias)
    {id, %{prov | fresh: [id | prov.fresh], deep: prov.deep or deep?(id)}}
  end

  @spec recent?(t(), Locator.t()) :: boolean()
  defp recent?(prov, id), do: id in prov.fresh or id in prov.recent

  @spec remember_fresh(t()) :: t()
  defp remember_fresh(%__MODULE__{fresh: []} = prov), do: prov
  defp remember_fresh(prov), do: %{prov | recent: prov.fresh, fresh: []}

  # A locator longer than four digits makes the edit that created it renumber every run.
  @spec deep?(Locator.t()) :: boolean()
  defp deep?(id), do: match?([_, _, _, _, _ | _], id)

  # Insertions packed into one place deepen locators by one digit about every 56 insertions.
  # Renumbering every run evenly, and every group's references with it, keeps locators short for any insertion order.
  # It costs O(n log n) and happens at most once per many insertions at one place.
  @spec renumber_when_deep(t()) :: t()
  defp renumber_when_deep(%__MODULE__{deep: false} = prov), do: prov

  defp renumber_when_deep(prov) do
    runs = RunTree.to_list(prov.tree)
    ids = Locator.even(length(runs))
    renamed = Map.new(Enum.zip(Enum.map(runs, & &1.id), ids))

    runs = runs |> Enum.zip(ids) |> Enum.map(fn {run, id} -> %{run | id: id} end)
    tree = RunTree.from_list(runs)

    overlap_runs =
      Map.new(prov.overlap_runs, fn {id, run_ids} ->
        {id, for(run_id <- run_ids, renamed_id = Map.get(renamed, run_id), do: renamed_id)}
      end)

    # Renumbering keeps order, so each group's sorted locators stay sorted.
    rename = fn set -> set |> :gb_sets.to_list() |> Enum.map(&Map.fetch!(renamed, &1)) end

    groups =
      Map.new(prov.groups, fn {id, group} ->
        {id, %{group | runs: :gb_sets.from_ordset(rename.(group.runs))}}
      end)

    changes =
      Map.new(prov.changes, fn {id, change} ->
        {id,
         %{
           change
           | made: :gb_sets.from_ordset(rename.(change.made)),
             replaced: :gb_sets.from_ordset(rename.(change.replaced))
         }}
      end)

    index_drafts(
      %{
        prov
        | tree: tree,
          groups: groups,
          changes: changes,
          deep: false,
          recent: [],
          fresh: [],
          overlap_runs: overlap_runs
      },
      runs
    )
  end

  @spec kill_run(t(), group_id(), Run.t(), Run.t()) :: t()
  defp kill_run(prov, group_id, old, run) do
    refresh_draft(
      %{
        prov
        | tree: RunTree.update(prov.tree, run),
          groups: add_run(prov.groups, group_id, run.id)
      },
      old,
      run
    )
  end

  @spec insert_between(
          t(),
          group_id() | nil,
          author(),
          Run.t() | nil,
          Run.t() | nil,
          non_neg_integer(),
          Change.id() | nil
        ) :: t()
  defp insert_between(prov, _group_id, _author, _preceding, _following, 0, _made_by), do: prov

  defp insert_between(prov, group_id, author, preceding, following, bytes, made_by) do
    if made_by == nil and extendable?(preceding, group_id, author) do
      %{prov | tree: RunTree.update(prov.tree, %{preceding | bytes: preceding.bytes + bytes})}
    else
      {id, prov} = allocate(prov, preceding, following)
      run = %Run{id: id, bytes: bytes, author: author, group: group_id, made_by: made_by}
      groups = if group_id, do: add_run(prov.groups, group_id, id), else: prov.groups
      index_changes(%{prov | tree: RunTree.insert(prov.tree, run), groups: groups}, run)
    end
  end

  # ── Undo and reject ─────────────────────────────────────────────────

  @spec set_applied(t(), group_id(), boolean(), Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  defp set_applied(prov, id, applied, document),
    do: set_applied_all(prov, [id], applied, document)

  # Flips every group in `ids` at once and applies all their changes in one pass over the document.
  @spec set_applied_all(t(), [group_id()], boolean(), Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  defp set_applied_all(prov, ids, applied, document) do
    flipping = Enum.reject(ids, &(Map.fetch!(prov.groups, &1).applied == applied))

    if flipping == [] do
      {:ok, document, nil, prov}
    else
      groups =
        Enum.reduce(flipping, prov.groups, fn id, groups ->
          Map.update!(groups, id, &%{&1 | applied: applied})
        end)

      content = Document.content(document)

      sets = Enum.map(flipping, &Map.fetch!(prov.groups, &1).runs)
      touched = Enum.reduce(sets, 0, &(:gb_sets.size(&1) + &2))
      prov = %{prov | groups: groups}

      {changes, flipped} =
        if touched * 8 > RunTree.count(prov.tree),
          do: flip_every_run(prov, content),
          else: flip_runs(prov, Enum.reduce(sets, &:gb_sets.union/2), content)

      with {:ok, new_document} <- apply_changes(changes, content, document) do
        {:ok, new_document, first_offset(changes), flipped}
      end
    end
  end

  # Visits the groups' runs from the end of the document to its start.
  # A run's offset never depends on the runs after it, so every change is located in the original document.
  # Prepending each change then leaves the list in document order.
  @spec flip_runs(t(), :gb_sets.set(Locator.t()), binary()) :: {[change()], t()}
  defp flip_runs(prov, touched, content) do
    touched
    |> :gb_sets.to_list()
    |> Enum.reverse()
    |> Enum.reduce({[], prov}, fn run_id, acc -> flip_run(acc, run_id, content) end)
  end

  # When the groups touch a large share of the runs, one pass over every run and a rebuilt tree costs O(n), less than
  # looking each run up. Offsets advance by each run's bytes in the original document.
  @spec flip_every_run(t(), binary()) :: {[change()], t()}
  defp flip_every_run(prov, content) do
    {runs, changes, _offset} =
      prov.tree
      |> RunTree.to_list()
      |> Enum.reduce({[], [], 0}, fn run, {runs, changes, offset} ->
        {flipped, change} = flip(run, prov.groups, content, offset)
        {[flipped | runs], List.wrap(change) ++ changes, offset + Run.live_bytes(run)}
      end)

    runs = Enum.reverse(runs)
    {Enum.reverse(changes), index_drafts(%{prov | tree: RunTree.from_list(runs)}, runs)}
  end

  # A change is `{offset, removed_bytes, inserted_text}` in the original document.
  @spec flip_run({[change()], t()}, Locator.t(), binary()) :: {[change()], t()}
  defp flip_run({changes, prov}, run_id, content) do
    {:ok, run, offset} = RunTree.fetch(prov.tree, run_id)
    {flipped, change} = flip(run, prov.groups, content, offset)
    {List.wrap(change) ++ changes, put_run(prov, run, flipped)}
  end

  # Applies every change at once and checks only the result.
  # A group's runs split a code point when its edit did, so the pieces of one change need not be valid UTF-8 alone.
  @spec apply_changes([change()], binary(), Document.t()) ::
          {:ok, Document.t()} | {:error, :invalid_utf8}
  defp apply_changes([], _content, document), do: {:ok, document}

  defp apply_changes(changes, content, _document) do
    {chunks, point} =
      Enum.reduce(changes, {[], 0}, fn {offset, removed, inserted}, {chunks, point} ->
        {[inserted, binary_part(content, point, offset - point) | chunks], offset + removed}
      end)

    new_content =
      [binary_part(content, point, byte_size(content) - point) | chunks]
      |> Enum.reverse()
      |> :erlang.iolist_to_binary()

    if Unicode.valid_utf8?(new_content),
      do: {:ok, Document.new(new_content)},
      else: {:error, :invalid_utf8}
  end

  @spec first_offset([change()]) :: non_neg_integer() | nil
  defp first_offset([]), do: nil
  defp first_offset([{offset, _removed, _inserted} | _rest]), do: offset

  @spec live?(Run.t(), %{group_id() => Group.t()}) :: boolean()
  defp live?(run, groups) do
    inserted?(groups, run.group) and not Enum.any?(run.deletions, &Map.fetch!(groups, &1).applied)
  end

  @spec inserted?(%{group_id() => Group.t()}, group_id() | nil) :: boolean()
  defp inserted?(_groups, nil), do: true
  defp inserted?(groups, id), do: Map.fetch!(groups, id).applied

  # Deleters are prepended, so the groups that deleted a run after this group did come before it in the list.
  # Text this group inserted can only have been deleted later.
  @spec later_deleters(Run.t(), group_id()) :: [group_id()]
  defp later_deleters(%Run{group: id, deletions: deletions}, id), do: deletions
  defp later_deleters(%Run{deletions: deletions}, id), do: Enum.take_while(deletions, &(&1 != id))

  # The groups that touched a run before `id` deleted it: its inserting group and the earlier deleters.
  @spec earlier_groups(Run.t(), group_id()) :: [group_id()]
  defp earlier_groups(%Run{deletions: deletions} = run, id) do
    case Enum.split_while(deletions, &(&1 != id)) do
      {_later, [^id | earlier]} -> Enum.reject([run.group | earlier], &is_nil/1)
      {_all, []} -> []
    end
  end

  @spec blocking_key(
          %{group_id() => Group.t()},
          group_id(),
          group_id(),
          (author(), group_key() -> boolean())
        ) :: group_key() | nil
  defp blocking_key(_groups, id, id, _blocks?), do: nil

  defp blocking_key(groups, deleter, _id, blocks?) do
    case Map.fetch!(groups, deleter) do
      %Group{applied: true, author: author, key: key} -> if blocks?.(author, key), do: key
      %Group{} -> nil
    end
  end

  # ── Discarding ──────────────────────────────────────────────────────

  @spec settle_run(t(), Locator.t(), %{group_id() => Group.t()}) :: t()
  defp settle_run(prov, run_id, discarded) do
    {:ok, run, _offset} = RunTree.fetch(prov.tree, run_id)

    case settle(run, discarded) do
      nil ->
        drop_run(prov, %{run | overlaps: settled_run(run, discarded).overlaps})

      %Run{group: nil} = settled when run.group != nil ->
        prov |> put_run(run, settled) |> coalesce(run_id)

      settled ->
        put_run(prov, run, settled)
    end
  end

  # Applies `settle/2` for every discarded group to every run in order, merging permanent neighbours, then
  # rebuilds the tree and the remaining groups' run sets from the result.
  @spec discard_in_one_pass(t(), [group_id()]) :: t()
  defp discard_in_one_pass(prov, ids) do
    {discarded, groups} = Map.split(prov.groups, ids)

    {runs, dropped} =
      prov.tree
      |> RunTree.to_list()
      |> Enum.reduce({[], []}, fn run, acc -> settle_in_pass(run, discarded, acc) end)

    runs = Enum.reverse(runs)

    members =
      runs
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn run, acc ->
        Enum.reduce(run_groups(run), acc, fn id, inner ->
          Map.update(inner, id, [run.id], &[run.id | &1])
        end)
      end)

    groups =
      Map.new(groups, fn {id, group} ->
        {id, %{group | runs: :gb_sets.from_ordset(Map.get(members, id, []))}}
      end)

    prov =
      index_drafts(
        %{
          prov
          | tree: RunTree.from_list(runs),
            groups: groups,
            changes: changes_from(prov.changes, runs, dropped),
            overlap_runs: Map.drop(prov.overlap_runs, ids)
        },
        runs
      )

    dropped
    |> Enum.reverse()
    |> Enum.reduce(settle_group_marks(prov, discarded), fn run, acc ->
      acc |> link_dropped(run) |> transfer_marks(run.overlaps)
    end)
    |> settle_owners(discarded)
    |> settle_changes()
  end

  # Settles one run into the runs kept so far, or lists it as dropped with its settled marks.
  @spec settle_in_pass(Run.t(), %{group_id() => Group.t()}, {[Run.t()], [Run.t()]}) ::
          {[Run.t()], [Run.t()]}
  defp settle_in_pass(run, discarded, {kept, dropped}) do
    case settle(run, discarded) do
      nil ->
        {kept, [%{run | overlaps: settled_run(run, discarded).overlaps} | dropped]}

      settled ->
        {merge_permanent(settled, kept), dropped}
    end
  end

  @spec merge_permanent(Run.t(), [Run.t()]) :: [Run.t()]
  defp merge_permanent(run, [previous | rest] = acc) do
    if permanent?(run) and permanent?(previous) and previous.author == run.author,
      do: [%{previous | bytes: previous.bytes + run.bytes} | rest],
      else: [run | acc]
  end

  defp merge_permanent(run, []), do: [run]

  # Merges a permanent run with permanent neighbours by the same author.
  # Settled history then leaves no more runs than authorship needs.
  @spec coalesce(t(), Locator.t()) :: t()
  defp coalesce(prov, run_id) do
    {:ok, run, _offset} = RunTree.fetch(prov.tree, run_id)
    previous = RunTree.previous(prov.tree, run_id)

    {prov, run} =
      if permanent?(run) and permanent?(previous) and previous.author == run.author do
        merged = %{previous | bytes: previous.bytes + run.bytes}
        {%{prov | tree: prov.tree |> RunTree.delete(run_id) |> RunTree.update(merged)}, merged}
      else
        {prov, run}
      end

    following = RunTree.next(prov.tree, run.id)

    if permanent?(run) and permanent?(following) and following.author == run.author do
      merged = %{run | bytes: run.bytes + following.bytes}
      %{prov | tree: prov.tree |> RunTree.delete(following.id) |> RunTree.update(merged)}
    else
      prov
    end
  end

  @spec permanent?(Run.t() | nil) :: boolean()
  defp permanent?(%Run{live: true, group: nil, deletions: [], made_by: nil, replaced_by: []}),
    do: true

  defp permanent?(_run), do: false

  # ── Editing in one pass ─────────────────────────────────────────────
  #
  # The changes are applied from the last to the first, as `edit/5` would apply them, over the run list walked from the
  # end: everything left of the current change is still as it was, and everything right of it already holds the later
  # changes. `left` holds the runs before the boundary nearest first, `right` the runs after it in order, and `pos` the
  # live offset of the boundary.

  @typep pass :: %{
           left: [Run.t()],
           right: [Run.t()],
           pos: non_neg_integer(),
           next_change: pos_integer(),
           steps: [{[Change.id()], Change.id() | nil, [Change.id()]}],
           dropped: [Run.t()]
         }

  # The pass applies every deletion and insertion and numbers the replacements as `edit/5` would. The covers come
  # after the rebuild, one change at a time in the order they were applied, with each replacement's live text taken
  # as of that change: text a change applied later kills was still live.
  @spec edit_in_one_pass(t(), group_id() | :untracked, [{non_neg_integer(), binary(), binary()}]) ::
          t()
  defp edit_in_one_pass(prov, group, changes) do
    {group_id, author} = writer(prov, group)

    pass = %{
      left: prov.tree |> RunTree.to_list() |> Enum.reverse(),
      right: [],
      pos: RunTree.size(prov.tree),
      next_change: prov.next_change,
      steps: [],
      dropped: []
    }

    pass =
      changes
      |> Enum.reverse()
      |> Enum.reduce(pass, &apply_in_pass(group_id, author, &1, &2))

    ranges =
      changes
      |> Enum.map(fn {start, removed, _inserted} -> {start, start + byte_size(removed)} end)
      |> List.to_tuple()

    last = tuple_size(ranges) - 1
    steps = Enum.reverse(pass.steps)

    # The covers and marks every change's worklist makes, decided on the record as it was before the pass, then applied
    # to the run list in the same pass that rebuilds the tree: O(n) for the whole batch.
    plan =
      steps
      |> Enum.with_index()
      |> Enum.reduce(%{covers: MapSet.new(), marks: %{}, fault: false}, fn
        {{seeds, _change, _pulled}, applied}, plan ->
          plan_each(prov, group_id, seeds, MapSet.new(seeds), {ranges, last - applied}, plan)
      end)

    {runs, covered_away} =
      pass.left |> Enum.reverse(pass.right) |> apply_plan(plan, group_id)

    dropped = covered_away ++ pass.dropped

    rebuilt =
      rebuild(%{prov | next_change: pass.next_change}, merge_live_neighbours(runs), dropped)

    rebuilt = if plan.fault, do: fault(rebuilt, :all), else: rebuilt

    rebuilt =
      Enum.reduce(dropped, rebuilt, fn run, acc ->
        acc |> link_dropped(run) |> transfer_marks(run.overlaps)
      end)

    steps
    |> Enum.reduce(rebuilt, fn
      {_seeds, nil, _pulled}, acc -> acc
      {_seeds, change, pulled}, acc -> Enum.reduce(pulled, acc, &pull(&2, change, &1))
    end)
    |> settle_changes()
  end

  @typep plan :: %{
           covers: MapSet.t(Locator.t()),
           marks: %{Locator.t() => [Run.overlap()]},
           fault: boolean()
         }

  # `consume/4` for one change of a batch, as a plan over the runs before the pass. `at` is the ranges and the index,
  # in document order, of the change being applied.
  @spec plan_each(
          t(),
          group_id() | nil,
          [Change.id()],
          MapSet.t(),
          {tuple(), non_neg_integer()},
          plan()
        ) ::
          plan()
  defp plan_each(_prov, _group_id, [], _seen, _at, plan), do: plan

  defp plan_each(prov, group_id, [change | rest], seen, at, plan) do
    {plan, reached} = plan_change(prov, group_id, change, at, plan)
    reached = reached |> Enum.uniq() |> Enum.reject(&MapSet.member?(seen, &1))
    plan_each(prov, group_id, reached ++ rest, Enum.into(reached, seen), at, plan)
  end

  @spec plan_change(t(), group_id() | nil, Change.id(), {tuple(), non_neg_integer()}, plan()) ::
          {plan(), [Change.id()]}
  defp plan_change(prov, group_id, change, {ranges, index} = at, plan) do
    with {:ok, record} <- Map.fetch(prov.changes, change),
         {:ok, made} <- fetch_runs(prov.tree, record.made) do
      owner = owner_of(record, made)

      cond do
        is_integer(owner) and not Map.has_key?(prov.groups, owner) ->
          {%{plan | fault: true}, []}

        # A change carries its replacement only while it is applied.
        is_integer(owner) and not Map.fetch!(prov.groups, owner).applied ->
          {plan, []}

        consumed_by(prov, ranges, index, change, made) == :partial ->
          {plan_marks(plan, prov.groups, group_id, owner, made), []}

        true ->
          plan_cover(prov, record, at, plan)
      end
    else
      :error -> {%{plan | fault: true}, []}
    end
  end

  @spec plan_marks(plan(), %{group_id() => Group.t()}, group_id() | nil, group_id() | nil, [
          Run.t()
        ]) :: plan()
  defp plan_marks(plan, groups, group_id, owner, made) do
    if group_id != nil and is_integer(owner) and foreign_owner?(groups, owner, group_id) do
      marks =
        Enum.reduce(made, plan.marks, fn run, marks ->
          Map.update(marks, run.id, [{owner, group_id}], &[{owner, group_id} | &1])
        end)

      %{plan | marks: marks}
    else
      plan
    end
  end

  # Dead replaced runs are covered. A replaced run this batch deleted itself by now is not covered again, but the
  # replacement that made it is still reached.
  @spec plan_cover(t(), Change.t(), {tuple(), non_neg_integer()}, plan()) ::
          {plan(), [Change.id()]}
  defp plan_cover(prov, record, {ranges, index}, plan) do
    record.replaced
    |> :gb_sets.to_list()
    |> Enum.reduce({plan, :gb_sets.to_list(record.pulls)}, fn run_id, {plan, reached} ->
      plan_covered_run(RunTree.fetch(prov.tree, run_id), {ranges, index}, plan, reached)
    end)
  end

  @spec plan_covered_run(
          {:ok, Run.t(), non_neg_integer()} | :error,
          {tuple(), non_neg_integer()},
          plan(),
          [Change.id()]
        ) :: {plan(), [Change.id()]}
  defp plan_covered_run({:ok, %Run{live: false} = run, _offset}, _at, plan, reached),
    do: {%{plan | covers: MapSet.put(plan.covers, run.id)}, List.wrap(run.made_by) ++ reached}

  defp plan_covered_run({:ok, run, offset}, {ranges, index}, plan, reached) do
    if touched?(ranges, index, offset, offset + run.bytes),
      do: {plan, List.wrap(run.made_by) ++ reached},
      else: {plan, reached}
  end

  defp plan_covered_run(:error, _at, plan, reached), do: {%{plan | fault: true}, reached}

  # Applies a plan's marks and covers to the runs after the pass. Returns the runs and the ones a cover dropped.
  @spec apply_plan([Run.t()], plan(), group_id() | nil) :: {[Run.t()], [Run.t()]}
  defp apply_plan(runs, %{covers: covers, marks: marks}, group_id) do
    if MapSet.size(covers) == 0 and marks == %{} do
      {runs, []}
    else
      {kept, dropped} =
        Enum.reduce(runs, {[], []}, &apply_plan_to(&1, &2, covers, marks, group_id))

      {Enum.reverse(kept), dropped}
    end
  end

  @spec apply_plan_to(
          Run.t(),
          {[Run.t()], [Run.t()]},
          MapSet.t(Locator.t()),
          %{Locator.t() => [Run.overlap()]},
          group_id() | nil
        ) :: {[Run.t()], [Run.t()]}
  defp apply_plan_to(run, {kept, dropped}, covers, marks, group_id) do
    run = marked(run, Map.get(marks, run.id, []))

    case planned_cover(run, MapSet.member?(covers, run.id), group_id) do
      nil -> {kept, [run | dropped]}
      covered -> {[covered | kept], dropped}
    end
  end

  @spec marked(Run.t(), [Run.overlap()]) :: Run.t()
  defp marked(run, marks),
    do:
      Enum.reduce(marks, run, fn {owner, overlapper}, acc ->
        with_overlap(acc, owner, overlapper)
      end)

  @spec planned_cover(Run.t(), boolean(), group_id() | nil) :: Run.t() | nil
  defp planned_cover(run, false, _group_id), do: run
  defp planned_cover(%Run{live: true} = run, true, _group_id), do: run

  defp planned_cover(run, true, group_id) do
    case deleted(run, group_id, run.text) do
      nil -> nil
      ^run -> run
      dead -> %{dead | covered_by: [group_id | dead.covered_by]}
    end
  end

  # Whether a range from `index` on, in document order, deletes any byte from `from` up to `to`.
  @spec touched?(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp touched?(ranges, index, from, to),
    do: touched_from?(ranges, first_ending_after(ranges, index, tuple_size(ranges), from), to)

  @spec touched_from?(tuple(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp touched_from?(ranges, index, to) when index < tuple_size(ranges) do
    case elem(ranges, index) do
      {start, _stop} when start >= to -> false
      {start, stop} when stop > start -> true
      _insertion -> touched_from?(ranges, index + 1, to)
    end
  end

  defp touched_from?(_ranges, _index, _to), do: false

  # Whether a replacement keeps live text once the changes from `index` to the last, in document order, are applied:
  # its made runs as they were before the pass, less those changes' ranges.
  @spec consumed_by(t(), tuple(), non_neg_integer(), Change.id(), [Run.t()]) :: :partial | :whole
  defp consumed_by(before, ranges, index, change, _made) do
    case before.changes do
      %{^change => record} ->
        live? =
          record.made |> :gb_sets.to_list() |> Enum.any?(&live_after?(before, ranges, index, &1))

        if live?, do: :partial, else: :whole

      _made_in_this_pass ->
        :partial
    end
  end

  # Whether a run that was live before the pass keeps bytes outside the ranges from `index` on.
  @spec live_after?(t(), tuple(), non_neg_integer(), Locator.t()) :: boolean()
  defp live_after?(before, ranges, index, run_id) do
    case RunTree.fetch(before.tree, run_id) do
      {:ok, %Run{live: true} = run, offset} ->
        not covered?(ranges, index, offset, offset + run.bytes)

      _dead_or_gone ->
        false
    end
  end

  # Whether the ranges from `index` on, disjoint and in order, cover the bytes from `from` up to `to`.
  @spec covered?(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp covered?(ranges, index, from, to),
    do:
      covered_from(ranges, first_ending_after(ranges, index, tuple_size(ranges), from), from, to)

  @spec first_ending_after(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp first_ending_after(ranges, low, high, offset) when low < high do
    middle = div(low + high, 2)
    {_start, stop} = elem(ranges, middle)

    if stop > offset,
      do: first_ending_after(ranges, low, middle, offset),
      else: first_ending_after(ranges, middle + 1, high, offset)
  end

  defp first_ending_after(_ranges, low, _high, _offset), do: low

  @spec covered_from(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  defp covered_from(_ranges, _index, point, to) when point >= to, do: true

  defp covered_from(ranges, index, point, to) when index < tuple_size(ranges) do
    {start, stop} = elem(ranges, index)
    if start > point, do: false, else: covered_from(ranges, index + 1, max(point, stop), to)
  end

  defp covered_from(_ranges, _index, _point, _to), do: false

  @spec apply_in_pass(
          group_id() | nil,
          author(),
          {non_neg_integer(), binary(), binary()},
          pass()
        ) :: pass()
  defp apply_in_pass(group_id, author, {start, removed, inserted}, pass) do
    pass = move_right_of(pass, start + byte_size(removed), removed != "")
    {segment, pass} = take_from(pass, start, [])
    change = if inserted != "" and removed != "" and group_id != nil, do: pass.next_change
    {deleted, dropped} = delete_segment(segment, group_id, removed, change)
    pulled = for %Run{made_by: maker} <- dropped, maker != nil, uniq: true, do: maker
    made_by = record_id(change, deleted, pulled, author)

    # A record's runs name it only when it has one; an edit that gets none lists nothing.
    deleted =
      if change != nil and made_by == nil,
        do: Enum.map(deleted, &unlist(&1, change)),
        else: deleted

    inserted_runs = inserted_runs(inserted, author, group_id, made_by)

    %{
      pass
      | right: inserted_runs ++ deleted ++ pass.right,
        next_change: if(made_by, do: made_by + 1, else: pass.next_change),
        steps: [{seeds(Enum.filter(segment, & &1.live)), made_by, pulled} | pass.steps],
        dropped: dropped ++ pass.dropped
    }
  end

  # Moves the runs after `stop` to the right side, splitting a live run that crosses it. Tombstones right at `stop` stay
  # on the left for a pure insertion, which lands after them, and move right after a deletion, which ends before them.
  @spec move_right_of(pass(), non_neg_integer(), boolean()) :: pass()
  defp move_right_of(%{left: [run | rest]} = pass, stop, deleting?) do
    run_start = pass.pos - Run.live_bytes(run)

    cond do
      run.live and run_start >= stop ->
        move_right_of(
          %{pass | left: rest, right: [run | pass.right], pos: run_start},
          stop,
          deleting?
        )

      run.live and pass.pos > stop ->
        {before, after_stop} = {%{run | bytes: stop - run_start}, %{run | bytes: pass.pos - stop}}
        %{pass | left: [before | rest], right: [after_stop | pass.right], pos: stop}

      not run.live and (pass.pos > stop or (pass.pos == stop and deleting?)) ->
        move_right_of(%{pass | left: rest, right: [run | pass.right]}, stop, deleting?)

      true ->
        pass
    end
  end

  defp move_right_of(pass, _stop, _deleting?), do: pass

  # Takes the runs from the live run at `start` to the boundary, in order, splitting a live run that crosses `start`.
  @spec take_from(pass(), non_neg_integer(), [Run.t()]) :: {[Run.t()], pass()}
  defp take_from(%{left: [run | rest]} = pass, start, acc) do
    run_start = pass.pos - Run.live_bytes(run)

    cond do
      run.live and run_start >= start and pass.pos > start ->
        take_from(%{pass | left: rest, pos: run_start}, start, [run | acc])

      run.live and run_start < start and pass.pos > start ->
        {before, taken} = {%{run | bytes: start - run_start}, %{run | bytes: pass.pos - start}}
        {[taken | acc], %{pass | left: [before | rest], pos: start}}

      not run.live and pass.pos > start ->
        take_from(%{pass | left: rest}, start, [run | acc])

      true ->
        {acc, pass}
    end
  end

  defp take_from(pass, _start, acc), do: {acc, pass}

  # The id an edit's inserted text names, as `open_change/5` decides: none when it could never cover, pull or mark.
  @spec record_id(Change.id() | nil, [Run.t()], [Change.id()], author()) :: Change.id() | nil
  defp record_id(nil, _deleted, _pulled, _author), do: nil

  defp record_id(change, deleted, pulled, author) do
    if deleted != [] or pulled != [] or minga?(author), do: change
  end

  @spec inserted_runs(binary(), author(), group_id() | nil, Change.id() | nil) :: [Run.t()]
  defp inserted_runs("", _author, _group_id, _made_by), do: []

  defp inserted_runs(inserted, author, group_id, made_by),
    do: [
      %Run{id: [0], bytes: byte_size(inserted), author: author, group: group_id, made_by: made_by}
    ]

  # The segment's runs once deleted, each kept one listed under `change`, and the runs the deletion dropped.
  @spec delete_segment([Run.t()], group_id() | nil, binary(), Change.id() | nil) ::
          {[Run.t()], [Run.t()]}
  defp delete_segment(segment, group_id, removed, change) do
    {kept, dropped, _consumed} =
      Enum.reduce(segment, {[], [], 0}, fn run, {kept, dropped, consumed} ->
        {text, consumed} =
          if run.live,
            do: {binary_part(removed, consumed, run.bytes), consumed + run.bytes},
            else: {run.text, consumed}

        case deleted(run, group_id, text) do
          nil ->
            {kept, [run | dropped], consumed}

          dead ->
            dead = how_deleted(dead, run, group_id, run.live)
            {[replaced_by(dead, change) | kept], dropped, consumed}
        end
      end)

    {Enum.reverse(kept), dropped}
  end

  @spec unlist(Run.t(), Change.id()) :: Run.t()
  defp unlist(run, change), do: %{run | replaced_by: List.delete(run.replaced_by, change)}

  @spec replaced_by(Run.t(), Change.id() | nil) :: Run.t()
  defp replaced_by(run, nil), do: run
  defp replaced_by(run, change), do: %{run | replaced_by: [change | run.replaced_by]}

  # Neighbouring live runs of the same group and author with no deleters or marks are one run, as typing forward
  # makes them; the one-pass path then never holds more runs than the same edits made one at a time.
  @spec merge_live_neighbours([Run.t()]) :: [Run.t()]
  defp merge_live_neighbours(runs) do
    runs
    |> Enum.reduce([], fn
      %Run{live: true, deletions: [], overlaps: []} = run,
      [%Run{live: true, deletions: [], overlaps: []} = previous | rest]
      when run.group == previous.group and run.author == previous.author and
             run.made_by == previous.made_by and run.replaced_by == previous.replaced_by ->
        [%{previous | bytes: previous.bytes + run.bytes} | rest]

      run, acc ->
        [run | acc]
    end)
    |> Enum.reverse()
  end

  # Gives every run an evenly spaced locator and rebuilds the tree, the groups' run sets, and both indexes from the
  # runs, in O(n).
  @spec rebuild(t(), [Run.t()], [Run.t()]) :: t()
  defp rebuild(prov, runs, dropped) do
    runs =
      runs
      |> Enum.zip(Locator.even(length(runs)))
      |> Enum.map(fn {run, id} -> %{run | id: id} end)

    members =
      runs
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn run, acc ->
        Enum.reduce(run_groups(run), acc, fn id, inner ->
          Map.update(inner, id, [run.id], &[run.id | &1])
        end)
      end)

    groups =
      Map.new(prov.groups, fn {id, group} ->
        {id, %{group | runs: :gb_sets.from_ordset(Map.get(members, id, []))}}
      end)

    overlap_runs =
      runs
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn run, acc ->
        for {_owner, group} when is_integer(group) <- run.overlaps, reduce: acc do
          inner -> Map.update(inner, group, [run.id], &[run.id | &1])
        end
      end)

    index_drafts(
      %{
        prov
        | tree: RunTree.from_list(runs),
          groups: groups,
          changes: changes_from(prov.changes, runs, dropped),
          overlap_runs: overlap_runs,
          deep: false,
          recent: [],
          fresh: []
      },
      runs
    )
  end

  # The replacement records rebuilt from the runs' `made_by` and `replaced_by`, in O(n). Links between records come
  # from dropped runs, not from the runs, so they carry over. A record that only links or only a dropped run names
  # stays until the operation settles it.
  @spec changes_from(%{Change.id() => Change.t()}, [Run.t()], [Run.t()]) :: %{
          Change.id() => Change.t()
        }
  defp changes_from(previous, runs, dropped) do
    {made, replaced} =
      runs
      |> Enum.reverse()
      |> Enum.reduce({%{}, %{}}, fn run, {made, replaced} ->
        made =
          if run.made_by,
            do: Map.update(made, run.made_by, [run.id], &[run.id | &1]),
            else: made

        replaced =
          Enum.reduce(run.replaced_by, replaced, fn change, acc ->
            Map.update(acc, change, [run.id], &[run.id | &1])
          end)

        {made, replaced}
      end)

    linked =
      for {id, change} <- previous,
          not :gb_sets.is_empty(change.pulls) or not :gb_sets.is_empty(change.pulled_by),
          do: id

    named = Enum.flat_map(dropped, &(List.wrap(&1.made_by) ++ &1.replaced_by))

    (Map.keys(made) ++ Map.keys(replaced) ++ linked ++ named)
    |> Enum.uniq()
    |> Map.new(fn id ->
      links = Map.get(previous, id, %Change{})

      {id,
       %Change{
         made: :gb_sets.from_ordset(Map.get(made, id, [])),
         replaced: :gb_sets.from_ordset(Map.get(replaced, id, [])),
         pulls: links.pulls,
         pulled_by: links.pulled_by,
         owner: links.owner
       }}
    end)
  end

  # ── Rules shared by the per-run and one-pass paths ──────────────────
  #
  # Each decision about a run lives here once, as a pure function of the run and the groups. The tree paths and the
  # one-pass paths differ only in how they visit runs and rebuild structure.

  # What a deletion by `group_id` (`nil` when untracked) does to a run: untracked deletion and a group deleting its own
  # text forget it (`nil`), a run the group already deleted stays as it is, and any other run becomes its tombstone.
  @spec deleted(Run.t(), group_id() | nil, binary()) :: Run.t() | nil
  defp deleted(_run, nil, _text), do: nil
  defp deleted(%Run{group: group_id}, group_id, _text), do: nil

  defp deleted(run, group_id, text) do
    if group_id in run.deletions,
      do: run,
      else: %{run | deletions: [group_id | run.deletions], live: false, text: own(text)}
  end

  # Another author's Minga text, whose partial deletion needs an overlap mark.
  @spec foreign?(%{group_id() => Group.t()}, Run.t(), group_id()) :: boolean()
  defp foreign?(_groups, %Run{group: nil}, _group_id), do: false
  defp foreign?(groups, %Run{group: group}, group_id), do: foreign_owner?(groups, group, group_id)

  # Whether `owner` is a Minga step by another author than `group_id`.
  @spec foreign_owner?(%{group_id() => Group.t()}, group_id(), group_id()) :: boolean()
  defp foreign_owner?(groups, owner, group_id) do
    author = Map.fetch!(groups, owner).author
    match?({:minga, _task}, author) and author != Map.fetch!(groups, group_id).author
  end

  @spec with_overlap(Run.t(), group_id(), group_id() | {:permanent, term()}) :: Run.t()
  defp with_overlap(run, owner, group_id) do
    if {owner, group_id} in run.overlaps,
      do: run,
      else: %{run | overlaps: [{owner, group_id} | run.overlaps]}
  end

  # A run after its groups' applied flags changed, and the change to the document at `offset` it causes, if any.
  @spec flip(Run.t(), %{group_id() => Group.t()}, binary(), non_neg_integer()) ::
          {Run.t(), change() | nil}
  defp flip(run, groups, content, offset) do
    case {run.live, live?(run, groups)} do
      {same, same} ->
        {run, nil}

      {false, true} ->
        {%{run | live: true, text: nil}, {offset, 0, run.text}}

      {true, false} ->
        text = :binary.copy(binary_part(content, offset, run.bytes))
        {%{run | live: false, text: text}, {offset, run.bytes, ""}}
    end
  end

  # A run once the `discarded` groups are final: `nil` when it can never be live again, otherwise without them. A kept
  # group's text becomes permanent; marks about a discarded owner go; a discarded overlapper's marks settle.
  @spec settle(Run.t(), %{group_id() => Group.t()}) :: Run.t() | nil
  defp settle(run, discarded) do
    cond do
      unapplied_writer?(run, discarded) -> nil
      Enum.any?(run.deletions, &kept?(discarded, &1)) -> nil
      true -> settled_run(run, discarded)
    end
  end

  @spec kept?(%{group_id() => Group.t()}, group_id()) :: boolean()
  defp kept?(discarded, id), do: match?(%{^id => %Group{applied: true}}, discarded)

  @spec unapplied_writer?(Run.t(), %{group_id() => Group.t()}) :: boolean()
  defp unapplied_writer?(%Run{group: group}, discarded) do
    case discarded do
      %{^group => %Group{applied: false}} -> true
      _kept_or_other -> false
    end
  end

  @spec settled_run(Run.t(), %{group_id() => Group.t()}) :: Run.t()
  defp settled_run(run, discarded) do
    group = if Map.has_key?(discarded, run.group), do: nil, else: run.group

    overlaps =
      Enum.flat_map(run.overlaps, fn
        {owner, _overlap} when is_map_key(discarded, owner) ->
          []

        {owner, id} when is_map_key(discarded, id) ->
          case settled_overlap(id, Map.fetch!(discarded, id)) do
            nil -> []
            settled -> [{owner, settled}]
          end

        mark ->
          [mark]
      end)

    %{
      run
      | group: group,
        deletions: Enum.reject(run.deletions, &Map.has_key?(discarded, &1)),
        covered_by: Enum.reject(run.covered_by, &Map.has_key?(discarded, &1)),
        swept_by: Enum.reject(run.swept_by, &Map.has_key?(discarded, &1)),
        overlaps: overlaps
    }
  end

  # ── Bookkeeping ─────────────────────────────────────────────────────

  @spec put_run(t(), Run.t(), Run.t()) :: t()
  defp put_run(prov, old, run),
    do: refresh_draft(%{prov | tree: RunTree.update(prov.tree, run)}, old, run)

  # The run leaves every index; see `forget_changes/2`. Its overlap marks move to another run of their owner.
  @spec drop_run(t(), Run.t()) :: t()
  defp drop_run(prov, run) do
    groups = Enum.reduce(run_groups(run), prov.groups, &remove_run(&2, &1, run.id))

    %{
      prov
      | tree: RunTree.delete(prov.tree, run.id),
        groups: groups,
        drafts: :gb_sets.delete_any({run.group, run.id}, prov.drafts)
    }
    |> forget_changes(run)
    |> transfer_marks(run.overlaps)
  end

  # A draft is a tombstone a Minga step wrote that a newer applied step of the same task deleted, with both applied:
  # the task overwrote its own text. Drafts are indexed by their group, so compaction finds the oldest in O(log n).
  # Agent edits without a task are bounded by their own cap and are never drafts.
  @spec draft_key(Run.t(), %{group_id() => Group.t()}) :: {group_id(), Locator.t()} | nil
  defp draft_key(%Run{live: false, group: owner} = run, groups) when owner != nil do
    case draft_partner(run, groups) do
      nil -> nil
      new -> if merge_safe?(run, owner, new), do: {owner, run.id}
    end
  end

  defp draft_key(_run, _groups), do: nil

  # The step a draft would merge into: the oldest newer applied step of the same task that deleted it, or `nil`.
  @spec draft_partner(Run.t(), %{group_id() => Group.t()}) :: group_id() | nil
  defp draft_partner(%Run{live: false, group: owner} = run, groups) when owner != nil do
    case Map.fetch!(groups, owner) do
      %Group{applied: true, author: {:minga, task} = author} when task != :untasked ->
        run.deletions
        # A group being discarded is already gone from the map; it is no partner.
        |> Enum.filter(&(&1 > owner and newer_step?(Map.get(groups, &1), author)))
        |> Enum.min(fn -> nil end)

      _other ->
        nil
    end
  end

  defp draft_partner(_run, _groups), do: nil

  # Merging `old` into `new` keeps every blocker only where no other group touched the run between them: in the order
  # its writer and deleters came, `old` and `new` are next to each other, or not both there.
  @spec merge_safe?(Run.t(), group_id(), group_id()) :: boolean()
  defp merge_safe?(run, old, new) do
    # An inert run names its writer among its deleters too; it counts once, so a chain of steps keeps folding.
    order = Enum.uniq([run.group | Enum.reverse(run.deletions)])

    # No group between the two may be named either, or the merge would point a dependency backwards in time.
    named = order ++ for({_owner, overlap} <- run.overlaps, is_integer(overlap), do: overlap)

    not Enum.any?(named, &(is_integer(&1) and &1 > old and &1 < new)) and
      case {Enum.find_index(order, &(&1 == old)), Enum.find_index(order, &(&1 == new))} do
        {nil, _new} -> true
        {_old, nil} -> true
        {old_at, new_at} -> abs(old_at - new_at) == 1
      end
  end

  @spec newer_step?(Group.t() | nil, author()) :: boolean()
  defp newer_step?(%Group{applied: true, author: author}, author), do: true
  defp newer_step?(_group, _author), do: false

  # Keeps the draft index exact after a run changed from `old` to `run`.
  @spec refresh_draft(t(), Run.t(), Run.t()) :: t()
  defp refresh_draft(prov, old, run) do
    drafts = :gb_sets.delete_any({old.group, old.id}, prov.drafts)

    case draft_key(run, prov.groups) do
      nil -> %{prov | drafts: drafts}
      key -> %{prov | drafts: :gb_sets.add(key, drafts)}
    end
  end

  # Rebuilds the draft index from every run, for the paths that rebuild the whole tree anyway.
  @spec index_drafts(t(), [Run.t()]) :: t()
  defp index_drafts(prov, runs) do
    drafts = for run <- runs, key = draft_key(run, prov.groups), do: key
    %{prov | drafts: :gb_sets.from_list(drafts)}
  end

  @spec run_groups(Run.t()) :: [group_id()]
  defp run_groups(%Run{group: nil, deletions: deletions}), do: deletions

  defp run_groups(%Run{group: group, deletions: deletions}) do
    # Only an inert run that compaction kept names its own writer as a deleter too.
    if group in deletions, do: deletions, else: [group | deletions]
  end

  @spec run_key(%{group_id() => Group.t()}, Run.t()) :: group_key()
  defp run_key(_groups, %Run{group: nil}), do: nil
  defp run_key(groups, %Run{group: id}), do: Map.fetch!(groups, id).key

  @spec add_run(%{group_id() => Group.t()}, group_id(), Locator.t()) ::
          %{group_id() => Group.t()}
  defp add_run(groups, id, run_id) do
    Map.update!(groups, id, fn group -> %{group | runs: :gb_sets.add(run_id, group.runs)} end)
  end

  # A group being discarded is already gone from the map.
  @spec remove_run(%{group_id() => Group.t()}, group_id(), Locator.t()) ::
          %{group_id() => Group.t()}
  defp remove_run(groups, id, run_id) do
    case groups do
      %{^id => group} ->
        %{groups | id => %{group | runs: :gb_sets.delete_any(run_id, group.runs)}}

      _discarded ->
        groups
    end
  end

  # Tombstone text must not keep a whole document binary alive.
  @spec own(binary()) :: binary()
  defp own(text) do
    if :binary.referenced_byte_size(text) > byte_size(text), do: :binary.copy(text), else: text
  end
end
