defmodule Minga.Buffer.IntervalTree do
  @moduledoc """
  Augmented interval tree for efficient range queries over buffer decorations.

  Backed by an AVL-balanced binary search tree where each node stores an
  interval `{start, end}` keyed by the start position, and is augmented
  with the maximum end position in its subtree. This augmentation enables
  O(log n + k) stabbing and overlap queries, where n is the total number
  of intervals and k is the number of results.

  ## Interval representation

  Intervals use `{line, col}` tuple positions, compared lexicographically.
  Start is inclusive, end is exclusive: `[start, end)`. This matches the
  convention used by tree-sitter, LSP, and Zed's decoration system.

  ## Performance characteristics

  - **Insert**: O(log n) amortized (AVL rebalancing)
  - **Delete**: O(log n) amortized
  - **Overlap query** ("all intervals intersecting [qstart, qend)"): O(log n + k)
  - **Stabbing query** ("all intervals containing point p"): O(log n + k)
  - **Bulk rebuild**: O(n log n) from a list of intervals

  The tree is optimized for the read path (queries every frame at 60fps)
  over the write path (decorations change on edits and sync, not every frame).

  ## Design decisions

  - Pure Elixir, no NIFs. The BEAM's per-process GC handles tree nodes
    without global pauses.
  - AVL balancing (not red-black) for simpler implementation with the same
    O(log n) guarantees. The constant factor difference is irrelevant for
    our workload (thousands of nodes, not millions).
  - Immutable: every mutation returns a new tree. This is the Elixir way
    and enables safe concurrent reads from the render pipeline while the
    buffer process updates decorations.
  """

  @typedoc """
  A position in the buffer: `{line, col}`, both 0-indexed.
  Compared lexicographically (line first, then col).
  """
  @type position :: {non_neg_integer(), non_neg_integer()}

  @typedoc """
  An interval stored in the tree. `start` is inclusive, `end_` is exclusive.
  `id` is a unique reference for deletion. `value` is the associated data
  (e.g., a highlight range struct).
  """
  @type interval :: %{
          id: reference(),
          start: position(),
          end_: position(),
          value: term()
        }

  @typedoc """
  A node in the AVL tree.

  - `interval`: the interval stored at this node
  - `max_end`: the maximum `end_` position in this node's entire subtree
  - `left`, `right`: child subtrees
  - `height`: AVL height for balance factor computation
  """
  @type node_t :: %{
          interval: interval(),
          max_end: position(),
          left: t(),
          right: t(),
          height: non_neg_integer()
        }

  @typedoc "The tree: either nil (empty) or a node."
  @type t :: node_t() | nil

  # ── Construction ─────────────────────────────────────────────────────────

  @doc "Returns an empty interval tree."
  @spec new() :: t()
  def new, do: nil

  @doc """
  Builds an interval tree from a list of intervals.

  More efficient than repeated `insert/2` calls: sorts once, then builds
  a balanced tree via median splitting. O(n log n).
  """
  @spec from_list([interval()]) :: t()
  def from_list([]), do: nil

  def from_list(intervals) do
    intervals
    |> Enum.sort_by(fn %{start: s} -> s end)
    |> build_balanced()
  end

  @spec build_balanced([interval()]) :: t()
  defp build_balanced([]), do: nil
  defp build_balanced([single]), do: make_leaf(single)

  defp build_balanced(sorted) do
    mid = div(length(sorted), 2)
    {left_list, [pivot | right_list]} = Enum.split(sorted, mid)

    left = build_balanced(left_list)
    right = build_balanced(right_list)
    make_node(pivot, left, right)
  end

  # ── Insert ───────────────────────────────────────────────────────────────

  @doc """
  Inserts an interval into the tree. Returns the new tree.

  The interval must have `:id`, `:start`, `:end_`, and `:value` keys.
  Duplicate IDs are not checked; callers should ensure uniqueness.
  """
  @spec insert(t(), interval()) :: t()
  def insert(nil, interval), do: make_leaf(interval)

  def insert(node, interval) do
    if interval.start <= node.interval.start do
      new_left = insert(node.left, interval)
      make_node(node.interval, new_left, node.right) |> rebalance()
    else
      new_right = insert(node.right, interval)
      make_node(node.interval, node.left, new_right) |> rebalance()
    end
  end

  # ── Delete ───────────────────────────────────────────────────────────────

  @doc """
  Deletes the interval with the given ID from the tree.

  Returns the new tree. No-op if the ID is not found.
  """
  @spec delete(t(), reference()) :: t()
  def delete(nil, _id), do: nil

  def delete(node, id) do
    if node.interval.id == id do
      merge_children(node.left, node.right)
    else
      new_left = delete(node.left, id)
      new_right = delete(node.right, id)

      if new_left == node.left and new_right == node.right do
        # ID not found in either subtree, tree unchanged
        node
      else
        make_node(node.interval, new_left, new_right) |> rebalance()
      end
    end
  end

  # ── Query ────────────────────────────────────────────────────────────────

  @doc """
  Returns all intervals that overlap with the query range `[query_start, query_end)`.

  An interval `[s, e)` overlaps `[qs, qe)` when `s < qe AND e > qs`.

  Runs in O(log n + k) where k is the number of results, thanks to the
  `max_end` augmentation that prunes entire subtrees.
  """
  @spec query(t(), position(), position()) :: [interval()]
  def query(tree, query_start, query_end) do
    query_acc(tree, query_start, query_end, [])
  end

  @spec query_acc(t(), position(), position(), [interval()]) :: [interval()]
  defp query_acc(nil, _qs, _qe, acc), do: acc

  defp query_acc(node, query_start, query_end, acc) do
    # Prune: if the max end in this subtree is <= query_start, no interval
    # in this subtree can overlap the query range.
    if node.max_end <= query_start do
      acc
    else
      # Check left subtree
      acc = query_acc(node.left, query_start, query_end, acc)

      # Check this node's interval: overlaps when s < qe AND e > qs
      acc =
        if node.interval.start < query_end and node.interval.end_ > query_start do
          [node.interval | acc]
        else
          acc
        end

      # Prune right subtree: if this node's start >= query_end, all nodes
      # in the right subtree have start >= query_end and cannot overlap.
      if node.interval.start >= query_end do
        acc
      else
        query_acc(node.right, query_start, query_end, acc)
      end
    end
  end

  @doc """
  Returns all intervals that contain the given point (stabbing query).

  A point `p` is contained by interval `[s, e)` when `s <= p AND e > p`.
  This is equivalent to `query(tree, p, {line, col + 1})` but expressed
  more clearly for point queries.
  """
  @spec stabbing(t(), position()) :: [interval()]
  def stabbing(tree, point) do
    stabbing_acc(tree, point, [])
  end

  @spec stabbing_acc(t(), position(), [interval()]) :: [interval()]
  defp stabbing_acc(nil, _point, acc), do: acc

  defp stabbing_acc(node, point, acc) do
    if node.max_end <= point do
      acc
    else
      acc = stabbing_acc(node.left, point, acc)

      acc =
        if node.interval.start <= point and node.interval.end_ > point do
          [node.interval | acc]
        else
          acc
        end

      if node.interval.start > point do
        acc
      else
        stabbing_acc(node.right, point, acc)
      end
    end
  end

  @doc """
  Returns all intervals that intersect any line in the range `[start_line, end_line]`
  (both inclusive).

  This is the primary query for the render pipeline: "give me all decorations
  that touch lines 50-80." It's a range query where the query range spans
  from `{start_line, 0}` to `{end_line + 1, 0}`.
  """
  @spec query_lines(t(), non_neg_integer(), non_neg_integer()) :: [interval()]
  def query_lines(tree, start_line, end_line) do
    query(tree, {start_line, 0}, {end_line + 1, 0})
  end

  # ── Bulk operations ──────────────────────────────────────────────────────

  @doc """
  Returns the number of intervals in the tree.
  """
  @spec size(t()) :: non_neg_integer()
  def size(nil), do: 0
  def size(node), do: 1 + size(node.left) + size(node.right)

  @doc """
  Converts the tree to a sorted list of intervals (in-order traversal).
  """
  @spec to_list(t()) :: [interval()]
  def to_list(tree), do: to_list_acc(tree, [])

  @spec to_list_acc(t(), [interval()]) :: [interval()]
  defp to_list_acc(nil, acc), do: acc

  defp to_list_acc(node, acc) do
    acc = to_list_acc(node.right, acc)
    acc = [node.interval | acc]
    to_list_acc(node.left, acc)
  end

  @doc """
  Applies a transformation function to every interval in the tree and
  rebuilds it. Used for bulk anchor adjustment after buffer edits.

  The function receives an interval and returns either `{:keep, updated_interval}`
  or `:remove` (if the edit invalidated the interval, e.g., its entire
  range was deleted).

  Rebuilds from scratch via `from_list/1` after transformation, which is
  O(n log n). This is appropriate for edit-time updates (not per-frame).
  """
  @spec map_filter(t(), (interval() -> {:keep, interval()} | :remove)) :: t()
  def map_filter(tree, fun) do
    tree
    |> to_list()
    |> Enum.reduce([], fn interval, acc ->
      case fun.(interval) do
        {:keep, updated} -> [updated | acc]
        :remove -> acc
      end
    end)
    |> from_list()
  end

  @doc "Returns true if the tree is empty."
  @spec empty?(t()) :: boolean()
  def empty?(nil), do: true
  def empty?(_), do: false

  # ── AVL balancing ────────────────────────────────────────────────────────

  @spec height(t()) :: non_neg_integer()
  defp height(nil), do: 0
  defp height(%{height: h}), do: h

  @spec balance_factor(node_t()) :: integer()
  defp balance_factor(node) do
    height(node.left) - height(node.right)
  end

  @spec make_leaf(interval()) :: node_t()
  defp make_leaf(interval) do
    %{
      interval: interval,
      max_end: interval.end_,
      left: nil,
      right: nil,
      height: 1
    }
  end

  @spec make_node(interval(), t(), t()) :: node_t()
  defp make_node(interval, left, right) do
    max_e =
      interval.end_
      |> max_pos(subtree_max(left))
      |> max_pos(subtree_max(right))

    %{
      interval: interval,
      max_end: max_e,
      left: left,
      right: right,
      height: 1 + max(height(left), height(right))
    }
  end

  @spec subtree_max(t()) :: position()
  defp subtree_max(nil), do: {0, 0}
  defp subtree_max(%{max_end: m}), do: m

  @spec max_pos(position(), position()) :: position()
  defp max_pos(a, b) when a >= b, do: a
  defp max_pos(_a, b), do: b

  @spec rebalance(node_t()) :: node_t()
  defp rebalance(node) do
    apply_rotation(node, balance_factor(node))
  end

  @spec apply_rotation(node_t(), integer()) :: node_t()

  # Left-heavy
  defp apply_rotation(node, bf) when bf > 1 do
    rebalance_left_heavy(node, balance_factor(node.left))
  end

  # Right-heavy
  defp apply_rotation(node, bf) when bf < -1 do
    rebalance_right_heavy(node, balance_factor(node.right))
  end

  # Balanced: no rotation needed
  defp apply_rotation(node, _bf), do: node

  # Left child is left-heavy or balanced: single right rotation
  @spec rebalance_left_heavy(node_t(), integer()) :: node_t()
  defp rebalance_left_heavy(node, left_bf) when left_bf >= 0, do: rotate_right(node)

  # Left child is right-heavy: left-right double rotation
  defp rebalance_left_heavy(node, _left_bf) do
    new_left = rotate_left(node.left)
    rotate_right(make_node(node.interval, new_left, node.right))
  end

  # Right child is right-heavy or balanced: single left rotation
  @spec rebalance_right_heavy(node_t(), integer()) :: node_t()
  defp rebalance_right_heavy(node, right_bf) when right_bf <= 0, do: rotate_left(node)

  # Right child is left-heavy: right-left double rotation
  defp rebalance_right_heavy(node, _right_bf) do
    new_right = rotate_right(node.right)
    rotate_left(make_node(node.interval, node.left, new_right))
  end

  @spec rotate_right(node_t()) :: node_t()
  defp rotate_right(node) do
    left = node.left
    make_node(left.interval, left.left, make_node(node.interval, left.right, node.right))
  end

  @spec rotate_left(node_t()) :: node_t()
  defp rotate_left(node) do
    right = node.right
    make_node(right.interval, make_node(node.interval, node.left, right.left), right.right)
  end

  @spec merge_children(t(), t()) :: t()
  defp merge_children(nil, right), do: right
  defp merge_children(left, nil), do: left

  defp merge_children(left, right) do
    # Find the in-order successor (leftmost node of right subtree)
    {successor, new_right} = extract_min(right)
    make_node(successor, left, new_right) |> rebalance()
  end

  @spec extract_min(node_t()) :: {interval(), t()}
  defp extract_min(%{left: nil} = node), do: {node.interval, node.right}

  defp extract_min(node) do
    {min_interval, new_left} = extract_min(node.left)
    {min_interval, make_node(node.interval, new_left, node.right) |> rebalance()}
  end
end
