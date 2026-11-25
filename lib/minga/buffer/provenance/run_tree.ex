defmodule Minga.Buffer.Provenance.RunTree do
  @moduledoc """
  A balanced sum tree of authorship runs in document order.

  The tree is an AVL tree keyed by each run's locator. Locators sort in document order, so an in-order walk visits the runs as they appear in the document, tombstones included. Every node caches the live byte length of its subtree, so the tree finds a run by its document byte offset, or by its locator together with that run's offset, in O(log n) for n runs. Inserting, deleting, or resizing a run updates the cached lengths on one root path, also O(log n).

  The tree knows nothing about history or authors; `Minga.Buffer.Provenance` owns those.
  """

  alias Minga.Buffer.Provenance.Locator
  alias Minga.Buffer.Provenance.Run

  @typedoc """
  A subtree: empty, or left, run, right, height, the live bytes of the whole subtree, its run count, and the bytes its tombstones keep.
  """
  @opaque t ::
            nil
            | {t(), Run.t(), t(), pos_integer(), non_neg_integer(), pos_integer(),
               non_neg_integer()}

  @doc "Returns an empty tree."
  @spec new() :: t()
  def new, do: nil

  @doc "Returns the live byte length of the whole tree, which equals the document's size."
  @spec size(t()) :: non_neg_integer()
  def size(nil), do: 0
  def size({_left, _run, _right, _height, bytes, _count, _dead}), do: bytes

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
  def count({_left, _run, _right, _height, _bytes, count, _dead}), do: count

  @doc "Returns how many bytes of deleted text the tree's tombstones keep, in O(1)."
  @spec dead_bytes(t()) :: non_neg_integer()
  def dead_bytes(nil), do: 0
  def dead_bytes({_left, _run, _right, _height, _bytes, _count, dead}), do: dead

  @doc """
  Rebuilds the runs from locator `from` to locator `to`, both included.

  `fun` receives those runs in document order and returns `{runs, result}`: the runs to keep in their place, still in order and each with a locator from the range's bounds, and any result for the caller. The range is cut out, rebuilt balanced, and joined back, so it costs O(m + log n) for m runs in the range. Returns the new tree and the result.
  """
  @spec rebuild_range(t(), Locator.t(), Locator.t(), ([Run.t()] -> {[Run.t()], result})) ::
          {t(), result}
        when result: term()
  def rebuild_range(tree, from, to, fun) when is_function(fun, 1) do
    {left, rest} = split_before(tree, from)
    {middle, right} = split_after(rest, to)
    {runs, result} = middle |> to_list() |> fun.()
    {left |> concat(from_list(runs)) |> concat(right), result}
  end

  @doc """
  Returns the first and last locator of the longest stretch of consecutive runs around the run `id` for which `keep?` holds, or `nil` when it does not hold for that run.

  It walks outward from the run in document order, so it costs O(log n + m) for a stretch of m runs.
  """
  @spec stretch(t(), Locator.t(), (Run.t() -> boolean())) :: {Locator.t(), Locator.t()} | nil
  def stretch(tree, id, keep?) when is_function(keep?, 1) do
    case fetch(tree, id) do
      {:ok, run, _offset} ->
        if keep?.(run) do
          first = tree |> descending_from(id) |> last_kept(keep?, id)
          last = tree |> ascending_from(id) |> last_kept(keep?, id)
          {first, last}
        end

      :error ->
        nil
    end
  end

  # Follows an iterator while runs are kept, returning the last kept locator.
  @spec last_kept([t()] | {:desc, [t()]}, (Run.t() -> boolean()), Locator.t()) :: Locator.t()
  defp last_kept(iterator, keep?, kept) do
    case step(iterator) do
      nil -> kept
      {run, rest} -> if keep?.(run), do: last_kept(rest, keep?, run.id), else: kept
    end
  end

  # Iterators are stacks of subtrees whose root comes next; a descending one is tagged.
  @spec ascending_from(t(), Locator.t()) :: [t()]
  defp ascending_from(tree, id), do: push_ascending(tree, id, [])

  @spec push_ascending(t(), Locator.t(), [t()]) :: [t()]
  defp push_ascending(nil, _id, stack), do: stack

  defp push_ascending({left, run, right, _height, _bytes, _count, _dead} = node, id, stack) do
    if run.id >= id,
      do: push_ascending(left, id, [node | stack]),
      else: push_ascending(right, id, stack)
  end

  @spec descending_from(t(), Locator.t()) :: {:desc, [t()]}
  defp descending_from(tree, id), do: {:desc, push_descending(tree, id, [])}

  @spec push_descending(t(), Locator.t(), [t()]) :: [t()]
  defp push_descending(nil, _id, stack), do: stack

  defp push_descending({left, run, right, _height, _bytes, _count, _dead} = node, id, stack) do
    if run.id <= id,
      do: push_descending(right, id, [node | stack]),
      else: push_descending(left, id, stack)
  end

  @spec step([t()] | {:desc, [t()]}) :: {Run.t(), [t()] | {:desc, [t()]}} | nil
  defp step([]), do: nil
  defp step({:desc, []}), do: nil

  defp step([{_left, run, right, _height, _bytes, _count, _dead} | stack]),
    do: {run, left_spine(right, stack)}

  defp step({:desc, [{left, run, _right, _height, _bytes, _count, _dead} | stack]}),
    do: {run, {:desc, right_spine(left, stack)}}

  @spec left_spine(t(), [t()]) :: [t()]
  defp left_spine(nil, stack), do: stack

  defp left_spine({left, _run, _right, _height, _bytes, _count, _dead} = node, stack),
    do: left_spine(left, [node | stack])

  @spec right_spine(t(), [t()]) :: [t()]
  defp right_spine(nil, stack), do: stack

  defp right_spine({_left, _run, right, _height, _bytes, _count, _dead} = node, stack),
    do: right_spine(right, [node | stack])

  # Splits into the runs before locator `id` and the rest.
  @spec split_before(t(), Locator.t()) :: {t(), t()}
  defp split_before(nil, _id), do: {nil, nil}

  defp split_before({left, run, right, _height, _bytes, _count, _dead}, id) do
    if run.id < id do
      {lesser, greater} = split_before(right, id)
      {join(left, run, lesser), greater}
    else
      {lesser, greater} = split_before(left, id)
      {lesser, join(greater, run, right)}
    end
  end

  # Splits into the runs up to locator `id`, included, and the rest.
  @spec split_after(t(), Locator.t()) :: {t(), t()}
  defp split_after(nil, _id), do: {nil, nil}

  defp split_after({left, run, right, _height, _bytes, _count, _dead}, id) do
    if run.id <= id do
      {lesser, greater} = split_after(right, id)
      {join(left, run, lesser), greater}
    else
      {lesser, greater} = split_after(left, id)
      {lesser, join(greater, run, right)}
    end
  end

  # Joins two trees whose runs are all ordered before `run` and after it, rebalancing along one spine in
  # O(|height difference|).
  @spec join(t(), Run.t(), t()) :: t()
  defp join(left, run, right) do
    left_height = height(left)
    right_height = height(right)

    cond do
      left_height > right_height + 1 ->
        {ll, lrun, lr, _height, _bytes, _count, _dead} = left
        rebalance(ll, lrun, join(lr, run, right))

      right_height > left_height + 1 ->
        {rl, rrun, rr, _height, _bytes, _count, _dead} = right
        rebalance(join(left, run, rl), rrun, rr)

      true ->
        branch(left, run, right)
    end
  end

  @spec concat(t(), t()) :: t()
  defp concat(left, nil), do: left
  defp concat(nil, right), do: right

  defp concat(left, right) do
    {min_run, rest} = pop_min(right)
    join(left, min_run, rest)
  end

  @doc "Inserts a run whose locator is not in the tree."
  @spec insert(t(), Run.t()) :: t()
  def insert(nil, %Run{} = run), do: branch(nil, run, nil)

  def insert({left, current, right, _height, _bytes, _count, _dead}, %Run{} = run) do
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

  def update({left, current, right, _height, _bytes, _count, _dead}, %Run{} = run) do
    cond do
      run.id < current.id -> branch(update(left, run), current, right)
      run.id > current.id -> branch(left, current, update(right, run))
      true -> branch(left, run, right)
    end
  end

  @doc "Removes the run with locator `id`."
  @spec delete(t(), Locator.t()) :: t()
  def delete(nil, id), do: raise(ArgumentError, "run locator #{inspect(id)} is not in the tree")

  def delete({left, current, right, _height, _bytes, _count, _dead}, id) do
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

  defp fetch({left, run, right, _height, _bytes, _count, _dead}, id, base) do
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

  defp at_offset({left, run, right, _height, _bytes, _count, _dead}, offset, base) do
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

  defp previous({left, run, right, _height, _bytes, _count, _dead}, id, best) do
    if run.id < id, do: previous(right, id, run), else: previous(left, id, best)
  end

  @doc "Returns the run just after locator `id` in document order, tombstones included, or `nil`."
  @spec next(t(), Locator.t()) :: Run.t() | nil
  def next(tree, id), do: next(tree, id, nil)

  @spec next(t(), Locator.t(), Run.t() | nil) :: Run.t() | nil
  defp next(nil, _id, best), do: best

  defp next({left, run, right, _height, _bytes, _count, _dead}, id, best) do
    if run.id > id, do: next(left, id, run), else: next(right, id, best)
  end

  @doc "Returns the last run in document order, or `nil` for an empty tree."
  @spec last(t()) :: Run.t() | nil
  def last(nil), do: nil
  def last({_left, run, nil, _height, _bytes, _count, _dead}), do: run
  def last({_left, _run, right, _height, _bytes, _count, _dead}), do: last(right)

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
  defp collect({_left, _run, _right, _height, 0, _count, _dead}, _from, _to, _base, acc), do: acc

  defp collect({left, run, right, _height, _bytes, _count, _dead}, from, to, base, acc) do
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

  defp runs_desc({left, run, right, _height, _bytes, _count, _dead}, acc),
    do: runs_desc(right, [run | runs_desc(left, acc)])

  @doc "Returns the tree's height, for balance checks in tests."
  @spec height(t()) :: non_neg_integer()
  def height(nil), do: 0
  def height({_left, _run, _right, height, _bytes, _count, _dead}), do: height

  # ── Balancing ───────────────────────────────────────────────────────

  @spec branch(t(), Run.t(), t()) :: t()
  defp branch(left, run, right) do
    {left, run, right, max(height(left), height(right)) + 1,
     size(left) + Run.live_bytes(run) + size(right), count(left) + 1 + count(right),
     dead_bytes(left) + run.bytes - Run.live_bytes(run) + dead_bytes(right)}
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
  defp rotate_right({ll, lrun, lr, _height, _bytes, _count, _dead}, run, right) do
    if height(ll) >= height(lr) do
      branch(ll, lrun, branch(lr, run, right))
    else
      {lrl, lrrun, lrr, _lr_height, _lr_bytes, _lr_count, _dead} = lr
      branch(branch(ll, lrun, lrl), lrrun, branch(lrr, run, right))
    end
  end

  @spec rotate_left(t(), Run.t(), t()) :: t()
  defp rotate_left(left, run, {rl, rrun, rr, _height, _bytes, _count, _dead}) do
    if height(rr) >= height(rl) do
      branch(branch(left, run, rl), rrun, rr)
    else
      {rll, rlrun, rlr, _rl_height, _rl_bytes, _rl_count, _dead} = rl
      branch(branch(left, run, rll), rlrun, branch(rlr, rrun, rr))
    end
  end

  @spec join_with_min(t(), t()) :: t()
  defp join_with_min(left, right) do
    {min_run, rest} = pop_min(right)
    rebalance(left, min_run, rest)
  end

  @spec pop_min(t()) :: {Run.t(), t()}
  defp pop_min({nil, run, right, _height, _bytes, _count, _dead}), do: {run, right}

  defp pop_min({left, run, right, _height, _bytes, _count, _dead}) do
    {min_run, rest} = pop_min(left)
    {min_run, rebalance(rest, run, right)}
  end
end
