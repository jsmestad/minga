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

  defstruct tree: nil, groups: %{}, next_group: 1, deep: false, recent: [], fresh: []

  @opaque t :: %__MODULE__{
            tree: RunTree.t(),
            groups: %{Run.group_id() => Group.t()},
            next_group: pos_integer(),
            deep: boolean(),
            recent: [Locator.t()],
            fresh: [Locator.t()]
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

        prov
        |> cover_replaced(group_id, last, left, following)
        |> insert_between(group_id, author, preceding, following, inserted_bytes)
        |> renumber_when_deep()
        |> remember_fresh()
    end
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
    prov = %{prov | groups: groups}

    group.runs
    |> :gb_sets.to_list()
    |> Enum.reduce(prov, fn run_id, prov -> settle_run(prov, run_id, id, group.applied) end)
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
        run_start < start and start + removed_bytes <= run_start + run.bytes

      _other ->
        false
    end
  end

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
    |> kill_run(group_id, dead, removed)
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
        %{prov | tree: tree, groups: groups}

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

  # A deletion that consumes another group's replacement also deletes the text that replacement replaced.
  # A replacement is one edit's inserted text followed by the tombstones it made, so the deletion consumes one when it
  # ends with that group's text and does not start inside the same replacement. It then marks that replacement's
  # tombstones, which are the dead runs right after it that the group deleted.
  @spec cover_replaced(t(), group_id() | nil, Run.t() | nil, Run.t() | nil, Run.t() | nil) :: t()
  defp cover_replaced(prov, _group_id, nil, _left, _first), do: prov
  defp cover_replaced(prov, _group_id, %Run{group: nil}, _left, _first), do: prov

  defp cover_replaced(prov, group_id, %Run{group: owner} = last, left, first) do
    if inside_replacement?(prov.tree, left, first, owner),
      do: prov,
      else: cover_tombstones(prov, group_id, owner, RunTree.next(prov.tree, last.id))
  end

  # The deletion starts inside the replacement when the live text before it belongs to the same group and no tombstone
  # of that group separates them; such a tombstone ends one replacement before the next begins.
  @spec inside_replacement?(RunTree.t(), Run.t() | nil, Run.t(), group_id()) :: boolean()
  defp inside_replacement?(tree, %Run{group: owner} = left, first, owner),
    do: not separated?(tree, RunTree.next(tree, left.id), first.id, owner)

  defp inside_replacement?(_tree, _left, _first, _owner), do: false

  @spec separated?(RunTree.t(), Run.t() | nil, Locator.t(), group_id()) :: boolean()
  defp separated?(tree, %Run{id: id} = run, first_id, owner) when id < first_id,
    do: owner in run.deletions or separated?(tree, RunTree.next(tree, id), first_id, owner)

  defp separated?(_tree, _run_or_first, _first_id, _owner), do: false

  # The replacement's tombstones are contiguous, so the walk ends at the first run that is live, inserted by the same
  # group, or not deleted by it. The cost is the size of that replacement, however many tombstones lie beyond it.
  @spec cover_tombstones(t(), group_id() | nil, group_id(), Run.t() | nil) :: t()
  defp cover_tombstones(prov, _group_id, owner, %Run{group: owner}), do: prov

  defp cover_tombstones(prov, group_id, owner, %Run{live: false} = run) do
    if owner in run.deletions do
      following = RunTree.next(prov.tree, run.id)

      prov
      |> mark_deleted(group_id, run, run.text)
      |> cover_tombstones(group_id, owner, following)
    else
      prov
    end
  end

  defp cover_tombstones(prov, _group_id, _owner, _live_or_end), do: prov

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

    tree =
      runs
      |> Enum.zip(ids)
      |> Enum.map(fn {run, id} -> %{run | id: id} end)
      |> RunTree.from_list()

    # Renumbering keeps order, so each group's sorted locators stay sorted.
    groups =
      Map.new(prov.groups, fn {id, group} ->
        locators = group.runs |> :gb_sets.to_list() |> Enum.map(&Map.fetch!(renamed, &1))
        {id, %{group | runs: :gb_sets.from_ordset(locators)}}
      end)

    %{prov | tree: tree, groups: groups, deep: false, recent: [], fresh: []}
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
  defp mark_deleted(prov, nil, run, _text), do: drop_run(prov, run)
  defp mark_deleted(prov, group_id, %Run{group: group_id} = run, _text), do: drop_run(prov, run)

  defp mark_deleted(prov, group_id, run, text) do
    if group_id in run.deletions,
      do: prov,
      else: kill_run(prov, group_id, run, text)
  end

  @spec kill_run(t(), group_id(), Run.t(), binary()) :: t()
  defp kill_run(prov, group_id, run, text) do
    run = %{run | deletions: [group_id | run.deletions], live: false, text: own(text)}

    %{
      prov
      | tree: RunTree.update(prov.tree, run),
        groups: add_run(prov.groups, group_id, run.id)
    }
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
        next_offset = offset + Run.live_bytes(run)

        case {run.live, live?(run, prov.groups)} do
          {same, same} ->
            {[run | runs], changes, next_offset}

          {false, true} ->
            {[%{run | live: true, text: nil} | runs], [{offset, 0, run.text} | changes],
             next_offset}

          {true, false} ->
            text = :binary.copy(binary_part(content, offset, run.bytes))

            {[%{run | live: false, text: text} | runs], [{offset, run.bytes, ""} | changes],
             next_offset}
        end
      end)

    {Enum.reverse(changes), %{prov | tree: runs |> Enum.reverse() |> RunTree.from_list()}}
  end

  # A change is `{offset, removed_bytes, inserted_text}` in the original document.
  @spec flip_run({[change()], t()}, Locator.t(), binary()) :: {[change()], t()}
  defp flip_run({changes, prov}, run_id, content) do
    {:ok, run, offset} = RunTree.fetch(prov.tree, run_id)

    case {run.live, live?(run, prov.groups)} do
      {same, same} ->
        {changes, prov}

      {false, true} ->
        {[{offset, 0, run.text} | changes], put_run(prov, %{run | live: true, text: nil})}

      {true, false} ->
        text = :binary.copy(binary_part(content, offset, run.bytes))
        {[{offset, run.bytes, ""} | changes], put_run(prov, %{run | live: false, text: text})}
    end
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

  @spec settle_run(t(), Locator.t(), group_id(), boolean()) :: t()
  defp settle_run(prov, run_id, id, applied) do
    {:ok, run, _offset} = RunTree.fetch(prov.tree, run_id)

    cond do
      run.group == id and applied -> prov |> put_run(%{run | group: nil}) |> coalesce(run_id)
      applied or run.group == id -> drop_run(prov, run)
      true -> put_run(prov, %{run | deletions: List.delete(run.deletions, id)})
    end
  end

  # Applies `settle_run/4`'s rules for every discarded group to every run in order, merging permanent neighbours, then
  # rebuilds the tree and the remaining groups' run sets from the result.
  @spec discard_in_one_pass(t(), [group_id()]) :: t()
  defp discard_in_one_pass(prov, ids) do
    {discarded, groups} = Map.split(prov.groups, ids)
    applied = for {id, %Group{applied: true}} <- discarded, into: MapSet.new(), do: id

    runs =
      prov.tree
      |> RunTree.to_list()
      |> Enum.reduce([], fn run, acc -> settle_in_pass(run, discarded, applied, acc) end)
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

    %{prov | tree: RunTree.from_list(runs), groups: groups}
  end

  @spec settle_in_pass(Run.t(), %{group_id() => Group.t()}, MapSet.t(group_id()), [Run.t()]) ::
          [Run.t()]
  defp settle_in_pass(run, discarded, applied, acc) do
    cond do
      Map.has_key?(discarded, run.group) and not MapSet.member?(applied, run.group) -> acc
      Enum.any?(run.deletions, &MapSet.member?(applied, &1)) -> acc
      true -> merge_permanent(settled_run(run, discarded), acc)
    end
  end

  @spec settled_run(Run.t(), %{group_id() => Group.t()}) :: Run.t()
  defp settled_run(run, discarded) do
    group = if Map.has_key?(discarded, run.group), do: nil, else: run.group
    %{run | group: group, deletions: Enum.reject(run.deletions, &Map.has_key?(discarded, &1))}
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

  # ── Bookkeeping ─────────────────────────────────────────────────────

  @spec put_run(t(), Run.t()) :: t()
  defp put_run(prov, run), do: %{prov | tree: RunTree.update(prov.tree, run)}

  @spec drop_run(t(), Run.t()) :: t()
  defp drop_run(prov, run) do
    groups = Enum.reduce(run_groups(run), prov.groups, &remove_run(&2, &1, run.id))
    %{prov | tree: RunTree.delete(prov.tree, run.id), groups: groups}
  end

  @spec run_groups(Run.t()) :: [group_id()]
  defp run_groups(%Run{group: nil, deletions: deletions}), do: deletions
  defp run_groups(%Run{group: group, deletions: deletions}), do: [group | deletions]

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
