defmodule Minga.Buffer.Provenance do
  @moduledoc """
  Who wrote each byte of a buffer, and the history that can take each author's work back out.

  The document is a sequence of authorship runs (`Minga.Buffer.Provenance.Run`) held in a balanced sum tree in document order. Each run names its author and the history group that inserted it, and lists the groups that deleted it. A run is live, and its text is in the document, when the group that inserted it is applied and no group that deleted it is applied. Deleted text stays in the tree as a tombstone that keeps its text, so it can be restored exactly where it was.

  A history group (`Minga.Buffer.Provenance.Group`) is one of your undo steps or one Minga step. Undoing, redoing, or rejecting a group flips whether it is applied (`revert/3`, `reapply/3`); every run it touched then turns live or dead on its own, and the document changes by exactly the text of that group. Because a group finds its runs by locator, not by byte offset, edits made by anyone else after it, above or inside it, never make it point at the wrong text.

  ## Edit order

  An insertion at byte `p` goes immediately before the live byte that was at `p`, so it lands after any tombstones that sit at `p`. A deletion kills the live runs in its range and also marks every tombstone strictly inside the range, so restoring that older text later cannot reappear in the middle of text a later edit removed.

  ## Lines

  Runs measure bytes only. A live run's text is in the document, not in the run, so splitting a run cannot count newlines without reading the document. Callers convert lines to bytes through the document's line index (`Minga.Buffer.Lines.start_of/2`) and query byte ranges here.

  ## Cost

  For n runs: applying an edit that touches k runs costs O((k + 1) log n); finding the author at a byte costs O(log n); listing the runs in a byte range costs O(log n + k); reverting or reapplying a group with k runs costs O(k log n) plus one pass over the document to apply its changes together.

  This module is pure. `Minga.Buffer.UndoHistory` owns the value and decides which groups exist; `Minga.Buffer.Process` keeps it in step with every change to the document.
  """

  alias Minga.Buffer.Document
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
            drafts: :gb_sets.new()

  @opaque t :: %__MODULE__{
            tree: RunTree.t(),
            groups: %{Run.group_id() => Group.t()},
            next_group: pos_integer(),
            deep: boolean(),
            recent: [Locator.t()],
            fresh: [Locator.t()],
            overlap_runs: %{group_id() => [Locator.t()]},
            drafts: :gb_sets.set({group_id(), Locator.t()})
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
    {id, %{prov | groups: Map.put(prov.groups, id, group), next_group: id + 1}}
  end

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

      true ->
        prov = prov |> split_at(start) |> split_at(start + removed_bytes)
        following = run_starting_at(prov.tree, start)
        preceding = preceding_run(prov.tree, following)
        left = live_before(prov.tree, start)
        {prov, last} = delete_from(prov, group_id, following, removed, 0, nil)
        right = if removed_bytes > 0, do: run_starting_at(prov.tree, start)

        prov
        |> mark_partial_overlap(group_id, left, following, last, right)
        |> cover_replaced(group_id, last, left, following)
        |> insert_between(group_id, author, preceding, following, inserted_bytes)
        |> renumber_when_deep()
        |> remember_fresh()
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

    if batch?,
      do: edit_in_one_pass(prov, group, changes),
      else:
        changes
        |> Enum.reverse()
        |> Enum.reduce(prov, fn {start, removed, inserted}, acc ->
          edit(acc, group, start, removed, inserted)
        end)
  end

  @doc """
  Unapplies a group and returns the document without its text.

  The group's inserted text leaves the document and the text it deleted comes back, unless another applied group deleted that text too. Returns the new document, with its cursor at the start, and the lowest byte offset that changed, or `nil` when the document did not change.

  Every change is located in `document` and all of them are applied together in one pass, so only the result must be valid UTF-8: a group whose edit split a code point restores it whole. When the result would not be valid UTF-8, because other groups' edits meet this group's inside one code point, returns `{:error, :invalid_utf8}` and nothing changes.
  """
  @spec revert(t(), group_id(), Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  def revert(%__MODULE__{} = prov, id, %Document{} = document),
    do: set_applied(prov, id, false, document)

  @doc "Unapplies every group in `ids` together, in one pass over the document. See `revert/3`."
  @spec revert_all(t(), [group_id()], Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  def revert_all(%__MODULE__{} = prov, ids, %Document{} = document) when is_list(ids),
    do: set_applied_all(prov, ids, false, document)

  @doc "Applies a reverted group again and returns the document with its text. See `revert/3`."
  @spec reapply(t(), group_id(), Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  def reapply(%__MODULE__{} = prov, id, %Document{} = document),
    do: set_applied(prov, id, true, document)

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

  `blocks?` receives the deleting group's author and key. `blocker/2` counts every group that is not yours; a reject counts the groups of other tasks.
  """
  @spec blocker(t(), group_id(), (author(), group_key() -> boolean())) :: group_key() | nil
  def blocker(%__MODULE__{groups: groups, tree: tree}, id, blocks?)
      when is_function(blocks?, 2) do
    Map.fetch!(groups, id).runs
    |> :gb_sets.to_list()
    |> Enum.find_value(fn run_id ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      run |> later_deleters(id) |> Enum.find_value(&blocking_key(groups, &1, id, blocks?))
    end)
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
      |> Enum.find_value(fn id ->
        run |> later_deleters(id) |> Enum.find_value(&blocking_key(prov.groups, &1, id, blocks?))
      end)
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
  def discard(%__MODULE__{} = prov, id) do
    {group, groups} = Map.pop!(prov.groups, id)
    prov = settle_overlaps(%{prov | groups: groups}, id, group)

    group.runs
    |> :gb_sets.to_list()
    |> Enum.reduce(prov, fn run_id, prov -> settle_run(prov, run_id, %{id => group}) end)
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
    |> Enum.uniq_by(&elem(&1, 0))
  end

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

    if touched * 8 > RunTree.count(prov.tree),
      do: discard_in_one_pass(prov, ids),
      else: Enum.reduce(ids, prov, &discard(&2, &1))
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

    {remove_when_empty(prov, old, new), length(before)}
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

    %{
      run
      | group: group,
        deletions: substitute(run.deletions, old, new),
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

    %{prov | tree: RunTree.insert(tree, dead), groups: groups}
    |> index_overlaps(dead)
    |> index_overlaps(right)
    |> mark_deleted(group_id, dead, removed)
    |> insert_between(group_id, author, left, dead, inserted_bytes)
  end

  @spec grow_run_at(t(), non_neg_integer(), pos_integer()) :: t()
  defp grow_run_at(prov, start, bytes) do
    {run, _run_start} = RunTree.at_offset(prov.tree, start)
    %{prov | tree: RunTree.update(prov.tree, %{run | bytes: run.bytes + bytes})}
  end

  @spec extendable?(Run.t() | nil, group_id() | nil, author()) :: boolean()
  defp extendable?(%Run{live: true, deletions: [], group: group, author: author}, group, author),
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
        index_overlaps(%{prov | tree: tree, groups: groups}, right)

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
  # Returns the last live run it killed, as it was before.
  @spec delete_from(
          t(),
          group_id() | nil,
          Run.t() | nil,
          binary(),
          non_neg_integer(),
          Run.t() | nil
        ) ::
          {t(), Run.t() | nil}
  defp delete_from(prov, _group_id, _run, removed, consumed, last)
       when consumed == byte_size(removed),
       do: {prov, last}

  defp delete_from(prov, group_id, %Run{live: true} = run, removed, consumed, _last) do
    following = RunTree.next(prov.tree, run.id)
    text = binary_part(removed, consumed, run.bytes)

    prov
    |> mark_deleted(group_id, run, text)
    |> delete_from(group_id, following, removed, consumed + run.bytes, run)
  end

  defp delete_from(prov, group_id, %Run{} = run, removed, consumed, last) do
    following = RunTree.next(prov.tree, run.id)

    prov
    |> mark_deleted(group_id, run, run.text)
    |> delete_from(group_id, following, removed, consumed, last)
  end

  # A deletion by another author that starts or ends strictly inside a Minga replacement cannot say which part of the
  # replaced text it stands for, so a later reject of that replacement could not be exact. The replacement's tombstones
  # record the deleting group in `overlaps`; while it is applied, the replacing group's reject is refused.
  @spec mark_partial_overlap(
          t(),
          group_id() | nil,
          Run.t() | nil,
          Run.t() | nil,
          Run.t() | nil,
          Run.t() | nil
        ) :: t()
  defp mark_partial_overlap(prov, nil, _left, _first, _last, _right), do: prov
  defp mark_partial_overlap(prov, _group_id, _left, _first, nil, _right), do: prov

  defp mark_partial_overlap(prov, group_id, left, first, last, right) do
    owner =
      replacement_owner(
        prov.groups,
        group_id,
        {left, first, runs_between(prov.tree, left, first)},
        {last, right, runs_between(prov.tree, last, right)}
      )

    if owner,
      do: mark_overlap_block(prov, group_id, owner, current_or_next(prov.tree, first.id)),
      else: prov
  end

  # The run as it is now, or the one after it when the deletion dropped it.
  @spec current_or_next(RunTree.t(), Locator.t()) :: Run.t() | nil
  defp current_or_next(tree, id) do
    case RunTree.fetch(tree, id) do
      {:ok, run, _offset} -> run
      :error -> RunTree.next(tree, id)
    end
  end

  # The runs strictly between two runs, lazily, so a rule that stops at the first matching tombstone walks no further.
  @spec runs_between(RunTree.t(), Run.t() | nil, Run.t() | nil) :: Enumerable.t()
  defp runs_between(tree, %Run{} = before, %Run{id: later_id}) do
    Stream.unfold(RunTree.next(tree, before.id), fn
      %Run{id: id} = run when id < later_id -> {run, RunTree.next(tree, id)}
      _later_or_end -> nil
    end)
  end

  defp runs_between(_tree, _before, _later), do: []

  # Walks forward from the first deleted run over the deleted text, the rest of the replacement (the owner's live text
  # and the deleter's own text inside it) to the owner's tombstones, and marks that contiguous block. The walk costs the
  # deletion and the replacement.
  @spec mark_overlap_block(t(), group_id(), group_id(), Run.t() | nil) :: t()
  defp mark_overlap_block(prov, _group_id, _owner, nil), do: prov

  defp mark_overlap_block(prov, group_id, owner, run) do
    case overlap_step(prov.groups, group_id, owner, run) do
      :tombstones -> mark_overlap_tombstones(prov, group_id, owner, run)
      :pass -> mark_overlap_block(prov, group_id, owner, RunTree.next(prov.tree, run.id))
      :stop -> prov
    end
  end

  @spec mark_overlap_tombstones(t(), group_id(), group_id(), Run.t() | nil) :: t()
  defp mark_overlap_tombstones(prov, _group_id, _owner, nil), do: prov

  defp mark_overlap_tombstones(prov, group_id, owner, run) do
    following = RunTree.next(prov.tree, run.id)

    case tombstone_step(run, owner) do
      :mark ->
        prov
        |> add_overlap(group_id, owner, run)
        |> mark_overlap_tombstones(group_id, owner, following)

      :pass ->
        mark_overlap_tombstones(prov, group_id, owner, following)

      :stop ->
        prov
    end
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

  @spec add_overlap(t(), group_id(), group_id(), Run.t()) :: t()
  defp add_overlap(prov, group_id, owner, run) do
    case with_overlap(run, owner, group_id) do
      ^run ->
        prov

      marked ->
        %{
          prov
          | tree: RunTree.update(prov.tree, marked),
            overlap_runs: Map.update(prov.overlap_runs, group_id, [run.id], &[run.id | &1])
        }
    end
  end

  # A deletion that consumes another group's replacement also deletes the text that replacement replaced.
  # A replacement is one edit's inserted text followed by the tombstones it made, so the deletion consumes one when it
  # ends with that group's text and does not start inside the same replacement. It then marks that replacement's
  # tombstones, which are the dead runs right after it that the group deleted.
  @spec cover_replaced(t(), group_id() | nil, Run.t() | nil, Run.t() | nil, Run.t() | nil) :: t()
  defp cover_replaced(prov, _group_id, nil, _left, _first), do: prov
  defp cover_replaced(prov, _group_id, %Run{group: nil}, _left, _first), do: prov

  defp cover_replaced(prov, group_id, %Run{group: owner} = last, left, first) do
    if inside_replacement?(left, owner, runs_between(prov.tree, left, first)),
      do: prov,
      else: cover_tombstones(prov, group_id, owner, RunTree.next(prov.tree, last.id))
  end

  # The replacement's tombstones are contiguous, so the walk ends at the first run that is live, inserted by the same
  # group, or not deleted by it. The cost is the size of that replacement, however many tombstones lie beyond it.
  @spec cover_tombstones(t(), group_id() | nil, group_id(), Run.t() | nil) :: t()
  defp cover_tombstones(prov, _group_id, _owner, nil), do: prov

  defp cover_tombstones(prov, group_id, owner, run) do
    following = RunTree.next(prov.tree, run.id)

    case cover_step(run, owner) do
      :cover ->
        prov
        |> mark_deleted(group_id, run, run.text)
        |> cover_tombstones(group_id, owner, following)

      :pass ->
        cover_tombstones(prov, group_id, owner, following)

      :stop ->
        prov
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
    groups =
      Map.new(prov.groups, fn {id, group} ->
        locators = group.runs |> :gb_sets.to_list() |> Enum.map(&Map.fetch!(renamed, &1))
        {id, %{group | runs: :gb_sets.from_ordset(locators)}}
      end)

    index_drafts(
      %{
        prov
        | tree: tree,
          groups: groups,
          deep: false,
          recent: [],
          fresh: [],
          overlap_runs: overlap_runs
      },
      runs
    )
  end

  @spec live_before(RunTree.t(), non_neg_integer()) :: Run.t() | nil
  defp live_before(_tree, 0), do: nil

  defp live_before(tree, offset) do
    {run, _start} = RunTree.at_offset(tree, offset - 1)
    run
  end

  # An untracked deletion forgets the text.
  # A group deleting its own text leaves a run that can never be live again, so it is dropped too.
  @spec mark_deleted(t(), group_id() | nil, Run.t(), binary()) :: t()
  defp mark_deleted(prov, group_id, run, text) do
    case deleted(run, group_id, text) do
      nil -> drop_run(prov, run)
      ^run -> prov
      killed -> kill_run(prov, group_id, run, killed)
    end
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
          non_neg_integer()
        ) :: t()
  defp insert_between(prov, _group_id, _author, _preceding, _following, 0), do: prov

  defp insert_between(prov, group_id, author, preceding, following, bytes) do
    if extendable?(preceding, group_id, author) do
      %{prov | tree: RunTree.update(prov.tree, %{preceding | bytes: preceding.bytes + bytes})}
    else
      {id, prov} = allocate(prov, preceding, following)
      run = %Run{id: id, bytes: bytes, author: author, group: group_id}
      groups = if group_id, do: add_run(prov.groups, group_id, id), else: prov.groups
      %{prov | tree: RunTree.insert(prov.tree, run), groups: groups}
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
        drop_run(prov, run)

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

    runs =
      prov.tree
      |> RunTree.to_list()
      |> Enum.reduce([], fn run, acc -> settle_in_pass(run, discarded, acc) end)
      |> Enum.reverse()

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

    index_drafts(
      %{
        prov
        | tree: RunTree.from_list(runs),
          groups: groups,
          overlap_runs: Map.drop(prov.overlap_runs, ids)
      },
      runs
    )
  end

  @spec settle_in_pass(Run.t(), %{group_id() => Group.t()}, [Run.t()]) :: [Run.t()]
  defp settle_in_pass(run, discarded, acc) do
    case settle(run, discarded) do
      nil -> acc
      settled -> merge_permanent(settled, acc)
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
  defp permanent?(%Run{live: true, group: nil, deletions: []}), do: true
  defp permanent?(_run), do: false

  # ── Editing in one pass ─────────────────────────────────────────────
  #
  # The changes are applied from the last to the first, as `edit/5` would apply them, over the run list walked from the
  # end: everything left of the current change is still as it was, and everything right of it already holds the later
  # changes. `left` holds the runs before the boundary nearest first, `right` the runs after it in order, and `pos` the
  # live offset of the boundary.

  @typep pass :: %{left: [Run.t()], right: [Run.t()], pos: non_neg_integer()}

  @spec edit_in_one_pass(t(), group_id() | :untracked, [{non_neg_integer(), binary(), binary()}]) ::
          t()
  defp edit_in_one_pass(prov, group, changes) do
    {group_id, author} = writer(prov, group)

    pass = %{
      left: prov.tree |> RunTree.to_list() |> Enum.reverse(),
      right: [],
      pos: RunTree.size(prov.tree)
    }

    %{left: left, right: right} =
      changes
      |> Enum.reverse()
      |> Enum.reduce(pass, &apply_in_pass(prov.groups, group_id, author, &1, &2))

    rebuild(prov, Enum.reverse(left, right))
  end

  @spec apply_in_pass(
          %{group_id() => Group.t()},
          group_id() | nil,
          author(),
          {non_neg_integer(), binary(), binary()},
          pass()
        ) :: pass()
  defp apply_in_pass(groups, group_id, author, {start, removed, inserted}, pass) do
    pass = move_right_of(pass, start + byte_size(removed), removed != "")
    {segment, pass} = take_from(pass, start, [])

    right =
      case segment do
        [] -> pass.right
        [_ | _] -> delete_in_pass(segment, groups, group_id, removed, pass)
      end

    inserted_runs =
      if inserted == "",
        do: [],
        else: [%Run{id: [0], bytes: byte_size(inserted), author: author, group: group_id}]

    %{pass | right: inserted_runs ++ right}
  end

  # Deletes the segment, then marks a partly deleted replacement and covers a consumed one, in `edit/5`'s order.
  @spec delete_in_pass(
          [Run.t(), ...],
          %{group_id() => Group.t()},
          group_id() | nil,
          binary(),
          pass()
        ) :: [Run.t()]
  defp delete_in_pass(segment, groups, group_id, removed, pass) do
    {left_gap, left} = Enum.split_while(pass.left, &(not &1.live))
    left = List.first(left)
    left_between = Enum.reverse(left_gap)
    [first | _] = segment
    last = segment |> Enum.reverse() |> Enum.find(& &1.live)
    deleted = delete_segment(segment, group_id, removed)

    owner =
      (group_id &&
         replacement_owner(groups, group_id, {left, first, left_between}, {last, nil, []})) ||
        (group_id && end_owner(groups, group_id, last, pass.right))

    tail = mark_in_pass(deleted ++ pass.right, groups, group_id, owner)
    {deleted, after_segment} = Enum.split(tail, length(deleted))
    deleted ++ cover_in_pass(after_segment, group_id, last, left, left_between)
  end

  # The owner when the deletion ends strictly inside a replacement; the live run after it is found only when needed.
  @spec end_owner(%{group_id() => Group.t()}, group_id(), Run.t(), [Run.t()]) :: group_id() | nil
  defp end_owner(_groups, _group_id, %Run{group: nil}, _right), do: nil

  defp end_owner(groups, group_id, last, right) do
    {right_gap, after_gap} = Enum.split_while(right, &(not &1.live))
    replacement_owner(groups, group_id, {nil, nil, []}, {last, List.first(after_gap), right_gap})
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

  @spec delete_segment([Run.t()], group_id() | nil, binary()) :: [Run.t()]
  defp delete_segment(segment, group_id, removed) do
    {runs, _consumed} =
      Enum.flat_map_reduce(segment, 0, fn
        %Run{live: true} = run, consumed ->
          {List.wrap(deleted(run, group_id, binary_part(removed, consumed, run.bytes))),
           consumed + run.bytes}

        run, consumed ->
          {List.wrap(deleted(run, group_id, run.text)), consumed}
      end)

    runs
  end

  @spec mark_in_pass([Run.t()], %{group_id() => Group.t()}, group_id() | nil, group_id() | nil) ::
          [Run.t()]
  defp mark_in_pass(runs, _groups, _group_id, nil), do: runs

  defp mark_in_pass([run | rest] = runs, groups, group_id, owner) do
    case overlap_step(groups, group_id, owner, run) do
      :tombstones -> mark_tombstones_in_pass(runs, group_id, owner)
      :pass -> [run | mark_in_pass(rest, groups, group_id, owner)]
      :stop -> runs
    end
  end

  defp mark_in_pass([], _groups, _group_id, _owner), do: []

  @spec mark_tombstones_in_pass([Run.t()], group_id(), group_id()) :: [Run.t()]
  defp mark_tombstones_in_pass([run | rest] = runs, group_id, owner) do
    case tombstone_step(run, owner) do
      :mark ->
        [with_overlap(run, owner, group_id) | mark_tombstones_in_pass(rest, group_id, owner)]

      :pass ->
        [run | mark_tombstones_in_pass(rest, group_id, owner)]

      :stop ->
        runs
    end
  end

  defp mark_tombstones_in_pass([], _group_id, _owner), do: []

  @spec cover_in_pass([Run.t()], group_id() | nil, Run.t() | nil, Run.t() | nil, [Run.t()]) :: [
          Run.t()
        ]
  defp cover_in_pass(runs, _group_id, nil, _left, _left_gap), do: runs
  defp cover_in_pass(runs, _group_id, %Run{group: nil}, _left, _left_gap), do: runs

  defp cover_in_pass(runs, group_id, %Run{group: owner}, left, left_gap) do
    if inside_replacement?(left, owner, left_gap),
      do: runs,
      else: cover_list(runs, group_id, owner)
  end

  @spec cover_list([Run.t()], group_id() | nil, group_id()) :: [Run.t()]
  defp cover_list([run | rest] = runs, group_id, owner) do
    case cover_step(run, owner) do
      :cover -> List.wrap(deleted(run, group_id, run.text)) ++ cover_list(rest, group_id, owner)
      :pass -> [run | cover_list(rest, group_id, owner)]
      :stop -> runs
    end
  end

  defp cover_list([], _group_id, _owner), do: []

  # Gives every run an evenly spaced locator and rebuilds the tree, the groups' run sets, and both indexes from the
  # runs, in O(n).
  @spec rebuild(t(), [Run.t()]) :: t()
  defp rebuild(prov, runs) do
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
          overlap_runs: overlap_runs,
          deep: false,
          recent: [],
          fresh: []
      },
      runs
    )
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

  defp foreign?(groups, %Run{group: group}, group_id) do
    author = Map.fetch!(groups, group).author
    match?({:minga, _task}, author) and author != Map.fetch!(groups, group_id).author
  end

  # The Minga group whose replacement a deletion by `group_id` starts or ends strictly inside, or `nil`.
  # Each pair is two live runs with the runs between them.
  # The first pair is the live run before the deletion and its first run; the second, its last live run and the live
  # run after it.
  # They belong to one replacement when both are the same foreign group's text and no tombstone of that group lies
  # between them.
  @spec replacement_owner(
          %{group_id() => Group.t()},
          group_id() | nil,
          {Run.t() | nil, Run.t() | nil, Enumerable.t()},
          {Run.t() | nil, Run.t() | nil, Enumerable.t()}
        ) :: group_id() | nil
  defp replacement_owner(groups, group_id, start_pair, end_pair) do
    Enum.find_value([start_pair, end_pair], fn
      {%Run{group: owner} = before, %Run{group: owner}, between} when owner != nil ->
        if foreign?(groups, before, group_id) and not Enum.any?(between, &separates?(&1, owner)),
          do: owner

      _pair ->
        nil
    end)
  end

  # A deletion starts inside a replacement when the live text before it belongs to the same group and no tombstone of
  # that group separates them; such a tombstone ends one replacement before the next begins.
  @spec inside_replacement?(Run.t() | nil, group_id(), Enumerable.t()) :: boolean()
  defp inside_replacement?(%Run{group: owner}, owner, between),
    do: not Enum.any?(between, &separates?(&1, owner))

  defp inside_replacement?(_left, _owner, _between), do: false

  # A tombstone of `owner`'s that ends one of its replacements before the next begins.
  @spec separates?(Run.t(), group_id()) :: boolean()
  defp separates?(run, owner), do: owner in run.deletions and not inert?(run)

  # A run a step both wrote and deleted, which compaction keeps only for another group's blocker. Every walk passes over
  # it as if it were gone, as such text otherwise is.
  @spec inert?(Run.t()) :: boolean()
  defp inert?(%Run{group: nil}), do: false
  defp inert?(%Run{group: group, deletions: deletions}), do: group in deletions

  # One step of the cover walk after a deletion that consumes `owner`'s replacement: the replacement's tombstones are
  # deleted too (`:cover`), and they are contiguous, so the walk stops at the first run that is not one.
  @spec cover_step(Run.t(), group_id()) :: :cover | :pass | :stop
  defp cover_step(run, owner) do
    cond do
      inert?(run) -> :pass
      run.group == owner -> :stop
      not run.live and owner in run.deletions -> :cover
      true -> :stop
    end
  end

  # One step of the overlap walk from the first deleted run: the owner's tombstones start the marked block, tombstones
  # of others and the owner's or the deleter's own live text are passed, and anything else ends the walk unmarked.
  @spec overlap_step(%{group_id() => Group.t()}, group_id(), group_id(), Run.t()) ::
          :tombstones | :pass | :stop
  defp overlap_step(_groups, _group_id, owner, %Run{live: false} = run),
    do: if(separates?(run, owner), do: :tombstones, else: :pass)

  defp overlap_step(_groups, _group_id, owner, %Run{group: owner}), do: :pass
  defp overlap_step(_groups, _group_id, _owner, %Run{group: nil}), do: :stop

  defp overlap_step(groups, group_id, _owner, %Run{group: group}) do
    if Map.fetch!(groups, group).author == Map.fetch!(groups, group_id).author,
      do: :pass,
      else: :stop
  end

  # One step through the owner's tombstones once the walk reached them: each is marked, inert runs are passed, and the
  # first run that is not one of them ends the block.
  @spec tombstone_step(Run.t(), group_id()) :: :mark | :pass | :stop
  defp tombstone_step(run, owner) do
    cond do
      inert?(run) -> :pass
      not run.live and owner in run.deletions and run.group != owner -> :mark
      true -> :stop
    end
  end

  @spec with_overlap(Run.t(), group_id(), group_id()) :: Run.t()
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
        overlaps: overlaps
    }
  end

  # ── Bookkeeping ─────────────────────────────────────────────────────

  @spec put_run(t(), Run.t(), Run.t()) :: t()
  defp put_run(prov, old, run),
    do: refresh_draft(%{prov | tree: RunTree.update(prov.tree, run)}, old, run)

  @spec drop_run(t(), Run.t()) :: t()
  defp drop_run(prov, run) do
    groups = Enum.reduce(run_groups(run), prov.groups, &remove_run(&2, &1, run.id))

    %{
      prov
      | tree: RunTree.delete(prov.tree, run.id),
        groups: groups,
        drafts: :gb_sets.delete_any({run.group, run.id}, prov.drafts)
    }
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
        |> Enum.filter(&(&1 > owner and newer_step?(Map.fetch!(groups, &1), author)))
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

    case {Enum.find_index(order, &(&1 == old)), Enum.find_index(order, &(&1 == new))} do
      {nil, _new} -> true
      {_old, nil} -> true
      {old_at, new_at} -> abs(old_at - new_at) == 1
    end
  end

  @spec newer_step?(Group.t(), author()) :: boolean()
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
