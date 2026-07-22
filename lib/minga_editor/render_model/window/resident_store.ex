defmodule MingaEditor.RenderModel.Window.ResidentStore do
  @moduledoc """
  Persistent indexed resident-row sequence.

  Rows are held in an implicit chunk treap. Rank split/concatenation copy only
  the search paths and the at-most-64-row boundary chunks; untouched prefix and
  suffix subtrees are shared verbatim. Buffer positions are therefore not
  stored eagerly in suffix payloads: `payload_at/2` and `payload_range/3`
  project positional metadata when a caller actually reads a row.
  """

  alias Minga.RenderModel.Window.ContentDigest
  alias MingaEditor.RenderModel.Window.VisualRow

  @chunk_size 64
  @type entry :: %{
          required(:id) => term(),
          required(:content_hash) => non_neg_integer(),
          required(:payload) => term()
        }
  @type tree :: nil | {:chunk, non_neg_integer(), pos_integer(), tree(), tuple(), tree()}
  @type work :: %{
          rows_visited: non_neg_integer(),
          rows_copied: non_neg_integer(),
          rows_emitted: non_neg_integer(),
          chunks_touched: non_neg_integer()
        }
  @type t :: %__MODULE__{
          root: tree(),
          size: non_neg_integer(),
          digest: ContentDigest.t(),
          work: work()
        }

  defstruct root: nil,
            size: 0,
            digest: 0,
            work: %{rows_visited: 0, rows_copied: 0, rows_emitted: 0, chunks_touched: 0}

  @spec new() :: t()
  def new, do: %__MODULE__{digest: ContentDigest.empty()}

  @spec entry(term(), non_neg_integer(), term()) :: entry()
  def entry(id, content_hash, payload),
    do: %{id: id, content_hash: content_hash, payload: payload}

  @spec from_entries([entry()]) :: t()
  def from_entries(entries) do
    root =
      entries
      |> Enum.chunk_every(@chunk_size)
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {chunk, ordinal}, tree -> merge(tree, chunk_node(chunk, ordinal)) end)

    %__MODULE__{
      root: root,
      size: length(entries),
      digest: digest_of(entries),
      work: %{
        rows_visited: length(entries),
        rows_copied: length(entries),
        rows_emitted: length(entries),
        chunks_touched: chunk_count(root)
      }
    }
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size
  @spec empty?(t()) :: boolean()
  def empty?(store), do: size(store) == 0
  @spec digest(t()) :: ContentDigest.t()
  def digest(%__MODULE__{digest: digest}), do: digest
  @spec work(t()) :: work()
  def work(%__MODULE__{work: work}), do: work

  @doc "Materializes all entries. Reserved for hydration/debug/oracle paths."
  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{root: root}), do: tree_entries(root, [])

  @doc "Materializes all projected payloads. Reserved for explicit full hydration."
  @spec payloads(t()) :: [term()]
  def payloads(store), do: payload_range(store, 0, store.size)

  @spec entry_at(t(), non_neg_integer()) :: {:ok, entry()} | :error
  def entry_at(%__MODULE__{root: root, size: size}, index) when index >= 0 and index < size,
    do: lookup(root, index)

  def entry_at(_, _), do: :error

  @spec payload_at(t(), non_neg_integer()) :: {:ok, term()} | :error
  def payload_at(store, index) do
    case entry_at(store, index) do
      {:ok, entry} -> {:ok, project_payload(entry.payload, index)}
      :error -> :error
    end
  end

  @spec payload_range(t(), non_neg_integer(), non_neg_integer()) :: [term()]
  def payload_range(%__MODULE__{} = store, start, count) do
    range_entries(store.root, start, count)
    |> Enum.with_index(start)
    |> Enum.map(fn {entry, index} -> project_payload(entry.payload, index) end)
  end

  @doc "Persistent rank splice. Only boundary/search chunks are copied."
  @spec replace_range(t(), non_neg_integer(), non_neg_integer(), [entry()]) :: t()
  def replace_range(%__MODULE__{} = store, start, delete_count, inserted) do
    start = min(start, store.size)
    delete_count = min(delete_count, store.size - start)
    work = empty_work()
    {left, tail, work} = split_counted(store.root, start, work)
    {removed, right, work} = split_counted(tail, delete_count, work)
    {removed_entries, removed_chunks} = tree_entries_counted(removed)

    work = %{
      work
      | rows_visited: length(removed_entries) + length(inserted),
        rows_emitted: length(inserted),
        chunks_touched: work.chunks_touched + removed_chunks
    }

    {inserted_tree, work} =
      inserted
      |> Enum.chunk_every(@chunk_size)
      |> Enum.with_index()
      |> Enum.reduce({nil, work}, fn {chunk, ordinal}, {tree, acc} ->
        {new_chunk, acc} = chunk_node_counted(chunk, {start, ordinal, store.size}, acc)
        merge_counted(tree, new_chunk, acc)
      end)

    digest =
      removed_entries
      |> Enum.reduce(store.digest, fn item, acc ->
        ContentDigest.remove(acc, item.id, item.content_hash)
      end)
      |> then(fn value ->
        Enum.reduce(inserted, value, fn item, acc ->
          ContentDigest.add(acc, item.id, item.content_hash)
        end)
      end)

    {joined, work} = merge_counted(left, inserted_tree, work)
    {root, work} = merge_counted(joined, right, work)

    %{
      store
      | root: root,
        size: store.size - delete_count + length(inserted),
        digest: digest,
        work: work
    }
  end

  @spec replace_at(t(), non_neg_integer(), entry()) :: t()
  def replace_at(store, index, item),
    do: if(index < store.size, do: replace_range(store, index, 1, [item]), else: store)

  @spec insert_at(t(), non_neg_integer(), entry()) :: t()
  def insert_at(store, index, item), do: replace_range(store, index, 0, [item])
  @spec delete_at(t(), non_neg_integer()) :: t()
  def delete_at(store, index),
    do: if(index < store.size, do: replace_range(store, index, 1, []), else: store)

  @spec rebuild(t(), MapSet.t(non_neg_integer()), (non_neg_integer() -> entry())) :: t()
  def rebuild(store, dirty, fun) do
    dirty
    |> Enum.sort()
    |> Enum.reduce(store, fn index, acc -> replace_at(acc, index, fun.(index)) end)
  end

  defp project_payload(%VisualRow{} = payload, index), do: VisualRow.reposition(payload, index)

  defp project_payload(payload, _index), do: payload

  defp chunk_node([], _salt), do: nil

  defp chunk_node(entries, salt) do
    tuple = List.to_tuple(entries)
    {:chunk, :erlang.phash2({salt, hd(entries).id}), tuple_size(tuple), nil, tuple, nil}
  end

  defp chunk_node_counted([], _salt, work), do: {nil, work}

  defp chunk_node_counted(entries, salt, work) do
    work = %{
      work
      | rows_copied: work.rows_copied + length(entries),
        chunks_touched: work.chunks_touched + 1
    }

    {chunk_node(entries, salt), work}
  end

  defp node(priority, left, tuple, right),
    do:
      {:chunk, priority, tree_size(left) + tuple_size(tuple) + tree_size(right), left, tuple,
       right}

  defp merge(nil, right), do: right
  defp merge(left, nil), do: left

  defp merge({:chunk, lp, _, ll, le, lr} = left, {:chunk, rp, _, rl, re, rr} = right) do
    if lp <= rp, do: node(lp, ll, le, merge(lr, right)), else: node(rp, merge(left, rl), re, rr)
  end

  # Counted variants are used by persistent mutations. Each compared/rebuilt
  # treap node is one touched chunk; each boundary/insert chunk records the
  # exact number of rows copied into its new tuple.
  defp merge_counted(nil, right, work), do: {right, work}
  defp merge_counted(left, nil, work), do: {left, work}

  defp merge_counted(
         {:chunk, lp, _, ll, le, lr} = left,
         {:chunk, rp, _, rl, re, rr} = right,
         work
       ) do
    work = touch_chunk(work)

    if lp <= rp do
      {merged, work} = merge_counted(lr, right, work)
      {node(lp, ll, le, merged), work}
    else
      {merged, work} = merge_counted(left, rl, work)
      {node(rp, merged, re, rr), work}
    end
  end

  defp split(nil, _rank), do: {nil, nil, 0}
  defp split(tree, rank) when rank <= 0, do: {nil, tree, 0}

  defp split(tree, rank) do
    if rank >= tree_size(tree) do
      {tree, nil, 0}
    else
      do_split(tree, rank)
    end
  end

  defp do_split({:chunk, priority, _, left, entries, right}, rank) do
    split_chunk(priority, left, entries, right, rank, tree_size(left), tuple_size(entries))
  end

  defp split_chunk(priority, left, entries, right, rank, left_size, _own)
       when rank < left_size do
    {a, b, touched} = split(left, rank)
    {a, node(priority, b, entries, right), touched + 1}
  end

  defp split_chunk(priority, left, entries, right, rank, left_size, own)
       when rank > left_size + own do
    {a, b, touched} = split(right, rank - left_size - own)
    {node(priority, left, entries, a), b, touched + 1}
  end

  defp split_chunk(priority, left, entries, right, rank, left_size, own) do
    within = rank - left_size
    before = tuple_slice(entries, 0, within)
    after_entries = tuple_slice(entries, within, own - within)
    left_tree = merge(left, chunk_node(Tuple.to_list(before), {priority, :left, within}))

    right_tree =
      merge(chunk_node(Tuple.to_list(after_entries), {priority, :right, within}), right)

    {left_tree, right_tree, 1}
  end

  defp split_counted(nil, _rank, work), do: {nil, nil, work}
  defp split_counted(tree, rank, work) when rank <= 0, do: {nil, tree, work}

  defp split_counted(tree, rank, work) do
    if rank >= tree_size(tree) do
      {tree, nil, work}
    else
      do_split_counted(tree, rank, work)
    end
  end

  defp do_split_counted({:chunk, priority, _, left, entries, right}, rank, work) do
    split_counted_chunk(
      priority,
      left,
      entries,
      right,
      rank,
      tree_size(left),
      tuple_size(entries),
      touch_chunk(work)
    )
  end

  defp split_counted_chunk(priority, left, entries, right, rank, left_size, _own, work)
       when rank < left_size do
    {a, b, work} = split_counted(left, rank, work)
    {a, node(priority, b, entries, right), work}
  end

  defp split_counted_chunk(priority, left, entries, right, rank, left_size, own, work)
       when rank > left_size + own do
    {a, b, work} = split_counted(right, rank - left_size - own, work)
    {node(priority, left, entries, a), b, work}
  end

  defp split_counted_chunk(priority, left, entries, right, rank, left_size, own, work) do
    within = rank - left_size
    before = entries |> tuple_slice(0, within) |> Tuple.to_list()
    after_entries = entries |> tuple_slice(within, own - within) |> Tuple.to_list()
    {before_chunk, work} = chunk_node_counted(before, {priority, :left, within}, work)
    {after_chunk, work} = chunk_node_counted(after_entries, {priority, :right, within}, work)
    {left_tree, work} = merge_counted(left, before_chunk, work)
    {right_tree, work} = merge_counted(after_chunk, right, work)
    {left_tree, right_tree, work}
  end

  defp lookup({:chunk, _, _, left, entries, right}, index),
    do: lookup_chunk(left, entries, right, index, tree_size(left))

  defp lookup_chunk(left, _entries, _right, index, left_size) when index < left_size,
    do: lookup(left, index)

  defp lookup_chunk(_left, entries, _right, index, left_size)
       when index < left_size + tuple_size(entries),
       do: {:ok, elem(entries, index - left_size)}

  defp lookup_chunk(_left, entries, right, index, left_size),
    do: lookup(right, index - left_size - tuple_size(entries))

  defp range_entries(_tree, _start, count) when count <= 0, do: []
  defp range_entries(nil, _start, _count), do: []

  defp range_entries(tree, start, count) do
    {_left, tail, _} = split(tree, max(start, 0))
    {wanted, _right, _} = split(tail, count)
    tree_entries(wanted, [])
  end

  defp tree_entries(nil, acc), do: acc

  defp tree_entries({:chunk, _, _, left, entries, right}, acc) do
    left_entries = tree_entries(left, [])
    right_entries = tree_entries(right, [])
    acc ++ left_entries ++ Tuple.to_list(entries) ++ right_entries
  end

  defp tree_entries_counted(tree), do: {tree_entries(tree, []), chunk_count(tree)}

  defp empty_work,
    do: %{rows_visited: 0, rows_copied: 0, rows_emitted: 0, chunks_touched: 0}

  defp touch_chunk(work), do: %{work | chunks_touched: work.chunks_touched + 1}

  defp tree_size(nil), do: 0
  defp tree_size({:chunk, _, size, _, _, _}), do: size
  defp chunk_count(nil), do: 0
  defp chunk_count({:chunk, _, _, left, _, right}), do: 1 + chunk_count(left) + chunk_count(right)
  defp tuple_slice(_tuple, _start, 0), do: {}

  defp tuple_slice(tuple, start, count),
    do: tuple |> Tuple.to_list() |> Enum.slice(start, count) |> List.to_tuple()

  defp digest_of(entries) do
    Enum.reduce(entries, ContentDigest.empty(), fn item, acc ->
      ContentDigest.add(acc, item.id, item.content_hash)
    end)
  end
end
