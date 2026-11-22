defmodule MingaEditor.RenderModel.UI.AgentChatResident.Trie do
  @moduledoc """
  Sparse ordinal trie for one segment of the renderer's resident Agent transcript.

  Leaves are `MingaEditor.RenderModel.UI.AgentChatResident.Entry` values at their source ordinal. Each branch caches its leaf count and the exact sum of leaf wire weights, so the byte-capped newest suffix is found by one descent instead of sizing every entry. Updates copy one root-to-leaf path and share every other subtree. Capacity doubles when an ordinal outgrows it; the old root becomes the left child.
  """

  alias MingaEditor.RenderModel.UI.AgentChatResident.Entry

  @typep subtree ::
           nil
           | Entry.t()
           | {:branch, subtree(), subtree(), pos_integer(), non_neg_integer()}

  defstruct root: nil, capacity: 1

  @opaque t :: %__MODULE__{root: subtree(), capacity: pos_integer()}

  @typedoc "Outcome of fitting the newest leaves into a byte budget."
  @type fit ::
          {:all, non_neg_integer(), boolean()}
          | {:partial, non_neg_integer(), non_neg_integer()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Builds a trie from leaves in strictly ascending ordinal order."
  @spec from_sorted([{non_neg_integer(), Entry.t()}]) :: t()
  def from_sorted([]), do: %__MODULE__{}

  def from_sorted(leaves) when is_list(leaves) do
    # Leaves are sorted, so the final ordinal is the largest one.
    max_ordinal = Enum.reduce(leaves, 0, fn {ordinal, _entry}, _previous -> ordinal end)
    capacity = capacity_for(max_ordinal + 1, 1)
    {root, []} = build(leaves, 0, capacity)
    %__MODULE__{root: root, capacity: capacity}
  end

  @doc "Returns the number of leaves."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{root: root}), do: node_count(root)

  @doc "Returns the summed wire weight of every leaf."
  @spec weight(t()) :: non_neg_integer()
  def weight(%__MODULE__{root: root}), do: node_weight(root)

  @doc "Returns the leaf at an exact ordinal without visiting siblings."
  @spec fetch(t(), non_neg_integer()) :: Entry.t() | nil
  def fetch(%__MODULE__{root: root, capacity: capacity}, ordinal)
      when ordinal >= 0 and ordinal < capacity,
      do: fetch_at(root, capacity, ordinal)

  def fetch(%__MODULE__{}, _ordinal), do: nil

  @doc "Installs one leaf, copying only its path."
  @spec put(t(), non_neg_integer(), Entry.t()) :: t()
  def put(%__MODULE__{root: root, capacity: capacity}, ordinal, %Entry{} = entry)
      when ordinal >= capacity do
    put(%__MODULE__{root: grow(root), capacity: capacity * 2}, ordinal, entry)
  end

  def put(%__MODULE__{root: root, capacity: capacity} = trie, ordinal, %Entry{} = entry)
      when ordinal >= 0 do
    %{trie | root: put_at(root, capacity, ordinal, entry)}
  end

  @doc "Removes one leaf, copying only its path."
  @spec delete(t(), non_neg_integer()) :: t()
  def delete(%__MODULE__{capacity: capacity} = trie, ordinal) when ordinal >= capacity, do: trie

  def delete(%__MODULE__{root: root, capacity: capacity} = trie, ordinal) when ordinal >= 0,
    do: %{trie | root: delete_at(root, capacity, ordinal)}

  @doc """
  Fits the newest leaves into `budget` bytes, newest first.

  `forced?` admits the first leaf reached even when it exceeds the budget, which keeps the newest displayed entry resident. `{:all, used, forced?}` means every leaf fits; `{:partial, used, from}` means only leaves at or after ordinal `from` fit. The walk follows one root-to-leaf path and reads cached weights for whole subtrees.
  """
  @spec fit(t(), integer(), boolean()) :: fit()
  def fit(%__MODULE__{root: root, capacity: capacity}, budget, forced?),
    do: fit_node(root, capacity, 0, budget, forced?)

  @doc "Folds leaves at or after `from` in ascending ordinal order."
  @spec reduce_from(t(), non_neg_integer(), acc, (Entry.t(), acc -> acc)) :: acc when acc: term()
  def reduce_from(%__MODULE__{root: root, capacity: capacity}, from, acc, reduce),
    do: reduce_node(root, capacity, 0, from, acc, reduce)

  @doc "Returns the height of the cached index, `ceil(log2(capacity))`."
  @spec height(t()) :: non_neg_integer()
  def height(%__MODULE__{capacity: capacity}), do: height_of(capacity, 0)

  defp height_of(1, height), do: height
  defp height_of(capacity, height), do: height_of(div(capacity, 2), height + 1)

  defp capacity_for(count, capacity) when count <= capacity, do: capacity
  defp capacity_for(count, capacity), do: capacity_for(count, capacity * 2)

  defp build([{ordinal, _} | _] = leaves, offset, capacity) when ordinal >= offset + capacity,
    do: {nil, leaves}

  defp build([], _offset, _capacity), do: {nil, []}
  defp build([{offset, %Entry{} = entry} | rest], offset, 1), do: {entry, rest}

  defp build(leaves, offset, capacity) do
    half = div(capacity, 2)
    {left, rest} = build(leaves, offset, half)
    {right, rest} = build(rest, offset + half, half)
    {branch(left, right), rest}
  end

  defp grow(nil), do: nil
  defp grow(root), do: branch(root, nil)

  defp fetch_at(nil, _capacity, _ordinal), do: nil
  defp fetch_at(%Entry{} = entry, 1, 0), do: entry

  defp fetch_at({:branch, left, right, _count, _weight}, capacity, ordinal) do
    half = div(capacity, 2)

    if ordinal < half,
      do: fetch_at(left, half, ordinal),
      else: fetch_at(right, half, ordinal - half)
  end

  defp put_at(_old, 1, 0, entry), do: entry

  defp put_at(node, capacity, ordinal, entry) do
    {left, right} = children(node)
    half = div(capacity, 2)

    if ordinal < half,
      do: branch(put_at(left, half, ordinal, entry), right),
      else: branch(left, put_at(right, half, ordinal - half, entry))
  end

  defp delete_at(nil, _capacity, _ordinal), do: nil
  defp delete_at(%Entry{}, 1, 0), do: nil

  defp delete_at({:branch, left, right, _count, _weight}, capacity, ordinal) do
    half = div(capacity, 2)

    if ordinal < half,
      do: branch(delete_at(left, half, ordinal), right),
      else: branch(left, delete_at(right, half, ordinal - half))
  end

  defp fit_node(nil, _capacity, _offset, _budget, forced?), do: {:all, 0, forced?}

  defp fit_node(node, capacity, offset, budget, forced?) do
    weight = node_weight(node)

    if weight <= budget,
      do: {:all, weight, false},
      else: fit_over(node, capacity, offset, budget, forced?)
  end

  defp fit_over(%Entry{weight: weight}, 1, _offset, _budget, true), do: {:all, weight, false}
  defp fit_over(%Entry{}, 1, offset, _budget, false), do: {:partial, 0, offset + 1}

  defp fit_over({:branch, left, right, _count, _weight}, capacity, offset, budget, forced?) do
    half = div(capacity, 2)

    case fit_node(right, half, offset + half, budget, forced?) do
      {:all, used, forced?} ->
        case fit_node(left, half, offset, budget - used, forced?) do
          {:all, left_used, forced?} -> {:all, used + left_used, forced?}
          {:partial, left_used, from} -> {:partial, used + left_used, from}
        end

      partial ->
        partial
    end
  end

  defp reduce_node(nil, _capacity, _offset, _from, acc, _reduce), do: acc

  defp reduce_node(_node, capacity, offset, from, acc, _reduce) when offset + capacity <= from,
    do: acc

  defp reduce_node(%Entry{} = entry, 1, _offset, _from, acc, reduce), do: reduce.(entry, acc)

  defp reduce_node({:branch, left, right, _count, _weight}, capacity, offset, from, acc, reduce) do
    half = div(capacity, 2)
    acc = reduce_node(left, half, offset, from, acc, reduce)
    reduce_node(right, half, offset + half, from, acc, reduce)
  end

  defp children(nil), do: {nil, nil}
  defp children({:branch, left, right, _count, _weight}), do: {left, right}

  defp branch(nil, nil), do: nil

  defp branch(left, right),
    do:
      {:branch, left, right, node_count(left) + node_count(right),
       node_weight(left) + node_weight(right)}

  defp node_count(nil), do: 0
  defp node_count(%Entry{}), do: 1
  defp node_count({:branch, _left, _right, count, _weight}), do: count

  defp node_weight(nil), do: 0
  defp node_weight(%Entry{weight: weight}), do: weight
  defp node_weight({:branch, _left, _right, _count, weight}), do: weight
end
