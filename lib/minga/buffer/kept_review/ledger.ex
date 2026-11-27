defmodule Minga.Buffer.KeptReview.Ledger do
  @moduledoc """
  Keeps operation witnesses separate from the saved projections that can prove them. Equal file bytes share one image, but two saves can have different authorship at the same byte. Only witnesses that coexisted in one projection may be inverted together.
  """

  alias Minga.Buffer.KeptReview.Source
  alias Minga.Buffer.Provenance
  alias Minga.Git.ReviewIdentity

  defstruct witnesses: %{}, bound: %{}, images: %{}

  @type digest :: <<_::256>>
  @type snapshot :: {map(), map(), map()}
  @typep observations :: %{ReviewIdentity.t() => [Source.t()]}
  @opaque t :: %__MODULE__{
            witnesses: observations(),
            bound: %{{digest(), digest()} => observations()},
            images: %{digest() => binary()}
          }

  @doc "Creates an empty ledger, including for checkpoints that predate commit proof."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Records exact source under the Git observation taken before Keep publication."
  @spec observe(t(), ReviewIdentity.t(), [Source.t()]) :: t()
  def observe(%__MODULE__{} = ledger, _baseline, []), do: ledger

  def observe(%__MODULE__{} = ledger, baseline, sources) do
    witnesses = Map.update(ledger.witnesses, baseline, sources, &unique_sources(&1, sources))
    %{ledger | witnesses: witnesses}
  end

  @doc "Imports the exact saved projection into the live history of a dirty buffer."
  @spec merge_saved(t(), t() | nil) :: t()
  def merge_saved(%__MODULE__{} = live, nil), do: live

  def merge_saved(%__MODULE__{} = live, %__MODULE__{} = saved) do
    %{
      live
      | witnesses:
          Map.merge(live.witnesses, saved.witnesses, fn _, a, b -> unique_sources(a, b) end),
        bound: Map.merge(live.bound, saved.bound),
        images: Map.merge(live.images, saved.images)
    }
  end

  @doc "Binds all surviving witnesses at their exact current saved placements."
  @spec save(t(), digest(), binary(), Provenance.t()) :: t()
  def save(%__MODULE__{witnesses: witnesses} = ledger, _digest, _bytes, _provenance)
      when map_size(witnesses) == 0,
      do: ledger

  def save(%__MODULE__{} = ledger, digest, content, provenance) do
    placements = Provenance.kept_placements(provenance)
    ledger = prune(ledger, [placements])

    bound =
      Enum.reduce(ledger.witnesses, %{}, fn {baseline, sources}, bound ->
        saved =
          sources
          |> Enum.flat_map(&Source.rebind(&1, content, placements))
          |> Enum.uniq()
          |> Source.in_postimage_order()

        put_sources(bound, baseline, saved)
      end)

    if map_size(bound) == 0 do
      ledger
    else
      projection = :crypto.hash(:sha256, :erlang.term_to_binary(bound, [:deterministic]))

      %{
        ledger
        | bound: Map.put_new(ledger.bound, {digest, projection}, bound),
          images: Map.put_new(ledger.images, digest, content)
      }
    end
  end

  @type observation :: {ReviewIdentity.t(), [Source.t()]}
  @type job :: {binary(), [observation()]}

  @doc "Returns each saved projection separately for the observed checkout and branch."
  @spec jobs(t(), ReviewIdentity.t()) :: [job()]
  def jobs(%__MODULE__{} = ledger, {root, path, {ref, _tip, _cursor}}) do
    Enum.reduce(ledger.bound, [], fn {{digest, _projection}, observations}, jobs ->
      eligible =
        for {baseline = {^root, ^path, {^ref, _, _}}, sources} <- observations,
            do: {baseline, sources}

      case eligible do
        [] -> jobs
        [_ | _] -> [{Map.fetch!(ledger.images, digest), eligible} | jobs]
      end
    end)
  end

  @doc "Whether there is any eligible source worth checking on a repo notification."
  @spec bound?(t()) :: boolean()
  def bound?(%__MODULE__{bound: bound}), do: map_size(bound) > 0

  @doc "Whether a save needs to project kept origins."
  @spec has_witnesses?(t()) :: boolean()
  def has_witnesses?(%__MODULE__{witnesses: witnesses}), do: map_size(witnesses) > 0

  @doc "Checks whether a Git root notification can affect this buffer's saved evidence."
  @spec bound_on?(t(), String.t()) :: boolean()
  def bound_on?(%__MODULE__{bound: bound}, root) do
    Enum.any?(bound, fn {_, observations} ->
      Enum.any?(observations, fn {{git_root, _, _}, _} -> git_root == root end)
    end)
  end

  @doc "Drops witnesses only once no saved, live or held descendant remains."
  @spec prune(t(), [Provenance.kept_placements()]) :: t()
  def prune(%__MODULE__{} = ledger, placements) do
    retained? = fn source -> Enum.any?(placements, &Map.has_key?(&1, Source.key(source))) end
    witnesses = filter_sources(ledger.witnesses, retained?)

    bound =
      Map.filter(ledger.bound, fn {_, observations} ->
        Enum.any?(observations, fn {_, sources} -> Enum.any?(sources, retained?) end)
      end)

    # The other splices in a surviving projection still describe its exact preimage.
    images = Map.take(ledger.images, Enum.map(Map.keys(bound), &elem(&1, 0)))
    %{ledger | witnesses: witnesses, bound: bound, images: images}
  end

  @doc "Returns only serializable evidence; no worker or buffer identities cross a reopen."
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{} = ledger), do: {ledger.witnesses, ledger.bound, ledger.images}

  @doc "Validates durable witnesses and their exact postimages before accepting a snapshot."
  @spec restore(term()) :: {:ok, t()} | {:error, :invalid_history}
  def restore(nil), do: {:ok, new()}

  def restore({witnesses, bound, images})
      when is_map(witnesses) and is_map(bound) and is_map(images) do
    valid_witnesses? = valid_observations?(witnesses, nil)

    valid_images? =
      Enum.all?(images, fn {digest, bytes} ->
        is_binary(bytes) and digest == :crypto.hash(:sha256, bytes)
      end)

    valid_bound? =
      Enum.all?(bound, fn
        {{digest, <<_::256>> = projection}, observations}
        when is_map(observations) and map_size(observations) > 0 ->
          case images do
            %{^digest => bytes} ->
              valid_observations?(observations, bytes) and
                :crypto.hash(:sha256, :erlang.term_to_binary(observations, [:deterministic])) ==
                  projection

            _invalid ->
              false
          end

        _invalid ->
          false
      end)

    if valid_witnesses? and valid_images? and valid_bound?,
      do: {:ok, %__MODULE__{witnesses: witnesses, bound: bound, images: images}},
      else: {:error, :invalid_history}
  end

  def restore(_invalid), do: {:error, :invalid_history}

  @spec valid_observations?(map(), binary() | nil) :: boolean()
  defp valid_observations?(observations, content) do
    Enum.all?(observations, fn {baseline, sources} ->
      valid_baseline?(baseline) and valid_sources?(sources, content)
    end)
  end

  @spec valid_baseline?(term()) :: boolean()
  defp valid_baseline?({"/" <> _, path, {"refs/heads/" <> ref, oid, {count, <<_::256>>}}})
       when is_binary(path) and path != "" and ref != "" and is_integer(count) and count >= 0 do
    oid == :unborn or
      (is_binary(oid) and Regex.match?(~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/, oid))
  end

  defp valid_baseline?(_invalid), do: false

  @spec valid_sources?(term(), binary() | nil) :: boolean()
  defp valid_sources?([_ | _] = sources, content),
    do: Enum.all?(sources, &Source.valid?(&1, content))

  defp valid_sources?(_invalid, _content), do: false

  @spec unique_sources([Source.t()], [Source.t()]) :: [Source.t()]
  defp unique_sources(a, b), do: Enum.uniq(a ++ b)

  @spec put_sources(map(), term(), [Source.t()]) :: map()
  defp put_sources(sets, key, []), do: Map.delete(sets, key)
  defp put_sources(sets, key, sources), do: Map.put(sets, key, sources)

  @spec filter_sources(map(), (Source.t() -> boolean())) :: map()
  defp filter_sources(sets, predicate) do
    Enum.reduce(sets, %{}, fn {key, sources}, kept ->
      put_sources(kept, key, Enum.filter(sources, predicate))
    end)
  end
end
