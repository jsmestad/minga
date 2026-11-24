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

  defstruct tree: nil, groups: %{}, next_group: 1

  @opaque t :: %__MODULE__{
            tree: RunTree.t(),
            groups: %{Run.group_id() => Group.t()},
            next_group: pos_integer()
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

      true ->
        prov = prov |> split_at(start) |> split_at(start + removed_bytes)
        following = run_starting_at(prov.tree, start)
        preceding = preceding_run(prov.tree, following)
        prov = delete_from(prov, group_id, following, removed, 0)
        insert_between(prov, group_id, author, preceding, following, inserted_bytes)
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
  def blocker(%__MODULE__{groups: groups, tree: tree}, id) do
    Map.fetch!(groups, id).runs
    |> :gb_sets.to_list()
    |> Enum.find_value(fn run_id ->
      {:ok, run, _offset} = RunTree.fetch(tree, run_id)
      run |> later_deleters(id) |> Enum.find_value(&foreign_key(groups, &1, id))
    end)
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
        right_id = Locator.between(run.id, following && following.id)
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
  @spec delete_from(t(), group_id() | nil, Run.t() | nil, binary(), non_neg_integer()) :: t()
  defp delete_from(prov, _group_id, _run, removed, consumed) when consumed == byte_size(removed),
    do: prov

  defp delete_from(prov, group_id, %Run{live: true} = run, removed, consumed) do
    following = RunTree.next(prov.tree, run.id)
    text = binary_part(removed, consumed, run.bytes)

    prov
    |> mark_deleted(group_id, run, text)
    |> delete_from(group_id, following, removed, consumed + run.bytes)
  end

  defp delete_from(prov, group_id, %Run{} = run, removed, consumed) do
    following = RunTree.next(prov.tree, run.id)

    prov
    |> mark_deleted(group_id, run, run.text)
    |> delete_from(group_id, following, removed, consumed)
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
      id = Locator.between(preceding && preceding.id, following && following.id)
      run = %Run{id: id, bytes: bytes, author: author, group: group_id}
      groups = if group_id, do: add_run(prov.groups, group_id, id), else: prov.groups
      %{prov | tree: RunTree.insert(prov.tree, run), groups: groups}
    end
  end

  # ── Undo and reject ─────────────────────────────────────────────────

  @spec set_applied(t(), group_id(), boolean(), Document.t()) ::
          {:ok, Document.t(), non_neg_integer() | nil, t()} | {:error, :invalid_utf8}
  defp set_applied(prov, id, applied, document) do
    group = Map.fetch!(prov.groups, id)

    if group.applied == applied do
      {:ok, document, nil, prov}
    else
      prov = %{prov | groups: Map.put(prov.groups, id, %{group | applied: applied})}
      content = Document.content(document)

      # Visit runs from the end of the document to its start.
      # A run's offset never depends on the runs after it, so every change is located in the original document.
      # Prepending each change then leaves the list in document order.
      {changes, flipped} =
        group.runs
        |> :gb_sets.to_list()
        |> Enum.reverse()
        |> Enum.reduce({[], prov}, fn run_id, acc -> flip_run(acc, run_id, content) end)

      with {:ok, new_document} <- apply_changes(changes, content, document) do
        {:ok, new_document, first_offset(changes), flipped}
      end
    end
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

  @spec foreign_key(%{group_id() => Group.t()}, group_id(), group_id()) :: group_key() | nil
  defp foreign_key(_groups, id, id), do: nil

  defp foreign_key(groups, deleter, _id) do
    case Map.fetch!(groups, deleter) do
      %Group{applied: true, author: author, key: key} when author != :you -> key
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
