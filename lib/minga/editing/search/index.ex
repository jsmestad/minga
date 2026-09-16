defmodule Minga.Editing.Search.Index do
  @moduledoc """
  Immutable order-statistic index for one line-local search query.

  Match-bearing lines live in a persistent treap augmented with subtree match
  counts. A lazy line offset on each subtree lets edits shift an unchanged
  suffix without walking it. The index preserves the byte-column semantics of
  `Minga.Editing.Search`.
  """

  alias Minga.Buffer.EditDelta
  alias Minga.Editing.Search
  alias Minga.Editing.Search.Match

  @type option :: {:case_sensitive, boolean()} | {:whole_word, boolean()} | {:regex, boolean()}
  @type line_matches :: tuple()
  @type tree_node ::
          nil
          | {non_neg_integer(), line_matches(), non_neg_integer(), tree_node(), tree_node(),
             integer(), non_neg_integer()}

  @type metrics :: %{
          scanned_lines: non_neg_integer(),
          scanned_bytes: non_neg_integer(),
          allocated_matches: non_neg_integer(),
          updated_lines: non_neg_integer(),
          suffix_shifts: non_neg_integer()
        }

  @enforce_keys [:query, :options, :root, :next_priority, :metrics]
  defstruct [:query, :options, :root, :next_priority, :metrics]

  @type t :: %__MODULE__{
          query: String.t(),
          options: [option()],
          root: tree_node(),
          next_priority: pos_integer(),
          metrics: metrics()
        }

  @doc "Builds an index by scanning each supplied line exactly once."
  @spec build([String.t()], String.t(), Search.search_opts()) :: t()
  def build(lines, query, options \\ []) when is_list(lines) and is_binary(query) do
    normalized_options = normalize_options(options)

    {root, next_priority, match_count, byte_count} =
      index_lines(nil, 1, lines, 0, query, normalized_options)

    %__MODULE__{
      query: query,
      options: normalized_options,
      root: root,
      next_priority: next_priority,
      metrics: %{
        scanned_lines: length(lines),
        scanned_bytes: byte_count,
        allocated_matches: match_count,
        updated_lines: 0,
        suffix_shifts: 0
      }
    }
  end

  @doc "Applies ordered edit deltas, then scans only the exact affected current lines."
  @spec apply_edits(t(), [EditDelta.t()], non_neg_integer(), [String.t()]) :: t()
  def apply_edits(%__MODULE__{} = index, deltas, first_line, lines)
      when is_list(deltas) and is_integer(first_line) and first_line >= 0 and is_list(lines) do
    shifted_root = Enum.reduce(deltas, index.root, &apply_delta/2)
    last_line = first_line + max(length(lines) - 1, 0)

    root =
      if lines == [], do: shifted_root, else: remove_range(shifted_root, first_line, last_line)

    {root, next_priority, match_count, byte_count} =
      index_lines(root, index.next_priority, lines, first_line, index.query, index.options)

    metrics = %{
      index.metrics
      | scanned_lines: index.metrics.scanned_lines + length(lines),
        scanned_bytes: index.metrics.scanned_bytes + byte_count,
        allocated_matches: index.metrics.allocated_matches + match_count,
        updated_lines: index.metrics.updated_lines + length(lines),
        suffix_shifts: index.metrics.suffix_shifts + Enum.count(deltas, &line_shift?/1)
    }

    %{index | root: root, next_priority: next_priority, metrics: metrics}
  end

  @doc "Returns the total number of matches."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{root: root}), do: node_count(root)

  @doc "Returns the one-based ordinal at or after the cursor, wrapping to one."
  @spec current_ordinal(t(), Search.position()) :: non_neg_integer()
  def current_ordinal(%__MODULE__{} = index, cursor) do
    case first_at_or_after_with_rank(index.root, cursor, 0) do
      nil -> if count(index) == 0, do: 0, else: 1
      {%Match{}, rank} -> rank + 1
    end
  end

  @doc "Returns the next match in the requested direction, with wraparound."
  @spec next(t(), Search.position(), Search.direction()) :: Match.t() | nil
  def next(%__MODULE__{root: nil}, _cursor, _direction), do: nil

  def next(%__MODULE__{root: root}, {line, col}, :forward) do
    first_after(root, {line, col}) || first_match(root)
  end

  def next(%__MODULE__{root: root}, {line, col}, :backward) do
    last_before(root, {line, col}) || last_match(root)
  end

  @doc "Returns the exact match beginning at the supplied byte position."
  @spec match_at(t(), Search.position()) :: Match.t() | nil
  def match_at(%__MODULE__{root: root}, {line, col}), do: exact_match(root, line, col)

  @doc "Returns every match in document order. Intended for verification and bulk edits."
  @spec to_matches(t()) :: [Match.t()]
  def to_matches(%__MODULE__{root: root}), do: collect_matches(root, [])

  @doc "Returns cumulative matching work for performance evidence."
  @spec metrics(t()) :: metrics()
  def metrics(%__MODULE__{metrics: metrics}), do: metrics

  @spec normalize_options(Search.search_opts()) :: [option()]
  defp normalize_options(options) do
    [
      case_sensitive: Keyword.get(options, :case_sensitive, true),
      whole_word: Keyword.get(options, :whole_word, false),
      regex: Keyword.get(options, :regex, false)
    ]
  end

  @spec index_lines(
          tree_node(),
          pos_integer(),
          [String.t()],
          non_neg_integer(),
          String.t(),
          Search.search_opts()
        ) :: {tree_node(), pos_integer(), non_neg_integer(), non_neg_integer()}
  defp index_lines(root, priority, lines, first_line, query, options) do
    matches =
      Search.find_all_in_range(lines, query, first_line, options)

    {root, next_priority} =
      matches
      |> Enum.chunk_by(& &1.line)
      |> Enum.reduce({root, priority}, fn line_matches, {tree, next_priority} ->
        [%Match{line: line_number} | _rest] = line_matches

        compact_matches =
          line_matches
          |> Enum.map(fn %Match{col: col, length: length} -> {col, length} end)
          |> List.to_tuple()

        tree = insert(tree, leaf(line_number, compact_matches, mixed_priority(next_priority)))
        {tree, next_priority + 1}
      end)

    scanned_bytes = Enum.reduce(lines, 0, &(byte_size(&1) + &2))
    {root, next_priority, length(matches), scanned_bytes}
  end

  @spec apply_delta(EditDelta.t(), tree_node()) :: tree_node()
  defp apply_delta(
         %EditDelta{
           start_position: {start_line, _},
           old_end_position: {old_end_line, _},
           new_end_position: {new_end_line, _}
         },
         root
       ) do
    root = remove_range(root, start_line, old_end_line)
    shift_suffix(root, old_end_line + 1, new_end_line - old_end_line)
  end

  @spec line_shift?(EditDelta.t()) :: boolean()
  defp line_shift?(%EditDelta{
         old_end_position: {old_end_line, _},
         new_end_position: {new_end_line, _}
       }),
       do: old_end_line != new_end_line

  @spec mixed_priority(pos_integer()) :: non_neg_integer()
  defp mixed_priority(value), do: :erlang.phash2({:gui_search_index, value})

  @spec leaf(non_neg_integer(), line_matches(), non_neg_integer()) :: tree_node()
  defp leaf(line, matches, priority),
    do: {line, matches, priority, nil, nil, 0, tuple_size(matches)}

  @spec make_node(
          non_neg_integer(),
          line_matches(),
          non_neg_integer(),
          tree_node(),
          tree_node(),
          integer()
        ) :: tree_node()
  defp make_node(line, matches, priority, left, right, lazy) do
    {line, matches, priority, left, right, lazy,
     tuple_size(matches) + node_count(left) + node_count(right)}
  end

  @spec node_count(tree_node()) :: non_neg_integer()
  defp node_count(nil), do: 0
  defp node_count({_line, _matches, _priority, _left, _right, _lazy, count}), do: count

  @spec add_shift(tree_node(), integer()) :: tree_node()
  defp add_shift(nil, _shift), do: nil
  defp add_shift(node, 0), do: node

  defp add_shift({line, matches, priority, left, right, lazy, count}, shift) do
    {line + shift, matches, priority, left, right, lazy + shift, count}
  end

  @spec push(tree_node()) :: tree_node()
  defp push({line, matches, priority, left, right, 0, count}),
    do: {line, matches, priority, left, right, 0, count}

  defp push({line, matches, priority, left, right, lazy, count}) do
    {line, matches, priority, add_shift(left, lazy), add_shift(right, lazy), 0, count}
  end

  @spec insert(tree_node(), tree_node()) :: tree_node()
  defp insert(nil, node), do: node

  defp insert(root, {_line, _matches, node_priority, _left, _right, _lazy, _count} = node) do
    {root_line, root_matches, root_priority, left, right, _lazy, _count} = push(root)

    {node_line, node_matches, _priority, node_left, node_right, _node_lazy, _node_count} =
      push(node)

    if node_priority < root_priority do
      {new_left, new_right} = split(root, node_line)

      make_node(
        node_line,
        node_matches,
        node_priority,
        merge(new_left, node_left),
        merge(node_right, new_right),
        0
      )
    else
      if node_line < root_line do
        make_node(root_line, root_matches, root_priority, insert(left, node), right, 0)
      else
        make_node(root_line, root_matches, root_priority, left, insert(right, node), 0)
      end
    end
  end

  @spec split(tree_node(), non_neg_integer()) :: {tree_node(), tree_node()}
  defp split(nil, _line), do: {nil, nil}

  defp split(root, line) do
    {root_line, matches, priority, left, right, _lazy, _count} = push(root)

    if root_line < line do
      {less_right, greater} = split(right, line)
      {make_node(root_line, matches, priority, left, less_right, 0), greater}
    else
      {less, greater_left} = split(left, line)
      {less, make_node(root_line, matches, priority, greater_left, right, 0)}
    end
  end

  @spec merge(tree_node(), tree_node()) :: tree_node()
  defp merge(nil, right), do: right
  defp merge(left, nil), do: left

  defp merge(left, right) do
    {left_line, left_matches, left_priority, left_left, left_right, _left_lazy, _left_count} =
      push(left)

    {right_line, right_matches, right_priority, right_left, right_right, _right_lazy,
     _right_count} = push(right)

    if left_priority < right_priority do
      make_node(left_line, left_matches, left_priority, left_left, merge(left_right, right), 0)
    else
      make_node(
        right_line,
        right_matches,
        right_priority,
        merge(left, right_left),
        right_right,
        0
      )
    end
  end

  @spec remove_range(tree_node(), non_neg_integer(), non_neg_integer()) :: tree_node()
  defp remove_range(root, first_line, last_line) do
    {before, from_first} = split(root, first_line)
    {_removed, after_last} = split(from_first, last_line + 1)
    merge(before, after_last)
  end

  @spec shift_suffix(tree_node(), non_neg_integer(), integer()) :: tree_node()
  defp shift_suffix(root, _first_line, 0), do: root

  defp shift_suffix(root, first_line, shift) do
    {before, suffix} = split(root, first_line)
    merge(before, add_shift(suffix, shift))
  end

  @spec first_at_or_after_with_rank(tree_node(), Search.position(), non_neg_integer()) ::
          {Match.t(), non_neg_integer()} | nil
  defp first_at_or_after_with_rank(nil, _position, _preceding_count), do: nil

  defp first_at_or_after_with_rank(root, {line, col} = position, preceding_count) do
    {root_line, matches, _priority, left, right, _lazy, _count} = push(root)
    left_count = node_count(left)
    line_count = tuple_size(matches)

    case root_line do
      n when n < line ->
        first_at_or_after_with_rank(
          right,
          position,
          preceding_count + left_count + line_count
        )

      ^line ->
        match_on_or_after_with_rank(
          matches,
          root_line,
          col,
          preceding_count + left_count
        ) ||
          first_match_with_rank(right, preceding_count + left_count + line_count)

      _ ->
        first_at_or_after_with_rank(left, position, preceding_count) ||
          first_line_match_with_rank(root_line, matches, preceding_count + left_count)
    end
  end

  @spec first_after(tree_node(), Search.position()) :: Match.t() | nil
  defp first_after(nil, _position), do: nil

  defp first_after(root, {line, col} = position) do
    {root_line, matches, _priority, left, right, _lazy, _count} = push(root)

    case root_line do
      n when n < line -> first_after(right, position)
      ^line -> match_after(matches, root_line, col) || first_match(right)
      _ -> first_after(left, position) || first_line_match(root_line, matches)
    end
  end

  @spec last_before(tree_node(), Search.position()) :: Match.t() | nil
  defp last_before(nil, _position), do: nil

  defp last_before(root, {line, col} = position) do
    {root_line, matches, _priority, left, right, _lazy, _count} = push(root)

    case root_line do
      n when n > line -> last_before(left, position)
      ^line -> match_before(matches, root_line, col) || last_match(left)
      _ -> last_before(right, position) || last_line_match(root_line, matches)
    end
  end

  @spec exact_match(tree_node(), non_neg_integer(), non_neg_integer()) :: Match.t() | nil
  defp exact_match(nil, _line, _col), do: nil

  defp exact_match(root, line, col) do
    {root_line, matches, _priority, left, right, _lazy, _count} = push(root)

    case root_line do
      n when n < line ->
        exact_match(right, line, col)

      n when n > line ->
        exact_match(left, line, col)

      _ ->
        case tuple_match(matches, lower_bound(matches, col), line) do
          %Match{col: ^col} = match -> match
          _other -> nil
        end
    end
  end

  @spec first_match(tree_node()) :: Match.t() | nil
  defp first_match(nil), do: nil

  defp first_match(root) do
    {line, matches, _priority, left, _right, _lazy, _count} = push(root)
    first_match(left) || first_line_match(line, matches)
  end

  @spec last_match(tree_node()) :: Match.t() | nil
  defp last_match(nil), do: nil

  defp last_match(root) do
    {line, matches, _priority, _left, right, _lazy, _count} = push(root)
    last_match(right) || last_line_match(line, matches)
  end

  @spec first_match_with_rank(tree_node(), non_neg_integer()) ::
          {Match.t(), non_neg_integer()} | nil
  defp first_match_with_rank(nil, _preceding_count), do: nil

  defp first_match_with_rank(root, preceding_count) do
    {line, matches, _priority, left, _right, _lazy, _count} = push(root)

    first_match_with_rank(left, preceding_count) ||
      first_line_match_with_rank(line, matches, preceding_count + node_count(left))
  end

  @spec first_line_match(non_neg_integer(), line_matches()) :: Match.t()
  defp first_line_match(line, matches) do
    {col, length} = elem(matches, 0)
    Match.new(line, col, length)
  end

  @spec first_line_match_with_rank(non_neg_integer(), line_matches(), non_neg_integer()) ::
          {Match.t(), non_neg_integer()}
  defp first_line_match_with_rank(line, matches, rank),
    do: {first_line_match(line, matches), rank}

  @spec last_line_match(non_neg_integer(), line_matches()) :: Match.t()
  defp last_line_match(line, matches) do
    {col, length} = elem(matches, tuple_size(matches) - 1)
    Match.new(line, col, length)
  end

  @spec match_on_or_after_with_rank(
          line_matches(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {Match.t(), non_neg_integer()} | nil
  defp match_on_or_after_with_rank(matches, line, col, preceding_count) do
    index = lower_bound(matches, col)

    case tuple_match(matches, index, line) do
      nil -> nil
      match -> {match, preceding_count + index}
    end
  end

  @spec match_after(line_matches(), non_neg_integer(), non_neg_integer()) :: Match.t() | nil
  defp match_after(matches, line, col),
    do: tuple_match(matches, upper_bound(matches, col), line)

  @spec match_before(line_matches(), non_neg_integer(), non_neg_integer()) :: Match.t() | nil
  defp match_before(matches, line, col),
    do: tuple_match(matches, lower_bound(matches, col) - 1, line)

  @spec lower_bound(line_matches(), non_neg_integer()) :: non_neg_integer()
  defp lower_bound(matches, col), do: lower_bound(matches, col, 0, tuple_size(matches))

  @spec lower_bound(line_matches(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp lower_bound(_matches, _col, low, high) when low >= high, do: low

  defp lower_bound(matches, col, low, high) do
    middle = div(low + high, 2)
    {match_col, _length} = elem(matches, middle)

    if match_col < col,
      do: lower_bound(matches, col, middle + 1, high),
      else: lower_bound(matches, col, low, middle)
  end

  @spec upper_bound(line_matches(), non_neg_integer()) :: non_neg_integer()
  defp upper_bound(matches, col), do: upper_bound(matches, col, 0, tuple_size(matches))

  @spec upper_bound(line_matches(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp upper_bound(_matches, _col, low, high) when low >= high, do: low

  defp upper_bound(matches, col, low, high) do
    middle = div(low + high, 2)
    {match_col, _length} = elem(matches, middle)

    if match_col <= col,
      do: upper_bound(matches, col, middle + 1, high),
      else: upper_bound(matches, col, low, middle)
  end

  @spec tuple_match(line_matches(), integer(), non_neg_integer()) :: Match.t() | nil
  defp tuple_match(matches, index, _line) when index < 0 or index >= tuple_size(matches), do: nil

  defp tuple_match(matches, index, line) do
    {col, length} = elem(matches, index)
    Match.new(line, col, length)
  end

  @spec collect_matches(tree_node(), [Match.t()]) :: [Match.t()]
  defp collect_matches(nil, acc), do: acc

  defp collect_matches(root, acc) do
    {line, matches, _priority, left, right, _lazy, _count} = push(root)
    acc = collect_matches(right, acc)

    acc =
      Enum.reduce(matches |> Tuple.to_list() |> Enum.reverse(), acc, fn {col, length}, items ->
        [Match.new(line, col, length) | items]
      end)

    collect_matches(left, acc)
  end
end
