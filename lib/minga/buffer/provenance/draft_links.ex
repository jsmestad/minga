defmodule Minga.Buffer.Provenance.DraftLinks do
  @moduledoc """
  Logical draft components whose last positional evidence was permanently removed. A component retains each live group once, not every historical pairing. Removing a final member does not split the remaining component.
  """

  alias Minga.Buffer.Provenance.Run

  @typep id :: Run.group_id()
  @opaque t :: %__MODULE__{
            owners: %{id() => id()},
            components: %{id() => :gb_sets.set(id())}
          }

  defstruct owners: %{}, components: %{}

  @doc "Returns empty draft links."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the detached draft components without their reverse index."
  @spec snapshot(t()) :: [[id()]]
  def snapshot(%__MODULE__{components: components}) do
    Enum.map(components, fn {_owner, members} -> :gb_sets.to_list(members) end)
  end

  @doc "Rebuilds detached draft links from disjoint components of live groups."
  @spec restore([[id()]]) :: t()
  def restore(components) do
    Enum.reduce(components, new(), fn [owner | _] = members, links ->
      owners = Enum.reduce(members, links.owners, &Map.put(&2, &1, owner))
      components = Map.put(links.components, owner, :gb_sets.from_list(members))
      %{links | owners: owners, components: components}
    end)
  end

  @doc "Joins two live groups without retaining a second connection inside one component."
  @spec link(t(), id(), id()) :: t()
  def link(%__MODULE__{} = links, left, right) do
    left_owner = Map.get(links.owners, left, left)
    right_owner = Map.get(links.owners, right, right)

    if left_owner == right_owner do
      links
    else
      left_members =
        Map.get_lazy(links.components, left_owner, fn -> :gb_sets.singleton(left) end)

      right_members =
        Map.get_lazy(links.components, right_owner, fn -> :gb_sets.singleton(right) end)

      if :gb_sets.size(left_members) >= :gb_sets.size(right_members) do
        join(links, left_owner, left_members, right_owner, right_members)
      else
        join(links, right_owner, right_members, left_owner, left_members)
      end
    end
  end

  @spec join(t(), id(), :gb_sets.set(id()), id(), :gb_sets.set(id())) :: t()
  defp join(links, larger, kept, smaller, moved) do
    owners =
      if Map.has_key?(links.components, larger),
        do: links.owners,
        else: Map.put(links.owners, larger, larger)

    {owners, members} =
      Enum.reduce(:gb_sets.to_list(moved), {owners, kept}, fn id, {owners, members} ->
        {Map.put(owners, id, larger), :gb_sets.add(id, members)}
      end)

    components = links.components |> Map.delete(smaller) |> Map.put(larger, members)
    %{links | owners: owners, components: components}
  end

  @doc "Returns the group's neighbours. Only the oldest live member enumerates the whole component."
  @spec partners(t(), id()) :: MapSet.t(id())
  def partners(%__MODULE__{} = links, id) do
    case links.owners do
      %{^id => owner} ->
        members = Map.fetch!(links.components, owner)

        case :gb_sets.smallest(members) do
          ^id ->
            [^id | rest] = :gb_sets.to_list(members)
            MapSet.new(rest)

          oldest ->
            MapSet.new([oldest])
        end

      _unlinked ->
        MapSet.new()
    end
  end

  @doc "Removes a final group. A component with only one group no longer needs a record."
  @spec forget(t(), id()) :: t()
  def forget(%__MODULE__{} = links, id) do
    case Map.pop(links.owners, id) do
      {nil, _owners} ->
        links

      {owner, owners} ->
        remaining = :gb_sets.delete(id, Map.fetch!(links.components, owner))

        if :gb_sets.size(remaining) == 1 do
          %{
            links
            | owners: Map.delete(owners, :gb_sets.smallest(remaining)),
              components: Map.delete(links.components, owner)
          }
        else
          %{links | owners: owners, components: %{links.components | owner => remaining}}
        end
    end
  end

  @doc "Transfers membership when compaction removes a group's identity."
  @spec absorb(t(), id(), id()) :: t()
  def absorb(%__MODULE__{} = links, old, new) do
    if Map.has_key?(links.owners, old),
      do: links |> link(old, new) |> forget(old),
      else: links
  end
end
