defmodule Minga.RenderModel.Window.LineIdentity do
  @moduledoc """
  Persistent durable identity rope for logical buffer lines.

  The rope is an AVL tree whose leaves are contiguous source-id runs. Nodes cache
  logical size and height, so line count is O(1), rank lookup and splices are
  O(log runs), and unchanged subtrees are structurally shared. Adjacent source-id
  runs are coalesced after every concatenation.
  """

  alias Minga.Buffer.EditDelta

  @max_source_id 0xFFFF_FFFF
  @max_epoch 0xFFFF_FFFF

  @typep rope ::
           nil
           | {:run, non_neg_integer(), pos_integer()}
           | {:node, rope(), rope(), pos_integer(), pos_integer()}
  @type source_id :: non_neg_integer()

  @enforce_keys [:content_epoch, :root, :next_source_id]
  defstruct content_epoch: 0, root: nil, next_source_id: 0

  @opaque t :: %__MODULE__{
            content_epoch: non_neg_integer(),
            root: rope(),
            next_source_id: non_neg_integer()
          }
  @type transition :: {:ok, t()} | :reset_required

  @doc "Creates an identity rope for the current logical-line count."
  @spec new(non_neg_integer(), non_neg_integer()) :: t()
  def new(line_count, content_epoch \\ 1)
      when is_integer(line_count) and line_count >= 0 and line_count <= @max_source_id + 1 and
             is_integer(content_epoch) and content_epoch >= 0 and content_epoch <= @max_epoch do
    %__MODULE__{
      content_epoch: content_epoch,
      root: run(0, line_count),
      next_source_id: line_count
    }
  end

  @doc "Starts a new content epoch, intentionally permitting source-id reuse."
  @spec reset(t() | nil, non_neg_integer(), non_neg_integer()) :: t()
  def reset(_identity, line_count, content_epoch), do: new(line_count, content_epoch)

  @doc "Returns the durable source id at a zero-based logical-line rank."
  @spec source_id(t(), non_neg_integer()) :: {:ok, source_id()} | :error
  def source_id(%__MODULE__{} = identity, line) when is_integer(line) and line >= 0 do
    lookup(identity.root, line)
  end

  @doc "Returns the content epoch owning this identity rope."
  @spec content_epoch(t()) :: non_neg_integer()
  def content_epoch(%__MODULE__{content_epoch: epoch}), do: epoch

  @doc "Returns the number of current logical lines in O(1)."
  @spec line_count(t()) :: non_neg_integer()
  def line_count(%__MODULE__{root: root}), do: size(root)

  @doc "Returns the number of contiguous source-id runs for invariant checks."
  @spec run_count(t()) :: non_neg_integer()
  def run_count(%__MODULE__{root: root}), do: count_runs(root)

  @doc "Returns the cached AVL height for invariant checks."
  @spec height(t()) :: non_neg_integer()
  def height(%__MODULE__{root: root}), do: node_height(root)

  @doc "Materializes source ids in rank order for diagnostics and tests."
  @spec source_ids(t()) :: [source_id()]
  def source_ids(%__MODULE__{root: root}), do: to_list(root, [])

  @doc "Applies one document edit to the durable identity rope."
  @spec apply_edit(t(), EditDelta.t()) :: transition()
  def apply_edit(%__MODULE__{} = identity, %EditDelta{} = delta) do
    with :ok <- validate_positions(identity, delta) do
      apply_valid_edit(identity, delta)
    end
  end

  @doc "Applies edits in order, stopping transactionally when reconciliation fails."
  @spec apply_edits(t(), [EditDelta.t()]) :: transition()
  def apply_edits(%__MODULE__{} = identity, deltas) when is_list(deltas) do
    Enum.reduce_while(deltas, {:ok, identity}, fn delta, {:ok, current} ->
      case apply_edit(current, delta) do
        {:ok, next} -> {:cont, {:ok, next}}
        :reset_required -> {:halt, :reset_required}
      end
    end)
  end

  @spec validate_positions(t(), EditDelta.t()) :: :ok | :reset_required
  defp validate_positions(%__MODULE__{} = identity, %EditDelta{} = delta) do
    {start_line, start_col} = delta.start_position
    {old_end_line, old_end_col} = delta.old_end_position
    {new_end_line, new_end_col} = delta.new_end_position
    count = line_count(identity)

    if start_line < count and old_end_line < count and start_line <= old_end_line and
         start_line <= new_end_line and start_col >= 0 and old_end_col >= 0 and new_end_col >= 0,
       do: :ok,
       else: :reset_required
  end

  @spec apply_valid_edit(t(), EditDelta.t()) :: transition()
  defp apply_valid_edit(%__MODULE__{} = identity, %EditDelta{
         start_position: {start_line, 0},
         old_end_position: {old_end_line, 0},
         new_end_position: {new_end_line, 0}
       }) do
    splice(identity, start_line, old_end_line - start_line, new_end_line - start_line)
  end

  defp apply_valid_edit(%__MODULE__{} = identity, %EditDelta{} = delta) do
    {start_line, _} = delta.start_position
    {old_end_line, _} = delta.old_end_position
    {new_end_line, _} = delta.new_end_position
    splice(identity, start_line + 1, old_end_line - start_line, new_end_line - start_line)
  end

  @spec splice(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: transition()
  defp splice(identity, rank, delete_count, insert_count) do
    with {:ok, inserted, next_source_id} <- allocate(identity.next_source_id, insert_count) do
      {prefix, tail} = split(identity.root, rank)
      {_deleted, suffix} = split(tail, delete_count)
      root = concat(concat(prefix, inserted), suffix)
      {:ok, %{identity | root: root, next_source_id: next_source_id}}
    end
  end

  @spec allocate(non_neg_integer(), non_neg_integer()) ::
          {:ok, rope(), non_neg_integer()} | :reset_required
  defp allocate(next_source_id, 0), do: {:ok, nil, next_source_id}

  defp allocate(next_source_id, count)
       when next_source_id <= @max_source_id and count <= @max_source_id - next_source_id + 1 do
    {:ok, {:run, next_source_id, count}, next_source_id + count}
  end

  defp allocate(_next_source_id, _count), do: :reset_required

  @spec lookup(rope(), non_neg_integer()) :: {:ok, source_id()} | :error
  defp lookup(nil, _rank), do: :error
  defp lookup({:run, start, length}, rank) when rank < length, do: {:ok, start + rank}
  defp lookup({:run, _start, _length}, _rank), do: :error

  defp lookup({:node, left, right, _size, _height}, rank) do
    left_size = size(left)
    if rank < left_size, do: lookup(left, rank), else: lookup(right, rank - left_size)
  end

  @spec split(rope(), non_neg_integer()) :: {rope(), rope()}
  defp split(nil, _rank), do: {nil, nil}
  defp split(tree, 0), do: {nil, tree}
  defp split(tree, rank), do: split_with_size(tree, rank, size(tree))

  @spec split_with_size(rope(), non_neg_integer(), non_neg_integer()) :: {rope(), rope()}
  defp split_with_size(tree, rank, tree_size) when rank >= tree_size, do: {tree, nil}

  defp split_with_size({:run, start, length}, rank, _tree_size) do
    {run(start, rank), run(start + rank, length - rank)}
  end

  defp split_with_size({:node, left, right, _size, _height}, rank, _tree_size) do
    left_size = size(left)

    if rank < left_size do
      {before, after_left} = split(left, rank)
      {before, concat(after_left, right)}
    else
      {before_right, remainder} = split(right, rank - left_size)
      {concat(left, before_right), remainder}
    end
  end

  @spec concat(rope(), rope()) :: rope()
  defp concat(nil, right), do: right
  defp concat(left, nil), do: left

  defp concat(left, right) do
    {{left_start, left_length}, left_rest} = pop_last(left)
    {{right_start, right_length}, right_rest} = pop_first(right)

    if left_start + left_length == right_start do
      join(join(left_rest, {:run, left_start, left_length + right_length}), right_rest)
    else
      join(
        join(left_rest, {:run, left_start, left_length}),
        join({:run, right_start, right_length}, right_rest)
      )
    end
  end

  @spec join(rope(), rope()) :: rope()
  defp join(nil, right), do: right
  defp join(left, nil), do: left

  defp join(left, right) do
    join_by_height(left, right, node_height(left), node_height(right))
  end

  @spec join_by_height(rope(), rope(), pos_integer(), pos_integer()) :: rope()
  defp join_by_height(left, right, left_height, right_height)
       when left_height > right_height + 1 do
    {:node, ll, lr, _size, _height} = left
    balance(ll, join(lr, right))
  end

  defp join_by_height(left, right, left_height, right_height)
       when right_height > left_height + 1 do
    {:node, rl, rr, _size, _height} = right
    balance(join(left, rl), rr)
  end

  defp join_by_height(left, right, _left_height, _right_height), do: node(left, right)

  @spec balance(rope(), rope()) :: rope()
  defp balance(left, right) do
    balance_by_height(left, right, node_height(left), node_height(right))
  end

  @spec balance_by_height(rope(), rope(), non_neg_integer(), non_neg_integer()) :: rope()
  defp balance_by_height(left, right, left_height, right_height)
       when left_height > right_height + 1 do
    {:node, ll, lr, _size, _height} = left

    if node_height(ll) >= node_height(lr) do
      node(ll, node(lr, right))
    else
      {:node, lrl, lrr, _inner_size, _inner_height} = lr
      node(node(ll, lrl), node(lrr, right))
    end
  end

  defp balance_by_height(left, right, left_height, right_height)
       when right_height > left_height + 1 do
    {:node, rl, rr, _size, _height} = right

    if node_height(rr) >= node_height(rl) do
      node(node(left, rl), rr)
    else
      {:node, rll, rlr, _inner_size, _inner_height} = rl
      node(node(left, rll), node(rlr, rr))
    end
  end

  defp balance_by_height(left, right, _left_height, _right_height), do: node(left, right)

  @spec pop_first(rope()) :: {{source_id(), pos_integer()}, rope()}
  defp pop_first({:run, start, length}), do: {{start, length}, nil}

  defp pop_first({:node, left, right, _size, _height}) do
    {first, rest} = pop_first(left)
    {first, join(rest, right)}
  end

  @spec pop_last(rope()) :: {{source_id(), pos_integer()}, rope()}
  defp pop_last({:run, start, length}), do: {{start, length}, nil}

  defp pop_last({:node, left, right, _size, _height}) do
    {last, rest} = pop_last(right)
    {last, join(left, rest)}
  end

  @spec run(non_neg_integer(), non_neg_integer()) :: rope()
  defp run(_start, 0), do: nil
  defp run(start, length), do: {:run, start, length}

  @spec node(rope(), rope()) :: rope()
  defp node(nil, right), do: right
  defp node(left, nil), do: left

  defp node(left, right),
    do:
      {:node, left, right, size(left) + size(right),
       max(node_height(left), node_height(right)) + 1}

  @spec size(rope()) :: non_neg_integer()
  defp size(nil), do: 0
  defp size({:run, _start, length}), do: length
  defp size({:node, _left, _right, size, _height}), do: size

  @spec node_height(rope()) :: non_neg_integer()
  defp node_height(nil), do: 0
  defp node_height({:run, _start, _length}), do: 1
  defp node_height({:node, _left, _right, _size, height}), do: height

  @spec count_runs(rope()) :: non_neg_integer()
  defp count_runs(nil), do: 0
  defp count_runs({:run, _start, _length}), do: 1
  defp count_runs({:node, left, right, _size, _height}), do: count_runs(left) + count_runs(right)

  @spec to_list(rope(), [source_id()]) :: [source_id()]
  defp to_list(nil, acc), do: acc
  defp to_list({:run, start, length}, acc), do: Enum.to_list(start..(start + length - 1)) ++ acc
  defp to_list({:node, left, right, _size, _height}, acc), do: to_list(left, to_list(right, acc))
end
