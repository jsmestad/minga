defmodule Minga.Test.UndoUnitModel do
  @moduledoc """
  A brute-force reference for which Minga tasks `SPC a u` may revert together.

  It enumerates sets of tasks and of your groups and keeps the minimal sets whose combined revert is exact, straight from the definition, without the dependency graph or Tarjan's algorithm that `Minga.Buffer.UndoHistory` uses. A set is exact when it holds a task and, for every task in it, every newer task that rewrote that task's text and every group that partly deleted one of its replacements is in the set too, and no permanent edit of yours did. A group of yours may join only when a task in the set rewrote its text after it, which blocks your undo of it, and none of its own text is still visible. The facts it reads (deleters, overlap marks, liveness) come from the runs directly.
  """

  alias Minga.Buffer.Author
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.UndoHistory

  @doc "Returns every minimal exact set, each as a `MapSet` of tasks and `{:you, group}` nodes."
  @spec revertable_units(UndoHistory.t()) :: MapSet.t()
  def revertable_units(history) do
    facts = facts(history)
    nodes = Map.keys(facts.tasks) ++ facts.your_candidates

    exact =
      nodes
      |> subsets()
      |> Enum.map(&MapSet.new/1)
      |> Enum.filter(&exact_set?(facts, &1))

    exact
    |> Enum.reject(fn set -> Enum.any?(exact, &(&1 != set and MapSet.subset?(&1, set))) end)
    |> MapSet.new()
  end

  @doc "Returns whether reverting the nodes in `set` together is exact."
  @spec exact?(UndoHistory.t(), Enumerable.t()) :: boolean()
  def exact?(history, set), do: exact_set?(facts(history), MapSet.new(set))

  @doc "Returns the text after reverting every group in `unit` together, from the runs' visibility rule."
  @spec reverted_text(UndoHistory.t(), binary(), [term()]) :: binary()
  def reverted_text(history, text, unit) do
    facts = facts(history)

    reverted =
      unit
      |> Enum.flat_map(fn
        {:you, group} -> [group]
        task -> Map.fetch!(facts.tasks, task)
      end)
      |> MapSet.new()

    applied? = &(Map.fetch!(facts.groups, &1).applied and not MapSet.member?(reverted, &1))

    {pieces, _offset} =
      Enum.reduce(facts.runs, {[], 0}, fn run, {pieces, offset} ->
        bytes = if run.live, do: binary_part(text, offset, run.bytes), else: run.text
        next = if run.live, do: offset + run.bytes, else: offset

        live? =
          (run.group == nil or applied?.(run.group)) and not Enum.any?(run.deletions, applied?)

        {if(live?, do: [bytes | pieces], else: pieces), next}
      end)

    pieces |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp facts(history) do
    %{minga: minga, untasked: untasked} = history
    provenance = UndoHistory.provenance(history)
    %{groups: groups} = provenance
    runs = Provenance.runs(provenance)

    tasks =
      minga
      |> Enum.reduce(%{}, fn {group, key}, acc ->
        Map.update(acc, Author.author(key), [group], &[group | &1])
      end)
      |> then(fn tasks ->
        case :queue.to_list(untasked) do
          [] -> tasks
          groups -> Map.put(tasks, {:minga, :untasked}, groups)
        end
      end)

    # A task started with the first group it opened, even once compaction merged that group into a newer one.
    %{task_started: started} = history

    starts =
      Map.new(tasks, fn {task, task_groups} ->
        {task, Map.get(started, task, Enum.min(task_groups))}
      end)

    facts = %{groups: groups, runs: runs, tasks: tasks, starts: starts}

    candidates =
      for {_task, task_groups} <- tasks,
          group <- task_groups,
          {:you, _id} = node <- overlap_nodes(facts, group, MapSet.new()),
          uniq: true,
          do: node

    Map.put(facts, :your_candidates, candidates)
  end

  defp exact_set?(facts, set) do
    tasks = for node <- set, not match?({:you, _group}, node), do: node
    reverted = set |> Enum.flat_map(&node_groups(facts, &1)) |> MapSet.new()

    tasks != [] and
      Enum.all?(set, fn
        {:you, group} ->
          rewriters = rewriter_tasks(facts, group, fn _task -> true end)

          own_live_bytes(facts, group) == 0 and Enum.any?(rewriters, &(&1 in set)) and
            Enum.all?(rewriters, &(&1 in set))

        task ->
          start = Map.fetch!(facts.starts, task)
          newer? = &(&1 != task and Map.get(facts.starts, &1, 0) > start)

          Enum.all?(Map.fetch!(facts.tasks, task), fn group ->
            Enum.all?(rewriter_tasks(facts, group, newer?), &(&1 in set)) and
              Enum.all?(
                overlap_nodes(facts, group, reverted),
                &(&1 != :permanent_you and &1 in set)
              )
          end)
      end)
  end

  defp node_groups(_facts, {:you, group}), do: [group]
  defp node_groups(facts, task), do: Map.fetch!(facts.tasks, task)

  # Tasks whose applied steps deleted text `group` wrote or removed, after it did.
  defp rewriter_tasks(facts, group, counts?) do
    for run <- facts.runs,
        run.group == group or group in run.deletions,
        deleter <- later(run, group),
        deleter_group = Map.fetch!(facts.groups, deleter),
        deleter_group.applied and deleter_group.author != :you,
        task = task_of(deleter_group.key),
        counts?.(task),
        uniq: true,
        do: task
  end

  defp later(%{group: id, deletions: deletions}, id), do: deletions
  defp later(run, id), do: Enum.take_while(run.deletions, &(&1 != id))

  defp overlap_nodes(facts, group, reverted) do
    for run <- facts.runs,
        group in run.deletions,
        {^group, overlap} <- run.overlaps,
        node = overlap_node(facts, overlap, reverted),
        uniq: true,
        do: node
  end

  defp overlap_node(_facts, {:permanent, :you}, _reverted), do: :permanent_you
  defp overlap_node(_facts, {:permanent, key}, _reverted), do: task_of(key)

  defp overlap_node(facts, id, reverted) do
    group = Map.fetch!(facts.groups, id)

    cond do
      MapSet.member?(reverted, id) -> nil
      not group.applied -> nil
      group.author == :you -> {:you, id}
      true -> task_of(group.key)
    end
  end

  defp own_live_bytes(facts, group) do
    for run <- facts.runs,
        run.group == group,
        run.live,
        reduce: 0,
        do: (bytes -> bytes + run.bytes)
  end

  defp task_of({:untasked, _n}), do: {:minga, :untasked}
  defp task_of(key), do: Author.author(key)

  defp subsets([]), do: [[]]

  defp subsets([node | rest]) do
    without = subsets(rest)
    without ++ Enum.map(without, &[node | &1])
  end
end
