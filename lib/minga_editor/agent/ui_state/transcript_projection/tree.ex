defmodule MingaEditor.Agent.UIState.TranscriptProjection.Tree do
  @moduledoc false

  alias MingaEditor.Agent.UIState.TranscriptProjection.Row

  @empty_summary {0, 0, 0, 0, 0, nil, nil, false}

  @type metric :: :entries | :lines | :pins | :pin_lines
  @type selection :: :all | :pinned
  @typep summary ::
           {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
            non_neg_integer(), String.t() | nil, String.t() | nil, boolean()}
  @typep subtree :: nil | Row.t() | {:branch, subtree(), subtree(), summary()}

  defstruct root: nil, capacity: 1

  @opaque t :: %__MODULE__{root: subtree(), capacity: pos_integer()}

  @doc "Builds a dense ordinal range in one traversal at a replacement boundary."
  @spec new([Row.t()]) :: t()
  def new([]), do: %__MODULE__{}

  def new(rows) when is_list(rows) do
    count = length(rows)
    capacity = capacity_for(count, 1)
    {root, []} = build(rows, count, capacity)
    %__MODULE__{root: root, capacity: capacity}
  end

  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{root: root}), do: weight(root, :entries)

  @spec line_slots(t()) :: non_neg_integer()
  def line_slots(%__MODULE__{root: root}), do: weight(root, :lines)

  @spec names_and_turns(t()) :: {String.t() | nil, String.t() | nil, non_neg_integer()}
  def names_and_turns(%__MODULE__{root: root}) do
    {_, _, _, _, turns, user, assistant, _} = summary(root)
    {user, assistant, turns}
  end

  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{root: {:branch, _, _, {_, _, _, _, turns, _, _, _}}}), do: turns
  def turn_count(%__MODULE__{root: %Row{role: {:user, _}}}), do: 1
  def turn_count(%__MODULE__{}), do: 0

  @spec first_run?(t()) :: boolean()
  def first_run?(%__MODULE__{root: root}), do: not elem(summary(root), 7)

  @doc "Returns one exact ordinal without visiting its siblings."
  @spec fetch(t(), non_neg_integer()) :: Row.t() | nil
  def fetch(%__MODULE__{root: root, capacity: capacity}, ordinal)
      when ordinal >= 0 and ordinal < capacity,
      do: fetch(root, capacity, ordinal)

  def fetch(%__MODULE__{}, _ordinal), do: nil

  @doc "Copies a changed ordinal's path and returns the old and new leaf and the two preceding line weights."
  @spec update(t(), non_neg_integer(), (Row.t() | nil -> Row.t())) ::
          {t(), Row.t() | nil, Row.t(), non_neg_integer(), non_neg_integer()}
  def update(%__MODULE__{root: root, capacity: ordinal}, ordinal, update) do
    {right, summary, before, after_row, lines, pin_lines} = replace(nil, ordinal, 0, update)
    {next, lines, pin_lines} = install_right(root, right, summary, lines, pin_lines)
    {%__MODULE__{root: next, capacity: ordinal * 2}, before, after_row, lines, pin_lines}
  end

  def update(%__MODULE__{root: root, capacity: capacity} = tree, ordinal, update)
      when ordinal >= 0 and ordinal < capacity do
    {next, _summary, before, after_row, lines, pin_lines} =
      replace(root, capacity, ordinal, update)

    {%{tree | root: next}, before, after_row, lines, pin_lines}
  end

  @doc "Measures one cached weight over all ordinals strictly before the cut."
  @spec prefix(t(), non_neg_integer(), metric()) :: non_neg_integer()
  def prefix(%__MODULE__{root: root, capacity: capacity}, cut, metric),
    do: prefix(root, capacity, cut, metric)

  @doc "Finds a row and intra-row offset by its absolute weighted line, including separators."
  @spec line_at(t(), non_neg_integer(), :lines | :pin_lines) ::
          {Row.t(), non_neg_integer()} | nil
  def line_at(%__MODULE__{root: root}, offset, metric) when offset >= 0 do
    if offset < weight(root, metric), do: locate(root, offset, metric)
  end

  @doc "Folds just the selected rows in ordinal order. Bounds are half open."
  @spec reduce_range(t(), non_neg_integer(), non_neg_integer(), selection(), acc, (Row.t(), acc ->
                                                                                     acc)) ::
          acc
        when acc: term()
  def reduce_range(%__MODULE__{root: root, capacity: capacity}, from, to, selection, acc, reduce)
      when from <= to do
    reduce_range(root, capacity, from, to, selection, acc, reduce)
  end

  @doc "Updates only selected leaves, reusing subtrees outside the affected range."
  @spec map_range(t(), non_neg_integer(), non_neg_integer(), selection(), (Row.t() -> Row.t())) ::
          t()
  def map_range(%__MODULE__{root: root, capacity: capacity} = tree, from, to, selection, map)
      when from <= to do
    %{tree | root: map_range(root, capacity, from, to, selection, map)}
  end

  @doc """
  Lists, in ascending order, the ordinals whose leaves differ between two trees of one generation.

  Shared subtrees compare by identity first, so the walk visits only the copied paths of changed or appended leaves.
  """
  @spec changed_ordinals(t(), t()) :: [non_neg_integer()]
  def changed_ordinals(%__MODULE__{root: root, capacity: capacity}, %__MODULE__{
        root: root,
        capacity: capacity
      }),
      do: []

  def changed_ordinals(%__MODULE__{root: old, capacity: old_capacity}, %__MODULE__{
        root: new,
        capacity: new_capacity
      }) do
    old
    |> changed(old_capacity, new, new_capacity, 0, [])
    |> Enum.reverse()
  end

  defp changed(old, old_capacity, new, new_capacity, offset, acc)
       when old_capacity < new_capacity do
    half = div(new_capacity, 2)
    {left, right} = children(new)
    acc = changed(old, old_capacity, left, half, offset, acc)
    leaf_ordinals(right, half, offset + half, acc)
  end

  defp changed(old, old_capacity, new, new_capacity, offset, acc)
       when old_capacity > new_capacity do
    half = div(old_capacity, 2)
    {left, right} = children(old)
    acc = changed(left, half, new, new_capacity, offset, acc)
    leaf_ordinals(right, half, offset + half, acc)
  end

  defp changed(same, _capacity, same, _same_capacity, _offset, acc), do: acc
  defp changed(_old, 1, _new, 1, offset, acc), do: [offset | acc]

  defp changed(old, capacity, new, capacity, offset, acc) do
    half = div(capacity, 2)
    {old_left, old_right} = children(old)
    {new_left, new_right} = children(new)
    acc = changed(old_left, half, new_left, half, offset, acc)
    changed(old_right, half, new_right, half, offset + half, acc)
  end

  defp children(nil), do: {nil, nil}
  defp children({:branch, left, right, _summary}), do: {left, right}

  defp leaf_ordinals(nil, _capacity, _offset, acc), do: acc
  defp leaf_ordinals(%Row{}, 1, offset, acc), do: [offset | acc]

  defp leaf_ordinals({:branch, left, right, _summary}, capacity, offset, acc) do
    half = div(capacity, 2)
    acc = leaf_ordinals(left, half, offset, acc)
    leaf_ordinals(right, half, offset + half, acc)
  end

  defp capacity_for(count, capacity) when count <= capacity, do: capacity
  defp capacity_for(count, capacity), do: capacity_for(count, capacity * 2)

  defp build(rows, 0, _capacity), do: {nil, rows}
  defp build([row | rest], 1, 1), do: {row, rest}

  defp build(rows, count, capacity) do
    half = div(capacity, 2)
    left_size = min(count, half)
    {left, rest} = build(rows, left_size, half)
    {right, rest} = build(rest, count - left_size, half)
    {branch(left, right), rest}
  end

  defp fetch(nil, _capacity, _ordinal), do: nil
  defp fetch(%Row{} = row, 1, 0), do: row

  defp fetch({:branch, left, right, _summary}, capacity, ordinal) do
    half = div(capacity, 2)

    if ordinal < half,
      do: fetch(left, half, ordinal),
      else: fetch(right, half, ordinal - half)
  end

  defp replace(before, 1, 0, update) do
    after_row = update.(before)
    {after_row, summary(after_row), before, after_row, 0, 0}
  end

  defp replace(nil, capacity, ordinal, update),
    do: replace_branch(nil, nil, capacity, ordinal, update)

  defp replace({:branch, left, right, _summary}, capacity, ordinal, update),
    do: replace_branch(left, right, capacity, ordinal, update)

  defp replace_branch(left, right, capacity, ordinal, update) do
    half = div(capacity, 2)

    if ordinal < half do
      {next, next_summary, before, after_row, lines, pin_lines} =
        replace(left, half, ordinal, update)

      rebuilt = branch(next, right, next_summary, summary(right))
      {rebuilt, elem(rebuilt, 3), before, after_row, lines, pin_lines}
    else
      {next, next_summary, before, after_row, lines, pin_lines} =
        replace(right, half, ordinal - half, update)

      {rebuilt, lines, pin_lines} = install_right(left, next, next_summary, lines, pin_lines)
      {rebuilt, elem(rebuilt, 3), before, after_row, lines, pin_lines}
    end
  end

  defp prefix(nil, _capacity, _cut, _metric), do: 0
  defp prefix(_node, _capacity, 0, _metric), do: 0
  defp prefix(node, capacity, cut, metric) when cut >= capacity, do: weight(node, metric)

  defp prefix({:branch, left, right, _summary}, capacity, cut, metric) do
    half = div(capacity, 2)

    if cut <= half,
      do: prefix(left, half, cut, metric),
      else: weight(left, metric) + prefix(right, half, cut - half, metric)
  end

  defp locate(%Row{} = row, offset, _metric), do: {row, offset}

  defp locate({:branch, left, right, _summary}, offset, metric) do
    left_weight = weight(left, metric)

    if offset < left_weight,
      do: locate(left, offset, metric),
      else: locate(right, offset - left_weight, metric)
  end

  defp reduce_range(node, capacity, from, to, selection, acc, reduce) do
    if included?(node, capacity, from, to, selection) do
      reduce_selected(node, capacity, from, to, selection, acc, reduce)
    else
      acc
    end
  end

  defp reduce_selected(%Row{} = row, 1, _from, _to, _selection, acc, reduce),
    do: reduce.(row, acc)

  defp reduce_selected(
         {:branch, left, right, _summary},
         capacity,
         from,
         to,
         selection,
         acc,
         reduce
       ) do
    half = div(capacity, 2)
    acc = reduce_range(left, half, from, to, selection, acc, reduce)
    reduce_range(right, half, from - half, to - half, selection, acc, reduce)
  end

  defp map_range(node, capacity, from, to, selection, map) do
    if included?(node, capacity, from, to, selection) do
      map_selected(node, capacity, from, to, selection, map)
    else
      node
    end
  end

  defp map_selected(%Row{} = row, 1, _from, _to, _selection, map), do: map.(row)

  defp map_selected({:branch, left, right, _summary} = node, capacity, from, to, selection, map) do
    half = div(capacity, 2)
    mapped_left = map_range(left, half, from, to, selection, map)
    mapped_right = map_range(right, half, from - half, to - half, selection, map)

    # Keep an unchanged subtree's identity so presentation changes stay local.
    if mapped_left === left and mapped_right === right,
      do: node,
      else: branch(mapped_left, mapped_right)
  end

  defp included?(nil, _capacity, _from, _to, _selection), do: false

  defp included?(_node, capacity, from, to, _selection)
       when to <= 0 or from >= capacity or from >= to, do: false

  defp included?(node, _capacity, _from, _to, :pinned), do: weight(node, :pins) > 0
  defp included?(_node, _capacity, _from, _to, :all), do: true

  defp install_right(left, right, right_summary, lines, pin_lines) do
    {_, left_lines, _, left_pin_lines, _, _, _, _} = left_summary = summary(left)

    {branch(left, right, left_summary, right_summary), lines + left_lines,
     pin_lines + left_pin_lines}
  end

  defp branch(left, right), do: branch(left, right, summary(left), summary(right))

  defp branch(left, right, left_summary, right_summary) do
    {lc, ll, lp, lpl, lu, l_user, l_agent, l_turn?} = left_summary
    {rc, rl, rp, rpl, ru, r_user, r_agent, r_turn?} = right_summary

    {:branch, left, right,
     {lc + rc, ll + rl, lp + rp, lpl + rpl, lu + ru, l_user || r_user, l_agent || r_agent,
      l_turn? or r_turn?}}
  end

  defp summary(nil), do: @empty_summary
  defp summary({:branch, _left, _right, summary}), do: summary

  defp summary(%Row{lines: {count, _types}, pinned?: pinned?, role: role}) do
    lines = count + 1
    {pins, pin_lines} = if pinned?, do: {1, lines}, else: {0, 0}

    case role do
      {:user, text} -> {1, lines, pins, pin_lines, 1, text, nil, true}
      {:assistant, text} -> {1, lines, pins, pin_lines, 0, nil, text, true}
      :turn -> {1, lines, pins, pin_lines, 0, nil, nil, true}
      :system -> {1, lines, pins, pin_lines, 0, nil, nil, false}
    end
  end

  defp weight(nil, _metric), do: 0
  defp weight(%Row{}, :entries), do: 1
  defp weight(%Row{lines: {count, _types}}, :lines), do: count + 1
  defp weight(%Row{pinned?: true}, :pins), do: 1
  defp weight(%Row{pinned?: true, lines: {count, _types}}, :pin_lines), do: count + 1
  defp weight(%Row{}, metric) when metric in [:pins, :pin_lines], do: 0
  defp weight({:branch, _, _, {entries, _, _, _, _, _, _, _}}, :entries), do: entries
  defp weight({:branch, _, _, {_, lines, _, _, _, _, _, _}}, :lines), do: lines
  defp weight({:branch, _, _, {_, _, pins, _, _, _, _, _}}, :pins), do: pins
  defp weight({:branch, _, _, {_, _, _, lines, _, _, _, _}}, :pin_lines), do: lines
end
