defmodule MingaEditor.RenderModel.Window.LazyRowTree do
  @moduledoc """
  Persistent ordered row tree with lazy suffix shifts.

  This module owns the treap node representation and structural operations. Callers supply calculations for their domain summary and for shifting that summary with a row suffix. The shift calculation must distribute over summary recomputation: shifting a complete subtree must produce the same summary as shifting every key in that subtree.
  """

  defmodule View do
    @moduledoc false

    @enforce_keys [:key, :value, :left, :right, :summary]
    defstruct [:key, :value, :left, :right, :summary]

    @type t(value, summary) :: %__MODULE__{
            key: non_neg_integer(),
            value: value,
            left: MingaEditor.RenderModel.Window.LazyRowTree.t(value, summary),
            right: MingaEditor.RenderModel.Window.LazyRowTree.t(value, summary),
            summary: summary
          }
  end

  @enforce_keys [:key, :value, :priority, :left, :right, :lazy, :count, :summary]
  defstruct [:key, :value, :priority, :left, :right, :lazy, :count, :summary]

  @type t(value, summary) ::
          nil
          | %__MODULE__{
              key: non_neg_integer(),
              value: value,
              priority: non_neg_integer(),
              left: t(value, summary),
              right: t(value, summary),
              lazy: integer(),
              count: pos_integer(),
              summary: summary
            }

  @type summarize(value, summary) ::
          (non_neg_integer(), value, summary | nil, summary | nil -> summary)

  @type shift_summary(summary) :: (summary, integer() -> summary)

  @spec leaf(non_neg_integer(), value, non_neg_integer(), summarize(value, summary)) ::
          t(value, summary)
        when value: var, summary: var
  def leaf(key, value, priority, summarize) do
    make(key, value, priority, nil, nil, summarize)
  end

  @spec view(t(value, summary), shift_summary(summary)) :: View.t(value, summary) | nil
        when value: var, summary: var
  def view(nil, _shift_summary), do: nil

  def view(tree, shift_summary) do
    tree = push(tree, shift_summary)

    %View{
      key: tree.key,
      value: tree.value,
      left: tree.left,
      right: tree.right,
      summary: tree.summary
    }
  end

  @spec update(
          t(value, summary),
          non_neg_integer(),
          (value -> {:replace, value} | :delete),
          summarize(value, summary),
          shift_summary(summary)
        ) :: t(value, summary)
        when value: var, summary: var
  def update(nil, _key, _fun, _summarize, _shift_summary), do: nil

  def update(root, key, fun, summarize, shift_summary) do
    root = push(root, shift_summary)
    update_root(root, key, fun, summarize, shift_summary)
  end

  @spec make(
          non_neg_integer(),
          value,
          non_neg_integer(),
          t(value, summary),
          t(value, summary),
          summarize(value, summary)
        ) :: t(value, summary)
        when value: var, summary: var
  def make(key, value, priority, left, right, summarize) do
    %__MODULE__{
      key: key,
      value: value,
      priority: priority,
      left: left,
      right: right,
      lazy: 0,
      count: 1 + count(left) + count(right),
      summary: summarize.(key, value, summary(left), summary(right))
    }
  end

  @spec shift(t(value, summary), integer(), shift_summary(summary)) :: t(value, summary)
        when value: var, summary: var
  def shift(nil, _shift, _shift_summary), do: nil
  def shift(tree, 0, _shift_summary), do: tree

  def shift(%__MODULE__{} = tree, delta, shift_summary) do
    %__MODULE__{
      tree
      | key: tree.key + delta,
        lazy: tree.lazy + delta,
        summary: shift_summary.(tree.summary, delta)
    }
  end

  @spec push(t(value, summary), shift_summary(summary)) :: t(value, summary)
        when value: var, summary: var
  def push(nil, _shift_summary), do: nil
  def push(%__MODULE__{lazy: 0} = tree, _shift_summary), do: tree

  def push(%__MODULE__{} = tree, shift_summary) do
    %__MODULE__{
      tree
      | left: shift(tree.left, tree.lazy, shift_summary),
        right: shift(tree.right, tree.lazy, shift_summary),
        lazy: 0
    }
  end

  @spec split(
          t(value, summary),
          non_neg_integer(),
          summarize(value, summary),
          shift_summary(summary)
        ) :: {t(value, summary), t(value, summary)}
        when value: var, summary: var
  def split(nil, _key, _summarize, _shift_summary), do: {nil, nil}

  def split(root, key, summarize, shift_summary) do
    root = push(root, shift_summary)

    if root.key < key do
      {middle, new_right} = split(root.right, key, summarize, shift_summary)
      {make(root.key, root.value, root.priority, root.left, middle, summarize), new_right}
    else
      {new_left, middle} = split(root.left, key, summarize, shift_summary)
      {new_left, make(root.key, root.value, root.priority, middle, root.right, summarize)}
    end
  end

  @spec merge(
          t(value, summary),
          t(value, summary),
          summarize(value, summary),
          shift_summary(summary)
        ) :: t(value, summary)
        when value: var, summary: var
  def merge(nil, right, _summarize, _shift_summary), do: right
  def merge(left, nil, _summarize, _shift_summary), do: left

  def merge(left, right, summarize, shift_summary) do
    left = push(left, shift_summary)
    right = push(right, shift_summary)
    merge_roots(left, right, summarize, shift_summary)
  end

  @spec insert(
          t(value, summary),
          t(value, summary),
          summarize(value, summary),
          shift_summary(summary)
        ) :: t(value, summary)
        when value: var, summary: var
  def insert(root, %__MODULE__{} = node, summarize, shift_summary) do
    {left, right} = split(root, node.key, summarize, shift_summary)
    merge(merge(left, node, summarize, shift_summary), right, summarize, shift_summary)
  end

  @spec summary(t(term(), summary)) :: summary | nil when summary: var
  def summary(nil), do: nil
  def summary(%__MODULE__{summary: summary}), do: summary

  defp count(nil), do: 0
  defp count(%__MODULE__{count: count}), do: count

  defp update_root(root, key, fun, summarize, shift_summary) when key < root.key do
    left = update(root.left, key, fun, summarize, shift_summary)
    make(root.key, root.value, root.priority, left, root.right, summarize)
  end

  defp update_root(root, key, fun, summarize, shift_summary) when key > root.key do
    right = update(root.right, key, fun, summarize, shift_summary)
    make(root.key, root.value, root.priority, root.left, right, summarize)
  end

  defp update_root(root, _key, fun, summarize, shift_summary) do
    case fun.(root.value) do
      :delete -> merge(root.left, root.right, summarize, shift_summary)
      {:replace, value} -> make(root.key, value, root.priority, root.left, root.right, summarize)
    end
  end

  defp merge_roots(left, right, summarize, shift_summary)
       when left.priority <= right.priority do
    merged = merge(left.right, right, summarize, shift_summary)
    make(left.key, left.value, left.priority, left.left, merged, summarize)
  end

  defp merge_roots(left, right, summarize, shift_summary) do
    merged = merge(left, right.left, summarize, shift_summary)
    make(right.key, right.value, right.priority, merged, right.right, summarize)
  end
end
