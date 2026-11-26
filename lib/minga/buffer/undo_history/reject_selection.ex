defmodule Minga.Buffer.UndoHistory.RejectSelection do
  @moduledoc """
  Chooses a jointly exact set for one automatic Reject. Surviving roots take their required groups with them. An unsafe union holds every competing choice, not standalone prerequisites that leave the user's deletion in place.
  """

  alias Minga.Buffer.Provenance
  alias Minga.Buffer.Provenance.RewriteScan
  alias Minga.Buffer.UndoHistory

  @type reason :: {:yours | :permanent, Provenance.group_id()}
  @typep id :: Provenance.group_id()
  @type exclusions :: %{id() => reason()}
  @typep graph :: %{
           reached: MapSet.t(id()),
           required_by: %{id() => [id()]},
           holds: [{id(), reason()}]
         }
  @typep closure :: %{
           provenance: Provenance.t(),
           edges: UndoHistory.merges(),
           hard_links: UndoHistory.merges(),
           roots: MapSet.t(id()),
           excluded: exclusions()
         }
  @typep facts :: {%{id() => group_facts()}, RewriteScan.t()}
  @typep group_facts :: {[id()], [RewriteScan.requirement()], reason() | nil}
  @typep vertex :: id() | {id(), non_neg_integer()}
  @typep influences :: %{vertex() => [vertex()]}
  @typep draft_walk :: {MapSet.t(id()), Provenance.draft_scan()}

  @doc "Returns the selected groups, newest hold, hold rounds, and groups a later task cannot take."
  @spec plan(Provenance.t(), UndoHistory.merges(), [id()], exclusions()) ::
          {MapSet.t(id()), reason() | nil, [[id()]], exclusions()}
  def plan(provenance, merges, roots, excluded) do
    settle(provenance, merges, MapSet.new(roots), %{}, excluded, [], {%{}, RewriteScan.new()})
  end

  # Remove holds together. A held root no longer suppresses a rewrite in the next round.
  @spec settle(
          Provenance.t(),
          UndoHistory.merges(),
          MapSet.t(id()),
          exclusions(),
          exclusions(),
          [[id()]],
          facts()
        ) :: {MapSet.t(id()), reason() | nil, [[id()]], exclusions()}
  defp settle(provenance, merges, roots, held, excluded, rounds, facts) do
    closure = %{
      provenance: provenance,
      edges: merges,
      hard_links: merges,
      roots: roots,
      excluded: excluded
    }

    {proposal, blocked, protected, facts} = refine(closure, facts, {MapSet.new(), %{}})

    held = merge_exclusions(held, blocked)
    rounds = [Enum.sort(Map.keys(held)) | rounds]

    if map_size(blocked) == 0 do
      hold = Enum.reduce(held, nil, fn {_id, reason}, acc -> newest(acc, reason) end)
      {proposal.reached, hold, Enum.reverse(rounds), excluded}
    else
      roots = Enum.reduce(blocked, roots, fn {id, _reason}, acc -> MapSet.delete(acc, id) end)
      excluded = excluded |> merge_exclusions(protected) |> merge_exclusions(blocked)
      settle(provenance, merges, roots, held, excluded, rounds, facts)
    end
  end

  @spec blocked_roots(Provenance.t(), graph(), MapSet.t(id())) :: {exclusions(), exclusions()}
  defp blocked_roots(provenance, proposal, roots) do
    user_text = Provenance.protected_user_text(provenance, proposal.reached)

    case block_roots(proposal, proposal.holds ++ user_text, roots) do
      blocked when map_size(blocked) == 0 ->
        block_revivals(
          proposal,
          Provenance.revived_user_deletions(provenance, proposal.reached),
          roots
        )

      blocked ->
        {blocked, Map.new(user_text)}
    end
  end

  # Couple drafts only when a proposal would remove a user entry.
  # Physical compaction must not decide whether that entry survives.
  @spec refine(closure(), facts(), draft_walk()) :: {graph(), exclusions(), exclusions(), facts()}
  defp refine(closure, facts, {checked, _scan} = walk) do
    {upper, facts} = reach(closure, closure.roots, facts)
    {proposal, facts} = settle_bounds(closure, closure.roots, upper, facts)
    {blocked, protected} = blocked_roots(closure.provenance, proposal, closure.roots)

    if map_size(blocked) == 0 do
      users =
        for id <- proposal.reached, Provenance.group_key(closure.provenance, id) == nil, do: id

      {needed, _seen} =
        ancestor_roots(users, proposal.required_by, proposal.reached, [], MapSet.new())

      pending = Enum.reject(needed, &MapSet.member?(checked, &1))
      {edges, walk} = link_drafts(pending, closure.provenance, closure.edges, walk)

      if edges == closure.edges,
        do: {proposal, blocked, protected, facts},
        else: refine(%{closure | edges: edges}, facts, walk)
    else
      {proposal, blocked, protected, facts}
    end
  end

  @spec link_drafts([id()], Provenance.t(), UndoHistory.merges(), draft_walk()) ::
          {UndoHistory.merges(), draft_walk()}
  defp link_drafts([], _provenance, merges, walk), do: {merges, walk}

  defp link_drafts([id | rest], provenance, merges, {checked, scan} = walk) do
    if MapSet.member?(checked, id) or Provenance.group_key(provenance, id) == nil do
      link_drafts(rest, provenance, merges, walk)
    else
      {partners, scan} = Provenance.draft_partners(provenance, id, scan)

      merges =
        Enum.reduce(partners, merges, fn other, acc ->
          acc
          |> Map.update(id, MapSet.new([other]), &MapSet.put(&1, other))
          |> Map.update(other, MapSet.new([id]), &MapSet.put(&1, id))
        end)

      walk = {MapSet.put(checked, id), scan}
      link_drafts(Enum.to_list(partners) ++ rest, provenance, merges, walk)
    end
  end

  # More assumed reverts can only turn off requirements. Alternate the bounds until neither moves.
  @spec settle_bounds(closure(), MapSet.t(id()), graph(), facts()) :: {graph(), facts()}
  defp settle_bounds(closure, low, high, facts) do
    if MapSet.equal?(low, high.reached) do
      {high, facts}
    else
      {next_low, facts} = reach(closure, high.reached, facts)

      if MapSet.equal?(low, next_low.reached) do
        resolve_upstream(closure, low, high, facts)
      else
        {next_high, facts} = reach(closure, next_low.reached, facts)
        settle_bounds(closure, next_low.reached, next_high, facts)
      end
    end
  end

  # Optional covers can waive each other's requirements.
  # Resolve upstream alternatives first, and retain the edges that justified taking them.
  @spec resolve_upstream(closure(), MapSet.t(id()), graph(), facts()) :: {graph(), facts()}
  defp resolve_upstream(closure, low, high, facts) do
    uncertain = MapSet.difference(high.reached, low)

    case impossible_supports(closure, uncertain, high, facts) do
      none when map_size(none) == 0 ->
        admit_upstream(closure, low, high, uncertain, facts)

      impossible ->
        closure = %{closure | excluded: merge_exclusions(closure.excluded, impossible)}
        {high, facts} = reach(closure, closure.roots, facts)
        settle_bounds(closure, closure.roots, high, facts)
    end
  end

  # Prune alternatives only when every admissible proposal containing them is unsafe.
  @spec impossible_supports(closure(), MapSet.t(id()), graph(), facts()) :: exclusions()
  defp impossible_supports(closure, uncertain, high, facts) do
    possible = available(high.reached, closure.excluded)
    user_bytes = Provenance.protected_user_requirements(closure.provenance, possible)
    revivals = Provenance.revived_user_deletions(closure.provenance, possible)

    if high.holds == [] and user_bytes == [] and revivals == [] do
      %{}
    else
      candidates = available(uncertain, closure.excluded)
      required_by = definite_requirements(possible, closure.hard_links, facts)
      {visible, hidden} = Enum.split_with(user_bytes, fn {_user, deleters} -> deleters == [] end)

      holds =
        Enum.reduce(visible, high.holds, fn {user, []}, acc -> [{user, {:yours, user}} | acc] end)

      blocked = block_roots(%{high | required_by: required_by}, holds, candidates)

      blocked =
        Enum.reduce(hidden, blocked, fn {user, deleters}, acc ->
          exclude(acc, common_roots(user, deleters, required_by, candidates), {:yours, user})
        end)

      # A revival in the upper bound has no writer any remaining proposal can remove.
      Enum.reduce(revivals, blocked, fn {users, [first | rest]}, acc ->
        exclude(
          acc,
          common_roots(first, rest, required_by, candidates),
          {:yours, Enum.max(users)}
        )
      end)
    end
  end

  @spec definite_requirements(MapSet.t(id()), UndoHistory.merges(), facts()) :: %{id() => [id()]}
  defp definite_requirements(possible, hard_links, {groups, scan}) do
    Enum.reduce(possible, %{}, fn id, reverse ->
      {required, rules, _hold} = Map.fetch!(groups, id)
      reverse = reverse_requirements(reverse, required, id)
      reverse = reverse_requirements(reverse, Map.get(hard_links, id, []), id)

      # A rule still required under the largest possible support cannot be waived.
      RewriteScan.reduce_required(
        scan,
        rules,
        id,
        possible,
        reverse,
        &reverse_requirement(&2, &1, id)
      )
    end)
  end

  @spec reverse_requirements(%{id() => [id()]}, [id()] | MapSet.t(id()), id()) :: %{
          id() => [id()]
        }
  defp reverse_requirements(graph, required, id) do
    Enum.reduce(required, graph, &reverse_requirement(&2, &1, id))
  end

  @spec reverse_requirement(%{id() => [id()]}, id(), id()) :: %{id() => [id()]}
  defp reverse_requirement(graph, dep, id) do
    Map.update(graph, dep, [id], fn
      [^id | _] = same -> same
      parents -> [id | parents]
    end)
  end

  @spec admit_upstream(closure(), MapSet.t(id()), graph(), MapSet.t(id()), facts()) ::
          {graph(), facts()}
  defp admit_upstream(closure, low, high, uncertain, facts) do
    lower = available(low, closure.excluded)
    upper = available(high.reached, closure.excluded)
    influences = influence_graph(high, uncertain, lower, upper, facts)
    admitted = upstream_groups(influences)

    edges =
      Enum.reduce(admitted, closure.edges, fn id, edges ->
        Enum.reduce(Map.fetch!(high.required_by, id), edges, fn from, edges ->
          Map.update(edges, from, MapSet.new([id]), &MapSet.put(&1, id))
        end)
      end)

    closure = %{closure | edges: edges}
    low = Enum.into(admitted, low)
    {high, facts} = reach(closure, low, facts)
    settle_bounds(closure, low, high, facts)
  end

  @spec influence_graph(graph(), MapSet.t(id()), MapSet.t(id()), MapSet.t(id()), facts()) ::
          influences()
  defp influence_graph(high, uncertain, lower, upper, {groups, scan}) do
    graph = Map.new(uncertain, &{&1, []})

    graph =
      for id <- uncertain,
          from <- Map.get(high.required_by, id, []),
          MapSet.member?(uncertain, from),
          reduce: graph do
        acc -> influence(acc, from, id)
      end

    can_support = MapSet.intersection(uncertain, upper)

    Enum.reduce(upper, graph, fn source, graph ->
      {_, rules, _} = Map.fetch!(groups, source)

      {_, graph} =
        Enum.reduce(rules, {0, graph}, fn rule, {index, graph} ->
          node = {source, index}
          graph = influence_guard(graph, node, scan, rule, uncertain, can_support, {lower, upper})
          {index + 1, graph}
        end)

      graph
    end)
  end

  # One vertex per guarded run, not one edge for each combination of a possible support and a later target.
  @spec influence_guard(
          influences(),
          {id(), non_neg_integer()},
          RewriteScan.t(),
          RewriteScan.requirement(),
          MapSet.t(id()),
          MapSet.t(id()),
          {MapSet.t(id()), MapSet.t(id())}
        ) :: influences()
  defp influence_guard(graph, {source, _index} = node, scan, rule, uncertain, supports, bounds) do
    {lower, upper} = bounds
    before = RewriteScan.targets(scan, rule, source, lower)

    case RewriteScan.targets(scan, rule, source, upper) do
      ^before ->
        graph

      upper_targets ->
        still_required = RewriteScan.target_ids(scan, upper_targets, source)

        targets =
          scan
          |> RewriteScan.target_ids(before, source)
          |> Enum.filter(&(MapSet.member?(uncertain, &1) and &1 not in still_required))

        {writer, deleters} = RewriteScan.support_inputs(scan, rule)
        add_guard_influences(graph, node, writer, deleters, targets, supports)
    end
  end

  @spec add_guard_influences(
          influences(),
          vertex(),
          id() | nil,
          [id()],
          [id()],
          MapSet.t(id())
        ) :: influences()
  defp add_guard_influences(graph, _node, _writer, _deleters, [], _supports), do: graph

  defp add_guard_influences(graph, node, writer, deleters, targets, supports) do
    graph = Map.put(graph, node, targets)
    graph = if MapSet.member?(supports, writer), do: influence(graph, writer, node), else: graph

    Enum.reduce(deleters, graph, fn id, graph ->
      if MapSet.member?(supports, id) and targets != [id],
        do: influence(graph, id, node),
        else: graph
    end)
  end

  @spec influence(influences(), vertex(), vertex()) :: influences()
  defp influence(graph, from, to), do: Map.update!(graph, from, &[to | &1])

  @spec upstream_groups(influences()) :: [id()]
  defp upstream_groups(graph) do
    {reversed, components} = dependency_components(graph)

    Enum.reduce(components, [], fn members, upstream ->
      if external_input?(members, reversed),
        do: upstream,
        else: Enum.reduce(members, upstream, &keep_group/2)
    end)
  end

  @spec external_input?([vertex()], influences()) :: boolean()
  defp external_input?(members, reversed) do
    component = MapSet.new(members)

    Enum.any?(members, fn member ->
      Enum.any?(Map.fetch!(reversed, member), &(not MapSet.member?(component, &1)))
    end)
  end

  # Finishing order and a reverse walk identify strongly connected components.
  # Return components with no outgoing dependencies first.
  @spec dependency_components(influences()) :: {influences(), [[vertex()]]}
  defp dependency_components(graph) do
    reversed =
      Enum.reduce(graph, Map.new(graph, fn {id, _} -> {id, []} end), fn {from, neighbours}, rev ->
        Enum.reduce(neighbours, rev, &influence(&2, &1, from))
      end)

    {_seen, order} =
      Enum.reduce(graph, {MapSet.new(), []}, fn {id, _}, acc -> finish_order(graph, id, acc) end)

    {_seen, components} =
      Enum.reduce(order, {MapSet.new(), []}, fn id, {seen, components} ->
        {seen, members} = finish_order(reversed, id, {seen, []})
        if members == [], do: {seen, components}, else: {seen, [members | components]}
      end)

    {reversed, components}
  end

  @spec keep_group(vertex(), [id()]) :: [id()]
  defp keep_group(id, groups) when is_integer(id), do: [id | groups]
  defp keep_group(_run, groups), do: groups

  @spec finish_order(influences(), vertex(), {MapSet.t(vertex()), [vertex()]}) ::
          {MapSet.t(vertex()), [vertex()]}
  defp finish_order(graph, id, {seen, order} = acc) do
    if MapSet.member?(seen, id) do
      acc
    else
      {seen, order} =
        Enum.reduce(
          Map.fetch!(graph, id),
          {MapSet.put(seen, id), order},
          &finish_order(graph, &1, &2)
        )

      {seen, [id | order]}
    end
  end

  @spec reach(closure(), MapSet.t(id()), facts()) :: {graph(), facts()}
  defp reach(closure, assuming, facts) do
    assuming = available(assuming, closure.excluded)
    graph = %{reached: closure.roots, required_by: %{}, holds: []}
    expand(MapSet.to_list(closure.roots), graph, closure, assuming, facts)
  end

  @spec available(MapSet.t(id()), exclusions()) :: MapSet.t(id())
  defp available(groups, excluded) do
    Enum.reduce(excluded, groups, fn {id, _}, acc -> MapSet.delete(acc, id) end)
  end

  # Visit a group only once per proposal, but retain every immediate predecessor even when a group is shared.
  @spec expand([id()], graph(), closure(), MapSet.t(id()), facts()) :: {graph(), facts()}
  defp expand([], graph, _closure, _assuming, facts), do: {graph, facts}

  defp expand([id | remaining], graph, closure, assuming, facts) do
    case closure.excluded do
      %{^id => reason} ->
        graph = %{graph | holds: [{id, reason} | graph.holds]}
        expand(remaining, graph, closure, assuming, facts)

      _open ->
        {{required, rules, hold}, {_groups, scan} = facts} =
          group_facts(facts, closure.provenance, id)

        graph = if hold == nil, do: graph, else: %{graph | holds: [{id, hold} | graph.holds]}

        pending = {graph, remaining}

        pending = Enum.reduce(Map.get(closure.edges, id, []), pending, &require_group(&1, id, &2))
        pending = Enum.reduce(required, pending, &require_group(&1, id, &2))

        {graph, remaining} =
          RewriteScan.reduce_required(
            scan,
            rules,
            id,
            assuming,
            pending,
            &require_group(&1, id, &2)
          )

        expand(remaining, graph, closure, assuming, facts)
    end
  end

  @spec group_facts(facts(), Provenance.t(), id()) :: {group_facts(), facts()}
  defp group_facts({groups, scan} = facts, provenance, id) do
    case groups do
      %{^id => data} ->
        {data, facts}

      _missing ->
        {rules, scan} = Provenance.rewrite_requirements(provenance, id, scan)
        data = read_group_facts(provenance, id, rules)
        {data, {Map.put(groups, id, data), scan}}
    end
  end

  @spec read_group_facts(Provenance.t(), id(), [RewriteScan.requirement()]) :: group_facts()
  defp read_group_facts(provenance, id, rules) do
    {required, hold} =
      if Provenance.group_key(provenance, id) == nil do
        {[], nil}
      else
        Enum.reduce(Provenance.overlapping_groups(provenance, [id]), {[], nil}, fn
          {{:permanent, _key}, _offset}, {required, _hold} -> {required, {:permanent, id}}
          {other, _offset}, {required, hold} -> {[other | required], hold}
        end)
      end

    {Enum.uniq(required), rules, hold}
  end

  @spec require_group(id(), id(), {graph(), [id()]}) :: {graph(), [id()]}
  defp require_group(dep, id, {graph, pending}) do
    required_by =
      Map.update(graph.required_by, dep, [id], fn
        [^id | _] = same -> same
        others -> [id | others]
      end)

    graph = %{graph | required_by: required_by}

    if MapSet.member?(graph.reached, dep),
      do: {graph, pending},
      else: {%{graph | reached: MapSet.put(graph.reached, dep)}, [dep | pending]}
  end

  # Hold roots that are unsafe on their own before comparing jointly incompatible choices.
  @spec block_revivals(graph(), [{[id()], [id()]}], MapSet.t(id())) ::
          {exclusions(), exclusions()}
  defp block_revivals(_graph, [], _roots), do: {%{}, %{}}

  defp block_revivals(graph, witnesses, roots) do
    {local, protected} =
      Enum.reduce(witnesses, {%{}, %{}}, fn {users, [first | rest]}, {local, protected} ->
        reason = {:yours, Enum.max(users)}
        required = common_roots(first, rest, graph.required_by, roots)

        if MapSet.size(required) == 0 do
          {local, protected}
        else
          {exclude(local, required, reason), exclude(protected, users, reason)}
        end
      end)

    if map_size(local) == 0 do
      demands = root_demands(graph, roots)

      protected =
        Enum.reduce(witnesses, %{}, fn {users, contributors}, acc ->
          reason = {:yours, Enum.max(users)}
          competing = minimal_requirements(contributors, demands)
          acc |> exclude(users, reason) |> exclude(competing, reason)
        end)

      {block_roots(graph, Map.to_list(protected), roots), protected}
    else
      {local, protected}
    end
  end

  # Each component shares a demand set. Read it only after computing its outgoing dependencies.
  @spec root_demands(graph(), MapSet.t(id())) :: %{id() => MapSet.t(id())}
  defp root_demands(graph, roots) do
    required_by = Map.new(graph.reached, &{&1, Map.get(graph.required_by, &1, [])})
    {_reversed, components} = dependency_components(required_by)

    Enum.reduce(components, %{}, fn members, ready ->
      demand = component_demand(members, required_by, roots, ready)
      Enum.reduce(members, ready, &Map.put(&2, &1, demand))
    end)
  end

  @spec component_demand([id()], %{id() => [id()]}, MapSet.t(id()), %{id() => MapSet.t(id())}) ::
          MapSet.t(id())
  defp component_demand(members, required_by, roots, ready) do
    Enum.reduce(members, MapSet.new(), fn id, demand ->
      demand = if MapSet.member?(roots, id), do: MapSet.put(demand, id), else: demand

      required_by
      |> Map.fetch!(id)
      |> Enum.reduce(demand, &merge_demand(Map.get(ready, &1), &2))
    end)
  end

  @spec merge_demand(MapSet.t(id()) | nil, MapSet.t(id())) :: MapSet.t(id())
  defp merge_demand(nil, demand), do: demand
  defp merge_demand(demand, demand), do: demand
  defp merge_demand(other, demand), do: MapSet.union(other, demand)

  # A requirement is redundant if each root taking a stricter requirement already takes it.
  # In particular, a shared rewrite can still revert on its own and unblock the user's undo.
  @spec minimal_requirements([id()], %{id() => MapSet.t(id())}) :: [id()]
  defp minimal_requirements(contributors, demands) do
    contributors
    |> Enum.group_by(&Map.fetch!(demands, &1))
    |> Enum.sort_by(fn {demand, _} -> MapSet.size(demand) end)
    |> Enum.reduce({[], []}, fn {demand, ids}, {minimum, retained} ->
      if Enum.any?(minimum, &MapSet.subset?(&1, demand)),
        do: {minimum, retained},
        else: {[demand | minimum], ids ++ retained}
    end)
    |> elem(1)
  end

  @spec exclude(exclusions(), [id()] | MapSet.t(id()), reason()) :: exclusions()
  defp exclude(excluded, ids, reason) do
    Enum.reduce(ids, excluded, fn id, acc -> Map.update(acc, id, reason, &newest(&1, reason)) end)
  end

  @spec merge_exclusions(exclusions(), exclusions()) :: exclusions()
  defp merge_exclusions(left, right), do: Map.merge(left, right, fn _, a, b -> newest(a, b) end)

  @spec common_roots(id(), [id()], %{id() => [id()]}, MapSet.t(id())) :: MapSet.t(id())
  defp common_roots(first, remaining, required_by, roots) do
    initial = roots_requiring(first, required_by, roots)

    Enum.reduce_while(remaining, initial, fn id, common ->
      common = MapSet.intersection(common, roots_requiring(id, required_by, common))
      if MapSet.size(common) == 0, do: {:halt, common}, else: {:cont, common}
    end)
  end

  @spec roots_requiring(id(), %{id() => [id()]}, MapSet.t(id())) :: MapSet.t(id())
  defp roots_requiring(id, required_by, roots) do
    {found, _seen} = ancestor_roots([id], required_by, roots, [], MapSet.new())
    MapSet.new(found)
  end

  # The newest witness propagates first, so every edge is walked at most once even when many holds reach one group.
  @spec block_roots(graph(), [{id(), reason()}], MapSet.t(id())) :: %{id() => reason()}
  defp block_roots(graph, holds, roots) do
    holds
    |> Enum.sort_by(fn {_id, reason} -> priority(reason) end, :desc)
    |> Enum.reduce({%{}, MapSet.new()}, fn {id, reason}, {blocked, seen} ->
      {found, seen} = ancestor_roots([id], graph.required_by, roots, [], seen)
      {Enum.reduce(found, blocked, &Map.put(&2, &1, reason)), seen}
    end)
    |> elem(0)
  end

  @spec ancestor_roots([id()], %{id() => [id()]}, MapSet.t(id()), [id()], MapSet.t(id())) ::
          {[id()], MapSet.t(id())}
  defp ancestor_roots([], _required_by, _roots, found, seen), do: {found, seen}

  defp ancestor_roots([id | rest], required_by, roots, found, seen) do
    if MapSet.member?(seen, id) do
      ancestor_roots(rest, required_by, roots, found, seen)
    else
      found = if MapSet.member?(roots, id), do: [id | found], else: found
      pending = Map.get(required_by, id, []) ++ rest
      ancestor_roots(pending, required_by, roots, found, MapSet.put(seen, id))
    end
  end

  @spec newest(reason() | nil, reason()) :: reason()
  defp newest(nil, reason), do: reason
  defp newest(acc, reason), do: if(priority(reason) > priority(acc), do: reason, else: acc)

  @spec priority(reason()) :: {0 | 1, id()}
  defp priority({:yours, id}), do: {1, id}
  defp priority({:permanent, id}), do: {0, id}
end
