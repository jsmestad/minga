defmodule MingaEditor.RenderModel.Window.ResidentStore do
  @moduledoc """
  Persistent indexed resident-row sequence.

  Rows are held in an implicit chunk treap weighted by visual rows and source
  line starts. A continuation contributes a visual row but no source start.
  Rank split/concatenation copies only the search paths and at-most-64-row
  boundary chunks; source positions in untouched payloads are projected on read.
  """

  alias Minga.RenderModel.Window.ContentDigest
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.RenderModel.Window.SourceOffsetMap

  @chunk_size 64
  @type entry :: %{
          required(:id) => term(),
          required(:content_hash) => non_neg_integer(),
          required(:payload) => term()
        }
  @type node_ref :: reference()
  @typep chunk :: {tuple(), binary()}
  @type tree ::
          nil
          | {:chunk, node_ref(), non_neg_integer(), pos_integer(), non_neg_integer(), tree(),
             chunk(), tree()}
  @type rank_node :: term()
  @type rank_header ::
          {rank_node() | nil, non_neg_integer(), non_neg_integer(), binary(), rank_node() | nil}
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

  @spec line_count(t()) :: non_neg_integer()
  def line_count(%__MODULE__{root: root}), do: tree_lines(root)

  @doc "Returns the visual rank of a source line start, including the exclusive EOF boundary."
  @spec visual_rank(t(), non_neg_integer()) :: non_neg_integer() | nil
  def visual_rank(%__MODULE__{root: root, size: size}, line) when line >= 0 do
    case tree_lines(root) do
      ^line -> size
      count when line < count -> select_start(root, line, &local_rank_header/1)
      _ -> nil
    end
  end

  @spec line_extent(t(), non_neg_integer()) :: {non_neg_integer(), pos_integer()} | nil
  def line_extent(store, line) do
    with first when is_integer(first) <- visual_rank(store, line),
         last when is_integer(last) <- visual_rank(store, line + 1) do
      {first, last - first}
    end
  end

  @spec anchor_at(t(), non_neg_integer()) :: {non_neg_integer(), non_neg_integer()} | nil
  def anchor_at(%__MODULE__{root: root, size: size}, rank) when rank >= 0 and rank < size,
    do: locate_anchor(root, rank, &local_rank_header/1)

  def anchor_at(_, _), do: nil

  @doc "Reads the normal payload at the start of a logical source line."
  @spec source_row(t(), non_neg_integer()) :: {:ok, VisualRow.t()} | :error
  def source_row(store, line) do
    case visual_rank(store, line) do
      rank when is_integer(rank) -> payload_at(store, rank)
      nil -> :error
    end
  end

  @doc "Projects a source byte to its absolute visual rank and display column."
  @spec source_position(t(), non_neg_integer(), non_neg_integer(), :start | :end) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def source_position(store, line, byte, affinity) do
    with {first, count} <- line_extent(store, line),
         {:ok, %VisualRow{} = start} <- payload_at(store, first) do
      project_source_position(store, start, first, first + count - 1, byte, affinity)
    else
      _ -> nil
    end
  end

  defp project_source_position(
         store,
         %VisualRow{source_offset_map: %{spans: [{:source, 0, _, 0, _}]}},
         first,
         last,
         byte,
         affinity
       ) do
    rank = endpoint_rank(store, first, last, byte, affinity, :source_end_byte)
    {:ok, entry} = payload_at(store, rank)
    {rank, VisualRow.plain_source_display_col(entry, byte)}
  end

  defp project_source_position(store, start, first, last, byte, affinity) do
    composed =
      SourceOffsetMap.source_to_composed_utf16(
        start.source_offset_map,
        byte,
        affinity
      )

    rank = endpoint_rank(store, first, last, composed, affinity, :composed_end_utf16)
    {:ok, entry} = payload_at(store, rank)
    {rank, VisualRow.display_col_at_composed(entry, composed)}
  end

  defp endpoint_rank(_store, first, last, _, _, _) when first >= last, do: last

  defp endpoint_rank(store, first, last, target, affinity, boundary) do
    mid = div(first + last, 2)
    {:ok, %{payload: entry}} = entry_at(store, mid)
    last_offset = Map.fetch!(entry, boundary)

    if target < last_offset or (affinity == :end and target == last_offset),
      do: endpoint_rank(store, first, mid, target, affinity, boundary),
      else: endpoint_rank(store, mid + 1, last, target, affinity, boundary)
  end

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
    case locate_rank(store.root, index, &local_rank_header/1) do
      {:ok, {:chunk, _, _, _, _, _, {entries, _}, _}, offset, line} ->
        {:ok, project_payload(elem(entries, offset).payload, line)}

      :error ->
        :error
    end
  end

  @doc "Returns the immutable root used by renderer-owned interaction indexes."
  @spec interaction_root(t()) :: tree()
  def interaction_root(%__MODULE__{root: root}), do: root

  @doc "Returns one immutable node projection for renderer-owned interaction indexes."
  @spec interaction_node(tree()) ::
          {:ok,
           {node_ref(), non_neg_integer(), non_neg_integer(), tree(), non_neg_integer(),
            non_neg_integer(), binary(), tuple(), tree()}}
          | :error
  def interaction_node({:chunk, ref, _, size, lines, left, {entries, starts}, right}) do
    {:ok, {ref, size, lines, left, tree_size(left), tree_lines(left), starts, entries, right}}
  end

  def interaction_node(nil), do: :error

  @doc "Locates a visual rank and its source line in a local or published tree."
  @spec locate_rank(rank_node() | nil, non_neg_integer(), (rank_node() ->
                                                             {:ok, rank_header()} | :error)) ::
          {:ok, rank_node(), non_neg_integer(), non_neg_integer()} | :error
  def locate_rank(root, index, header) when index >= 0, do: locate_rank(root, index, header, 0)
  def locate_rank(_root, _index, _header), do: :error

  defp locate_rank(nil, _index, _header, _lines), do: :error

  defp locate_rank(root, index, header, lines) do
    case header.(root) do
      {:ok, {left, left_size, _, _, _}} when index < left_size ->
        locate_rank(left, index, header, lines)

      {:ok, {_, left_size, left_lines, starts, _}}
      when index - left_size + 1 < byte_size(starts) ->
        offset = index - left_size
        {:ok, root, offset, lines + left_lines + :binary.at(starts, offset + 1) - 1}

      {:ok, {_, left_size, left_lines, starts, right}} ->
        own_size = byte_size(starts) - 1

        locate_rank(
          right,
          index - left_size - own_size,
          header,
          lines + left_lines + :binary.at(starts, own_size)
        )

      :error ->
        :error
    end
  end

  @doc "Selects a logical line's start using only chunk headers."
  @spec select_start(rank_node() | nil, non_neg_integer(), (rank_node() ->
                                                              {:ok, rank_header()} | :error)) ::
          non_neg_integer() | nil
  def select_start(root, line, header), do: select_start(root, line, header, 0)

  defp select_start(nil, _line, _header, _rank), do: nil

  defp select_start(root, line, header, rank) do
    case header.(root) do
      {:ok, {left, _, left_lines, _, _}} when line < left_lines ->
        select_start(left, line, header, rank)

      {:ok, {_, left_size, left_lines, starts, right}} ->
        own_size = byte_size(starts) - 1
        own_lines = :binary.at(starts, own_size)
        line = line - left_lines
        rank = rank + left_size

        if line < own_lines do
          rank + select_chunk_start(starts, line, 0, own_size)
        else
          select_start(right, line - own_lines, header, rank + own_size)
        end

      :error ->
        nil
    end
  end

  defp select_chunk_start(_starts, _line, first, last) when last - first <= 1, do: first

  defp select_chunk_start(starts, line, first, last) do
    mid = div(first + last, 2)

    if :binary.at(starts, mid) > line,
      do: select_chunk_start(starts, line, first, mid),
      else: select_chunk_start(starts, line, mid, last)
  end

  @doc "Projects a visual rank into a source line and continuation offset using headers only."
  @spec locate_anchor(rank_node() | nil, non_neg_integer(), (rank_node() ->
                                                               {:ok, rank_header()} | :error)) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def locate_anchor(root, rank, header) do
    with {:ok, _, _, line} <- locate_rank(root, rank, header),
         start when is_integer(start) <- select_start(root, line, header) do
      {line, rank - start}
    else
      _ -> nil
    end
  end

  @doc "Applies resident positional projection to one stored payload."
  @spec project_payload(term(), non_neg_integer()) :: term()
  def project_payload(%VisualRow{} = payload, line), do: VisualRow.reposition(payload, line)

  def project_payload(payload, _line), do: payload

  @spec payload_range(t(), non_neg_integer(), non_neg_integer()) :: [term()]
  def payload_range(%__MODULE__{} = store, start, count) do
    with {:ok, _, _, line} <- locate_rank(store.root, start, &local_rank_header/1),
         [first | rest] <- range_entries(store.root, start, count, []) do
      {rest, _line} =
        Enum.map_reduce(rest, line, fn entry, prior_line ->
          line = prior_line + start_weight(entry)
          {project_payload(entry.payload, line), line}
        end)

      [project_payload(first.payload, line) | rest]
    else
      _ ->
        []
    end
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

  defp chunk_node([], _salt), do: nil

  defp chunk_node(entries, salt) do
    {_, reversed} =
      Enum.reduce(entries, {0, [0]}, fn entry, {total, bytes} ->
        total = total + start_weight(entry)
        {total, [total | bytes]}
      end)

    chunk = {List.to_tuple(entries), reversed |> Enum.reverse() |> :erlang.list_to_binary()}
    node(:erlang.phash2({salt, hd(entries).id}), nil, chunk, nil)
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

  defp node(priority, left, {entries, starts} = chunk, right) do
    own_size = tuple_size(entries)
    lines = tree_lines(left) + :binary.at(starts, own_size) + tree_lines(right)

    {:chunk, make_ref(), priority, tree_size(left) + own_size + tree_size(right), lines, left,
     chunk, right}
  end

  defp merge(nil, right), do: right
  defp merge(left, nil), do: left

  defp merge({:chunk, _, lp, _, _, ll, le, lr} = left, {:chunk, _, rp, _, _, rl, re, rr} = right) do
    if lp <= rp, do: node(lp, ll, le, merge(lr, right)), else: node(rp, merge(left, rl), re, rr)
  end

  # Counted variants are used by persistent mutations. Each compared/rebuilt
  # treap node is one touched chunk; each boundary/insert chunk records the
  # exact number of rows copied into its new tuple.
  defp merge_counted(nil, right, work), do: {right, work}
  defp merge_counted(left, nil, work), do: {left, work}

  defp merge_counted(
         {:chunk, _, lp, _, _, ll, le, lr} = left,
         {:chunk, _, rp, _, _, rl, re, rr} = right,
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

  defp split_counted(nil, _rank, work), do: {nil, nil, work}
  defp split_counted(tree, rank, work) when rank <= 0, do: {nil, tree, work}

  defp split_counted(tree, rank, work) do
    if rank >= tree_size(tree) do
      {tree, nil, work}
    else
      do_split_counted(tree, rank, work)
    end
  end

  defp do_split_counted(
         {:chunk, _, priority, _, _, left, {entries, _} = chunk, right},
         rank,
         work
       ) do
    split_counted_chunk(
      priority,
      left,
      chunk,
      right,
      rank,
      tree_size(left),
      tuple_size(entries),
      touch_chunk(work)
    )
  end

  defp split_counted_chunk(priority, left, chunk, right, rank, left_size, _own, work)
       when rank < left_size do
    {a, b, work} = split_counted(left, rank, work)
    {a, node(priority, b, chunk, right), work}
  end

  defp split_counted_chunk(priority, left, chunk, right, rank, left_size, own, work)
       when rank > left_size + own do
    {a, b, work} = split_counted(right, rank - left_size - own, work)
    {node(priority, left, chunk, a), b, work}
  end

  defp split_counted_chunk(priority, left, {entries, _}, right, rank, left_size, _own, work) do
    within = rank - left_size
    {before, after_entries} = Enum.split(Tuple.to_list(entries), within)
    {before_chunk, work} = chunk_node_counted(before, {priority, :left, within}, work)
    {after_chunk, work} = chunk_node_counted(after_entries, {priority, :right, within}, work)
    {left_tree, work} = merge_counted(left, before_chunk, work)
    {right_tree, work} = merge_counted(after_chunk, right, work)
    {left_tree, right_tree, work}
  end

  defp lookup(root, index) do
    case locate_rank(root, index, &local_rank_header/1) do
      {:ok, {:chunk, _, _, _, _, _, {entries, _}, _}, offset, _line} ->
        {:ok, elem(entries, offset)}

      _ ->
        :error
    end
  end

  defp range_entries(_, _, count, acc) when count <= 0, do: acc
  defp range_entries(nil, _, _, acc), do: acc

  defp range_entries({:chunk, _, _, _, _, left, {entries, _}, right}, start, count, acc) do
    left_size = tree_size(left)
    own_size = tuple_size(entries)
    last = start + count
    right_start = left_size + own_size
    acc = range_entries(right, max(start - right_start, 0), last - max(start, right_start), acc)

    acc =
      prepend_entries(entries, max(start - left_size, 0), min(last - left_size, own_size), acc)

    range_entries(left, start, min(last, left_size) - start, acc)
  end

  defp prepend_entries(_, first, last, acc) when first >= last, do: acc

  defp prepend_entries(entries, first, last, acc),
    do: prepend_entries(entries, first, last - 1, [elem(entries, last - 1) | acc])

  defp tree_entries(tree, acc), do: range_entries(tree, 0, tree_size(tree), acc)

  defp tree_entries_counted(tree), do: {tree_entries(tree, []), chunk_count(tree)}

  defp empty_work,
    do: %{rows_visited: 0, rows_copied: 0, rows_emitted: 0, chunks_touched: 0}

  defp touch_chunk(work), do: %{work | chunks_touched: work.chunks_touched + 1}

  defp tree_size(nil), do: 0
  defp tree_size({:chunk, _, _, size, _, _, _, _}), do: size

  defp tree_lines(nil), do: 0
  defp tree_lines({:chunk, _, _, _, lines, _, _, _}), do: lines

  defp start_weight(%{payload: %VisualRow{row: %{row_type: :wrap_continuation}}}), do: 0
  defp start_weight(_), do: 1

  defp chunk_count(nil), do: 0

  defp chunk_count({:chunk, _, _, _, _, left, _, right}),
    do: 1 + chunk_count(left) + chunk_count(right)

  defp local_rank_header({:chunk, _, _, _, _, left, {_, starts}, right}),
    do: {:ok, {left, tree_size(left), tree_lines(left), starts, right}}

  defp digest_of(entries) do
    Enum.reduce(entries, ContentDigest.empty(), fn item, acc ->
      ContentDigest.add(acc, item.id, item.content_hash)
    end)
  end
end
