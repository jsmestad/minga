defmodule Minga.Buffer.DraftOrigins do
  @moduledoc """
  Writing step and time for the surviving bytes of a staged draft.

  The draft owner installs this projection with the exact content revision. Missing ranges make no claim about who wrote the bytes. An edit splits only the extents at its boundaries and shifts the suffix without visiting its ranges. Undo can restore the previous value with the previous bytes.
  """

  alias Minga.Buffer.Author
  alias Minga.Buffer.Document
  alias Minga.Buffer.FileMutation
  alias Minga.Buffer.Lines
  alias Minga.Buffer.Position
  alias Minga.Buffer.UndoPatch
  alias Minga.Core.Diff
  alias Minga.Core.LazyRowTree, as: Tree

  require Author

  @typedoc "An observed writing step and its wall time in milliseconds. A nil key means a known untasked edit."
  @type origin :: {Author.key() | nil, integer()}
  @type range :: {start :: non_neg_integer(), count :: pos_integer(), origin()}
  @typep owner :: origin() | {:base, non_neg_integer()}
  @typep extent :: {pos_integer(), owner()}
  @typep tree :: Tree.t(extent(), non_neg_integer())
  @opaque t :: {tree(), non_neg_integer()}

  @doc "Starts an untracked draft."
  @spec empty() :: t()
  def empty, do: {nil, 0}

  @doc "Tracks the original byte identities for a fork of a live buffer."
  @spec from_base(non_neg_integer()) :: t()
  def from_base(0), do: empty()
  def from_base(count) when count > 0, do: {leaf(0, {count, {:base, 0}}, 0), 1}

  @doc "Finds whole lines retained from the actual base bytes, including identical copies of a line."
  @spec base_lines(t(), Document.t(), Document.t()) :: [Diff.placement()]
  def base_lines({tree, _serial}, ancestor, fork) do
    fold_extents(tree, 0, Document.content_byte_size(fork), [], fn
      start, stop, {:base, base}, runs ->
        prepend_base_lines(ancestor, fork, base, start, stop - start, runs)

      _start, _stop, _writer, runs ->
        runs
    end)
    |> Enum.reverse()
  end

  @spec prepend_base_lines(
          Document.t(),
          Document.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          [Diff.placement()]
        ) :: [Diff.placement()]
  defp prepend_base_lines(ancestor, fork, old, new, size, runs) do
    {row, old_col} = Position.from_point(ancestor, old)
    {_, new_col} = Position.from_point(fork, new)
    first = if old_col == 0 and new_col == 0, do: row, else: row + 1
    leading_bytes = line_boundary(ancestor, first) - old

    if first < Document.line_count(ancestor) and leading_bytes < size do
      {fork_first, 0} = Position.from_point(fork, new + leading_bytes)
      {old_last, old_tail} = Position.from_point(ancestor, old + size)
      {new_last, new_tail} = Position.from_point(fork, new + size)

      whole_count = min(old_last - first, new_last - fork_first)

      count =
        if old_tail > 0 and new_tail > 0 and
             line_text_end(ancestor, old_last) == old + size and
             line_text_end(fork, new_last) == new + size,
           do: whole_count + 1,
           else: whole_count

      if count > 0, do: [{first, fork_first, count} | runs], else: runs
    else
      runs
    end
  end

  @spec line_text_end(Document.t(), non_neg_integer()) :: non_neg_integer()
  defp line_text_end(doc, row) do
    if row + 1 < Document.line_count(doc),
      do: Lines.start_of(doc, row + 1) - 1,
      else: Document.content_byte_size(doc)
  end

  @doc "Builds the net splices, in undo order, using the original bytes the fork actually retained."
  @spec splices_from_base(t(), binary(), binary()) :: [FileMutation.splice()]
  def splices_from_base({tree, _serial}, base, draft) do
    {old_at, new_at, splices} = base_splices(tree, base, draft, {0, 0, []})
    rest = add_splice(splices, base, old_at, byte_size(base), draft, new_at, byte_size(draft))
    Enum.reverse(rest)
  end

  @typep next_splice :: {non_neg_integer(), non_neg_integer(), [FileMutation.splice()]}
  @spec base_splices(tree(), binary(), binary(), next_splice()) :: next_splice()
  defp base_splices(nil, _base, _draft, acc), do: acc

  defp base_splices(tree, base, draft, acc) do
    %{key: key, value: {count, owner}, left: left, right: right} =
      Tree.view(tree, &shift_stop/2)

    {old_at, new_at, splices} = base_splices(left, base, draft, acc)

    next =
      case owner do
        {:base, old_start} ->
          splices = add_splice(splices, base, old_at, old_start, draft, new_at, key)
          {old_start + count, key + count, splices}

        _writer ->
          {old_at, new_at, splices}
      end

    base_splices(right, base, draft, next)
  end

  @spec add_splice(
          [FileMutation.splice()],
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [FileMutation.splice()]
  defp add_splice(splices, base, old_at, old_end, draft, new_at, new_end) do
    removed = binary_part(base, old_at, old_end - old_at)
    inserted = binary_part(draft, new_at, new_end - new_at)
    if removed == inserted, do: splices, else: [{old_at, removed, inserted} | splices]
  end

  @doc "Uses the selected merge's parent alignment to retain existing bytes and project the original fork writers."
  @spec replay(
          t(),
          Document.t(),
          Document.t(),
          Document.t(),
          binary(),
          [Diff.placement()],
          [Diff.parent_alignment()]
        ) :: {[FileMutation.splice()], [range()]}
  def replay({tree, _serial}, ancestor, parent, fork, bytes, placed, alignment) do
    result = Document.new(bytes)
    old = Document.content(parent)

    keep = fn {parent_at, result_at, count}, {old_at, new_at, splices} ->
      splices = add_splice(splices, old, old_at, parent_at, bytes, new_at, result_at)
      {parent_at + count, result_at + count, splices}
    end

    inputs = {ancestor, parent, fork, result, tree}

    {old_at, new_at, splices} =
      Enum.reduce(alignment, {0, 0, []}, &replay_region(&1, inputs, keep, &2))

    splices = add_splice(splices, old, old_at, byte_size(old), bytes, new_at, byte_size(bytes))
    {Enum.reverse(splices), project_document(tree, fork, result, placed)}
  end

  @typep byte_placement :: {non_neg_integer(), non_neg_integer(), pos_integer()}
  @typep replay_inputs :: {Document.t(), Document.t(), Document.t(), Document.t(), tree()}
  @typep retain_bytes :: (byte_placement(), next_splice() -> next_splice())
  @spec replay_region(Diff.parent_alignment(), replay_inputs(), retain_bytes(), next_splice()) ::
          next_splice()
  defp replay_region({:keep, {old_row, new_row, count}}, {_, parent, _, result, _}, keep, acc) do
    {from, into, size} = paired_lines(parent, old_row, result, new_row, count)
    if size > 0, do: keep.({from, into, size}, acc), else: acc
  end

  defp replay_region(
         {:replay, ancestor_row, parent_row, parent_count, fork_row, result_row, count},
         {ancestor, parent, fork, result, tree},
         keep,
         acc
       ) do
    {original, in_parent, old_size} =
      paired_lines(ancestor, ancestor_row, parent, parent_row, parent_count)

    {from, into, size} = paired_lines(fork, fork_row, result, result_row, count)

    fold_extents(tree, from, from + size, acc, fn
      start, stop, {:base, base}, acc ->
        first = max(base, original)
        last = min(base + stop - start, original + old_size)

        if first < last do
          parent_byte = in_parent + first - original
          result_byte = into + start - from + first - base
          keep.({parent_byte, result_byte, last - first}, acc)
        else
          acc
        end

      _start, _stop, _writer, acc ->
        acc
    end)
  end

  defp replay_region(
         {:reconcile, old_row, new_row, old_count, new_count},
         {_, parent, _, result, _},
         keep,
         acc
       ) do
    old_at = line_boundary(parent, old_row)
    new_at = line_boundary(result, new_row)
    old_end = line_boundary(parent, old_row + old_count)
    new_end = line_boundary(result, new_row + new_count)
    old = Document.slice_byte_range(parent, old_at, old_end - old_at)
    new = Document.slice_byte_range(result, new_at, new_end - new_at)

    {old_at, new_at, acc} =
      old_at
      |> UndoPatch.segment_changes(old, new, true)
      |> Enum.reduce({old_at, new_at, acc}, fn {from, removed, inserted}, {prev, into, acc} ->
        retained = from - prev
        acc = keep_bytes(keep, prev, into, retained, acc)
        {from + byte_size(removed), into + retained + byte_size(inserted), acc}
      end)

    keep_bytes(keep, old_at, new_at, old_end - old_at, acc)
  end

  @spec keep_bytes(
          retain_bytes(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          next_splice()
        ) ::
          next_splice()
  defp keep_bytes(_keep, _from, _into, 0, acc), do: acc
  defp keep_bytes(keep, from, into, count, acc), do: keep.({from, into, count}, acc)

  @spec paired_lines(
          Document.t(),
          non_neg_integer(),
          Document.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp paired_lines(source, source_row, result, result_row, count) do
    start = line_boundary(source, source_row)
    into = line_boundary(result, result_row)
    size = line_boundary(source, source_row + count) - start
    result_size = line_boundary(result, result_row + count) - into
    {start, into, min(size, result_size)}
  end

  @doc "Rebuilds the index from sorted, disjoint byte ranges validated at the draft boundary."
  @spec from_sorted([range()]) :: t()
  def from_sorted(ranges) do
    {entries, serial} =
      Enum.map_reduce(ranges, 0, fn {start, count, origin}, serial ->
        {{start, {count, origin}, :erlang.phash2(serial)}, serial + 1}
      end)

    {Tree.from_sorted(entries, &summarize/4), serial}
  end

  @doc "Names the observed writer, or makes no claim when the source is unavailable."
  @spec at(Minga.Buffer.EditSource.undo_source() | nil, integer()) :: origin() | nil
  def at(key, time) when Author.is_key(key), do: {key, time}
  def at(:agent, time), do: {nil, time}
  def at(_source, _time), do: nil

  @doc "Updates the live ranges using the coordinates accepted by the writer."
  @spec edited(t(), Document.t(), Document.t(), :whole, origin() | nil) :: t()
  @spec edited(
          t(),
          Document.t() | nil,
          Document.t() | nil,
          [FileMutation.splice()],
          origin() | nil
        ) ::
          t()
  def edited({nil, _serial} = ranges, _old, _new, _geometry, nil), do: ranges

  def edited(ranges, old, new, :whole, origin) do
    old
    |> UndoPatch.changes(new)
    |> Enum.reverse()
    |> Enum.reduce(ranges, fn patch, acc ->
      {start, removed, inserted} = UndoPatch.change(patch)

      UndoPatch.segment_changes(start, removed, inserted, true)
      |> Enum.reverse()
      |> Enum.reduce(acc, fn {at, before, after_edit}, ranges ->
        replace(ranges, at, byte_size(before), byte_size(after_edit), origin)
      end)
    end)
  end

  def edited(ranges, _old, _new, geometry, origin) when is_list(geometry) do
    geometry
    |> Enum.reverse()
    |> Enum.reduce(ranges, fn {start, removed, inserted}, acc ->
      replace(acc, start, byte_size(removed), byte_size(inserted), origin)
    end)
  end

  @doc "Transfers only original byte extents contained in line intervals the merge selected."
  @spec project(t(), Document.t(), binary(), [Diff.placement()]) :: [range()]
  def project({nil, _serial}, _source, _result, _placements), do: []
  def project(_origins, _source, _result, []), do: []

  def project({tree, _serial}, source, bytes, placements) do
    project_document(tree, source, Document.new(bytes), placements)
  end

  @spec project_document(tree(), Document.t(), Document.t(), [Diff.placement()]) :: [range()]
  defp project_document(tree, source, result, placements) do
    placements
    |> Enum.reduce([], fn {source_line, result_line, count}, ranges ->
      from = line_boundary(source, source_line)
      into = line_boundary(result, result_line)
      source_end = line_boundary(source, source_line + count)
      result_end = line_boundary(result, result_line + count)
      stop = from + min(source_end - from, result_end - into)

      # The selected line can begin with the separator written by the fork.
      # Do not project it twice if the preceding selected span already did.
      ranges =
        if from > 0 and into > 0 and after_last?(ranges, into - 1),
          do: collect(tree, from - 1, from, into - from, ranges),
          else: ranges

      collect(tree, from, stop, into - from, ranges)
    end)
    |> Enum.reverse()
  end

  @spec after_last?([range()], non_neg_integer()) :: boolean()
  defp after_last?([], _offset), do: true
  defp after_last?([{start, count, _origin} | _], offset), do: start + count <= offset

  @spec line_boundary(Document.t(), non_neg_integer()) :: non_neg_integer()
  defp line_boundary(document, line) do
    if line < Document.line_count(document),
      do: Lines.start_of(document, line),
      else: Document.content_byte_size(document)
  end

  @spec collect(tree(), non_neg_integer(), non_neg_integer(), integer(), [range()]) :: [range()]
  defp collect(tree, from, stop, shift, acc) do
    fold_extents(tree, from, stop, acc, fn first, last, owner, ranges ->
      add_origin(ranges, first + shift, last - first, owner)
    end)
  end

  @spec fold_extents(
          tree(),
          non_neg_integer(),
          non_neg_integer(),
          acc,
          (non_neg_integer(), non_neg_integer(), owner(), acc -> acc)
        ) :: acc
        when acc: var
  defp fold_extents(nil, _from, _stop, acc, _fold), do: acc
  defp fold_extents(_tree, byte, byte, acc, _fold), do: acc

  defp fold_extents(tree, from, stop, acc, fold) do
    if Tree.summary(tree) <= from do
      acc
    else
      %{key: start, value: {count, owner}, left: left, right: right} =
        Tree.view(tree, &shift_stop/2)

      acc = fold_extents(left, from, stop, acc, fold)

      if start < stop do
        first = max(start, from)
        last = min(start + count, stop)

        acc = fold_extent(first, last, start, owner, acc, fold)

        fold_extents(right, from, stop, acc, fold)
      else
        acc
      end
    end
  end

  @spec fold_extent(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          owner(),
          acc,
          (non_neg_integer(), non_neg_integer(), owner(), acc -> acc)
        ) :: acc
        when acc: var
  defp fold_extent(first, last, start, owner, acc, fold) when first < last do
    owner =
      case owner do
        {:base, base} -> {:base, base + first - start}
        writer -> writer
      end

    fold.(first, last, owner, acc)
  end

  defp fold_extent(_first, _last, _start, _owner, acc, _fold), do: acc

  @doc "Returns the observed origins sorted by starting byte."
  @spec ranges(t()) :: [range()]
  def ranges({tree, _serial}), do: ranges(tree, [])

  @spec ranges(tree(), [range()]) :: [range()]
  defp ranges(nil, acc), do: acc

  defp ranges(tree, acc) do
    %{key: key, value: {count, origin}, left: left, right: right} = Tree.view(tree, &shift_stop/2)
    ranges(left, add_origin(ranges(right, acc), key, count, origin))
  end

  @spec add_origin([range()], non_neg_integer(), integer(), owner()) :: [range()]
  defp add_origin(acc, _start, _count, {:base, _offset}), do: acc
  defp add_origin(acc, start, count, origin) when count > 0, do: [{start, count, origin} | acc]
  defp add_origin(acc, _start, _count, _origin), do: acc

  @spec replace(t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), origin() | nil) ::
          t()
  defp replace({nil, _serial} = ranges, _start, _count, _inserted, nil), do: ranges

  defp replace({tree, serial}, start, count, inserted, origin) do
    {left, rest, serial} = cut(tree, start, serial)
    {_overwritten, right, serial} = cut(rest, start + count, serial)
    right = Tree.shift(right, inserted - count, &shift_stop/2)

    case {inserted, origin} do
      {size, origin} when size > 0 and not is_nil(origin) ->
        middle = leaf(start, {size, origin}, serial)
        {join(join(left, middle), right), serial + 1}

      _ ->
        {join(left, right), serial}
    end
  end

  # A key split only partitions extent starts. Shorten the single extent that
  # crosses the boundary and install its tail on the right before shifting.
  @spec cut(tree(), non_neg_integer(), non_neg_integer()) :: {tree(), tree(), non_neg_integer()}
  defp cut(tree, start, serial) do
    {left, right} = Tree.split(tree, start, &summarize/4, &shift_stop/2)

    case Tree.summary(left) do
      stop when is_integer(stop) and stop > start ->
        {key, {count, origin}} = last(left)
        shortened = &{:replace, {start - key, elem(&1, 1)}}
        left = Tree.update(left, key, shortened, &summarize/4, &shift_stop/2)
        tail = leaf(start, {key + count - start, shift_owner(origin, start - key)}, serial)
        {left, join(tail, right), serial + 1}

      _ ->
        {left, right, serial}
    end
  end

  @spec shift_owner(owner(), non_neg_integer()) :: owner()
  defp shift_owner({:base, at}, count), do: {:base, at + count}
  defp shift_owner(origin, _count), do: origin

  @spec last(tree()) :: {non_neg_integer(), extent()}
  defp last(tree) do
    case Tree.view(tree, &shift_stop/2) do
      %{key: key, value: value, right: nil} -> {key, value}
      %{right: right} -> last(right)
    end
  end

  @spec leaf(non_neg_integer(), extent(), non_neg_integer()) :: tree()
  defp leaf(key, extent, serial) do
    Tree.leaf(key, extent, :erlang.phash2(serial), &summarize/4)
  end

  @spec join(tree(), tree()) :: tree()
  defp join(left, right), do: Tree.merge(left, right, &summarize/4, &shift_stop/2)

  @spec summarize(non_neg_integer(), extent(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          non_neg_integer()
  defp summarize(key, {count, _origin}, _left, right), do: right || key + count

  @spec shift_stop(non_neg_integer(), integer()) :: non_neg_integer()
  defp shift_stop(stop, shift), do: stop + shift
end
