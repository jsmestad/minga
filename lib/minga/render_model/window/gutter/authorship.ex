defmodule Minga.RenderModel.Window.Gutter.Authorship do
  @moduledoc "Compact authored regions for one gutter, qualified by the observed buffer revision."

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.RendererConsume
  alias Minga.Buffer.ReviewDamage
  alias Minga.RenderModel.Window.Gutter.AuthorshipIndex

  @enforce_keys [:revision, :lease, :ranges, :coverage, :index]
  defstruct @enforce_keys ++ [change: nil]

  @type t :: %__MODULE__{
          revision: pos_integer(),
          lease: RendererConsume.review_lease(),
          ranges: [RendererConsume.line_range()],
          coverage: :resident | :windowed,
          index: AuthorshipIndex.t(),
          change: {pos_integer(), [region()], [region()]} | nil
        }

  @type region :: RendererConsume.review_region()
  @type update ::
          :absent
          | {:snapshot, pos_integer(), [region()]}
          | {:retain, pos_integer()}
          | {:patch, pos_integer(), pos_integer(), [region()], [region()]}

  @doc "Seeds a gutter projection from one exact buffer observation."
  @spec new(
          pos_integer(),
          RendererConsume.review_lease(),
          [RendererConsume.line_range()],
          [region()],
          :resident | :windowed
        ) :: t()
  def new(revision, lease, ranges, regions, coverage) do
    %__MODULE__{
      revision: revision,
      lease: lease,
      ranges: ranges,
      coverage: coverage,
      index: AuthorshipIndex.new(regions)
    }
  end

  @doc "Replaces only the source intervals whose author facts changed."
  @spec patch(
          t(),
          {pos_integer(), RendererConsume.review_lease(), [RendererConsume.line_range()]},
          [RendererConsume.line_range()],
          [region()],
          [EditDelta.t()]
        ) :: t()
  def patch(%__MODULE__{} = previous, {revision, lease, ranges}, damage, replacements, deltas) do
    {moved, first_shift} = AuthorshipIndex.apply_deltas(previous.index, deltas)
    observed = MapSet.new(replacements)
    touched = AuthorshipIndex.overlapping(moved, damage)

    index =
      AuthorshipIndex.replace(
        moved,
        touched |> MapSet.difference(observed) |> MapSet.to_list(),
        observed |> MapSet.difference(touched) |> MapSet.to_list()
      )

    {old, new} =
      if deltas == [] do
        {touched, observed}
      else
        wire_ranges = wire_damage(damage, first_shift, previous.ranges, ranges)

        {AuthorshipIndex.overlapping(previous.index, wire_ranges),
         AuthorshipIndex.overlapping(index, wire_ranges)}
      end

    removed = old |> MapSet.difference(new) |> Enum.sort()
    added = new |> MapSet.difference(old) |> Enum.sort()

    if removed == [] and added == [] and lease == previous.lease do
      %{previous | ranges: ranges, index: index}
    else
      %{
        previous
        | revision: revision,
          lease: lease,
          ranges: ranges,
          index: index,
          change: {previous.revision, added, removed}
      }
    end
  end

  @spec wire_damage(
          [RendererConsume.line_range()],
          non_neg_integer() | nil,
          [RendererConsume.line_range()],
          [RendererConsume.line_range()]
        ) :: [RendererConsume.line_range()]
  defp wire_damage(damage, nil, _old, _new), do: damage

  defp wire_damage(damage, first, [{0, old_last}], [{0, new_last}]),
    do: ReviewDamage.merge_ranges(damage, [{first, max(old_last, new_last)}])

  @doc "Reads cached regions touching the requested source lines without walking the whole index."
  @spec overlapping(t(), [RendererConsume.line_range()]) :: [region()]
  def overlapping(%__MODULE__{index: index}, ranges),
    do: index |> AuthorshipIndex.overlapping(ranges) |> MapSet.to_list()

  @doc "Returns the current projected regions in source order for a snapshot."
  @spec regions(t()) :: [region()]
  def regions(%__MODULE__{index: index}), do: AuthorshipIndex.all(index)

  @doc "Builds the exact change to apply against the previous committed authored gutter."
  @spec update(t() | nil, t() | nil) :: update()
  def update(_previous, nil), do: :absent

  def update(nil, %__MODULE__{revision: revision} = current),
    do: {:snapshot, revision, regions(current)}

  def update(%__MODULE__{revision: revision}, %__MODULE__{revision: revision}),
    do: {:retain, revision}

  def update(
        %__MODULE__{revision: base, lease: {buffer, _, _}},
        %__MODULE__{revision: revision, lease: {buffer, _, _}, change: {base, added, removed}}
      ),
      do: {:patch, base, revision, added, removed}

  def update(%__MODULE__{}, %__MODULE__{} = current), do: update(nil, current)
end
