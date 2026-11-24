defmodule Minga.Buffer.Provenance.RunTree do
  @moduledoc """
  A balanced sum tree of authorship runs in document order.

  The tree is an AVL tree keyed by each run's locator. Locators sort in document order, so an in-order walk visits the runs as they appear in the document, tombstones included. Every node caches the live byte length of its subtree, so the tree finds a run by its document byte offset, or by its locator together with that run's offset, in O(log n) for n runs. Inserting, deleting, or resizing a run updates the cached lengths on one root path, also O(log n).

  The tree knows nothing about history or authors; `Minga.Buffer.Provenance` owns those.
  """

  alias Minga.Buffer.Provenance.Locator
  alias Minga.Buffer.Provenance.Run

  @typedoc "A subtree: empty, or left, run, right, height, the live bytes of the whole subtree, and its run count."
  @opaque t :: nil | {t(), Run.t(), t(), pos_integer(), non_neg_integer(), pos_integer()}

  @doc "Returns an empty tree."
  @spec new() :: t()
  def new, do: nil

  @doc "Returns the live byte length of the whole tree, which equals the document's size."
  @spec size(t()) :: non_neg_integer()
  def size(nil), do: 0
  def size({_left, _run, _right, _height, bytes, _count}), do: bytes

  @doc "Builds a balanced tree from runs already in locator order, in O(n)."
  @spec from_list([Run.t()]) :: t()
  def from_list(runs) when is_list(runs) do
    {tree, []} = build(runs, length(runs))
    tree
  end

  @spec build([Run.t()], non_neg_integer()) :: {t(), [Run.t()]}
  defp build(runs, 0), do: {nil, runs}

  defp build(runs, count) do
    left_count = div(count - 1, 2)
    {left, [run | rest]} = build(runs, left_count)
    {right, rest} = build(rest, count - 1 - left_count)
    {branch(left, run, right), rest}
  end

  @doc "Returns how many runs the tree holds, tombstones included, in O(1)."
  @spec count(t()) :: non_neg_integer()
  def count(nil), do: 0
  def count({_left, _run, _right, _height, _bytes, count}), do: count

  @doc "Inserts a run whose locator is not in the tree."
  @spec insert(t(), Run.t()) :: t()
  def insert(nil, %Run{} = run), do: branch(nil, run, nil)

  def insert({left, current, right, _height, _bytes, _count}, %Run{} = run) do
    cond do
      run.id < current.id -> rebalance(insert(left, run), current, right)
      run.id > current.id -> rebalance(left, current, insert(right, run))
      true -> raise ArgumentError, "run locator #{inspect(run.id)} is already in the tree"
    end
  end

  @doc "Replaces the run that has the same locator, keeping its place."
  @spec update(t(), Run.t()) :: t()
  def update(nil, %Run{id: id}),
    do: raise(ArgumentError, "run locator #{inspect(id)} is not in the tree")

  def update({left, current, right, _height, _bytes, _count}, %Run{} = run) do
    cond do
      run.id < current.id -> branch(update(left, run), current, right)
      run.id > current.id -> branch(left, current, update(right, run))
      true -> branch(left, run, right)
    end
  end

  @doc "Removes the run with locator `id`."
  @spec delete(t(), Locator.t()) :: t()
  def delete(nil, id), do: raise(ArgumentError, "run locator #{inspect(id)} is not in the tree")

  def delete({left, current, right, _height, _bytes, _count}, id) do
    cond do
      id < current.id -> rebalance(delete(left, id), current, right)
      id > current.id -> rebalance(left, current, delete(right, id))
      right == nil -> left
      left == nil -> right
      true -> join_with_min(left, right)
    end
  end

  @doc "Returns the run with locator `id` and the byte offset where it starts in the document."
  @spec fetch(t(), Locator.t()) :: {:ok, Run.t(), non_neg_integer()} | :error
  def fetch(tree, id), do: fetch(tree, id, 0)

  @spec fetch(t(), Locator.t(), non_neg_integer()) ::
          {:ok, Run.t(), non_neg_integer()} | :error
  defp fetch(nil, _id, _base), do: :error

  defp fetch({left, run, right, _height, _bytes, _count}, id, base) do
    cond do
      id < run.id -> fetch(left, id, base)
      id > run.id -> fetch(right, id, base + size(left) + Run.live_bytes(run))
      true -> {:ok, run, base + size(left)}
    end
  end

  @doc """
  Returns the live run that holds the byte at `offset`, with the offset where that run starts.

  Returns `nil` when `offset` is at or past the end of the document.
  """
  @spec at_offset(t(), non_neg_integer()) :: {Run.t(), non_neg_integer()} | nil
  def at_offset(tree, offset), do: at_offset(tree, offset, 0)

  @spec at_offset(t(), non_neg_integer(), non_neg_integer()) ::
          {Run.t(), non_neg_integer()} | nil
  defp at_offset(nil, _offset, _base), do: nil

  defp at_offset({left, run, right, _height, _bytes, _count}, offset, base) do
    left_bytes = size(left)
    run_bytes = Run.live_bytes(run)

    cond do
      offset < left_bytes -> at_offset(left, offset, base)
      offset < left_bytes + run_bytes -> {run, base + left_bytes}
      true -> at_offset(right, offset - left_bytes - run_bytes, base + left_bytes + run_bytes)
    end
  end

  @doc "Returns the run just before locator `id` in document order, tombstones included, or `nil`."
  @spec previous(t(), Locator.t()) :: Run.t() | nil
  def previous(tree, id), do: previous(tree, id, nil)

  @spec previous(t(), Locator.t(), Run.t() | nil) :: Run.t() | nil
  defp previous(nil, _id, best), do: best

  defp previous({left, run, right, _height, _bytes, _count}, id, best) do
    if run.id < id, do: previous(right, id, run), else: previous(left, id, best)
  end

  @doc "Returns the run just after locator `id` in document order, tombstones included, or `nil`."
  @spec next(t(), Locator.t()) :: Run.t() | nil
  def next(tree, id), do: next(tree, id, nil)

  @spec next(t(), Locator.t(), Run.t() | nil) :: Run.t() | nil
  defp next(nil, _id, best), do: best

  defp next({left, run, right, _height, _bytes, _count}, id, best) do
    if run.id > id, do: next(left, id, run), else: next(right, id, best)
  end

  @doc "Returns the last run in document order, or `nil` for an empty tree."
  @spec last(t()) :: Run.t() | nil
  def last(nil), do: nil
  def last({_left, run, nil, _height, _bytes, _count}), do: run
  def last({_left, _run, right, _height, _bytes, _count}), do: last(right)

  @doc """
  Returns the live runs that overlap the byte range `from` up to `to`, in document order, each with its start offset.

  Visits only the subtrees that overlap the range and hold live bytes, so tombstones in the window cost nothing and the cost is O(log n + k) for k returned runs.
  """
  @spec live_between(t(), non_neg_integer(), non_neg_integer()) ::
          [{Run.t(), non_neg_integer()}]
  def live_between(tree, from, to) when from < to,
    do: tree |> collect(from, to, 0, []) |> Enum.reverse()

  def live_between(_tree, _from, _to), do: []

  @spec collect(t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), [
          {Run.t(), non_neg_integer()}
        ]) :: [{Run.t(), non_neg_integer()}]
  defp collect(nil, _from, _to, _base, acc), do: acc
  defp collect({_left, _run, _right, _height, 0, _count}, _from, _to, _base, acc), do: acc

  defp collect({left, run, right, _height, _bytes, _count}, from, to, base, acc) do
    run_start = base + size(left)
    run_end = run_start + Run.live_bytes(run)
    acc = if from < run_start, do: collect(left, from, to, base, acc), else: acc

    acc =
      if run.live and run_start < to and run_end > from, do: [{run, run_start} | acc], else: acc

    if to > run_end, do: collect(right, from, to, run_end, acc), else: acc
  end

  @doc "Returns every run in document order, tombstones included. Meant for tests and diagnostics."
  @spec to_list(t()) :: [Run.t()]
  def to_list(tree), do: tree |> runs_desc([]) |> Enum.reverse()

  @spec runs_desc(t(), [Run.t()]) :: [Run.t()]
  defp runs_desc(nil, acc), do: acc

  defp runs_desc({left, run, right, _height, _bytes, _count}, acc),
    do: runs_desc(right, [run | runs_desc(left, acc)])

  @doc "Returns the tree's height, for balance checks in tests."
  @spec height(t()) :: non_neg_integer()
  def height(nil), do: 0
  def height({_left, _run, _right, height, _bytes, _count}), do: height

  # ── Balancing ───────────────────────────────────────────────────────

  @spec branch(t(), Run.t(), t()) :: t()
  defp branch(left, run, right) do
    {left, run, right, max(height(left), height(right)) + 1,
     size(left) + Run.live_bytes(run) + size(right), count(left) + 1 + count(right)}
  end

  @spec rebalance(t(), Run.t(), t()) :: t()
  defp rebalance(left, run, right) do
    left_height = height(left)
    right_height = height(right)

    cond do
      left_height > right_height + 1 -> rotate_right(left, run, right)
      right_height > left_height + 1 -> rotate_left(left, run, right)
      true -> branch(left, run, right)
    end
  end

  @spec rotate_right(t(), Run.t(), t()) :: t()
  defp rotate_right({ll, lrun, lr, _height, _bytes, _count}, run, right) do
    if height(ll) >= height(lr) do
      branch(ll, lrun, branch(lr, run, right))
    else
      {lrl, lrrun, lrr, _lr_height, _lr_bytes, _lr_count} = lr
      branch(branch(ll, lrun, lrl), lrrun, branch(lrr, run, right))
    end
  end

  @spec rotate_left(t(), Run.t(), t()) :: t()
  defp rotate_left(left, run, {rl, rrun, rr, _height, _bytes, _count}) do
    if height(rr) >= height(rl) do
      branch(branch(left, run, rl), rrun, rr)
    else
      {rll, rlrun, rlr, _rl_height, _rl_bytes, _rl_count} = rl
      branch(branch(left, run, rll), rlrun, branch(rlr, rrun, rr))
    end
  end

  @spec join_with_min(t(), t()) :: t()
  defp join_with_min(left, right) do
    {min_run, rest} = pop_min(right)
    rebalance(left, min_run, rest)
  end

  @spec pop_min(t()) :: {Run.t(), t()}
  defp pop_min({nil, run, right, _height, _bytes, _count}), do: {run, right}

  defp pop_min({left, run, right, _height, _bytes, _count}) do
    {min_run, rest} = pop_min(left)
    {min_run, rebalance(rest, run, right)}
  end
end
