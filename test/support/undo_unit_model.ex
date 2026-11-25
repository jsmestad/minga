defmodule Minga.Test.UndoUnitModel do
  @moduledoc """
  A brute-force reference for which Minga tasks `SPC a u` may revert together.

  It enumerates sets of tasks and of your groups and keeps the minimal sets whose combined revert is exact, straight from the definition, without the dependency graph or Tarjan's algorithm that `Minga.Buffer.UndoHistory` uses. A set is exact when it holds a task and, for every task in it, every newer task that rewrote that task's text and every group that partly deleted one of its replacements is in the set too, and no permanent edit of yours did. A group of yours may join only when a task in the set rewrote its text after it, which blocks your undo of it, none of its own text is still visible, the tasks whose text it deleted are in the set too, and its revert brings back no other text it deleted. The facts it reads (deleters, overlap marks, liveness) come from the runs directly.
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

  @doc """
  Returns whether reverting the groups in `groups` together is exact, at group level: every applied Minga group that later deleted text one of them wrote or removed is in the set (your later deletions never block, and text the set both wrote and deleted does not count), every group that edited inside a Minga group's replacement is in the set and no permanent edit did, and every group of yours in the set has no visible text, brings back no other text it deleted, and has its Minga rewriters in the set.
  """
  @spec exact_groups?(UndoHistory.t(), [pos_integer()]) :: boolean()
  def exact_groups?(history, groups) do
    %{groups: all} = provenance = UndoHistory.provenance(history)
    runs = Provenance.runs(provenance)
    set = MapSet.new(groups)
    applied? = &Map.fetch!(all, &1).applied

    Enum.all?(groups, fn group ->
      yours? = Map.fetch!(all, group).author == :you

      rewriters =
        for run <- runs,
            not internal?(run, set),
            removed_by?(run, group),
            d <- later(run, group),
            d != group and d not in run.covered_by,
            applied?.(d),
            Map.fetch!(all, d).author != :you,
            uniq: true,
            do: d

      kept = Map.get(provenance.group_marks, group, [])

      marks =
        for overlap <-
              for(
                run <- runs,
                run.group == group or group in run.deletions,
                {^group, o} <- run.overlaps,
                do: o
              ) ++ kept,
            uniq: true do
          if is_integer(overlap), do: overlap, else: :permanent
        end

      Enum.all?(rewriters, &MapSet.member?(set, &1)) and
        if yours? do
          visible = Enum.any?(runs, &(&1.group == group and &1.live))

          revives =
            Enum.any?(runs, fn run ->
              run.group != group and group in run.deletions and
                (run.group == nil or (applied?.(run.group) and not MapSet.member?(set, run.group))) and
                not Enum.any?(run.deletions, &(applied?.(&1) and not MapSet.member?(set, &1)))
            end)

          not visible and not revives
        else
          Enum.all?(marks, &(&1 != :permanent and (not applied?.(&1) or MapSet.member?(set, &1))))
        end
    end)
  end

  @doc "Returns the text after reverting the groups in `groups` together, by the runs' visibility rule."
  @spec reverted_groups_text(UndoHistory.t(), binary(), [pos_integer()]) :: binary()
  def reverted_groups_text(history, text, groups) do
    %{groups: all} = provenance = UndoHistory.provenance(history)
    reverted = MapSet.new(groups)
    applied? = &(Map.fetch!(all, &1).applied and not MapSet.member?(reverted, &1))

    {pieces, _offset} =
      Enum.reduce(Provenance.runs(provenance), {[], 0}, fn run, {pieces, offset} ->
        bytes = if run.live, do: binary_part(text, offset, run.bytes), else: run.text
        next = if run.live, do: offset + run.bytes, else: offset

        live? =
          (run.group == nil or applied?.(run.group)) and not Enum.any?(run.deletions, applied?)

        {if(live?, do: [bytes | pieces], else: pieces), next}
      end)

    pieces |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @doc """
  Returns whether every dependency between groups points from an older group to a newer one: a later deleter of a group's text, a group that marked its replacement, and a Minga rewriter of your group.
  """
  @spec acyclic?(UndoHistory.t()) :: boolean()
  def acyclic?(history) do
    %{groups: all} = provenance = UndoHistory.provenance(history)
    runs = Provenance.runs(provenance)

    deleter_edges =
      for run <- runs,
          group <- Enum.reject([run.group | run.deletions], &is_nil/1),
          Map.has_key?(all, group),
          d <- later(run, group),
          d != group,
          Map.fetch!(all, d).author != :you,
          do: {group, d}

    mark_edges =
      for run <- runs, {owner, overlap} <- run.overlaps, is_integer(overlap), do: {owner, overlap}

    # Steps compaction merged revert as one node: an edge counts between their classes. Cycles through Minga steps of
    # other tasks are allowed (the walk takes the whole component); the components must form no cycle.
    history
    |> class_edges(deleter_edges ++ mark_edges)
    |> components()
    |> condensed()
    |> acyclic_graph?()
  end

  @doc """
  Returns whether some strongly connected component of the merged dependency graph with more than one node holds a group of yours with visible text. That is the round-4 deadlock in the merged view: the component would be held by your edit while a step in it blocks your undo.
  """
  @spec held_component?(UndoHistory.t()) :: boolean()
  def held_component?(history), do: held_components(history) != []

  @doc "Returns the components `held_component?/1` finds, with the edges between their nodes."
  @spec held_components(UndoHistory.t()) :: [MapSet.t()]
  def held_components(history) do
    %{groups: all} = provenance = UndoHistory.provenance(history)
    runs = Provenance.runs(provenance)

    edges =
      for run <- runs,
          group <- Enum.reject([run.group | run.deletions], &is_nil/1),
          Map.has_key?(all, group),
          d <- later(run, group),
          d != group,
          Map.fetch!(all, d).author != :you,
          do: {group, d}

    marks =
      for run <- runs, {owner, overlap} <- run.overlaps, is_integer(overlap), do: {owner, overlap}

    history
    |> class_edges(edges ++ marks)
    |> components()
    |> elem(0)
    |> Enum.filter(fn component ->
      MapSet.size(component) > 1 and
        Enum.any?(component, fn group ->
          Map.has_key?(all, group) and Map.fetch!(all, group).author == :you and
            Provenance.live_bytes_of(provenance, group) > 0
        end)
    end)
  end

  defp class_edges(history, edges) do
    class = fn group -> history |> UndoHistory.merge_class(group) |> Enum.max() end
    for {from, to} <- edges, a = class.(from), b = class.(to), a != b, uniq: true, do: {a, b}
  end

  # Strongly connected components by Kosaraju's algorithm, each a set of nodes.
  defp components(edges) do
    nodes = edges |> Enum.flat_map(fn {a, b} -> [a, b] end) |> Enum.uniq()
    forward = Enum.group_by(edges, &elem(&1, 0), &elem(&1, 1))
    backward = Enum.group_by(edges, &elem(&1, 1), &elem(&1, 0))

    {order, _seen} =
      Enum.reduce(nodes, {[], MapSet.new()}, fn node, {order, seen} ->
        visit(node, forward, order, seen)
      end)

    {components, _seen} =
      Enum.reduce(order, {[], MapSet.new()}, fn node, {components, seen} ->
        if MapSet.member?(seen, node) do
          {components, seen}
        else
          {component, seen} = collect(node, backward, MapSet.new(), seen)
          {[component | components], seen}
        end
      end)

    {components, edges}
  end

  defp visit(node, graph, order, seen) do
    if MapSet.member?(seen, node) do
      {order, seen}
    else
      {order, seen} =
        graph
        |> Map.get(node, [])
        |> Enum.reduce({order, MapSet.put(seen, node)}, fn next, {o, s} ->
          visit(next, graph, o, s)
        end)

      {[node | order], seen}
    end
  end

  defp collect(node, graph, component, seen) do
    if MapSet.member?(seen, node) do
      {component, seen}
    else
      graph
      |> Map.get(node, [])
      |> Enum.reduce({MapSet.put(component, node), MapSet.put(seen, node)}, fn next, {c, s} ->
        collect(next, graph, c, s)
      end)
    end
  end

  # The edges between components.
  defp condensed({components, edges}) do
    index =
      components
      |> Enum.with_index()
      |> Enum.flat_map(fn {component, i} -> Enum.map(component, &{&1, i}) end)
      |> Map.new()

    for {a, b} <- edges, x = index[a], y = index[b], x != y, uniq: true, do: {x, y}
  end

  # Kahn's algorithm: the graph is acyclic when repeatedly removing nodes with no incoming edge removes every node.
  defp acyclic_graph?([]), do: true

  defp acyclic_graph?(edges) do
    targets = MapSet.new(edges, &elem(&1, 1))

    sources =
      edges |> Enum.map(&elem(&1, 0)) |> Enum.reject(&MapSet.member?(targets, &1)) |> MapSet.new()

    if MapSet.size(sources) == 0,
      do: false,
      else: edges |> Enum.reject(&MapSet.member?(sources, elem(&1, 0))) |> acyclic_graph?()
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

    facts = %{
      groups: groups,
      runs: runs,
      tasks: tasks,
      starts: starts,
      group_marks: provenance.group_marks
    }

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
          rewriters = rewriter_tasks(facts, group, reverted, fn _task -> true end)

          own_live_bytes(facts, group) == 0 and not revives?(facts, group, reverted) and
            Enum.any?(rewriters, &(&1 in set)) and Enum.all?(rewriters, &(&1 in set)) and
            Enum.all?(deleted_writer_tasks(facts, group), &(&1 in set))

        task ->
          start = Map.fetch!(facts.starts, task)
          newer? = &(&1 != task and Map.get(facts.starts, &1, 0) > start)

          Enum.all?(Map.fetch!(facts.tasks, task), fn group ->
            Enum.all?(rewriter_tasks(facts, group, reverted, newer?), &(&1 in set)) and
              Enum.all?(
                overlap_nodes(facts, group, reverted),
                &(&1 != :permanent_you and &1 in set)
              )
          end)
      end)
  end

  defp node_groups(_facts, {:you, group}), do: [group]
  defp node_groups(facts, task), do: Map.fetch!(facts.tasks, task)

  # Tasks whose applied steps deleted text `group` wrote or removed, after it did, except text the reverted groups both
  # wrote and deleted.
  defp rewriter_tasks(facts, group, reverted, counts?) do
    for run <- facts.runs,
        not internal?(run, reverted),
        removed_by?(run, group),
        deleter <- later(run, group),
        deleter not in run.covered_by,
        deleter_group = Map.fetch!(facts.groups, deleter),
        deleter_group.applied and deleter_group.author != :you,
        task = task_of(deleter_group.key),
        counts?.(task),
        uniq: true,
        do: task
  end

  # Text a group of the set wrote and a group of the set deleted stays dead when the set reverts.
  defp internal?(run, set),
    do: MapSet.member?(set, run.group) and Enum.any?(run.deletions, &MapSet.member?(set, &1))

  # The group wrote the run or deleted it while it was visible; sweeping or covering it never removed it.
  defp removed_by?(%{group: id}, id), do: true

  defp removed_by?(run, id),
    do: id in run.deletions and id not in run.covered_by and id not in run.swept_by

  defp later(%{group: id, deletions: deletions}, id), do: deletions
  defp later(run, id), do: Enum.take_while(run.deletions, &(&1 != id))

  # Marks about the group, on its runs or kept by the group itself once their run was dropped.
  defp overlap_nodes(facts, group, reverted) do
    on_runs =
      for run <- facts.runs,
          run.group == group or group in run.deletions,
          {^group, overlap} <- run.overlaps,
          do: overlap

    for overlap <- on_runs ++ Map.get(facts.group_marks, group, []),
        node = overlap_node(facts, overlap, reverted),
        uniq: true,
        do: node
  end

  # A permanent mark holds for good, whoever made it.
  defp overlap_node(_facts, {:permanent, _key}, _reverted), do: :permanent_you

  defp overlap_node(facts, id, reverted) do
    group = Map.fetch!(facts.groups, id)

    cond do
      MapSet.member?(reverted, id) -> nil
      not group.applied -> nil
      group.author == :you -> {:you, id}
      true -> task_of(group.key)
    end
  end

  # The tasks whose text this group deleted: reverting the group brings that text back unless they revert too.
  defp deleted_writer_tasks(facts, group) do
    for run <- facts.runs,
        run.group != nil and run.group != group,
        group in run.deletions,
        key = Map.fetch!(facts.groups, run.group).key,
        uniq: true,
        do: task_of(key)
  end

  # Reverting the set would make live a tombstone this group made that nothing outside the set keeps deleted.
  defp revives?(facts, group, reverted) do
    applied? = &(Map.fetch!(facts.groups, &1).applied and not MapSet.member?(reverted, &1))

    Enum.any?(facts.runs, fn run ->
      run.group != group and group in run.deletions and (run.group == nil or applied?.(run.group)) and
        not Enum.any?(run.deletions, applied?)
    end)
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
