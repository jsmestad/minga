defmodule Minga.Buffer.ReviewDamage do
  @moduledoc "Tracks the source rows whose author facts changed between renderer observations."

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.RendererConsume

  @enforce_keys [:base, :current, :ranges]
  defstruct @enforce_keys

  @typep lease :: RendererConsume.review_lease()
  @typep range :: RendererConsume.line_range()
  @opaque t :: %__MODULE__{base: lease(), current: lease(), ranges: [range()]}

  @doc "Returns known damage and advances the source observation, independently of wire acknowledgement."
  @spec consume(t() | nil, lease()) :: {RendererConsume.review_damage(), t()}
  def consume(%__MODULE__{base: lease, current: lease, ranges: []} = damage, lease),
    do: {{:since, lease, []}, damage}

  def consume(damage, lease) do
    observed = %__MODULE__{base: lease, current: lease, ranges: []}

    case damage do
      %__MODULE__{base: base, current: ^lease, ranges: ranges} ->
        {{:since, base, ranges}, observed}

      _lost_observation ->
        {:reset_required, observed}
    end
  end

  @doc "Adds Keep's exact damage without advancing the renderer's observation."
  @spec keep(t() | nil, lease(), lease(), [range()]) :: t() | nil
  def keep(%__MODULE__{current: before} = damage, before, after_keep, ranges) do
    %{damage | current: after_keep, ranges: merge_ranges(ranges, damage.ranges)}
  end

  def keep(_damage, _before, _after_keep, _ranges), do: nil

  @doc "Carries outstanding semantic changes across ordered edits with a verified local footprint."
  @spec edit(t() | nil, lease(), lease(), [EditDelta.t()]) :: t() | nil
  def edit(%__MODULE__{current: before} = damage, before, after_edit, deltas) do
    %{damage | current: after_edit, ranges: remap_ranges(damage.ranges, deltas)}
  end

  def edit(_damage, _before, _after_edit, _deltas), do: nil

  @doc "Maps existing source ranges through ordered edits, retaining disjoint damage."
  @spec remap_ranges([range()], [EditDelta.t()]) :: [range()]
  def remap_ranges([], _deltas), do: []
  def remap_ranges(ranges, []), do: ranges

  def remap_ranges(ranges, deltas) do
    remapped =
      Enum.reduce(deltas, ranges, fn delta, ranges ->
        Enum.map(ranges, &EditDelta.transform_line_range(&1, delta))
      end)

    merge_ranges(remapped, [])
  end

  @doc "Returns edit boundaries in final coordinates, including neighbors that can gain a new head."
  @spec topology_ranges([EditDelta.t()]) :: [range()]
  def topology_ranges(deltas) do
    Enum.reduce(deltas, [], fn delta, ranges ->
      %EditDelta{start_position: {start, _}, new_end_position: {stop, _}} = delta
      merge_ranges(remap_ranges(ranges, [delta]), [{max(0, start - 1), stop + 1}])
    end)
  end

  @doc "Returns requested source lines not already covered by a cached observation."
  @spec missing_ranges([range()], [range()]) :: [range()]
  def missing_ranges(requested, covered), do: Enum.flat_map(requested, &subtract(&1, covered))

  defp subtract({first, last}, []) when first <= last, do: [{first, last}]
  defp subtract({first, last}, _) when first > last, do: []
  defp subtract({first, last}, [{from, _} | _]) when from > last, do: [{first, last}]

  defp subtract({first, last}, [{_, stop} | rest]) when stop < first,
    do: subtract({first, last}, rest)

  defp subtract({first, last}, [{from, stop} | rest]) do
    tail = subtract({stop + 1, last}, rest)
    if from > first, do: [{first, from - 1} | tail], else: tail
  end

  @doc "Unions two sets of inclusive source-line ranges without filling unchanged gaps."
  @spec merge_ranges([range()], [range()]) :: [range()]
  def merge_ranges(left, right) do
    (left ++ right)
    |> Enum.sort()
    |> Enum.reduce([], fn
      {first, last}, [{head, tail} | rest] when first <= tail + 1 ->
        [{head, max(tail, last)} | rest]

      range, acc ->
        [range | acc]
    end)
    |> Enum.reverse()
  end
end
