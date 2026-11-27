defmodule Minga.Buffer.GitAuthorship do
  @moduledoc "Projects human gutter ink onto the current file's uncommitted Git rows."

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.RendererConsume
  alias Minga.Buffer.ReviewDamage

  @type observation :: [RendererConsume.line_range()] | :unknown
  @type t :: :unknown | {[RendererConsume.line_range()], tuple()}
  @typep range :: RendererConsume.line_range()
  @typep region :: RendererConsume.review_region()

  @doc "Indexes sorted, disjoint changed-row ranges once at the observation boundary."
  @spec new(observation()) :: t()
  def new(:unknown), do: :unknown
  def new(ranges), do: {ranges, List.to_tuple(ranges)}

  @doc "Carries known dirty rows through edits and treats newly touched rows as uncommitted until Git catches up."
  @spec through_edits(t(), [EditDelta.t()]) :: t()
  def through_edits(:unknown, _deltas), do: :unknown
  def through_edits(projection, []), do: projection

  def through_edits({ranges, _indexed}, deltas) do
    touched =
      Enum.reduce(deltas, [], fn delta, accumulated ->
        %EditDelta{start_position: {first, _}, new_end_position: {last, _}} = delta

        ReviewDamage.merge_ranges(ReviewDamage.remap_ranges(accumulated, [delta]), [{first, last}])
      end)

    ranges |> ReviewDamage.remap_ranges(deltas) |> ReviewDamage.merge_ranges(touched) |> new()
  end

  @doc "Restricts human ink without discarding provenance or hiding a pending or kept Minga mark."
  @spec project([region()], t()) :: [region()]
  def project(regions, :unknown), do: regions

  def project(regions, {_ranges, indexed}),
    do: Enum.flat_map(regions, &project_region(&1, indexed))

  @spec project_region(region(), tuple()) :: [region()]
  defp project_region({role, {first, _} = anchor, last}, indexed) when role in [:you, :shared] do
    start = first_reaching(indexed, first, 0, tuple_size(indexed))
    spans(indexed, start, tuple_size(indexed), role, anchor, last)
  end

  defp project_region(region, _indexed), do: [region]

  @spec first_reaching(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp first_reaching(_indexed, _line, at, at), do: at

  defp first_reaching(indexed, line, lo, hi) do
    mid = div(lo + hi, 2)
    {_, stop} = elem(indexed, mid)

    if stop < line,
      do: first_reaching(indexed, line, mid + 1, hi),
      else: first_reaching(indexed, line, lo, mid)
  end

  @spec spans(
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          :you | :shared,
          {non_neg_integer(), non_neg_integer()},
          non_neg_integer()
        ) :: [region()]
  defp spans(_indexed, size, size, _role, _anchor, _last), do: []

  defp spans(indexed, at, size, role, {line, _} = anchor, last) do
    {first, stop} = elem(indexed, at)

    if first <= last do
      start = if first <= line, do: anchor, else: {first, 0}
      [{role, start, min(stop, last)} | spans(indexed, at + 1, size, role, anchor, last)]
    else
      []
    end
  end

  @doc "Returns the affected rows when the observations changed, or a reset when a comparison became (un)available."
  @spec damage(t(), t()) :: [range()] | :reset
  def damage(same, same), do: []
  def damage(:unknown, _after), do: :reset
  def damage(_before, :unknown), do: :reset
  def damage({before, _}, {after_head, _}), do: changed_ranges(before, after_head, [])

  @spec changed_ranges([range()], [range()], [range()]) :: [range()]
  defp changed_ranges([], remaining, acc), do: Enum.reverse(acc, remaining)
  defp changed_ranges(remaining, [], acc), do: Enum.reverse(acc, remaining)

  defp changed_ranges([{_, last} = a | rest], [{first, _} | _] = right, acc)
       when last < first,
       do: changed_ranges(rest, right, [a | acc])

  defp changed_ranges([{first, _} | _] = left, [{_, last} = b | rest], acc)
       when last < first,
       do: changed_ranges(left, rest, [b | acc])

  defp changed_ranges([{a, x} | left], [{b, y} | right], acc) do
    acc = if a == b, do: acc, else: [{min(a, b), max(a, b) - 1} | acc]

    cond do
      x > y -> changed_ranges([{y + 1, x} | left], right, acc)
      y > x -> changed_ranges(left, [{x + 1, y} | right], acc)
      true -> changed_ranges(left, right, acc)
    end
  end
end
