defmodule Minga.Buffer.Provenance.RewriteScan do
  @moduledoc """
  Read-only rewrite facts cached for one Reject plan. Each run indexes its touch order once. Identical target prefixes share a node, so a group emits each dependency once without changing which later rewriters it requires.
  """

  alias Minga.Buffer.Provenance.{Group, Locator, Run, RunTree}

  @typep id :: Run.group_id()
  @typep prefix :: non_neg_integer()
  @typep position :: {prefix(), non_neg_integer(), boolean()}
  @typep run_facts :: {id() | nil, [id()], %{id() => position()}, prefix(), non_neg_integer()}
  @type requirement :: {Locator.t(), prefix(), non_neg_integer()}
  @type targets :: :none | {:one, id()} | {:all, prefix()}

  @opaque t :: %__MODULE__{
            runs: %{Locator.t() => run_facts() | :none},
            prefixes: %{{id(), prefix()} => prefix()},
            nodes: %{prefix() => {id(), prefix()}}
          }
  defstruct runs: %{}, prefixes: %{}, nodes: %{}

  @doc "Starts a planning scan without reading any runs."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Reads or reuses the rewrite requirements of the runs a group touched."
  @spec collect(t(), id(), :gb_sets.set(Locator.t()), RunTree.t(), %{id() => Group.t()}) ::
          {[requirement()], t()}
  def collect(%__MODULE__{} = scan, id, runs, tree, groups) do
    Enum.reduce(:gb_sets.to_list(runs), {[], scan}, fn locator, {requirements, scan} ->
      {facts, scan} = run_facts(scan, locator, tree, groups)

      case requirement(facts, id) do
        nil -> {requirements, scan}
        {prefix, cutoff} -> {[{locator, prefix, cutoff} | requirements], scan}
      end
    end)
  end

  @spec run_facts(t(), Locator.t(), RunTree.t(), %{id() => Group.t()}) ::
          {run_facts() | :none, t()}
  defp run_facts(scan, locator, tree, groups) do
    case scan.runs do
      %{^locator => facts} ->
        {facts, scan}

      _missing ->
        {:ok, run, _offset} = RunTree.fetch(tree, locator)
        {facts, scan} = index_run(scan, run, groups)
        {facts, %{scan | runs: Map.put(scan.runs, locator, facts)}}
    end
  end

  @spec index_run(t(), Run.t(), %{id() => Group.t()}) :: {run_facts() | :none, t()}
  defp index_run(scan, %Run{bytes: 0}, _groups), do: {:none, scan}
  defp index_run(scan, %Run{deletions: []}, _groups), do: {:none, scan}

  defp index_run(scan, %Run{group: writer, deletions: deleters}, groups) do
    {prefix, position, applied, positions, scan} =
      Enum.reduce(deleters, {0, 0, [], %{}, scan}, fn id, facts ->
        index_deleter(facts, id, Map.fetch!(groups, id))
      end)

    {{writer, applied, positions, prefix, position}, scan}
  end

  @spec index_deleter(
          {prefix(), non_neg_integer(), [id()], %{id() => position()}, t()},
          id(),
          Group.t()
        ) ::
          {prefix(), non_neg_integer(), [id()], %{id() => position()}, t()}
  defp index_deleter({prefix, position, applied, positions, scan}, id, group) do
    target? = group.applied and group.author != :you
    positions = Map.put(positions, id, {prefix, position, target?})
    applied = if group.applied, do: [id | applied], else: applied
    {next, scan} = if target?, do: intern(scan, {id, prefix}), else: {prefix, scan}
    {next, position + 1, applied, positions, scan}
  end

  @spec intern(t(), {id(), prefix()}) :: {prefix(), t()}
  defp intern(scan, key) do
    case scan.prefixes do
      %{^key => prefix} ->
        {prefix, scan}

      _missing ->
        prefix = map_size(scan.nodes) + 1
        nodes = Map.put(scan.nodes, prefix, key)
        {prefix, %{scan | prefixes: Map.put(scan.prefixes, key, prefix), nodes: nodes}}
    end
  end

  @spec requirement(run_facts() | :none, id()) :: {prefix(), non_neg_integer()} | nil
  defp requirement(:none, _id), do: nil
  defp requirement({id, _applied, _positions, 0, _cutoff}, id), do: nil
  defp requirement({id, _applied, _positions, prefix, cutoff}, id), do: {prefix, cutoff}

  defp requirement({_writer, _applied, positions, _prefix, _cutoff}, id) do
    case Map.fetch!(positions, id) do
      {0, _position, _target?} -> nil
      {prefix, cutoff, _target?} -> {prefix, cutoff}
    end
  end

  @doc "Returns the possible supporting writer and applied deletions of this requirement."
  @spec support_inputs(t(), requirement()) :: {id() | nil, [id()]}
  def support_inputs(%__MODULE__{} = scan, {locator, _prefix, _cutoff}) do
    {writer, deleters, _positions, _prefix, _length} = Map.fetch!(scan.runs, locator)
    {writer, deleters}
  end

  @doc "Finds which targets still have to revert under the given set of assumptions."
  @spec targets(t(), requirement(), id(), MapSet.t(id())) :: targets()
  def targets(%__MODULE__{} = scan, {locator, prefix, cutoff}, parent, assuming) do
    case Map.fetch!(scan.runs, locator) do
      {nil, _applied, _positions, _full, _length} ->
        {:all, prefix}

      {_writer, [_one], _positions, _full, _length} ->
        {:all, prefix}

      {writer, deleters, positions, _full, _length} ->
        requirement_targets(writer, deleters, positions, prefix, cutoff, parent, assuming)
    end
  end

  @spec requirement_targets(
          id(),
          [id()],
          %{id() => position()},
          prefix(),
          non_neg_integer(),
          id(),
          MapSet.t(id())
        ) :: targets()
  defp requirement_targets(writer, deleters, positions, prefix, cutoff, parent, assuming) do
    witnessed = if MapSet.member?(assuming, writer), do: support(deleters, assuming, nil)

    case witnessed do
      nil -> {:all, prefix}
      :several -> :none
      only -> sole_target(Map.fetch!(positions, only), cutoff, only, parent)
    end
  end

  # A target cannot use its own selection to waive the requirement that would include it.
  @spec support([id()], MapSet.t(id()), id() | nil) :: id() | nil | :several
  defp support([], _assuming, only), do: only

  defp support([id | rest], assuming, only) do
    cond do
      not MapSet.member?(assuming, id) -> support(rest, assuming, only)
      only == nil -> support(rest, assuming, id)
      true -> :several
    end
  end

  @spec sole_target(position(), non_neg_integer(), id(), id()) :: targets()
  defp sole_target({_prefix, position, true}, cutoff, only, parent)
       when position < cutoff and only != parent,
       do: {:one, only}

  defp sole_target(_position, _cutoff, _only, _parent), do: :none

  @doc "Folds fired dependencies once per shared prefix of a single parent."
  @spec reduce_required(t(), [requirement()], id(), MapSet.t(id()), acc, (id(), acc -> acc)) ::
          acc
        when acc: term()
  def reduce_required(%__MODULE__{}, [], _parent, _assuming, acc, _fun), do: acc

  def reduce_required(%__MODULE__{} = scan, requirements, parent, assuming, acc, fun) do
    requirements
    |> Enum.reduce({acc, MapSet.new()}, fn requirement, state ->
      fold_targets(targets(scan, requirement, parent, assuming), scan.nodes, parent, state, fun)
    end)
    |> elem(0)
  end

  @doc "Lists one rule's effective targets when comparing two assumptions."
  @spec target_ids(t(), targets(), id()) :: [id()]
  def target_ids(%__MODULE__{} = scan, targets, parent) do
    {ids, _seen} = fold_targets(targets, scan.nodes, parent, {[], MapSet.new()}, &[&1 | &2])
    ids
  end

  @spec fold_targets(
          targets(),
          %{prefix() => {id(), prefix()}},
          id(),
          {acc, MapSet.t(prefix())},
          (id(), acc -> acc)
        ) ::
          {acc, MapSet.t(prefix())}
        when acc: term()
  defp fold_targets(:none, _nodes, _parent, state, _fun), do: state
  defp fold_targets({:one, id}, _nodes, _parent, {acc, seen}, fun), do: {fun.(id, acc), seen}

  defp fold_targets({:all, prefix}, nodes, parent, state, fun),
    do: fold_prefix(prefix, nodes, parent, state, fun)

  @spec fold_prefix(
          prefix(),
          %{prefix() => {id(), prefix()}},
          id(),
          {acc, MapSet.t(prefix())},
          (id(), acc -> acc)
        ) ::
          {acc, MapSet.t(prefix())}
        when acc: term()
  defp fold_prefix(0, _nodes, _parent, state, _fun), do: state

  defp fold_prefix(prefix, nodes, parent, {acc, seen} = state, fun) do
    if MapSet.member?(seen, prefix) do
      state
    else
      {id, next} = Map.fetch!(nodes, prefix)
      acc = if id == parent, do: acc, else: fun.(id, acc)
      fold_prefix(next, nodes, parent, {acc, MapSet.put(seen, prefix)}, fun)
    end
  end
end
