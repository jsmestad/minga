defmodule Minga.Buffer.Provenance do
  @moduledoc """
  Who wrote each byte of a buffer, and the history that can take each author's work back out.

  The document is a sequence of authorship runs (`Minga.Buffer.Provenance.Run`) held in a balanced sum tree in document order. Each run names its author and the history group that inserted it, and lists the groups that deleted it. A run is live, and its text is in the document, when the group that inserted it is applied and no group that deleted it is applied. Deleted text stays in the tree as a tombstone that keeps its text, so it can be restored exactly where it was.

  A history group (`Minga.Buffer.Provenance.Group`) is one of your undo steps or one Minga step. Undoing, redoing, or rejecting a group flips whether it is applied (`revert/3`, `reapply/3`); every run it touched then turns live or dead on its own, and the document changes by exactly the text of that group. Because a group finds its runs by locator, not by byte offset, edits made by anyone else after it, above or inside it, never make it point at the wrong text.

  ## Edit order

  An insertion at byte `p` goes immediately before the live byte that was at `p`, so it lands after any tombstones that sit at `p`. A deletion kills the live runs in its range and also marks every tombstone strictly inside the range, so restoring that older text later cannot reappear in the middle of text a later edit removed.

  ## Replacements

  An edit that inserts text over a non-empty range is a replacement, recorded by identity as a `Minga.Buffer.Provenance.Change`. It made the runs it inserted. It replaced the live runs in its range and the tombstones strictly inside it that can still come back; text already gone for good (deleted by its own writer, by an untracked change or by a kept group, or written by a group discarded unapplied) is dropped from the tree and replaced by no one.

  Compaction can discard the text of a superseded draft while keeping its replacement reachable. It leaves a zero-byte anchor at the draft's locator when later replacements can still need its coverage. A replacement that strictly spans that anchor records it like a tombstone but the anchor never contributes text, authorship, or a deletion dependency. Adjacent anchors with the same coverage and lifetime share a record.

  A deletion consumes a replacement when none of its made runs stays live. It then deletes the dead runs the replacement replaced too, and examines each replacement that made those runs, or that the replacement pulls, each once. A replacement that keeps live text is only partly consumed: when it is another author's Minga step, its runs get an overlap mark, and rejecting that step is refused while the deleting group is applied. A cover only adds a deleter to dead runs, so it never changes the document. A change carries its replacement only while its group is applied: a reached change whose group is undone, or was discarded unapplied (it never happened), neither covers nor marks.

  ## Record lifecycle

  A record is in one of three states.

  1. **With runs or anchors.** Created by an edit that inserted text over a non-empty range, unless it could never cover, pull or mark (it replaced nothing, pulls nothing, and is not a Minga step's). `made` lists its runs and compacted anchors; a split adds the new piece. Its group is the writer of its first made entry (`owner: :runs`). It retires to nothing when it has nothing replaced, pulls nothing, and its entries belong to no Minga step: the entries forget it.
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

  alias Minga.Buffer.Cursor
  alias Minga.Buffer.Document
  alias Minga.Buffer.Position
  alias Minga.Buffer.Provenance.Change
  alias Minga.Buffer.Provenance.DraftLinks
  alias Minga.Buffer.Provenance.Group
  alias Minga.Buffer.Provenance.Locator
  alias Minga.Buffer.Provenance.RewriteScan
  alias Minga.Buffer.Provenance.Run
  alias Minga.Buffer.Provenance.RunTree
  alias Minga.Core.Unicode

  alias Minga.Buffer.Author
  require Author

  import Bitwise, only: [band: 2, bor: 2, bsl: 2]

  @origin_counter_mask bsl(1, 64) - 1

  # Only authored splices carry the buffer incarnation. Ordinary undo changes keep small local IDs.
  defstruct tree: nil,
            groups: %{},
            user_groups: nil,
            next_group: 1,
            deep: false,
            recent: [],
            fresh: [],
            overlap_runs: %{},
            drafts: nil,
            review_sites: nil,
            strand_sites: nil,
            witnessed_drafts: nil,
            settling_drafts: nil,
            next_change: 1,
            origin_scope: 0,
            changes: %{},
            stale: [],
            faults: %{},
            group_marks: %{},
            owned: %{},
            trace: nil

  @opaque t :: %__MODULE__{
            tree: RunTree.t(),
            groups: %{Run.group_id() => Group.t()},
            user_groups: :gb_sets.set(group_id()),
            next_group: pos_integer(),
            deep: boolean(),
            recent: [Locator.t()],
            fresh: [Locator.t()],
            overlap_runs: %{group_id() => [Locator.t()]},
            drafts: :gb_sets.set({group_id(), Locator.t()}),
            review_sites: :gb_sets.set(Locator.t()),
            strand_sites: :gb_sets.set(Locator.t()),
            witnessed_drafts: DraftLinks.t(),
            settling_drafts: MapSet.t(Locator.t()) | nil,
            next_change: pos_integer(),
            origin_scope: non_neg_integer(),
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

  @typedoc "An applied Minga group and a contributing live run or direct deletion gap."
  @type review_site :: {group_id(), non_neg_integer(), non_neg_integer()}

  @typedoc "A non-actionable visible strand and its source byte extent."
  @type strand_span :: {:kept | :you | :shared, non_neg_integer(), non_neg_integer()}

  @typedoc "The written extent or actual preimage of a direct Minga edit, positioned in the exact Keep projection."
  @type keep_source ::
          {:written, Run.origin(), non_neg_integer(), pos_integer()}
          | {:removed, Run.origin(), non_neg_integer(), binary()}

  @type keep_interval ::
          {:insert | :replace | :delete, pos_integer(), non_neg_integer(), pos_integer()}

  @type source_key :: {:insert | :replace | :delete, pos_integer()}
  @type kept_placement ::
          {:visible, Run.origin(), non_neg_integer(), pos_integer()}
          | {:gap, Run.origin(), non_neg_integer()}
          | {:held, Run.origin()}
  @type kept_placements :: %{source_key() => [kept_placement()]}

  @typep kept_gaps :: %{optional(Locator.t()) => Run.origin() | nil}
  @typep change :: {non_neg_integer(), non_neg_integer(), binary()}
  @typep saved_run ::
           {non_neg_integer(), author(), group_id() | nil, [group_id()], [Run.overlap()],
            binary() | nil, Change.id() | nil, [Change.id()], [group_id()], [group_id()],
            [group_id()], boolean(), Run.origin() | nil, [{group_id(), Run.origin()}],
            Run.attribution() | nil}
  @typep saved_groups :: %{group_id() => {author(), group_key(), boolean()}}
  @typep saved_changes :: %{Change.id() => {Change.owner(), [Change.id()]}}
  @opaque snapshot ::
            {:provenance_v5, pos_integer(), pos_integer(), saved_groups(), [saved_run()],
             saved_changes(), [[group_id()]], map(), boolean()}

  @doc "Returns provenance for a document of `size` bytes that all predates tracking."
  @spec new(non_neg_integer(), non_neg_integer()) :: t()
  def new(size, origin_scope \\ 0) when is_integer(size) and size >= 0 do
    tree =
      if size == 0,
        do: RunTree.new(),
        else:
          RunTree.insert(RunTree.new(), %Run{
            id: Locator.between(nil, nil),
            bytes: size,
            author: :unattributed
          })

    %__MODULE__{
      tree: tree,
      origin_scope: origin_scope,
      user_groups: :gb_sets.new(),
      drafts: :gb_sets.new(),
      review_sites: :gb_sets.new(),
      strand_sites: :gb_sets.new(),
      witnessed_drafts: DraftLinks.new()
    }
  end

  @doc "Carries the live allocation scope and high-water mark into restored or reset history."
  @spec inherit_origin_scope(t(), t()) :: t()
  def inherit_origin_scope(%__MODULE__{} = next, %__MODULE__{} = live) do
    %{
      next
      | origin_scope: live.origin_scope,
        next_change: max(next.next_change, live.next_change)
    }
  end

  @spec source_id(non_neg_integer(), pos_integer()) :: pos_integer()
  defp source_id(scope, counter), do: bor(bsl(scope, 64), counter)

  @spec valid_source_id?(term(), pos_integer()) :: boolean()
  defp valid_source_id?(id, next) when is_integer(id) and id > 0,
    do: valid_id?(band(id, @origin_counter_mask), next)

  defp valid_source_id?(_id, _next), do: false

  @doc "Returns the document size in bytes that this provenance describes."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{tree: tree}), do: RunTree.size(tree)

  @doc "Returns the number of live or parked groups in the provenance."
  @spec group_count(t()) :: non_neg_integer()
  def group_count(%__MODULE__{groups: groups}), do: map_size(groups)

  @doc "Returns the first group identifier not yet allocated."
  @spec group_ceiling(t()) :: pos_integer()
  def group_ceiling(%__MODULE__{next_group: id}), do: id

  @doc "Captures ordered runs and irreducible history links, not the tree or search indexes."
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{} = prov) do
    groups =
      Map.new(prov.groups, fn {id, group} -> {id, {group.author, group.key, group.applied}} end)

    changes =
      Map.new(prov.changes, fn {id, record} ->
        {id, {record.owner, :gb_sets.to_list(record.pulls)}}
      end)

    runs = Enum.map(RunTree.to_list(prov.tree), &save_run/1)

    {:provenance_v5, prov.next_group, prov.next_change, groups, runs, changes,
     DraftLinks.snapshot(prov.witnessed_drafts), prov.group_marks, faulted?(prov)}
  end

  @doc "Validates references and live bytes before rebuilding the provenance indexes."
  @spec restore_snapshot(term(), non_neg_integer()) :: {:ok, t()} | {:error, :invalid_provenance}
  def restore_snapshot(
        {version, next_group, next_change, groups, runs, changes, drafts, marks, faulted},
        size
      )
      when version in [
             :provenance_v1,
             :provenance_v2,
             :provenance_v3,
             :provenance_v4,
             :provenance_v5
           ] do
    format =
      if version in [:provenance_v4, :provenance_v5], do: {version, next_change}, else: version

    with :ok <-
           validate_saved_shape(
             next_group,
             next_change,
             {groups, runs, changes, drafts, marks, faulted}
           ),
         :ok <- validate_saved_groups(groups, next_group),
         :ok <- validate_saved_changes(changes, groups, next_change),
         :ok <- validate_saved_links(groups, drafts, marks),
         {:ok, runs} <- restore_runs(runs, groups, changes, size, [], format) do
      prov = %__MODULE__{
        groups: Map.new(groups, &restore_group/1),
        changes:
          Map.new(changes, fn {id, {owner, _pulls}} -> {id, %{Change.new() | owner: owner}} end),
        user_groups: :gb_sets.from_list(for {id, {:you, _key, _applied}} <- groups, do: id),
        witnessed_drafts: DraftLinks.restore(drafts),
        group_marks: marks,
        faults: if(faulted, do: %{all: true}, else: %{}),
        next_group: next_group,
        next_change: next_change
      }

      prov = Enum.reduce(changes, prov, &restore_change_links/2)
      {:ok, rebuild(prov, runs, [])}
    end
  end

  def restore_snapshot(_snapshot, _size), do: {:error, :invalid_provenance}

  @spec validate_saved_shape(term(), term(), tuple()) :: :ok | {:error, :invalid_provenance}
  defp validate_saved_shape(
         next_group,
         next_change,
         {groups, runs, changes, drafts, marks, faulted}
       )
       when is_integer(next_group) and next_group > 0 and is_integer(next_change) and
              next_change > 0 and
              is_map(groups) and is_list(runs) and is_map(changes) and is_list(drafts) and
              is_map(marks) and is_boolean(faulted),
       do: :ok

  defp validate_saved_shape(_group, _change, _shape), do: {:error, :invalid_provenance}

  @spec restore_change_links({Change.id(), {Change.owner(), [Change.id()]}}, t()) :: t()
  defp restore_change_links({id, {owner, pulls}}, prov) do
    prov =
      if is_integer(owner), do: own(prov, id, Map.fetch!(prov.changes, id), owner), else: prov

    Enum.reduce(pulls, prov, &pull(&2, id, &1))
  end

  @spec validate_saved_groups(saved_groups(), pos_integer()) ::
          :ok | {:error, :invalid_provenance}
  defp validate_saved_groups(groups, next) do
    valid_snapshot(
      Enum.all?(groups, fn
        {id, {author, key, applied}} ->
          valid_id?(id, next) and is_boolean(applied) and valid_group_key?(author, key)

        _invalid ->
          false
      end)
    )
  end

  @spec validate_saved_changes(saved_changes(), saved_groups(), pos_integer()) ::
          :ok | {:error, :invalid_provenance}
  defp validate_saved_changes(changes, groups, next) do
    valid_snapshot(
      Enum.all?(changes, fn
        {id, {owner, pulls}} when is_list(pulls) ->
          valid_id?(id, next) and (owner in [:runs, :permanent] or is_map_key(groups, owner)) and
            Enum.all?(pulls, &(&1 != id and is_map_key(changes, &1)))

        _invalid ->
          false
      end)
    )
  end

  @spec validate_saved_links(saved_groups(), [[group_id()]], map()) ::
          :ok | {:error, :invalid_provenance}
  defp validate_saved_links(groups, drafts, marks) do
    valid_snapshot(
      valid_drafts?(groups, drafts) and
        Enum.all?(marks, fn {owner, links} ->
          is_map_key(groups, owner) and is_list(links) and
            Enum.all?(links, &valid_overlap_target?(groups, &1))
        end)
    )
  end

  @spec valid_drafts?(saved_groups(), [[group_id()]]) :: boolean()
  defp valid_drafts?(groups, drafts) do
    Enum.reduce_while(drafts, MapSet.new(), fn
      [_, _ | _] = ids, seen ->
        members = MapSet.new(ids)

        if MapSet.size(members) == length(ids) and MapSet.disjoint?(members, seen) and
             Enum.all?(members, &is_map_key(groups, &1)),
           do: {:cont, MapSet.union(members, seen)},
           else: {:halt, :invalid}

      _invalid, _seen ->
        {:halt, :invalid}
    end) != :invalid
  end

  @spec valid_snapshot(boolean()) :: :ok | {:error, :invalid_provenance}
  defp valid_snapshot(true), do: :ok
  defp valid_snapshot(false), do: {:error, :invalid_provenance}

  @spec valid_id?(term(), pos_integer()) :: boolean()
  defp valid_id?(id, next), do: is_integer(id) and id > 0 and id < next

  @spec valid_group_key?(term(), term()) :: boolean()
  defp valid_group_key?(:you, nil), do: true
  defp valid_group_key?({:minga, :untasked}, {:untasked, id}), do: is_integer(id) and id > 0
  defp valid_group_key?(author, key) when Author.is_key(key), do: Author.author(key) == author
  defp valid_group_key?(_author, _key), do: false

  @spec valid_overlap_target?(saved_groups(), term()) :: boolean()
  defp valid_overlap_target?(_groups, {:permanent, key}) when key in [nil, :you], do: true

  defp valid_overlap_target?(_groups, {:permanent, key}) when Author.is_key(key), do: true

  defp valid_overlap_target?(_groups, {:permanent, {:untasked, id}}),
    do: is_integer(id) and id > 0

  defp valid_overlap_target?(groups, id), do: is_map_key(groups, id)

  @spec restore_group({group_id(), {author(), group_key(), boolean()}}) :: {group_id(), Group.t()}
  defp restore_group({id, {author, key, applied}}),
    do: {id, %Group{author: author, key: key, applied: applied, runs: :gb_sets.new()}}

  @spec save_run(Run.t()) :: saved_run()
  defp save_run(run),
    do:
      {run.bytes, run.author, run.group, run.deletions, run.overlaps, run.text, run.made_by,
       run.replaced_by, run.covered_by, run.swept_by, run.direct_gaps, run.kept?, run.origin,
       run.gap_origins, run.attribution}

  @typep snapshot_format ::
           :provenance_v1
           | :provenance_v2
           | :provenance_v3
           | {:provenance_v4 | :provenance_v5, pos_integer()}

  @spec restore_runs(
          list(),
          saved_groups(),
          saved_changes(),
          integer(),
          [Run.t()],
          snapshot_format()
        ) ::
          {:ok, [Run.t()]} | {:error, :invalid_provenance}
  defp restore_runs([], _groups, _changes, 0, acc, _version), do: {:ok, Enum.reverse(acc)}

  defp restore_runs([run | rest], groups, changes, remaining, acc, :provenance_v1)
       when tuple_size(run) == 10 do
    upgraded =
      run
      |> Tuple.insert_at(10, legacy_direct_gaps(run))
      |> Tuple.insert_at(11, false)
      |> Tuple.insert_at(12, nil)
      |> Tuple.insert_at(13, [])
      |> Tuple.insert_at(14, nil)

    restore_run(upgraded, rest, groups, changes, remaining, acc, :provenance_v1)
  end

  defp restore_runs([run | rest], groups, changes, remaining, acc, :provenance_v2)
       when tuple_size(run) == 11 do
    upgraded =
      run
      |> Tuple.insert_at(11, false)
      |> Tuple.insert_at(12, nil)
      |> Tuple.insert_at(13, [])
      |> Tuple.insert_at(14, nil)

    restore_run(upgraded, rest, groups, changes, remaining, acc, :provenance_v2)
  end

  defp restore_runs([run | rest], groups, changes, remaining, acc, :provenance_v3)
       when tuple_size(run) == 12 do
    upgraded =
      run |> Tuple.insert_at(12, nil) |> Tuple.insert_at(13, []) |> Tuple.insert_at(14, nil)

    restore_run(upgraded, rest, groups, changes, remaining, acc, :provenance_v3)
  end

  defp restore_runs([run | rest], groups, changes, remaining, acc, {:provenance_v4, _} = format)
       when tuple_size(run) == 14,
       do:
         restore_run(Tuple.insert_at(run, 14, nil), rest, groups, changes, remaining, acc, format)

  defp restore_runs([run | rest], groups, changes, remaining, acc, {:provenance_v5, _} = format),
    do: restore_run(run, rest, groups, changes, remaining, acc, format)

  defp restore_runs(_runs, _groups, _changes, _remaining, _acc, _version),
    do: {:error, :invalid_provenance}

  # A v1 checkpoint did not distinguish a paired replacement from a later sweep by the same group.
  # Recover only unambiguous gaps. All the old groups still participate in exact review.
  @spec legacy_direct_gaps(tuple()) :: [group_id()]
  defp legacy_direct_gaps({bytes, _, _, deletions, _, _, _, [], covered, swept})
       when is_integer(bytes) and bytes > 0 and is_list(deletions) and is_list(covered) and
              is_list(swept) do
    Enum.reject(deletions, &(&1 in covered or &1 in swept))
  end

  defp legacy_direct_gaps(_run), do: []

  @spec restore_run(
          term(),
          list(),
          saved_groups(),
          saved_changes(),
          integer(),
          [Run.t()],
          snapshot_format()
        ) ::
          {:ok, [Run.t()]} | {:error, :invalid_provenance}
  defp restore_run(
         {bytes, author, writer, deletions, overlaps, _, _, replaced, covered, swept, gaps, kept?,
          _, gap_origins, _attribution} = run,
         rest,
         groups,
         changes,
         remaining,
         acc,
         version
       )
       when is_integer(bytes) and bytes >= 0 and is_list(deletions) and is_list(overlaps) and
              is_list(replaced) and is_list(covered) and is_list(swept) and is_list(gaps) and
              is_boolean(kept?) and is_list(gap_origins) do
    with {:ok, written?} <- validate_writer(groups, writer, author),
         :ok <- validate_run_references(run, groups, changes),
         {:ok, restored, used} <- decode_saved_run(run, groups, written?, remaining, version) do
      restore_runs(rest, groups, changes, remaining - used, [restored | acc], version)
    end
  end

  defp restore_run(_run, _rest, _groups, _changes, _remaining, _acc, _version),
    do: {:error, :invalid_provenance}

  @spec decode_saved_run(saved_run(), saved_groups(), boolean(), integer(), snapshot_format()) ::
          {:ok, Run.t(), non_neg_integer()} | {:error, :invalid_provenance}
  defp decode_saved_run(run, groups, written?, remaining, version) do
    {bytes, author, writer, deletions, overlaps, text, made, replaced, covered, swept, gaps,
     kept?, origin, gap_origins, attribution} = run

    live = bytes > 0 and written? and not Enum.any?(deletions, &elem(Map.fetch!(groups, &1), 2))
    used = if live, do: bytes, else: 0

    if used <= remaining and valid_run_text?(live, bytes, text) and valid_kept_run?(run) and
         valid_origin?(origin, writer, author, bytes, kept?, version) and
         valid_gap_origins?(gap_origins, gaps, deletions, bytes, version) and
         valid_attribution?(attribution, author, bytes) do
      restored = %Run{
        id: Locator.between(nil, nil),
        bytes: bytes,
        author: author,
        group: writer,
        deletions: deletions,
        overlaps: overlaps,
        text: text,
        live: live,
        made_by: made,
        replaced_by: replaced,
        covered_by: covered,
        swept_by: swept,
        direct_gaps: gaps,
        kept?: kept?,
        origin: origin,
        gap_origins: gap_origins,
        attribution: attribution
      }

      {:ok, restored, used}
    else
      {:error, :invalid_provenance}
    end
  end

  @spec valid_attribution?(term(), author(), non_neg_integer()) :: boolean()
  defp valid_attribution?(nil, _author, _bytes), do: true

  defp valid_attribution?({nil, at}, {:minga, _review_owner}, bytes),
    do: bytes > 0 and is_integer(at)

  defp valid_attribution?({{:minga, task, step}, at}, {:minga, _review_owner}, bytes),
    do: bytes > 0 and is_binary(task) and is_binary(step) and is_integer(at)

  defp valid_attribution?(_fact, _author, _bytes), do: false

  @spec valid_kept_run?(saved_run()) :: boolean()
  defp valid_kept_run?({_, _, _, _, _, _, _, _, _, _, _, false, _, _, _}), do: true

  defp valid_kept_run?({0, :unattributed, nil, [], [], _, nil, [], [], [], [], true, _, [], nil}),
    do: true

  defp valid_kept_run?({bytes, author, nil, _, _, _, _, _, _, _, _, true, _, _, _})
       when bytes > 0,
       do: minga?(author)

  defp valid_kept_run?(_run), do: false

  @spec valid_origin?(
          term(),
          group_id() | nil,
          author(),
          non_neg_integer(),
          boolean(),
          snapshot_format()
        ) ::
          boolean()
  defp valid_origin?(nil, _writer, _author, _bytes, _kept, _format), do: true

  defp valid_origin?(
         {kind, id, offset, total},
         writer,
         author,
         bytes,
         kept,
         {version, next}
       )
       when version in [:provenance_v4, :provenance_v5] and kind in [:insert, :replace] and
              bytes > 0 and (not is_nil(writer) or kept),
       do: valid_source_id?(id, next) and minga?(author) and valid_extent?(offset, bytes, total)

  defp valid_origin?(
         {:delete, id, offset, total},
         nil,
         :unattributed,
         0,
         true,
         {version, next}
       )
       when version in [:provenance_v4, :provenance_v5],
       do: valid_source_id?(id, next) and valid_extent?(offset, 1, total)

  defp valid_origin?(_origin, _writer, _author, _bytes, _kept, _format), do: false

  @spec valid_extent?(term(), pos_integer(), term()) :: boolean()
  defp valid_extent?(offset, bytes, total),
    do: is_integer(offset) and offset >= 0 and is_integer(total) and offset + bytes <= total

  @spec valid_gap_origins?(
          list(),
          [group_id()],
          [group_id()],
          non_neg_integer(),
          snapshot_format()
        ) ::
          boolean()
  defp valid_gap_origins?([], _gaps, _deletions, _bytes, _format), do: true

  defp valid_gap_origins?(origins, gaps, deletions, bytes, {version, next})
       when version in [:provenance_v4, :provenance_v5] and bytes > 0 do
    Enum.all?(origins, fn
      {group, {:delete, id, offset, total}} ->
        group in gaps and valid_source_id?(id, next) and valid_extent?(offset, bytes, total)

      {group, {:replace, id, offset, total}} ->
        group in deletions and valid_source_id?(id, next) and valid_extent?(offset, bytes, total)

      _invalid ->
        false
    end) and length(origins) == length(Enum.uniq_by(origins, &elem(&1, 0)))
  end

  defp valid_gap_origins?(_origins, _gaps, _deletions, _bytes, _format), do: false

  @spec validate_run_references(saved_run(), saved_groups(), saved_changes()) ::
          :ok | {:error, :invalid_provenance}
  defp validate_run_references(
         {bytes, _author, _writer, deletions, overlaps, _text, made, replaced, covered, swept,
          gaps, _kept?, _origin, _gap_origins, _attribution},
         groups,
         changes
       ) do
    valid_snapshot(
      Enum.all?(deletions, &is_map_key(groups, &1)) and
        Enum.all?(covered, &(&1 in deletions)) and Enum.all?(swept, &(&1 in deletions)) and
        valid_gap_references?(bytes, made, gaps, deletions, covered, swept) and
        Enum.all?(overlaps, &valid_run_overlap?(groups, &1)) and
        (is_nil(made) or is_map_key(changes, made)) and
        Enum.all?(replaced, &is_map_key(changes, &1))
    )
  end

  @spec valid_gap_references?(
          non_neg_integer(),
          Change.id() | nil,
          [group_id()],
          [group_id()],
          [group_id()],
          [group_id()]
        ) :: boolean()
  defp valid_gap_references?(_bytes, _made, [], _deletions, _covered, _swept), do: true

  defp valid_gap_references?(bytes, made, gaps, deletions, covered, swept) do
    (bytes > 0 or not is_nil(made)) and gaps == Enum.uniq(gaps) and
      Enum.all?(gaps, &(&1 in deletions and &1 not in covered and &1 not in swept))
  end

  @spec valid_run_overlap?(saved_groups(), term()) :: boolean()
  defp valid_run_overlap?(groups, {owner, target}),
    do: is_map_key(groups, owner) and valid_overlap_target?(groups, target)

  defp valid_run_overlap?(_groups, _invalid), do: false

  @spec validate_writer(saved_groups(), group_id() | nil, author()) ::
          {:ok, boolean()} | {:error, :invalid_provenance}
  defp validate_writer(_groups, nil, author)
       when author in [:unattributed, :you, {:minga, :untasked}],
       do: {:ok, true}

  defp validate_writer(_groups, nil, {:minga, id}) when is_binary(id), do: {:ok, true}

  defp validate_writer(groups, writer, author) do
    case groups do
      %{^writer => {^author, _key, applied}} -> {:ok, applied}
      _invalid -> {:error, :invalid_provenance}
    end
  end

  @spec valid_run_text?(boolean(), non_neg_integer(), binary() | nil) :: boolean()
  defp valid_run_text?(true, _bytes, text), do: is_nil(text)
  defp valid_run_text?(false, 0, text), do: text in [nil, ""]
  defp valid_run_text?(false, bytes, text), do: is_binary(text) and byte_size(text) == bytes

  @doc "Opens a new applied group for edits by `author`, named `key` to callers, and returns its id."
  @spec open_group(t(), author(), group_key()) :: {group_id(), t()}
  def open_group(%__MODULE__{} = prov, author, key) do
    id = prov.next_group
    group = %Group{author: author, key: key, runs: :gb_sets.new()}

    users = if author == :you, do: :gb_sets.add(id, prov.user_groups), else: prov.user_groups

    prov = %{
      prov
      | groups: Map.put(prov.groups, id, group),
        user_groups: users,
        next_group: id + 1
    }

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
  @spec edit(
          t(),
          group_id() | :untracked,
          non_neg_integer(),
          binary(),
          binary(),
          Run.attribution() | nil
        ) :: t()
  def edit(%__MODULE__{} = prov, group, start, removed, inserted, attribution \\ nil)
      when is_integer(start) and start >= 0 and is_binary(removed) and is_binary(inserted) do
    prov
    |> apply_edit(group, start, removed, inserted, attribution)
    |> traced({:edit, group, start, removed, inserted})
  end

  @spec apply_edit(
          t(),
          group_id() | :untracked,
          non_neg_integer(),
          binary(),
          binary(),
          Run.attribution() | nil
        ) :: t()
  defp apply_edit(prov, group, start, removed, inserted, attribution) do
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

      removed_bytes == 0 and inside_own_run?(prov, group_id, author, start, attribution) ->
        grow_run_at(prov, start, inserted_bytes)

      replacing_inside_run?(prov, group_id, start, removed_bytes) ->
        prov
        |> replace_inside_run(group_id, author, start, removed, inserted_bytes, attribution)
        |> renumber_when_deep()
        |> remember_fresh()
        |> settle_changes()

      true ->
        prov = prov |> split_at(start) |> split_at(start + removed_bytes)
        following = run_starting_at(prov.tree, start)
        preceding = preceding_run(prov.tree, following)

        change =
          if inserted_bytes > 0 and removed_bytes > 0 and group_id != nil, do: prov.next_change

        {gap, next} =
          gap_source(author, removed_bytes, change, prov.next_change, prov.origin_scope)

        {prov, {killed, replaced, pulled}} =
          delete_from(
            %{prov | next_change: next},
            group_id,
            {change, gap},
            following,
            removed,
            0,
            {[], [], []}
          )

        {prov, made_by} = open_change(prov, change, replaced, pulled, author)

        prov
        |> consume(group_id, seeds(killed), fn _change, made -> any_live(made) end)
        |> insert_between(
          group_id,
          author,
          preceding,
          following,
          inserted_bytes,
          made_by,
          attribution
        )
        |> renumber_when_deep()
        |> remember_fresh()
        |> settle_changes()
    end
  end

  @doc """
  Applies several changes by one group, as `edit/5` would one at a time from the last to the first.

  `changes` are `{start, removed, inserted}`, in document order and disjoint, with offsets valid when the changes are applied from the last to the first. When they touch a large share of the runs (`mode` `:auto`, the default), one pass over every run applies them all and rebuilds the record in O(n), instead of O(log n) per change. `mode` `:batch` or `:each` forces one way, for tests. Both give the same text, authors, blockers, overlap marks, draft text, and replacement records and links, up to how the records are numbered. Run boundaries may differ: one pass can leave a deleted run in two pieces where changes one at a time leave one, so run and draft counts can differ by those pieces. The run budget only bounds memory, and compaction merges a whole stretch of drafts at once, so no outcome depends on the count.
  """
  @spec edit_all(
          t(),
          group_id() | :untracked,
          [{non_neg_integer(), binary(), binary()}],
          :auto | :batch | :each,
          Run.attribution() | nil
        ) ::
          t()
  def edit_all(%__MODULE__{} = prov, group, changes, mode \\ :auto, attribution \\ nil)
      when is_list(changes) do
    batch? =
      case mode do
        :auto -> length(changes) * 8 > RunTree.count(prov.tree)
        :batch -> changes != []
        :each -> false
      end

    edited =
      if batch?,
        do: edit_in_one_pass(prov, group, changes, attribution),
        else:
          changes
          |> Enum.reverse()
          |> Enum.reduce(prov, fn {start, removed, inserted}, acc ->
            apply_edit(acc, group, start, removed, inserted, attribution)
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

  @doc "Unapplies every group in one pass. With `preserve_cursor?`, maps the cursor across the changed bytes."
  @spec revert_all(t(), [group_id()], Document.t(), boolean()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  def revert_all(%__MODULE__{} = prov, ids, %Document{} = document, preserve_cursor? \\ false)
      when is_list(ids),
      do:
        prov |> set_applied_all(ids, false, document, preserve_cursor?) |> traced_flip(ids, false)

  @doc "Applies a reverted group again and returns the document with its text. See `revert/3`."
  @spec reapply(t(), group_id(), Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  def reapply(%__MODULE__{} = prov, id, %Document{} = document),
    do: prov |> set_applied(id, true, document) |> traced_flip([id], true)

  @doc "Reapplies every group in a review unit in one document pass."
  @spec reapply_all(t(), [group_id()], Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  def reapply_all(%__MODULE__{} = prov, ids, %Document{} = document) when is_list(ids),
    do: prov |> set_applied_all(ids, true, document) |> traced_flip(ids, true)

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
    identify = blocking_author(blocks?)

    Map.fetch!(groups, id).runs
    |> :gb_sets.to_list()
    |> Enum.find_value(fn run_id ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      run_blocker(run, id, groups, identify)
    end)
  end

  @typep identify_blocker :: (group_id(), Group.t() -> group_key() | :you | nil)

  @spec blocking_author((author(), group_key() -> boolean())) :: identify_blocker()
  defp blocking_author(blocks?) do
    fn _id, %Group{author: author, key: key} ->
      if blocks?.(author, key), do: key
    end
  end

  @spec run_blocker(
          Run.t(),
          group_id(),
          %{group_id() => Group.t()},
          identify_blocker()
        ) :: group_key() | :you | nil
  defp run_blocker(run, id, groups, identify) do
    if removed_by?(run, id) do
      run
      |> later_deleters(id)
      |> Enum.reject(&(&1 in run.covered_by))
      |> Enum.find_value(&blocking_key(groups, &1, id, identify))
    end
  end

  # Whether `id` wrote the run or deleted it while it was visible.
  # Sweeping it as a tombstone inside a range, or covering it with a consumed replacement, never makes a group the one
  # who removed it.
  @spec removed_by?(Run.t(), group_id()) :: boolean()
  defp removed_by?(%Run{bytes: 0}, _id), do: false
  defp removed_by?(%Run{group: id}, id), do: true

  defp removed_by?(run, id),
    do: id in run.deletions and id not in run.covered_by and id not in run.swept_by

  @doc """
  Returns every applied group not yours that deleted, after group `id` did, a run `id` wrote or deleted in any way, as group ids.

  This is wider than `blocker/3` on purpose: it also counts covers, and runs `id` only swept or covered. A press takes these groups with `id`, and reverting `id` while such a group stays could bring back text you deleted (your deletion and a later cover of the same text both keep it dead). Taking more only reverts more, and stays exact.

  `reverting?` names the groups that revert with `id`: text one of them wrote and one of them deleted is left out, as in `blocker_among/3`.
  """
  @spec later_deleters_of(t(), group_id(), (group_id() -> boolean())) :: [group_id()]
  def later_deleters_of(
        %__MODULE__{groups: groups, tree: tree},
        id,
        reverting? \\ fn _id -> false end
      )
      when is_function(reverting?, 1) do
    groups
    |> Map.fetch!(id)
    |> Map.fetch!(:runs)
    |> :gb_sets.to_list()
    |> Enum.flat_map(fn run_id ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      run_later_deleters(run, id, groups, reverting?)
    end)
    |> Enum.uniq()
  end

  @spec run_later_deleters(Run.t(), group_id(), %{group_id() => Group.t()}, (group_id() ->
                                                                               boolean())) ::
          [group_id()]
  defp run_later_deleters(%Run{bytes: 0}, _id, _groups, _reverting?), do: []

  defp run_later_deleters(run, id, groups, reverting?) do
    if reverting?.(run.group) and Enum.any?(run.deletions, reverting?),
      do: [],
      else: applied_minga_deleters(run, id, groups)
  end

  @spec applied_minga_deleters(Run.t(), group_id(), %{group_id() => Group.t()}) :: [group_id()]
  defp applied_minga_deleters(run, id, groups) do
    for deleter <- later_deleters(run, id),
        deleter != id,
        deleting = Map.fetch!(groups, deleter),
        deleting.applied and deleting.author != :you,
        do: deleter
  end

  @doc "Reads this group's rewrite requirements into the current Reject scan."
  @spec rewrite_requirements(t(), group_id(), RewriteScan.t()) ::
          {[RewriteScan.requirement()], RewriteScan.t()}
  def rewrite_requirements(%__MODULE__{groups: groups, tree: tree}, id, scan) do
    RewriteScan.collect(scan, id, Map.fetch!(groups, id).runs, tree, groups)
  end

  @doc """
  Returns a key that `blocker/3` would return for one of the groups in `ids` reverting together, or `nil` when none is blocked.

  A later deletion of text that one of the groups wrote and one of them deleted does not count: that text stays dead when they revert, whoever else deleted it. A single group's `blocker/3` is unchanged.

  When the groups hold a large share of the runs, one pass over every run answers in O(n) instead of looking each run up.
  """
  @spec blocker_among(t(), [group_id()], (author(), group_key() -> boolean())) ::
          group_key() | nil
  def blocker_among(%__MODULE__{} = prov, ids, blocks?)
      when is_list(ids) and is_function(blocks?, 2) do
    blocked_among(prov, ids, MapSet.new(ids), blocking_author(blocks?))
  end

  @doc "Names the first conflict outside the exact review unit IDs."
  @spec review_conflict(t(), [group_id()], :reject | :restore) ::
          group_key() | :you | nil
  def review_conflict(%__MODULE__{} = prov, ids, direction) do
    selected = MapSet.new(ids)

    identify = fn group, value ->
      cond do
        MapSet.member?(selected, group) -> nil
        direction == :reject and value.author == :you -> nil
        true -> overlap_name(value)
      end
    end

    case blocked_among(prov, ids, selected, identify) do
      nil ->
        case overlaps_among(prov, ids) do
          [] -> nil
          [{key, _offset} | _rest] -> key
        end

      key ->
        key
    end
  end

  @typedoc "Retained bytes and the exact visible input of a parked review unit."
  @type restore_proof :: {non_neg_integer(), <<_::256>>}

  @doc "Binds review restore to the direct and covered text that reapplication would consume."
  @spec review_restore_proof(t(), [group_id()], Document.t()) :: restore_proof()
  def review_restore_proof(%__MODULE__{groups: groups, tree: tree}, ids, document) do
    {input, retained} =
      Enum.map_reduce(ids, 0, fn id, size ->
        {size, direct, covered} =
          groups
          |> Map.fetch!(id)
          |> Map.fetch!(:runs)
          |> :gb_sets.to_list()
          |> Enum.reduce({size, [], []}, &review_run_proof(tree, id, &1, document, &2))

        hashes = [
          :crypto.hash(:sha256, Enum.reverse(direct)),
          :crypto.hash(:sha256, Enum.reverse(covered))
        ]

        {hashes, size}
      end)

    {retained, :crypto.hash(:sha256, input)}
  end

  @typep input_bytes :: {non_neg_integer(), [binary()], [binary()]}

  @spec review_run_proof(RunTree.t(), group_id(), Locator.t(), Document.t(), input_bytes()) ::
          input_bytes()
  defp review_run_proof(tree, group, run_id, document, {size, direct, covered}) do
    {:ok, run, offset} = RunTree.fetch(tree, run_id)
    directly_touched? = removed_by?(run, group)
    size = if directly_touched?, do: size + run.bytes, else: size

    if run.live and group in run.deletions do
      text = Document.slice_byte_range(document, offset, run.bytes)

      if directly_touched?,
        do: {size, [text | direct], covered},
        else: {size, direct, [text | covered]}
    else
      {size, direct, covered}
    end
  end

  @spec blocked_among(t(), [group_id()], MapSet.t(group_id()), identify_blocker()) ::
          group_key() | :you | nil
  defp blocked_among(prov, ids, set, identify) do
    touched = Enum.reduce(ids, 0, &(:gb_sets.size(Map.fetch!(prov.groups, &1).runs) + &2))

    if touched * 8 > RunTree.count(prov.tree),
      do: blocker_in_one_pass(prov, set, identify),
      else: Enum.find_value(ids, &set_blocker(prov, &1, set, identify))
  end

  @spec set_blocker(t(), group_id(), MapSet.t(group_id()), identify_blocker()) ::
          group_key() | :you | nil
  defp set_blocker(%__MODULE__{groups: groups, tree: tree}, id, set, identify) do
    Map.fetch!(groups, id).runs
    |> :gb_sets.to_list()
    |> Enum.find_value(fn run_id ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      if not internal?(run, set), do: run_blocker(run, id, groups, identify)
    end)
  end

  # Text a member of the set wrote and a member deleted stays dead when the set reverts, whoever else deleted it, so
  # a later deletion of it protects nothing and never blocks the set.
  @spec internal?(Run.t(), MapSet.t(group_id())) :: boolean()
  defp internal?(run, set),
    do: MapSet.member?(set, run.group) and Enum.any?(run.deletions, &MapSet.member?(set, &1))

  @spec blocker_in_one_pass(t(), MapSet.t(group_id()), identify_blocker()) ::
          group_key() | :you | nil
  defp blocker_in_one_pass(prov, ids, identify) do
    prov.tree
    |> RunTree.to_list()
    |> Enum.reject(&internal?(&1, ids))
    |> Enum.find_value(fn run ->
      run
      |> run_groups()
      |> Enum.filter(&MapSet.member?(ids, &1))
      |> Enum.find_value(&run_blocker(run, &1, prov.groups, identify))
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

  @doc "Returns other groups that lose bytes they wrote or deleted if this group is finalized."
  @spec groups_losing_bytes_on_retirement(t(), group_id()) :: MapSet.t(group_id())
  def groups_losing_bytes_on_retirement(%__MODULE__{groups: groups, tree: tree}, id) do
    %Group{applied: applied, runs: runs} = Map.fetch!(groups, id)

    runs
    |> :gb_sets.to_list()
    |> Enum.reduce(MapSet.new(), fn run_id, losing ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)

      run
      |> retired_run_neighbours(id, applied)
      |> Enum.reduce(losing, &keep_removed_group(run, &1, &2))
    end)
  end

  @spec retired_run_neighbours(Run.t(), group_id(), boolean()) :: [group_id()]
  defp retired_run_neighbours(run, id, true), do: earlier_groups(run, id)
  defp retired_run_neighbours(%Run{group: id, deletions: deletions}, id, false), do: deletions
  defp retired_run_neighbours(_run, _id, false), do: []

  @spec keep_removed_group(Run.t(), group_id(), MapSet.t(group_id())) :: MapSet.t(group_id())
  defp keep_removed_group(run, id, losing) do
    if removed_by?(run, id), do: MapSet.put(losing, id), else: losing
  end

  @doc """
  Forgets a group whose state is final, keeping the document as it is.

  An applied group's text becomes permanent and keeps its author; the text it deleted is dropped. An unapplied group's text is dropped and it no longer counts as a deletion of anyone's text. Use it when a group leaves every history: your oldest undo step falls off the stack, your redo steps are replaced by a new edit, or a Minga step is reverted for good.
  """
  @spec discard(t(), group_id()) :: t()
  def discard(%__MODULE__{} = prov, id) do
    %{prov | settling_drafts: MapSet.new()}
    |> discard_one(id, prov, nil)
    |> unpair_drafts(id)
    |> traced({:discard, [id]})
    |> finish_group_discard([id])
  end

  @spec discard_one(t(), group_id(), t(), kept_gaps() | nil) :: t()
  defp discard_one(prov, id, before, gaps) do
    {group, groups} = Map.pop!(prov.groups, id)
    marked = Map.get(prov.overlap_runs, id, [])

    prov =
      %{prov | groups: groups}
      |> settle_overlaps(id, group)
      |> settle_group_marks(%{id => group})

    group.runs
    |> :gb_sets.to_list()
    |> Enum.reduce(prov, fn run_id, prov ->
      settle_run(prov, run_id, %{id => group}, before, gaps)
    end)
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

  # What a discarded overlapper becomes in a mark: nothing when it never happened, a permanent name when it always will.
  @spec settled_overlap(group_id(), Group.t()) :: {:permanent, term()} | nil
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
  defp deleted_writer_key(groups, %Run{group: writer, bytes: bytes} = run, id)
       when bytes > 0 and writer != nil and writer != id do
    if id in run.deletions, do: List.wrap(Map.fetch!(groups, writer).key), else: []
  end

  defp deleted_writer_key(_groups, _base_or_own, _id), do: []

  @doc """
  Identifies user groups with text visible now or restored by undoing selected Minga deletions. User deletions stay applied for this check, even when the plan would also remove them.
  """
  @spec protected_user_text(t(), MapSet.t(group_id())) :: [{group_id(), {:yours, group_id()}}]
  def protected_user_text(%__MODULE__{groups: groups, tree: tree}, selected) do
    keeps_deleted? = fn id ->
      group = Map.fetch!(groups, id)
      group.applied and (group.author == :you or not MapSet.member?(selected, id))
    end

    for id <- selected,
        %{author: :you, applied: true, runs: runs} <- [Map.fetch!(groups, id)],
        Enum.any?(:gb_sets.to_list(runs), &user_text_returns?(tree, id, &1, keeps_deleted?)),
        do: {id, {:yours, id}}
  end

  @spec user_text_returns?(RunTree.t(), group_id(), Locator.t(), (group_id() -> boolean())) ::
          boolean()
  defp user_text_returns?(tree, id, locator, keeps_deleted?) do
    {:ok, run, _offset} = RunTree.fetch(tree, locator)
    run.group == id and not Enum.any?(run.deletions, keeps_deleted?)
  end

  @doc "Returns each user group and the Minga deletions that must revert to expose one of its own bytes."
  @spec protected_user_requirements(t(), MapSet.t(group_id())) :: [{group_id(), [group_id()]}]
  def protected_user_requirements(%__MODULE__{groups: groups, tree: tree}, possible) do
    for id <- possible,
        %{author: :you, applied: true, runs: runs} <- [Map.fetch!(groups, id)],
        reduce: [] do
      evidence ->
        requirements = user_requirements(tree, id, runs, groups, possible)

        Enum.reduce(requirements, evidence, &[{id, &1} | &2])
    end
  end

  @spec user_requirements(
          RunTree.t(),
          group_id(),
          :gb_sets.set(Locator.t()),
          %{group_id() => Group.t()},
          MapSet.t(group_id())
        ) :: MapSet.t([group_id()])
  defp user_requirements(tree, id, runs, groups, possible) do
    Enum.reduce_while(:gb_sets.to_list(runs), MapSet.new(), fn locator, acc ->
      case RunTree.fetch(tree, locator) do
        {:ok, %Run{group: ^id, live: true, bytes: bytes}, _offset} when bytes > 0 ->
          {:halt, MapSet.new([[]])}

        {:ok, %Run{group: ^id, deletions: deleters, bytes: bytes}, _offset} when bytes > 0 ->
          collect_user_requirements(deleters, groups, possible, acc)

        {:ok, _other_run, _offset} ->
          {:cont, acc}
      end
    end)
  end

  @spec collect_user_requirements(
          [group_id()],
          %{group_id() => Group.t()},
          MapSet.t(group_id()),
          MapSet.t([group_id()])
        ) :: {:cont, MapSet.t([group_id()])}
  defp collect_user_requirements(deleters, groups, possible, acc) do
    case user_byte_deleters(deleters, groups, possible, []) do
      nil -> {:cont, acc}
      required -> {:cont, MapSet.put(acc, required)}
    end
  end

  @spec user_byte_deleters(
          [group_id()],
          %{group_id() => Group.t()},
          MapSet.t(group_id()),
          [group_id()]
        ) :: [group_id()] | nil
  defp user_byte_deleters([], _groups, _possible, required), do: required

  defp user_byte_deleters([id | rest], groups, possible, required) do
    case Map.fetch!(groups, id) do
      %Group{applied: false} ->
        user_byte_deleters(rest, groups, possible, required)

      %Group{author: :you} ->
        nil

      %Group{} ->
        if MapSet.member?(possible, id),
          do: user_byte_deleters(rest, groups, possible, [id | required])
    end
  end

  @doc """
  Returns the holding user groups and all contributing deleters for each distinct revival in a proposed revert. Separate revival witnesses stay separate so the planner can distinguish a local refusal from a conflict between choices.
  """
  @spec revived_user_deletions(t(), MapSet.t(group_id())) :: [{[group_id()], [group_id()]}]
  def revived_user_deletions(%__MODULE__{groups: groups, tree: tree}, selected) do
    runs =
      for id <- selected,
          %{author: :you, applied: true, runs: runs} <- [Map.fetch!(groups, id)],
          run_id <- :gb_sets.to_list(runs),
          into: MapSet.new(),
          do: run_id

    Enum.reduce(runs, MapSet.new(), fn run_id, conflicts ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      add_revival_conflict(run, selected, groups, conflicts)
    end)
    |> MapSet.to_list()
  end

  @spec add_revival_conflict(
          Run.t(),
          MapSet.t(group_id()),
          %{group_id() => Group.t()},
          MapSet.t({[group_id()], [group_id()]})
        ) :: MapSet.t({[group_id()], [group_id()]})
  defp add_revival_conflict(run, selected, groups, conflicts) do
    writer_remains? =
      run.group == nil or
        (Map.fetch!(groups, run.group).applied and not MapSet.member?(selected, run.group))

    if writer_remains? and not run.live and run.bytes > 0 do
      active = Enum.filter(run.deletions, &Map.fetch!(groups, &1).applied)
      users = for id <- active, %Group{author: :you} <- [Map.fetch!(groups, id)], do: id

      if users != [] and Enum.all?(active, &MapSet.member?(selected, &1)) do
        MapSet.put(conflicts, {users, active})
      else
        conflicts
      end
    else
      conflicts
    end
  end

  @doc "Returns how many bytes of the group's own text are live, by the groups' applied flags."
  @spec live_bytes_of(t(), group_id()) :: non_neg_integer()
  def live_bytes_of(%__MODULE__{groups: groups, tree: tree}, id) do
    groups
    |> Map.fetch!(id)
    |> Map.fetch!(:runs)
    |> :gb_sets.to_list()
    |> Enum.reduce(0, fn run_id, bytes ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      if run.group == id and live?(run, groups), do: bytes + run.bytes, else: bytes
    end)
  end

  @doc """
  Forgets several groups whose state is final; see `discard/2`.

  When the groups hold a large share of the runs, as when a long task is rejected, one pass over every run settles them all and rebuilds the tree and every group's run set, in O(n), instead of looking each run up.
  """
  @spec discard_all(t(), [group_id()]) :: t()
  def discard_all(%__MODULE__{} = prov, ids) when is_list(ids) do
    prov |> discard_groups(ids) |> finish_group_discard(ids)
  end

  @doc "Keeps reviewed text and deletion marks, then retires those groups and their dependents."
  @spec keep_groups(t(), [group_id()], [group_id()]) :: t()
  def keep_groups(%__MODULE__{} = prov, reviewed, retired) do
    {prov, gaps} = Enum.reduce(reviewed, {prov, %{}}, &mark_kept_group/2)
    prov |> discard_groups(retired, gaps) |> finish_group_discard(retired)
  end

  @spec mark_kept_group(group_id(), {t(), kept_gaps()}) :: {t(), kept_gaps()}
  defp mark_kept_group(id, {prov, gaps}) do
    case Map.fetch!(prov.groups, id) do
      %Group{applied: true, runs: runs} ->
        Enum.reduce(:gb_sets.to_list(runs), {prov, gaps}, &mark_kept_run(id, &1, &2))

      %Group{applied: false} ->
        {prov, gaps}
    end
  end

  @spec mark_kept_run(group_id(), Locator.t(), {t(), kept_gaps()}) :: {t(), kept_gaps()}
  defp mark_kept_run(id, locator, {prov, gaps}) do
    {:ok, run, _offset} = RunTree.fetch(prov.tree, locator)

    gaps =
      if not run.live and id in run.direct_gaps and inserted?(prov.groups, run.group),
        do: mark_kept_gap(gaps, run, id),
        else: gaps

    prov =
      if run.group == id and run.bytes > 0 and not run.kept?,
        do: put_run(prov, run, %{run | kept?: true}),
        else: prov

    {prov, gaps}
  end

  @spec mark_kept_gap(kept_gaps(), Run.t(), group_id()) :: kept_gaps()
  defp mark_kept_gap(gaps, run, id) do
    origin =
      case List.keyfind(run.gap_origins, id, 0) do
        {^id, {:delete, _, _, _} = source} -> source
        _other -> nil
      end

    Map.update(gaps, run.id, origin, fn previous ->
      if previous == origin, do: origin
    end)
  end

  @doc """
  Retires the selected groups and replays an untracked replacement as one history change.

  `replay` applies the replacement to the provenance after the groups are finalized. Compaction evidence is evaluated before and after the entire change, not while the replacement is being applied.
  """
  @spec replace_base(t(), [group_id()], (t() -> t())) :: t()
  def replace_base(%__MODULE__{} = prov, [], replay) when is_function(replay, 1),
    do: replay.(prov)

  def replace_base(%__MODULE__{} = prov, [_ | _] = ids, replay) when is_function(replay, 1) do
    prov
    |> discard_groups(ids)
    |> replay.()
    |> finish_group_discard(ids)
  end

  @spec discard_groups(t(), [group_id()], kept_gaps() | nil) :: t()
  defp discard_groups(prov, ids, gaps \\ nil) do
    touched = Enum.reduce(ids, 0, &(:gb_sets.size(Map.fetch!(prov.groups, &1).runs) + &2))
    settling = %{prov | settling_drafts: MapSet.new()}

    discarded =
      if touched * 8 > RunTree.count(prov.tree),
        do: discard_in_one_pass(settling, ids, gaps),
        else: Enum.reduce(ids, settling, &discard_one(&2, &1, prov, gaps))

    ids
    |> Enum.reduce(discarded, &unpair_drafts(&2, &1))
    |> traced({:discard, ids})
  end

  @spec finish_group_discard(t(), [group_id()]) :: t()
  defp finish_group_discard(prov, ids),
    do: prov |> witness_settled_drafts() |> retire_user_barriers(ids)

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

  @typedoc "Per-proposal run evidence and applied pivots for witnessed draft components."
  @type draft_scan :: %{
          optional(Locator.t()) => :claimed | MapSet.t(group_id()),
          optional(DraftLinks.pivot_key()) => group_id()
        }

  @doc "Returns applied witnessed draft neighbours and currently compactible chains this group can claim."
  @spec draft_partners(t(), group_id(), draft_scan()) :: {MapSet.t(group_id()), draft_scan()}
  def draft_partners(%__MODULE__{groups: groups} = prov, id, scan) do
    case Map.fetch!(groups, id) do
      %Group{applied: false} ->
        {MapSet.new(), scan}

      %Group{runs: runs} ->
        {neighbours, scan} = DraftLinks.applied_partners(prov.witnessed_drafts, id, groups, scan)
        frontier = newest_yours(prov)

        Enum.reduce(
          :gb_sets.to_list(runs),
          {neighbours, scan},
          &claim_draft(prov, frontier, id, &1, &2)
        )
    end
  end

  @spec claim_draft(
          t(),
          non_neg_integer(),
          group_id(),
          Locator.t(),
          {MapSet.t(group_id()), draft_scan()}
        ) :: {MapSet.t(group_id()), draft_scan()}
  defp claim_draft(prov, frontier, id, locator, {partners, scan} = acc) do
    case scan do
      %{^locator => :claimed} ->
        acc

      %{^locator => members} ->
        claim_members(id, locator, members, acc)

      _new ->
        {:ok, run, _offset} = RunTree.fetch(prov.tree, locator)

        case compactible_chain(run, prov.groups, frontier) do
          [] -> {partners, Map.put(scan, locator, :claimed)}
          chain -> claim_members(id, locator, MapSet.new(chain), acc)
        end
    end
  end

  @spec claim_members(
          group_id(),
          Locator.t(),
          MapSet.t(group_id()),
          {MapSet.t(group_id()), draft_scan()}
        ) :: {MapSet.t(group_id()), draft_scan()}
  defp claim_members(id, locator, members, {partners, scan}) do
    if MapSet.member?(members, id),
      do: {MapSet.union(partners, MapSet.delete(members, id)), Map.put(scan, locator, :claimed)},
      else: {partners, Map.put(scan, locator, members)}
  end

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
  @spec compact_oldest(t(), (group_id() -> [group_id()])) ::
          {:ok, t(), {group_id(), group_id()}, pos_integer()} | :none
  def compact_oldest(%__MODULE__{} = prov, class_of \\ &[&1]) when is_function(class_of, 1) do
    # A draft of a step older than your newest group can never merge (see `merge_allowed?/2`), so the search starts
    # after it: a history your edits hold costs nothing to look at. Locators are nonempty lists, so `[]` sorts first.
    newest_yours = newest_yours(prov)

    prov.drafts
    |> then(&:gb_sets.iterator_from({newest_yours + 1, []}, &1))
    |> mergeable_draft(prov, class_of, newest_yours, %{})
    |> case do
      nil ->
        :none

      {old, new, draft_id} ->
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

  # The oldest draft whose merge `merge_allowed?/3` accepts, each pair checked once.
  @spec mergeable_draft(
          :gb_sets.iter(term()),
          t(),
          (group_id() -> [group_id()]),
          non_neg_integer(),
          %{{group_id(), group_id()} => boolean()}
        ) :: {group_id(), group_id(), Locator.t()} | nil
  defp mergeable_draft(iterator, prov, class_of, newest_yours, checked) do
    case :gb_sets.next(iterator) do
      :none ->
        nil

      {{old, draft_id}, rest} ->
        {:ok, draft, _offset} = RunTree.fetch(prov.tree, draft_id)
        new = draft_partner(draft, prov.groups)

        allowed =
          Map.get_lazy(checked, {old, new}, fn ->
            merge_allowed?(Enum.uniq([old, new | class_of.(old) ++ class_of.(new)]), newest_yours)
          end)

        if allowed,
          do: {old, new, draft_id},
          else:
            mergeable_draft(
              rest,
              prov,
              class_of,
              newest_yours,
              Map.put(checked, {old, new}, false)
            )
    end
  end

  # Steps never merge while a group of yours newer than the class's oldest step can still be undone. Such a group is
  # the only way an edit of yours can reach a merged class: through a mark it left on a member's replacement, or on a
  # dependent's, and dependents are newer still. With none, no edit of yours can hold the class or wait for it, so a
  # merge changes nothing a press or `u` can see. History from before your latest edit compacts once that edit is
  # final.
  @spec merge_allowed?([group_id()], non_neg_integer()) :: boolean()
  defp merge_allowed?(members, newest_yours), do: Enum.min(members) > newest_yours

  # Your newest group that can still be undone or redone, or 0 when there is none.
  @spec newest_yours(t()) :: non_neg_integer()
  defp newest_yours(%__MODULE__{user_groups: users}) do
    if :gb_sets.is_empty(users), do: 0, else: :gb_sets.largest(users)
  end

  @doc """
  Merges step `old` into the newer step `new` of the same task across the stretch from locator `first` to locator `last`: every run there that names `old` as its writer or a deleter names `new` instead, and text `new` now both wrote and deleted is dropped, since it can never be live again.

  The document is unchanged for every choice of applied groups in which `old` and `new` agree. Reverting `new` alone afterwards restores the text from before `old` in the stretch, and reverting `old` alone no longer touches it. When `old` names no runs afterwards, the group is removed and any marks it left elsewhere name `new`. The stretch costs O(m + log n) to rebuild, plus the index updates for the coverage references it redirects.
  """
  @spec absorb(t(), group_id(), group_id(), {Locator.t(), Locator.t()}) :: t()
  def absorb(%__MODULE__{} = prov, old, new, {first, last}) do
    {prov, _examined} = absorb_stretch(prov, old, new, first, last)
    prov
  end

  @spec absorb_stretch(t(), group_id(), group_id(), Locator.t(), Locator.t()) ::
          {t(), pos_integer()}
  defp absorb_stretch(prov, old, new, first, last) do
    {tree, {before, kept, aliases}} =
      RunTree.rebuild_range(prov.tree, first, last, fn runs ->
        kept =
          for run <- runs,
              mapped = compact_run(prov, relabel(run, old, new), new),
              mapped != nil,
              do: mapped

        {kept, aliases} = coalesce_coverage_anchors(kept, prov, old, new)
        {kept, {runs, kept, aliases}}
      end)

    kept_ids = MapSet.new(kept, & &1.id)
    dropped = Enum.reject(before, &MapSet.member?(kept_ids, &1.id))

    prov =
      Enum.reduce(dropped, prov, fn run, prov ->
        prov |> forget_changes(run) |> unindex_review_site(run.id) |> unindex_strand_site(run)
      end)

    prov =
      Enum.reduce(kept, prov, fn run, acc ->
        acc |> index_review_site(run) |> index_strand_site(run)
      end)

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

    {new_drafts, witnessed} =
      draft_index_entries(kept, groups, newest_yours(prov), prov.witnessed_drafts)

    drafts =
      prov.drafts
      |> remove_all(Enum.map(before, &{&1.group, &1.id}))
      |> add_all(new_drafts)

    marked = for run <- kept, Enum.any?(run.overlaps, &match?({_owner, ^new}, &1)), do: run.id

    prov = %{
      prov
      | tree: tree,
        groups: groups,
        drafts: drafts,
        witnessed_drafts: witnessed,
        overlap_runs: Map.update(prov.overlap_runs, new, marked, &(marked ++ &1))
    }

    prov =
      prov
      |> resolve_coverage_aliases(aliases)
      |> remove_when_empty(old, new)
      |> settle_changes()
      |> traced({:absorb, old, new})

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
    gaps = substitute(run.direct_gaps, old, new)
    direct? = new in gaps or Enum.any?([old, new], &removed_by?(%{run | group: nil}, &1))
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
        direct_gaps: gaps,
        gap_origins: relabel_gap_origins(run.gap_origins, old, new),
        overlaps: substitute_marks(run.overlaps, old, new)
    }
  end

  @spec relabel_gap_origins([{group_id(), Run.origin()}], group_id(), group_id()) ::
          [{group_id(), Run.origin()}]
  defp relabel_gap_origins(origins, old, new) do
    case List.keytake(origins, old, 0) do
      {{^old, origin}, rest} ->
        if List.keymember?(rest, new, 0), do: rest, else: [{new, origin} | rest]

      nil ->
        origins
    end
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

  @spec compact_run(t(), Run.t(), group_id()) :: Run.t() | nil
  defp compact_run(prov, run, new) do
    if self_deleted?(run, new),
      do: compacted_anchor(Map.get(prov.changes, run.made_by), run),
      else: run
  end

  @spec compacted_anchor(Change.t() | nil, Run.t()) :: Run.t() | nil
  defp compacted_anchor(nil, _run), do: nil

  defp compacted_anchor(%Change{replaced: replaced, pulls: pulls}, run) do
    if not :gb_sets.is_empty(replaced) or not :gb_sets.is_empty(pulls),
      do: %{run | bytes: 0, text: "", origin: nil, gap_origins: [], attribution: nil}
  end

  # First join adjacent pieces of one replacement, then collapse replacements that only cover the next anchor.
  # Two adjacent anchors with the same owner can still have different coverers.
  # A bare pull never erases a position.
  @spec coalesce_coverage_anchors([Run.t()], t(), group_id(), group_id()) ::
          {[Run.t()], [{Run.t(), Run.t()}]}
  defp coalesce_coverage_anchors(runs, prov, old, new) do
    same_lifetime? = fn source, target ->
      source.group == new and target.group == new and source.deletions == target.deletions and
        source.direct_gaps == target.direct_gaps and source.overlaps == [] and
        target.overlaps == []
    end

    {runs, pieces} =
      coalesce_anchors(runs, fn source, target ->
        source.made_by == target.made_by and source.replaced_by == target.replaced_by and
          same_lifetime?.(source, target)
      end)

    locations = Map.new(pieces, fn {source, target} -> {source.id, target.id} end)
    removed = Enum.frequencies_by(pieces, fn {source, _target} -> source.made_by end)

    {runs, chains} =
      coalesce_anchors(runs, fn source, target ->
        source.made_by > target.made_by and same_lifetime?.(source, target) and
          only_covers?(prov.changes, source, target, locations, removed) and
          compatible_coverers?(
            prov,
            source.replaced_by,
            List.delete(target.replaced_by, source.made_by),
            old,
            new
          )
      end)

    {runs, chains ++ pieces}
  end

  @spec coalesce_anchors([Run.t()], (Run.t(), Run.t() -> boolean())) ::
          {[Run.t()], [{Run.t(), Run.t()}]}
  defp coalesce_anchors(runs, alias?) do
    Enum.reduce(Enum.reverse(runs), {[], []}, fn
      %Run{bytes: 0, made_by: source_id} = source,
      {[%Run{bytes: 0, made_by: target_id} = target | _] = kept, aliases}
      when is_integer(source_id) and is_integer(target_id) ->
        if alias?.(source, target),
          do: {kept, [{source, target} | aliases]},
          else: {[source | kept], aliases}

      run, {kept, aliases} ->
        {[run | kept], aliases}
    end)
  end

  # The newer maker covers the older position while applied.
  # Its exclusive coverers may inherit the link only inside its class.
  # Exclusive coverers of the older position stay distinct.
  @spec compatible_coverers?(t(), [Change.id()], [Change.id()], group_id(), group_id()) ::
          boolean()
  defp compatible_coverers?(_prov, same, same, _old, _new), do: true

  defp compatible_coverers?(prov, [same | left], [same | right], old, new),
    do: compatible_coverers?(prov, left, right, old, new)

  defp compatible_coverers?(prov, [change | left], right, old, new)
       when right == [] or change > hd(right) do
    record_owner(prov, Map.fetch!(prov.changes, change)) in [old, new] and
      compatible_coverers?(prov, left, right, old, new)
  end

  defp compatible_coverers?(_prov, _left, _right, _old, _new), do: false

  @spec only_covers?(
          %{Change.id() => Change.t()},
          Run.t(),
          Run.t(),
          %{Locator.t() => Locator.t()},
          %{Change.id() => pos_integer()}
        ) :: boolean()
  defp only_covers?(changes, source, target, locations, removed) do
    record = Map.fetch!(changes, source.made_by)
    made_by = target.made_by

    :gb_sets.size(record.made) == 1 + Map.get(removed, source.made_by, 0) and
      :gb_sets.size(record.replaced) <= 1 + Map.get(removed, made_by, 0) and
      :gb_sets.size(record.pulls) <= 1 and
      not :gb_sets.is_empty(record.replaced) and :gb_sets.is_empty(record.pulled_by) and
      Enum.all?(:gb_sets.to_list(record.replaced), &(Map.get(locations, &1, &1) == target.id)) and
      Enum.all?(:gb_sets.to_list(record.pulls), &(&1 == made_by))
  end

  @spec resolve_coverage_aliases(t(), [{Run.t(), Run.t()}]) :: t()
  defp resolve_coverage_aliases(prov, []), do: prov

  defp resolve_coverage_aliases(prov, aliases) do
    targets = Map.new(aliases, fn {source, target} -> {source.id, target} end)

    prov =
      Enum.reduce(aliases, prov, fn {source, target}, acc ->
        if source.made_by == target.made_by do
          acc
        else
          acc = pull(acc, source.made_by, target.made_by)
          splice(acc, source.made_by, Map.fetch!(acc.changes, source.made_by))
        end
      end)

    Enum.reduce(aliases, prov, fn {source, target}, acc ->
      target = Map.get(targets, target.id, target)
      Enum.reduce(source.replaced_by, acc, &transfer_anchor_cover(&2, target, &1))
    end)
  end

  # A previous replacement that covered the alias must still mark this position when it is consumed.
  @spec transfer_anchor_cover(t(), Run.t(), Change.id()) :: t()
  defp transfer_anchor_cover(prov, target, change) do
    if change != target.made_by and Map.has_key?(prov.changes, change) do
      {:ok, anchor, _offset} = RunTree.fetch(prov.tree, target.id)
      covers = Enum.sort(Enum.uniq([change | anchor.replaced_by]), :desc)
      tree = RunTree.update(prov.tree, %{anchor | replaced_by: covers})

      %{prov | tree: tree}
      |> update_change(change, fn record ->
        %{
          record
          | replaced: :gb_sets.add(target.id, record.replaced),
            pulls: :gb_sets.delete_any(target.made_by, record.pulls)
        }
      end)
      |> update_change(target.made_by, fn record ->
        %{record | pulled_by: :gb_sets.delete_any(change, record.pulled_by)}
      end)
    else
      prov
    end
  end

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
          overlap_runs: Map.update(overlap_runs, new, marked, &(marked ++ &1)),
          witnessed_drafts: DraftLinks.absorb(prov.witnessed_drafts, old, new)
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

  @type attribution ::
          {author(), Minga.Buffer.Author.key() | nil, integer() | nil,
           :unreviewed | :kept | :recorded}

  @doc "Returns exact Minga attribution for the live byte, not a nearby review gap."
  @spec attribution_at(t(), non_neg_integer()) :: attribution() | nil
  def attribution_at(%__MODULE__{tree: tree}, offset) when is_integer(offset) and offset >= 0 do
    case RunTree.at_offset(tree, offset) do
      {%Run{author: {:minga, _} = author} = run, _start} ->
        review = attribution_review(run)

        case run.attribution do
          {nil, at} -> {{:minga, :untasked}, nil, at, review}
          {key, at} -> {Author.author(key), key, at, review}
          nil -> {author, nil, nil, review}
        end

      _ ->
        nil
    end
  end

  @doc "Attaches original writer facts to newly published runs without changing their review group."
  @spec attribute_publication(
          t(),
          group_id(),
          [{non_neg_integer(), pos_integer(), Run.attribution()}]
        ) :: t()
  def attribute_publication(%__MODULE__{} = prov, _group, []), do: prov

  def attribute_publication(%__MODULE__{} = prov, group, ranges) do
    ranges
    |> Enum.reduce(prov, fn {start, count, attribution}, acc ->
      stop = start + count

      acc =
        acc
        |> split_publication_at(group, start)
        |> split_publication_at(group, stop)

      tree =
        acc.tree
        |> RunTree.live_between(start, stop)
        |> Enum.reduce(acc.tree, fn
          {%Run{group: ^group} = run, _offset}, tree ->
            RunTree.update(tree, %{run | attribution: attribution})

          _other, tree ->
            tree
        end)

      remember_fresh(%{acc | tree: tree})
    end)
    |> renumber_when_deep()
  end

  @spec split_publication_at(t(), group_id(), non_neg_integer()) :: t()
  defp split_publication_at(prov, group, offset) do
    case RunTree.at_offset(prov.tree, offset) do
      {%Run{group: ^group} = run, start} when start < offset ->
        {_left, _right, prov} = split_run(prov, run, offset - start)
        prov

      _other ->
        prov
    end
  end

  @spec attribution_review(Run.t()) :: :unreviewed | :kept | :recorded
  defp attribution_review(%Run{kept?: true}), do: :kept
  defp attribution_review(%Run{group: group}) when is_integer(group), do: :unreviewed
  defp attribution_review(%Run{}), do: :recorded

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
  Returns the applied Minga runs and direct deletion gaps touching `[from, to)`, in file order.

  A gap belongs to the range starting there. Include the gap at EOF only when `include_eof?` is true and the range reaches EOF. A replacement contributes its live text, not an extra gap for the bytes it replaced. A live run retains its full extent when it crosses a query boundary. Seeks through the sparse site index; retired, parked, and untracked runs between sites do not need a visit.
  """
  @spec review_sites(t(), non_neg_integer(), non_neg_integer(), boolean()) :: [review_site()]
  def review_sites(%__MODULE__{} = prov, from, to, include_eof? \\ true)
      when is_integer(from) and is_integer(to) and from >= 0 and to >= from do
    size = RunTree.size(prov.tree)
    at_eof? = include_eof? and to >= size

    if :gb_sets.is_empty(prov.review_sites) or (from == to and not at_eof?) do
      []
    else
      case RunTree.first_overlapping(prov.tree, from) do
        nil ->
          []

        first ->
          to = min(to, size)
          iterator = :gb_sets.iterator_from(first, prov.review_sites)
          prov |> collect_review_sites(iterator, to, at_eof?, []) |> Enum.reverse()
      end
    end
  end

  @doc "Lazily seeks the pending authored sites from a byte in either direction."
  @spec review_sites_from(t(), non_neg_integer(), :next | :previous) :: Enumerable.t()
  def review_sites_from(%__MODULE__{} = prov, offset, direction) do
    order = if direction == :next, do: :ordered, else: :reversed

    case RunTree.first_overlapping(prov.tree, offset) do
      nil when direction == :next ->
        []

      nil ->
        stream_review_sites(prov, :gb_sets.iterator(prov.review_sites, order))

      locator ->
        stream_review_sites(prov, :gb_sets.iterator_from(locator, prov.review_sites, order))
    end
  end

  @spec stream_review_sites(t(), :gb_sets.iter(Locator.t())) :: Enumerable.t()
  defp stream_review_sites(prov, iterator) do
    Stream.resource(
      fn -> iterator end,
      fn current ->
        case :gb_sets.next(current) do
          :none ->
            {:halt, current}

          {locator, next} ->
            {:ok, run, start} = RunTree.fetch(prov.tree, locator)
            {append_review_sites([], run, start, prov), next}
        end
      end,
      fn _iterator -> :ok end
    )
  end

  @doc "Returns live human, shared and kept strands and deletion gaps with their full source extents."
  @spec strand_spans(t(), non_neg_integer(), non_neg_integer(), boolean()) :: [strand_span()]
  def strand_spans(%__MODULE__{} = prov, from, to, include_eof? \\ false) do
    at_eof? = include_eof? and to == size(prov)

    if :gb_sets.is_empty(prov.strand_sites) or (from >= to and not at_eof?) do
      []
    else
      case RunTree.first_overlapping(prov.tree, from) do
        nil ->
          []

        first ->
          iterator = :gb_sets.iterator_from(first, prov.strand_sites)
          prov |> collect_strand_spans(iterator, to, at_eof?, []) |> Enum.reverse()
      end
    end
  end

  @spec collect_strand_spans(
          t(),
          :gb_sets.iter(Locator.t()),
          non_neg_integer(),
          boolean(),
          [strand_span()]
        ) :: [strand_span()]
  defp collect_strand_spans(prov, iterator, to, at_eof?, acc) do
    case :gb_sets.next(iterator) do
      :none ->
        acc

      {locator, next} ->
        {:ok, run, start} = RunTree.fetch(prov.tree, locator)

        if start < to or (at_eof? and start == to) do
          role = presented_strand_role(prov, run)
          last = start + run.bytes

          collect_strand_spans(prov, next, to, at_eof?, [{role, start, last} | acc])
        else
          acc
        end
    end
  end

  # A human replacement can cover every authored byte on its row. Its exact replacement edges
  # still carry that connection, but never make the human text an actionable review site.
  @spec presented_strand_role(t(), Run.t()) :: :kept | :you | :shared | nil
  defp presented_strand_role(prov, %Run{author: :you, made_by: id}) when is_integer(id) do
    if pending_preimage?(prov, [id], %{}), do: :shared, else: :you
  end

  defp presented_strand_role(_prov, run), do: strand_role(run)

  @spec pending_preimage?(t(), [Change.id()], %{optional(Change.id()) => true}) :: boolean()
  defp pending_preimage?(_prov, [], _seen), do: false

  defp pending_preimage?(prov, [id | rest], seen) do
    with false <- is_map_key(seen, id),
         %Change{} = record <- Map.get(prov.changes, id),
         owner when is_integer(owner) <- replacement_group(prov, record) do
      case shared_preimage(prov, :gb_sets.iterator(record.replaced), owner, rest) do
        :pending -> true
        older -> pending_preimage?(prov, older, Map.put(seen, id, true))
      end
    else
      _unavailable -> pending_preimage?(prov, rest, seen)
    end
  end

  @spec replacement_group(t(), Change.t()) :: group_id() | nil
  defp replacement_group(prov, %Change{owner: :runs, made: made}) do
    {:ok, run, _start} = RunTree.fetch(prov.tree, :gb_sets.smallest(made))
    run.group
  end

  defp replacement_group(_prov, %Change{owner: owner}) when is_integer(owner), do: owner
  defp replacement_group(_prov, %Change{}), do: nil

  @spec directly_replaced?(Run.t(), group_id()) :: boolean()
  defp directly_replaced?(run, owner),
    do: owner not in run.swept_by and owner not in run.covered_by and owner not in run.direct_gaps

  @spec shared_preimage(t(), :gb_sets.iter(Locator.t()), group_id(), [Change.id()]) ::
          :pending | [Change.id()]
  defp shared_preimage(prov, iterator, owner, older) do
    case :gb_sets.next(iterator) do
      :none ->
        older

      {locator, next} ->
        {:ok, run, _offset} = RunTree.fetch(prov.tree, locator)

        cond do
          not directly_replaced?(run, owner) ->
            shared_preimage(prov, next, owner, older)

          run.group != nil and
              match?(%Group{author: {:minga, _}, applied: true}, Map.get(prov.groups, run.group)) ->
            :pending

          run.author == :you and run.made_by != nil ->
            shared_preimage(prov, next, owner, [run.made_by | older])

          true ->
            shared_preimage(prov, next, owner, older)
        end
    end
  end

  @doc "Returns a live grouped run at the byte, ignoring zero-width deletion sites."
  @spec live_review_run_at(t(), non_neg_integer()) :: review_site() | nil
  def live_review_run_at(%__MODULE__{tree: tree}, offset) when offset >= 0 do
    case RunTree.at_offset(tree, offset) do
      {%Run{group: group, bytes: bytes}, start} when is_integer(group) ->
        {group, start, start + bytes}

      _other ->
        nil
    end
  end

  @doc "Returns exact source fragments before finalizing an applied Keep in this projection."
  @spec keep_sources(t(), [group_id()]) :: [keep_source()]
  def keep_sources(%__MODULE__{} = prov, groups) do
    for group <- groups,
        %Group{applied: true, runs: runs} <- [Map.fetch!(prov.groups, group)],
        locator <- :gb_sets.to_list(runs),
        {:ok, run, point} = RunTree.fetch(prov.tree, locator),
        source <- keep_run_sources(run, point, group, prov.groups),
        do: source
  end

  @spec keep_run_sources(Run.t(), non_neg_integer(), group_id(), %{group_id() => Group.t()}) ::
          [keep_source()]
  defp keep_run_sources(
         %Run{live: true, group: group, origin: origin, bytes: bytes},
         point,
         group,
         _groups
       )
       when is_tuple(origin),
       do: [{:written, origin, point, bytes}]

  defp keep_run_sources(%Run{live: false, text: text} = run, point, group, groups)
       when is_binary(text) and byte_size(text) > 0 do
    case List.keyfind(run.gap_origins, group, 0) do
      {^group, origin} ->
        if inserted?(groups, run.group), do: [{:removed, origin, point, text}], else: []

      nil ->
        []
    end
  end

  defp keep_run_sources(_run, _point, _group, _groups), do: []

  @doc "Returns the visible source and shared replacement spans whose authorship changes on Keep."
  @spec keep_sites(t(), [group_id()]) :: [byte_range()]
  def keep_sites(%__MODULE__{} = prov, groups) do
    {visible, covered} =
      for group <- groups,
          locator <- :gb_sets.to_list(Map.fetch!(prov.groups, group).runs),
          reduce: {[], []} do
        {visible, covered} ->
          {:ok, run, start} = RunTree.fetch(prov.tree, locator)

          visible =
            if keep_site?(prov.groups, run, group),
              do: [{start, start + Run.live_bytes(run)} | visible],
              else: visible

          covered =
            if run.group == group and not run.live,
              do: direct_replacements(prov, run, covered),
              else: covered

          {visible, covered}
      end

    shared_keep_sites(prov, covered, %{}, visible)
  end

  @spec keep_site?(%{group_id() => Group.t()}, Run.t(), group_id()) :: boolean()
  defp keep_site?(_groups, %Run{live: true, group: group}, group), do: true

  defp keep_site?(groups, %Run{live: false} = run, group),
    do: group in run.direct_gaps and inserted?(groups, run.group)

  defp keep_site?(_groups, _run, _group), do: false

  @spec shared_keep_sites(t(), [Change.id()], %{optional(Change.id()) => true}, [byte_range()]) ::
          [byte_range()]
  defp shared_keep_sites(_prov, [], _seen, sites), do: sites

  defp shared_keep_sites(prov, [id | rest], seen, sites) do
    if is_map_key(seen, id) do
      shared_keep_sites(prov, rest, seen, sites)
    else
      change = Map.fetch!(prov.changes, id)

      {rest, sites} =
        Enum.reduce(:gb_sets.to_list(change.made), {rest, sites}, &shared_keep_site(prov, &1, &2))

      shared_keep_sites(prov, rest, Map.put(seen, id, true), sites)
    end
  end

  @spec shared_keep_site(t(), Locator.t(), {[Change.id()], [byte_range()]}) ::
          {[Change.id()], [byte_range()]}
  defp shared_keep_site(prov, locator, {pending, sites} = unchanged) do
    case RunTree.fetch(prov.tree, locator) do
      {:ok, %Run{author: :you, live: true, bytes: width}, start} ->
        {pending, [{start, start + width} | sites]}

      {:ok, %Run{author: :you} = run, _start} ->
        {direct_replacements(prov, run, pending), sites}

      _other ->
        unchanged
    end
  end

  @spec direct_replacements(t(), Run.t(), [Change.id()]) :: [Change.id()]
  defp direct_replacements(prov, run, pending) do
    for id <- run.replaced_by,
        owner when is_integer(owner) <- [replacement_group(prov, Map.fetch!(prov.changes, id))],
        directly_replaced?(run, owner),
        reduce: pending do
      pending -> [id | pending]
    end
  end

  @doc "Finds one active review group at the exact byte, including a deletion at EOF."
  @spec review_group_at(t(), non_neg_integer()) :: group_id() | nil
  def review_group_at(%__MODULE__{} = prov, offset) when is_integer(offset) and offset >= 0 do
    if not :gb_sets.is_empty(prov.review_sites) do
      case RunTree.first_overlapping(prov.tree, offset) do
        nil ->
          nil

        first ->
          first |> :gb_sets.iterator_from(prov.review_sites) |> review_point(prov, offset)
      end
    end
  end

  @spec review_point(:gb_sets.iter(Locator.t()), t(), non_neg_integer()) :: group_id() | nil
  defp review_point(iterator, prov, offset) do
    case :gb_sets.next(iterator) do
      :none ->
        nil

      {locator, _rest} ->
        case RunTree.fetch(prov.tree, locator) do
          {:ok, %Run{live: true, group: id}, start} when start <= offset ->
            id

          {:ok, run, ^offset} ->
            Enum.find(run.direct_gaps, &active_minga_gap?(prov.groups, &1))

          {:ok, _run, _start} ->
            nil
        end
    end
  end

  @spec collect_review_sites(t(), :gb_sets.iter(Locator.t()), non_neg_integer(), boolean(), [
          review_site()
        ]) :: [review_site()]
  defp collect_review_sites(prov, iterator, to, at_eof, acc) do
    case :gb_sets.next(iterator) do
      :none ->
        acc

      {locator, iterator} ->
        {:ok, run, start} = RunTree.fetch(prov.tree, locator)

        if start < to or (at_eof and start == to) do
          acc = append_review_sites(acc, run, start, prov)
          collect_review_sites(prov, iterator, to, at_eof, acc)
        else
          acc
        end
    end
  end

  @spec append_review_sites([review_site()], Run.t(), non_neg_integer(), t()) :: [review_site()]
  defp append_review_sites(acc, %Run{live: true} = run, start, _prov),
    do: [{run.group, start, start + run.bytes} | acc]

  defp append_review_sites(acc, run, start, prov) do
    Enum.reduce(run.direct_gaps, acc, fn id, sites ->
      if active_minga_gap?(prov.groups, id), do: [{id, start, start} | sites], else: sites
    end)
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

      case {run.bytes, acc} do
        {0, _acc} -> acc
        {_bytes, [{region_start, ^start} | rest]} -> [{region_start, stop} | rest]
        {_bytes, _acc} -> [{start, stop} | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc "Projects kept origin placements for checkpoint proof, including hidden descendants."
  @spec kept_placements(t()) :: kept_placements()
  def kept_placements(%__MODULE__{tree: tree}) do
    RunTree.reduce(tree, %{}, fn
      %Run{kept?: true, origin: {kind, id, _, _} = origin} = run, point, placements ->
        placement =
          cond do
            run.live -> {:visible, origin, point, run.bytes}
            run.bytes == 0 -> {:gap, origin, point}
            true -> {:held, origin}
          end

        Map.update(placements, {kind, id}, [placement], &[placement | &1])

      _run, _point, placements ->
        placements
    end)
  end

  @doc "Retires proved Keep intervals without altering text, authorship, groups, or undo."
  @spec retire_kept(t(), [keep_interval()]) :: {t(), [byte_range()]}
  def retire_kept(%__MODULE__{} = prov, []), do: {prov, []}

  def retire_kept(%__MODULE__{} = prov, intervals) do
    by_origin = intervals |> Enum.group_by(&interval_origin/1, &interval_range/1)
    by_origin = Map.new(by_origin, fn {origin, ranges} -> {origin, Enum.sort(ranges)} end)

    {prov, sites} =
      RunTree.reduce(prov.tree, {prov, []}, fn
        %Run{kept?: true, origin: {kind, id, _, _}} = run, point, acc ->
          case Map.fetch(by_origin, {kind, id}) do
            {:ok, ranges} -> retire_run(run, point, ranges, acc)
            :error -> acc
          end

        _run, _point, acc ->
          acc
      end)

    {renumber_when_deep(prov), Enum.reverse(sites)}
  end

  @spec interval_origin(keep_interval()) :: {:insert | :replace | :delete, pos_integer()}
  defp interval_origin({kind, id, _from, _to}), do: {kind, id}

  @spec interval_range(keep_interval()) :: byte_range()
  defp interval_range({_kind, _id, from, to}), do: {from, to}

  @spec retire_run(Run.t(), non_neg_integer(), [byte_range()], {t(), [byte_range()]}) ::
          {t(), [byte_range()]}
  defp retire_run(%Run{origin: {:delete, _, _, total}} = run, point, ranges, {prov, sites}) do
    if covers_source?(ranges, 0, total),
      do: {drop_run(prov, run), [{point, point} | sites]},
      else: {prov, sites}
  end

  defp retire_run(run, point, ranges, acc), do: retire_run_parts(run, point, ranges, acc)

  @spec covers_source?([byte_range()], non_neg_integer(), pos_integer()) :: boolean()
  defp covers_source?(_ranges, covered, total) when covered >= total, do: true

  defp covers_source?([{start, stop} | rest], covered, total) when start <= covered,
    do: covers_source?(rest, max(covered, stop), total)

  defp covers_source?(_ranges, _covered, _total), do: false

  @spec retire_run_parts(Run.t(), non_neg_integer(), [byte_range()], {t(), [byte_range()]}) ::
          {t(), [byte_range()]}
  defp retire_run_parts(_run, _point, [], acc), do: acc

  defp retire_run_parts(
         %Run{origin: {_, _, offset, _}, bytes: bytes} = run,
         point,
         [{low, high} | rest],
         acc
       ) do
    cond do
      high <= offset ->
        retire_run_parts(run, point, rest, acc)

      low >= offset + bytes ->
        acc

      low > offset ->
        {prov, sites} = acc
        {left, right, prov} = split_run(prov, run, low - offset)

        retire_run_parts(
          right,
          point + Run.live_bytes(left),
          [{low, high} | rest],
          {remember_fresh(prov), sites}
        )

      high < offset + bytes ->
        {prov, sites} = acc
        {left, right, prov} = split_run(prov, run, high - offset)
        {prov, sites} = clear_kept_run(remember_fresh(prov), left, point, sites)
        retire_run_parts(right, point + Run.live_bytes(left), rest, {prov, sites})

      true ->
        {prov, sites} = acc
        clear_kept_run(prov, run, point, sites)
    end
  end

  @spec clear_kept_run(t(), Run.t(), non_neg_integer(), [byte_range()]) :: {t(), [byte_range()]}
  defp clear_kept_run(prov, run, point, sites) do
    prov =
      prov
      |> unindex_strand_site(run)
      |> put_run(run, %{run | kept?: false, origin: nil})

    {prov, if(run.live, do: [{point, point + run.bytes} | sites], else: sites)}
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
  @spec inside_own_run?(
          t(),
          group_id() | nil,
          author(),
          non_neg_integer(),
          Run.attribution() | nil
        ) :: boolean()
  defp inside_own_run?(prov, group_id, author, start, attribution) do
    case RunTree.at_offset(prov.tree, start) do
      {run, run_start} -> run_start < start and extendable?(run, group_id, author, attribution)
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
          non_neg_integer(),
          Run.attribution() | nil
        ) ::
          t()
  defp replace_inside_run(prov, group_id, author, start, removed, inserted_bytes, attribution) do
    {run, run_start} = RunTree.at_offset(prov.tree, start)
    removed_bytes = byte_size(removed)
    rest = run_start + run.bytes - start - removed_bytes
    following = RunTree.next(prov.tree, run.id)
    {dead_id, prov} = allocate(prov, run, following)
    {left, remaining} = split_live_run(run, start - run_start)
    dead = %{remaining | id: dead_id, bytes: removed_bytes}

    {right, prov} =
      if rest > 0 do
        {right_id, prov} = allocate(prov, dead, following)
        {_taken, right} = split_live_run(remaining, removed_bytes)
        {%{right | id: right_id}, prov}
      else
        {nil, prov}
      end

    tree = RunTree.update(prov.tree, left)
    tree = if right, do: RunTree.insert(tree, right), else: tree
    groups = Enum.reduce(run_groups(run), prov.groups, &add_run(&2, &1, dead_id))

    groups =
      if right, do: Enum.reduce(run_groups(run), groups, &add_run(&2, &1, right.id)), else: groups

    change = if inserted_bytes > 0, do: prov.next_change
    {gap, next} = gap_source(author, removed_bytes, change, prov.next_change, prov.origin_scope)

    {prov, replaced, pulled} =
      %{prov | tree: RunTree.insert(tree, dead), groups: groups, next_change: next}
      |> add_live_review_site(right)
      |> index_overlaps(dead)
      |> index_overlaps(right)
      |> index_changes(dead)
      |> index_changes(right)
      |> replace_run(group_id, change, dead, removed, gap_origin(gap, 0))

    {prov, made_by} = open_change(prov, change, replaced, pulled, author)
    insert_between(prov, group_id, author, left, dead, inserted_bytes, made_by, attribution)
  end

  @spec grow_run_at(t(), non_neg_integer(), pos_integer()) :: t()
  defp grow_run_at(prov, start, bytes) do
    {run, _run_start} = RunTree.at_offset(prov.tree, start)
    %{prov | tree: RunTree.update(prov.tree, %{run | bytes: run.bytes + bytes})}
  end

  # Only text with no replacement record grows: a replacement's own text stays its own run, so a later deletion can tell
  # whether all of it is gone.
  @spec extendable?(Run.t() | nil, group_id() | nil, author(), Run.attribution() | nil) ::
          boolean()
  defp extendable?(
         %Run{
           live: true,
           deletions: [],
           group: group,
           author: author,
           made_by: nil,
           replaced_by: [],
           kept?: false,
           origin: nil,
           attribution: attribution
         },
         group,
         author,
         attribution
       )
       when author in [:you, :unattributed, {:minga, :untasked}],
       do: true

  defp extendable?(_run, _group_id, _author, _attribution), do: false

  # Splits the live run that holds `offset` so a run starts exactly there.
  @spec split_at(t(), non_neg_integer()) :: t()
  defp split_at(prov, offset) do
    case RunTree.at_offset(prov.tree, offset) do
      {run, run_start} when run_start < offset ->
        {_left, _right, prov} = split_run(prov, run, offset - run_start)
        prov

      _boundary_or_end ->
        prov
    end
  end

  @spec split_run(t(), Run.t(), pos_integer()) :: {Run.t(), Run.t(), t()}
  defp split_run(prov, run, left_bytes) do
    following = RunTree.next(prov.tree, run.id)
    {right_id, prov} = allocate(prov, run, following)
    {left, right} = split_live_run(run, left_bytes)
    right = %{right | id: right_id}

    {left, right} =
      if run.live do
        {left, right}
      else
        {%{left | text: binary_part(run.text, 0, left.bytes)},
         %{right | text: binary_part(run.text, left.bytes, right.bytes)}}
      end

    tree = prov.tree |> RunTree.update(left) |> RunTree.insert(right)
    groups = Enum.reduce(run_groups(right), prov.groups, &add_run(&2, &1, right_id))
    prov = %{prov | tree: tree, groups: groups}

    prov =
      if right.live, do: add_live_review_site(prov, right), else: index_review_site(prov, right)

    {left, right, prov |> index_overlaps(right) |> index_changes(right)}
  end

  @spec split_live_run(Run.t(), non_neg_integer()) :: {Run.t(), Run.t()}
  defp split_live_run(run, left_bytes) do
    origin =
      case run.origin do
        {kind, id, offset, total} -> {kind, id, offset + left_bytes, total}
        nil -> nil
      end

    moved_gaps =
      Enum.map(run.gap_origins, fn {group, {kind, id, offset, total}} ->
        {group, {kind, id, offset + left_bytes, total}}
      end)

    {%{run | bytes: left_bytes},
     %{run | bytes: run.bytes - left_bytes, origin: origin, gap_origins: moved_gaps}}
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
          {Change.id() | nil, Run.origin() | nil},
          Run.t() | nil,
          binary(),
          non_neg_integer(),
          {[Run.t()], [Locator.t()], [Change.id()]}
        ) ::
          {t(), {[Run.t()], [Locator.t()], [Change.id()]}}
  defp delete_from(prov, _group_id, _change, _run, removed, consumed, acc)
       when consumed == byte_size(removed),
       do: {prov, acc}

  defp delete_from(prov, group_id, {change, gap} = source, %Run{} = run, removed, consumed, acc) do
    # A dropped run's marks may have moved onto this one since it was looked up.
    run = current(prov.tree, run)
    following = RunTree.next(prov.tree, run.id)
    {killed, replaced, pulled} = acc

    {text, killed, consumed_after} =
      if run.live,
        do: {binary_part(removed, consumed, run.bytes), [run | killed], consumed + run.bytes},
        else: {run.text, killed, consumed}

    {prov, kept, makers} =
      replace_run(prov, group_id, change, run, text, gap_origin(gap, consumed))

    acc = {killed, kept ++ replaced, makers ++ pulled}
    delete_from(prov, group_id, source, following, removed, consumed_after, acc)
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
  @spec replace_run(
          t(),
          group_id() | nil,
          Change.id() | nil,
          Run.t(),
          binary(),
          Run.origin() | nil
        ) ::
          {t(), [Locator.t()], [Change.id()]}
  defp replace_run(prov, _group, _change, %Run{bytes: 0, kept?: true}, _text, _origin),
    do: {prov, [], []}

  defp replace_run(prov, group_id, change, run, text, origin) do
    case deleted(run, group_id, text) do
      nil ->
        prov = prov |> remember_draft_chain(run, prov) |> drop_run(run)
        {prov, [], List.wrap(run.made_by)}

      dead ->
        dead = how_deleted(dead, run, group_id, change, origin)

        {dead, kept} =
          if change,
            do: {%{dead | replaced_by: [change | dead.replaced_by]}, [run.id]},
            else: {dead, []}

        {if(dead == run, do: prov, else: kill_run(prov, group_id, run, dead)), kept, []}
    end
  end

  # Deleting visible text is direct: it clears any earlier cover or sweep by the group.
  # Newly deleting a tombstone inside the range is a sweep.
  @spec how_deleted(Run.t(), Run.t(), group_id(), Change.id() | nil, Run.origin() | nil) ::
          Run.t()
  defp how_deleted(dead, %Run{live: true}, group_id, change, origin) do
    gaps = if change, do: dead.direct_gaps, else: [group_id | dead.direct_gaps]

    origins =
      if origin,
        do: List.keystore(dead.gap_origins, group_id, 0, {group_id, origin}),
        else: dead.gap_origins

    %{
      dead
      | covered_by: List.delete(dead.covered_by, group_id),
        swept_by: List.delete(dead.swept_by, group_id),
        direct_gaps: gaps,
        gap_origins: origins
    }
  end

  defp how_deleted(dead, run, group_id, _change, _origin) do
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

  @spec gap_source(
          author(),
          non_neg_integer(),
          Change.id() | nil,
          pos_integer(),
          non_neg_integer()
        ) :: {Run.origin() | nil, pos_integer()}
  defp gap_source({:minga, _task}, removed, nil, next, scope)
       when removed > 0,
       do: {{:delete, source_id(scope, next), 0, removed}, next + 1}

  defp gap_source({:minga, _task}, removed, change, next, scope)
       when removed > 0,
       do: {{:replace, source_id(scope, change), 0, removed}, next}

  defp gap_source(_author, _removed, _change, next, _scope), do: {nil, next}

  @spec gap_origin(Run.origin() | nil, non_neg_integer()) :: Run.origin() | nil
  defp gap_origin(nil, _offset), do: nil
  defp gap_origin({kind, id, 0, total}, offset), do: {kind, id, offset, total}

  # The record of a replacement whose edit marked `replaced` and dropped runs made by `pulled`. An edit that can neither
  # cover nor mark gets none: it replaced nothing, pulls nothing and is no Minga step's. Returns the id its text names.
  @spec open_change(t(), Change.id() | nil, [Locator.t()], [Change.id()], author()) ::
          {t(), Change.id() | nil}
  defp open_change(prov, nil, _replaced, _pulled, _author), do: {prov, nil}

  defp open_change(prov, change, replaced, pulled, author) do
    if replaced == [] and pulled == [] and not minga?(author) do
      {prov, nil}
    else
      record = %{Change.new() | replaced: :gb_sets.from_list(replaced)}
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
        prov |> remember_draft_chain(run, prov) |> drop_run(run)

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
    if :gb_sets.is_empty(record.made),
      do: retire_runless(prov, change, record),
      else: retire_with_runs(prov, change, record)
  end

  @spec retire_runless(t(), Change.id(), Change.t()) :: {t(), [Change.id()]}
  defp retire_runless(prov, change, record) do
    linked = :gb_sets.to_list(record.pulls) ++ :gb_sets.to_list(record.pulled_by)

    cond do
      # Nothing reaches it, or reaching it does nothing: it has nothing to cover or pull.
      :gb_sets.is_empty(record.pulled_by) or
          (:gb_sets.is_empty(record.replaced) and :gb_sets.is_empty(record.pulls)) ->
        {remove_change(prov, change, record), linked}

      :gb_sets.is_empty(record.replaced) and spliceable?(prov, record) ->
        {splice(prov, change, record), linked}

      true ->
        {prov, []}
    end
  end

  # A record with runs retires when it could never cover, pull or mark: its runs forget it.
  @spec retire_with_runs(t(), Change.id(), Change.t()) :: {t(), [Change.id()]}
  defp retire_with_runs(prov, change, record) do
    if :gb_sets.is_empty(record.replaced) and :gb_sets.is_empty(record.pulls) and
         inert_change?(prov, record) do
      prov = clear_made(prov, record.made)
      {remove_change(prov, change, record), :gb_sets.to_list(record.pulled_by)}
    else
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

  # Only consumption marks runs, and its deleter is always a live group; marks settle to permanent only on discard.
  @spec put_mark(t(), group_id(), group_id(), Run.t()) :: t()
  defp put_mark(prov, owner, overlapper, run) do
    case with_overlap(run, owner, overlapper) do
      ^run ->
        prov

      marked ->
        overlap_runs = Map.update(prov.overlap_runs, overlapper, [run.id], &[run.id | &1])

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
          review_sites: rename_review_sites(prov.review_sites, renamed),
          strand_sites: rename_review_sites(prov.strand_sites, renamed),
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
    put_run(%{prov | groups: add_run(prov.groups, group_id, run.id)}, old, run)
  end

  @spec insert_between(
          t(),
          group_id() | nil,
          author(),
          Run.t() | nil,
          Run.t() | nil,
          non_neg_integer(),
          Change.id() | nil,
          Run.attribution() | nil
        ) :: t()
  defp insert_between(
         prov,
         _group_id,
         _author,
         _preceding,
         _following,
         0,
         _made_by,
         _attribution
       ),
       do: prov

  defp insert_between(prov, group_id, author, preceding, following, bytes, made_by, attribution) do
    if made_by == nil and extendable?(preceding, group_id, author, attribution) do
      %{prov | tree: RunTree.update(prov.tree, %{preceding | bytes: preceding.bytes + bytes})}
    else
      {id, prov} = allocate(prov, preceding, following)

      {origin, next} =
        insertion_origin(author, group_id, made_by, bytes, prov.next_change, prov.origin_scope)

      run = %Run{
        id: id,
        bytes: bytes,
        author: author,
        group: group_id,
        made_by: made_by,
        origin: origin,
        attribution: attribution
      }

      groups = if group_id, do: add_run(prov.groups, group_id, id), else: prov.groups

      %{prov | tree: RunTree.insert(prov.tree, run), groups: groups, next_change: next}
      |> add_live_review_site(run)
      |> index_changes(run)
    end
  end

  @spec insertion_origin(
          author(),
          group_id() | nil,
          Change.id() | nil,
          pos_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          {Run.origin() | nil, pos_integer()}
  defp insertion_origin({:minga, _task}, group, nil, bytes, next, scope)
       when is_integer(group),
       do: {{:insert, source_id(scope, next), 0, bytes}, next + 1}

  defp insertion_origin({:minga, _task}, group, made_by, bytes, next, scope)
       when is_integer(group),
       do: {{:replace, source_id(scope, made_by), 0, bytes}, next}

  defp insertion_origin(_author, _group, _made_by, _bytes, next, _scope), do: {nil, next}

  # ── Undo and reject ─────────────────────────────────────────────────

  @spec set_applied(t(), group_id(), boolean(), Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  defp set_applied(prov, id, applied, document),
    do: set_applied_all(prov, [id], applied, document)

  # Flips every group in `ids` at once and applies all their changes in one pass over the document.
  @spec set_applied_all(t(), [group_id()], boolean(), Document.t(), boolean()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  defp set_applied_all(prov, ids, applied, document, preserve_cursor? \\ false) do
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
        next = preserve_cursor(new_document, document, changes, preserve_cursor?)

        {:ok, next, first_offset(changes), flipped}
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
    {runs, changes, sites, strands, _offset} =
      prov.tree
      |> RunTree.to_list()
      |> Enum.reduce({[], [], [], [], 0}, fn run, {runs, changes, sites, strands, offset} ->
        {flipped, change} = flip(run, prov.groups, content, offset)
        sites = if review_site?(flipped, prov.groups), do: [run.id | sites], else: sites
        strands = if strand_role(flipped), do: [run.id | strands], else: strands

        {[flipped | runs], List.wrap(change) ++ changes, sites, strands,
         offset + Run.live_bytes(run)}
      end)

    runs = Enum.reverse(runs)

    prov = %{
      prov
      | tree: RunTree.from_list(runs),
        review_sites: :gb_sets.from_ordset(Enum.reverse(sites)),
        strand_sites: :gb_sets.from_ordset(Enum.reverse(strands))
    }

    {Enum.reverse(changes), index_drafts(prov, runs)}
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

  @spec preserve_cursor(Document.t(), Document.t(), [change()], boolean()) :: Document.t()
  defp preserve_cursor(new_document, _document, _changes, false), do: new_document

  defp preserve_cursor(new_document, document, changes, true) do
    point = Document.cursor_offset(document)

    shift =
      Enum.reduce_while(changes, 0, fn {offset, removed, inserted}, shift ->
        cond do
          point < offset -> {:halt, shift}
          point < offset + removed -> {:halt, shift + offset - point}
          true -> {:cont, shift + byte_size(inserted) - removed}
        end
      end)

    Cursor.place(new_document, Position.from_point(new_document, point + shift))
  end

  @spec first_offset([change()]) :: non_neg_integer() | nil
  defp first_offset([]), do: nil
  defp first_offset([{offset, _removed, _inserted} | _rest]), do: offset

  @spec live?(Run.t(), %{group_id() => Group.t()}) :: boolean()
  defp live?(%Run{bytes: 0}, _groups), do: false

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
  defp earlier_groups(%Run{bytes: 0}, _id), do: []

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
          identify_blocker()
        ) :: group_key() | :you | nil
  defp blocking_key(_groups, id, id, _blocks?), do: nil

  defp blocking_key(groups, deleter, _id, identify) do
    case Map.fetch!(groups, deleter) do
      %Group{applied: true} = group -> identify.(deleter, group)
      %Group{} -> nil
    end
  end

  # ── Discarding ──────────────────────────────────────────────────────

  @spec settle_run(t(), Locator.t(), %{group_id() => Group.t()}, t(), kept_gaps() | nil) :: t()
  defp settle_run(prov, run_id, discarded, before, gaps) do
    {:ok, run, _offset} = RunTree.fetch(prov.tree, run_id)

    case settle(run, discarded) do
      nil ->
        {:ok, original, _offset} = RunTree.fetch(before.tree, run_id)

        prov
        |> remember_draft_chain(original, before)
        |> drop_run(%{run | overlaps: settled_run(run, discarded).overlaps})
        |> restore_kept_gap(run_id, gaps)

      %Run{group: nil} = settled when run.group != nil ->
        prov |> put_run(run, settled) |> coalesce(run_id)

      settled ->
        put_run(prov, run, settled)
    end
  end

  @spec restore_kept_gap(t(), Locator.t(), kept_gaps() | nil) :: t()
  defp restore_kept_gap(prov, _id, nil), do: prov

  defp restore_kept_gap(prov, id, gaps) do
    case Map.fetch(gaps, id) do
      {:ok, origin} ->
        anchor = kept_gap(id, origin)
        index_strand_site(%{prov | tree: RunTree.insert(prov.tree, anchor)}, anchor)

      :error ->
        prov
    end
  end

  @spec kept_gap(Locator.t(), Run.origin() | nil) :: Run.t()
  defp kept_gap(id, origin),
    do: %Run{id: id, bytes: 0, author: :unattributed, live: false, kept?: true, origin: origin}

  # Applies `settle/2` for every discarded group to every run in order, merging permanent neighbours, then
  # rebuilds the tree and the remaining groups' run sets from the result.
  @spec discard_in_one_pass(t(), [group_id()], kept_gaps() | nil) :: t()
  defp discard_in_one_pass(prov, ids, gaps) do
    before = prov
    {discarded, groups} = Map.split(prov.groups, ids)

    {runs, dropped} =
      prov.tree
      |> RunTree.to_list()
      |> Enum.reduce({[], []}, fn run, acc -> settle_in_pass(run, discarded, acc, gaps) end)

    {groups, sites, strands} = rebuild_group_runs(runs, groups)
    runs = Enum.reverse(runs)

    prov =
      index_drafts(
        %{
          prov
          | tree: RunTree.from_list(runs),
            review_sites: sites,
            strand_sites: strands,
            groups: groups,
            changes: changes_from(prov.changes, runs, dropped),
            overlap_runs: Map.drop(prov.overlap_runs, ids)
        },
        runs
      )

    dropped
    |> Enum.reverse()
    |> Enum.reduce(settle_group_marks(prov, discarded), fn run, acc ->
      acc
      |> remember_draft_chain(run, before)
      |> link_dropped(run)
      |> transfer_marks(settled_run(run, discarded).overlaps)
    end)
    |> settle_owners(discarded)
    |> settle_changes()
  end

  # Keep the original metadata of a dropped run until its draft relationship is recorded.
  @spec settle_in_pass(
          Run.t(),
          %{group_id() => Group.t()},
          {[Run.t()], [Run.t()]},
          kept_gaps() | nil
        ) :: {[Run.t()], [Run.t()]}
  defp settle_in_pass(run, discarded, {kept, dropped}, gaps) do
    case settle(run, discarded) do
      nil ->
        kept =
          case Map.fetch(gaps || %{}, run.id) do
            {:ok, origin} -> [kept_gap(run.id, origin) | kept]
            :error -> kept
          end

        {kept, [run | dropped]}

      settled ->
        {merge_permanent(settled, kept), dropped}
    end
  end

  @spec merge_permanent(Run.t(), [Run.t()]) :: [Run.t()]
  defp merge_permanent(run, [previous | rest] = acc) do
    if same_permanent_author?(previous, run),
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
      if same_permanent_author?(previous, run) do
        merged = %{previous | bytes: previous.bytes + run.bytes}
        tree = prov.tree |> RunTree.delete(run_id) |> RunTree.update(merged)
        {unindex_strand_site(%{prov | tree: tree}, run), merged}
      else
        {prov, run}
      end

    following = RunTree.next(prov.tree, run.id)

    if same_permanent_author?(run, following) do
      merged = %{run | bytes: run.bytes + following.bytes}
      tree = prov.tree |> RunTree.delete(following.id) |> RunTree.update(merged)
      unindex_strand_site(%{prov | tree: tree}, following)
    else
      prov
    end
  end

  @spec same_permanent_author?(Run.t() | nil, Run.t() | nil) :: boolean()
  defp same_permanent_author?(%Run{} = left, %Run{} = right) do
    left.author == right.author and left.kept? == right.kept? and
      left.attribution == right.attribution and permanent?(left) and permanent?(right) and
      adjacent_origins?(left, right)
  end

  defp same_permanent_author?(_left, _right), do: false

  @spec adjacent_origins?(Run.t(), Run.t()) :: boolean()
  defp adjacent_origins?(%Run{origin: nil}, %Run{origin: nil}), do: true

  defp adjacent_origins?(
         %Run{origin: {kind, id, first, total}, bytes: bytes},
         %Run{origin: {kind, id, second, total}}
       ),
       do: first + bytes == second

  defp adjacent_origins?(_left, _right), do: false

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
           origin_scope: non_neg_integer(),
           steps: [{[Change.id()], Change.id() | nil, [Change.id()]}],
           dropped: [Run.t()]
         }

  # The pass applies every deletion and insertion and numbers the replacements as `edit/5` would. The covers come
  # after the rebuild, one change at a time in the order they were applied, with each replacement's live text taken
  # as of that change: text a change applied later kills was still live.
  @spec edit_in_one_pass(t(), group_id() | :untracked, [change()], Run.attribution() | nil) :: t()
  defp edit_in_one_pass(prov, group, changes, attribution) do
    {group_id, author} = writer(prov, group)

    pass = %{
      left: prov.tree |> RunTree.to_list() |> Enum.reverse(),
      right: [],
      pos: RunTree.size(prov.tree),
      next_change: prov.next_change,
      origin_scope: prov.origin_scope,
      steps: [],
      dropped: []
    }

    pass =
      changes
      |> Enum.reverse()
      |> Enum.reduce(pass, &apply_in_pass(group_id, author, &1, &2, attribution))

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
        acc
        |> remember_draft_chain(run, prov)
        |> link_dropped(run)
        |> transfer_marks(run.overlaps)
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
          pass(),
          Run.attribution() | nil
        ) :: pass()
  defp apply_in_pass(group_id, author, {start, removed, inserted}, pass, attribution) do
    pass = move_right_of(pass, start + byte_size(removed), removed != "")
    {segment, pass} = take_from(pass, start, [])
    change = if inserted != "" and removed != "" and group_id != nil, do: pass.next_change

    {gap, next} =
      gap_source(author, byte_size(removed), change, pass.next_change, pass.origin_scope)

    {deleted, dropped} = delete_segment(segment, group_id, removed, {change, gap})
    pulled = for %Run{made_by: maker} <- dropped, maker != nil, uniq: true, do: maker
    made_by = record_id(change, deleted, pulled, author)

    # A record's runs name it only when it has one; an edit that gets none lists nothing.
    deleted =
      if change != nil and made_by == nil,
        do: Enum.map(deleted, &unlist(&1, change)),
        else: deleted

    next = if made_by, do: made_by + 1, else: next

    {origin, next} =
      if inserted == "",
        do: {nil, next},
        else:
          insertion_origin(
            author,
            group_id,
            made_by,
            byte_size(inserted),
            next,
            pass.origin_scope
          )

    inserted_runs = inserted_runs(inserted, author, group_id, made_by, origin, attribution)

    %{
      pass
      | right: inserted_runs ++ deleted ++ pass.right,
        next_change: next,
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
        {before, after_stop} = split_live_run(run, stop - run_start)
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
        {before, taken} = split_live_run(run, start - run_start)
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
    if pulled != [] or minga?(author) or Enum.any?(deleted, &(not kept_gap?(&1))), do: change
  end

  @spec inserted_runs(
          binary(),
          author(),
          group_id() | nil,
          Change.id() | nil,
          Run.origin() | nil,
          Run.attribution() | nil
        ) ::
          [Run.t()]
  defp inserted_runs("", _author, _group_id, _made_by, _origin, _attribution), do: []

  defp inserted_runs(inserted, author, group_id, made_by, origin, attribution),
    do: [
      %Run{
        id: [0],
        bytes: byte_size(inserted),
        author: author,
        group: group_id,
        made_by: made_by,
        origin: origin,
        attribution: attribution
      }
    ]

  # The segment's runs once deleted, each kept one listed under `change`, and the runs the deletion dropped.
  @spec delete_segment(
          [Run.t()],
          group_id() | nil,
          binary(),
          {Change.id() | nil, Run.origin() | nil}
        ) ::
          {[Run.t()], [Run.t()]}
  defp delete_segment(segment, group_id, removed, {change, gap}) do
    {kept, dropped, _consumed} =
      Enum.reduce(segment, {[], [], 0}, fn
        %Run{bytes: 0, kept?: true} = anchor, {kept, dropped, consumed} ->
          {[anchor | kept], dropped, consumed}

        run, {kept, dropped, consumed} ->
          {text, consumed_after} =
            if run.live,
              do: {binary_part(removed, consumed, run.bytes), consumed + run.bytes},
              else: {run.text, consumed}

          case deleted(run, group_id, text) do
            nil ->
              {kept, [run | dropped], consumed_after}

            dead ->
              dead = how_deleted(dead, run, group_id, change, gap_origin(gap, consumed))
              {[replaced_by(dead, change) | kept], dropped, consumed_after}
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
      [%Run{live: true, deletions: [], overlaps: []} = previous | rest] = acc
      when run.group == previous.group and run.author == previous.author and
             run.made_by == previous.made_by and run.replaced_by == previous.replaced_by and
             run.kept? == previous.kept? and run.attribution == previous.attribution ->
        if adjacent_origins?(previous, run),
          do: [%{previous | bytes: previous.bytes + run.bytes} | rest],
          else: [run | acc]

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

    reversed = Enum.reverse(runs)
    {groups, sites, strands} = rebuild_group_runs(reversed, prov.groups)

    overlap_runs =
      Enum.reduce(reversed, %{}, fn run, acc ->
        for {_owner, group} when is_integer(group) <- run.overlaps, reduce: acc do
          inner -> Map.update(inner, group, [run.id], &[run.id | &1])
        end
      end)

    index_drafts(
      %{
        prov
        | tree: RunTree.from_list(runs),
          review_sites: sites,
          strand_sites: strands,
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
      links = Map.get_lazy(previous, id, &Change.new/0)

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
  defp deleted(%Run{bytes: 0, group: group_id} = run, group_id, _text), do: run
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
        direct_gaps: Enum.reject(run.direct_gaps, &Map.has_key?(discarded, &1)),
        gap_origins: Enum.reject(run.gap_origins, &Map.has_key?(discarded, elem(&1, 0))),
        overlaps: overlaps,
        origin: if(group == nil and not run.kept?, do: nil, else: run.origin)
    }
  end

  # ── Bookkeeping ─────────────────────────────────────────────────────

  @spec put_run(t(), Run.t(), Run.t()) :: t()
  defp put_run(prov, old, run) do
    prov = %{prov | tree: RunTree.update(prov.tree, run)}

    prov =
      if review_site_candidate?(old) or review_site_candidate?(run),
        do: index_review_site(prov, run),
        else: prov

    prov
    |> index_strand_site(run)
    |> refresh_draft(old, run)
  end

  @spec add_live_review_site(t(), Run.t() | nil) :: t()
  defp add_live_review_site(prov, %Run{live: true, author: {:minga, _}, group: id} = run)
       when is_integer(id) do
    %{prov | review_sites: :gb_sets.insert(run.id, prov.review_sites)}
  end

  defp add_live_review_site(prov, %Run{live: true} = run),
    do: index_strand_site(prov, run)

  defp add_live_review_site(prov, _run), do: prov

  @spec index_review_site(t(), Run.t()) :: t()
  defp index_review_site(prov, run) do
    if review_site?(run, prov.groups) do
      %{prov | review_sites: :gb_sets.add(run.id, prov.review_sites)}
    else
      unindex_review_site(prov, run.id)
    end
  end

  @spec unindex_review_site(t(), Locator.t()) :: t()
  defp unindex_review_site(prov, id) do
    if :gb_sets.is_member(id, prov.review_sites) do
      %{prov | review_sites: :gb_sets.delete(id, prov.review_sites)}
    else
      prov
    end
  end

  @spec index_strand_site(t(), Run.t()) :: t()
  defp index_strand_site(prov, run) do
    if strand_role(run),
      do: %{prov | strand_sites: :gb_sets.add(run.id, prov.strand_sites)},
      else: unindex_strand_site(prov, run)
  end

  @spec strand_role(Run.t()) :: :kept | :you | nil
  defp strand_role(%Run{kept?: true} = run) when run.live or run.bytes == 0, do: :kept
  defp strand_role(%Run{live: true, author: :you}), do: :you
  defp strand_role(_run), do: nil

  @spec kept_gap?(Run.t()) :: boolean()
  defp kept_gap?(%Run{bytes: 0, kept?: true}), do: true
  defp kept_gap?(_run), do: false

  @spec unindex_strand_site(t(), Run.t()) :: t()
  defp unindex_strand_site(prov, %Run{id: id} = run) when run.kept? or run.author == :you,
    do: %{prov | strand_sites: :gb_sets.delete_any(id, prov.strand_sites)}

  defp unindex_strand_site(prov, _run), do: prov

  @spec rebuild_group_runs([Run.t()], %{group_id() => Group.t()}) ::
          {%{group_id() => Group.t()}, :gb_sets.set(Locator.t()), :gb_sets.set(Locator.t())}
  defp rebuild_group_runs(reversed, groups) do
    {members, sites, strands} =
      Enum.reduce(reversed, {%{}, [], []}, fn run, {members, sites, strands} ->
        members =
          Enum.reduce(run_groups(run), members, fn id, acc ->
            Map.update(acc, id, [run.id], &[run.id | &1])
          end)

        sites = if review_site?(run, groups), do: [run.id | sites], else: sites
        strands = if strand_role(run), do: [run.id | strands], else: strands
        {members, sites, strands}
      end)

    groups =
      Map.new(groups, fn {id, group} ->
        {id, %{group | runs: :gb_sets.from_ordset(Map.get(members, id, []))}}
      end)

    {groups, :gb_sets.from_ordset(sites), :gb_sets.from_ordset(strands)}
  end

  @spec rename_review_sites(:gb_sets.set(Locator.t()), %{Locator.t() => Locator.t()}) ::
          :gb_sets.set(Locator.t())
  defp rename_review_sites(sites, renamed) do
    sites |> :gb_sets.to_list() |> Enum.map(&Map.fetch!(renamed, &1)) |> :gb_sets.from_ordset()
  end

  @spec review_site_candidate?(Run.t()) :: boolean()
  defp review_site_candidate?(%Run{author: {:minga, _}, group: id}) when is_integer(id), do: true
  defp review_site_candidate?(%Run{direct_gaps: [_ | _]}), do: true
  defp review_site_candidate?(_run), do: false

  @spec review_site?(Run.t(), %{group_id() => Group.t()}) :: boolean()
  defp review_site?(%Run{live: true, author: {:minga, _}, group: id}, _groups), do: is_integer(id)
  defp review_site?(%Run{live: true}, _groups), do: false

  defp review_site?(%Run{direct_gaps: [_ | _]} = run, groups) do
    inserted?(groups, run.group) and Enum.any?(run.direct_gaps, &active_minga_gap?(groups, &1))
  end

  defp review_site?(_run, _groups), do: false

  @spec active_minga_gap?(%{group_id() => Group.t()}, group_id()) :: boolean()
  defp active_minga_gap?(groups, id),
    do: match?(%Group{author: {:minga, _}, applied: true}, Map.fetch!(groups, id))

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
    |> unindex_review_site(run.id)
    |> unindex_strand_site(run)
    |> forget_changes(run)
    |> transfer_marks(run.overlaps)
  end

  # A draft is a tombstone a Minga step wrote that a newer applied step of the same task deleted, with both applied:
  # the task overwrote its own text. Drafts are indexed by their group, so compaction finds the oldest in O(log n).
  # Agent edits without a task are bounded by their own cap and are never drafts.
  @spec draft_key(Run.t(), %{group_id() => Group.t()}) :: {group_id(), Locator.t()} | nil
  defp draft_key(run, groups) do
    if compactible_partner(run, groups) != nil, do: {run.group, run.id}
  end

  @spec compactible_partner(Run.t(), %{group_id() => Group.t()}) :: group_id() | nil
  defp compactible_partner(%Run{live: false, group: owner, bytes: bytes} = run, groups)
       when owner != nil and bytes > 0 do
    case draft_partner(run, groups) do
      nil -> nil
      newer -> if merge_safe?(run, owner, newer), do: newer
    end
  end

  defp compactible_partner(_run, _groups), do: nil

  # The writer has to be newer than every retained undo and redo group, just as in compact_oldest/2.
  # The original touch order, including numbered overlaps, determines where the chain ends.
  @spec compactible_chain(Run.t(), %{group_id() => Group.t()}, non_neg_integer()) :: [group_id()]
  defp compactible_chain(%Run{live: false, group: owner, bytes: bytes} = run, groups, frontier)
       when is_integer(owner) and owner > frontier and bytes > 0 do
    case Map.get(groups, owner) do
      %Group{applied: true, author: {:minga, task} = author} when task != :untasked ->
        overlaps =
          run.overlaps
          |> Enum.flat_map(fn
            {_owner, id} when is_integer(id) -> [id]
            _permanent -> []
          end)
          |> Enum.sort()

        case chain_steps(Enum.reverse(run.deletions), groups, author, overlaps, [owner]) do
          [^owner] -> []
          chain -> chain
        end

      _other ->
        []
    end
  end

  defp compactible_chain(_run, _groups, _frontier), do: []

  @spec chain_steps([group_id()], %{group_id() => Group.t()}, author(), [group_id()], [group_id()]) ::
          [group_id()]
  defp chain_steps([], _groups, _author, _overlaps, chain), do: chain

  defp chain_steps([id | rest], groups, author, overlaps, [last | _] = chain) when id <= last,
    do: chain_steps(rest, groups, author, overlaps, chain)

  defp chain_steps([id | rest], groups, author, overlaps, [last | _] = chain) do
    overlaps = Enum.drop_while(overlaps, &(&1 <= last))

    case overlaps do
      [barrier | _] when barrier < id ->
        chain

      _no_barrier ->
        if newer_step?(Map.get(groups, id), author),
          do: chain_steps(rest, groups, author, overlaps, [id | chain]),
          else: chain
    end
  end

  # Intermediate run shapes in a discard are not compaction opportunities.
  @spec witness_settled_drafts(t()) :: t()
  defp witness_settled_drafts(%__MODULE__{settling_drafts: pending} = prov) do
    frontier = newest_yours(prov)

    links =
      Enum.reduce(pending, prov.witnessed_drafts, fn locator, links ->
        case RunTree.fetch(prov.tree, locator) do
          {:ok, run, _offset} ->
            link_draft_chain(links, compactible_chain(run, prov.groups, frontier))

          :error ->
            links
        end
      end)

    %{prov | settling_drafts: nil, witnessed_drafts: links}
  end

  # A retreat can expose old drafts without changing their runs.
  # Seek only the newly eligible range. Opening a user group never visits drafts.
  @spec retire_user_barriers(t(), [group_id()]) :: t()
  defp retire_user_barriers(%__MODULE__{user_groups: users} = prov, ids) do
    if :gb_sets.is_empty(users) do
      prov
    else
      install_user_barriers(prov, remove_all(users, ids))
    end
  end

  @spec install_user_barriers(t(), :gb_sets.set(group_id())) :: t()
  defp install_user_barriers(%__MODULE__{user_groups: users} = prov, users), do: prov

  defp install_user_barriers(prov, users) do
    old_frontier = newest_yours(prov)
    prov = %{prov | user_groups: users}
    frontier = newest_yours(prov)

    if frontier < old_frontier do
      iterator = :gb_sets.iterator_from({frontier + 1, []}, prov.drafts)
      links = witness_drafts(iterator, prov, frontier, old_frontier, prov.witnessed_drafts)
      %{prov | witnessed_drafts: links}
    else
      prov
    end
  end

  @spec witness_drafts(
          :gb_sets.iter(term()),
          t(),
          non_neg_integer(),
          non_neg_integer(),
          DraftLinks.t()
        ) :: DraftLinks.t()
  defp witness_drafts(iterator, prov, frontier, old_frontier, links) do
    case :gb_sets.next(iterator) do
      {{group, locator}, rest} when group <= old_frontier ->
        {:ok, run, _offset} = RunTree.fetch(prov.tree, locator)
        chain = compactible_chain(run, prov.groups, frontier)
        witness_drafts(rest, prov, frontier, old_frontier, link_draft_chain(links, chain))

      _beyond_retreat ->
        links
    end
  end

  @spec remember_draft_chain(t(), Run.t(), t()) :: t()
  defp remember_draft_chain(prov, run, before) do
    case compactible_chain(run, before.groups, newest_yours(before)) do
      [] -> prov
      chain -> %{prov | witnessed_drafts: link_draft_chain(prov.witnessed_drafts, chain)}
    end
  end

  @spec link_draft_chain(DraftLinks.t(), [group_id()]) :: DraftLinks.t()
  defp link_draft_chain(links, []), do: links

  defp link_draft_chain(links, [first | rest]),
    do: Enum.reduce(rest, links, &DraftLinks.link(&2, first, &1))

  @spec unpair_drafts(t(), group_id()) :: t()
  defp unpair_drafts(prov, id),
    do: %{prov | witnessed_drafts: DraftLinks.forget(prov.witnessed_drafts, id)}

  # The step a draft would merge into: the oldest newer applied step of the same task that deleted it, or `nil`.
  @spec draft_partner(Run.t(), %{group_id() => Group.t()}) :: group_id() | nil
  defp draft_partner(%Run{live: false, group: owner} = run, groups) when owner != nil do
    case Map.get(groups, owner) do
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
      nil ->
        %{prov | drafts: drafts}

      key ->
        prov = %{prov | drafts: :gb_sets.add(key, drafts)}
        record_draft_candidate(prov, run, newest_yours(prov))
    end
  end

  @spec record_draft_candidate(t(), Run.t(), non_neg_integer()) :: t()
  defp record_draft_candidate(prov, %Run{group: writer}, frontier) when writer <= frontier,
    do: prov

  defp record_draft_candidate(%__MODULE__{settling_drafts: nil} = prov, run, frontier) do
    chain = compactible_chain(run, prov.groups, frontier)
    %{prov | witnessed_drafts: link_draft_chain(prov.witnessed_drafts, chain)}
  end

  defp record_draft_candidate(prov, run, _frontier) do
    %{prov | settling_drafts: MapSet.put(prov.settling_drafts, run.id)}
  end

  # Rebuilds the draft index from every run, for the paths that rebuild the whole tree anyway.
  @spec index_drafts(t(), [Run.t()]) :: t()
  defp index_drafts(%__MODULE__{settling_drafts: nil} = prov, runs) do
    {keys, witnessed} =
      draft_index_entries(runs, prov.groups, newest_yours(prov), prov.witnessed_drafts)

    %{prov | drafts: :gb_sets.from_list(keys), witnessed_drafts: witnessed}
  end

  defp index_drafts(prov, runs) do
    frontier = newest_yours(prov)

    {keys, pending} =
      Enum.reduce(runs, {[], prov.settling_drafts}, fn run, {keys, pending} = acc ->
        case draft_key(run, prov.groups) do
          nil ->
            acc

          key ->
            {[key | keys], defer_draft_witness(pending, key, frontier)}
        end
      end)

    %{prov | drafts: :gb_sets.from_list(keys), settling_drafts: pending}
  end

  @spec defer_draft_witness(MapSet.t(Locator.t()), {group_id(), Locator.t()}, non_neg_integer()) ::
          MapSet.t(Locator.t())
  defp defer_draft_witness(pending, {writer, locator}, frontier) when writer > frontier,
    do: MapSet.put(pending, locator)

  defp defer_draft_witness(pending, _key, _frontier), do: pending

  @spec draft_index_entries(
          [Run.t()],
          %{group_id() => Group.t()},
          non_neg_integer(),
          DraftLinks.t()
        ) :: {[{group_id(), Locator.t()}], DraftLinks.t()}
  defp draft_index_entries(runs, groups, frontier, links) do
    Enum.reduce(runs, {[], links}, fn run, {keys, links} = acc ->
      case draft_key(run, groups) do
        nil ->
          acc

        key ->
          {[key | keys], link_draft_chain(links, compactible_chain(run, groups, frontier))}
      end
    end)
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
