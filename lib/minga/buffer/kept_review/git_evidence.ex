defmodule Minga.Buffer.KeptReview.GitEvidence do
  @moduledoc """
  Worker-side reads for Keep and commit retirement. The worktree, branch and immutable tip are pinned for a complete proof. The buffer process owns publication and rejects a result for a superseded saved generation.
  """

  alias Minga.Buffer.KeptReview.{Ledger, Observation, Proof, Source}
  alias Minga.Buffer.Provenance
  alias Minga.Git.System, as: Git
  alias Minga.Git.ReviewIdentity

  @typep chains :: %{ReviewIdentity.t() => [Observation.transition()]}
  @typep bytes :: binary() | nil | :unavailable
  @typep image ::
           {binary(), [Source.t()], %{Observation.transition() => Observation.origin_set()}}

  @doc "Samples a fresh lower bound before Keep. A failed file read never changes the branch observation."
  @spec capture(String.t(), boolean(), (String.t() -> {:ok, ReviewIdentity.t()} | :error)) ::
          Observation.capture()
  def capture(path, read_saved?, observe \\ &Minga.Git.review_baseline/1) do
    case observe.(path) do
      {:ok, {root, relative, _ref} = baseline} ->
        {baseline, if(read_saved?, do: saved_bytes(Path.join(root, relative)))}

      :error ->
        :unproven
    end
  end

  @doc "Proves only transitions later than each source's own Keep observation."
  @spec prove(String.t(), Ledger.t(), Observation.cache()) :: Observation.result()
  def prove(path, ledger, cache) do
    with {:ok, {root, relative, {branch, _, _} = tip} = scope} <- Git.review_baseline(path),
         [_ | _] = jobs <- Ledger.jobs(ledger, scope) do
      chains = read_chains(jobs, tip)
      key = {root, relative, branch}
      {proof, entries} = prove_images(jobs, chains, root, relative, cached_entries(cache, key))

      case Git.review_baseline(path) do
        {:ok, ^scope} -> {:ok, Enum.uniq(proof), {key, entries}}
        _changed -> :stale
      end
    else
      _unavailable -> {:ok, [], nil}
    end
  end

  @spec cached_entries(Observation.cache(), Observation.scope_key()) ::
          Observation.cache_entries()
  defp cached_entries({scope, entries}, scope), do: entries
  defp cached_entries(_cache, _scope), do: %{}

  @spec saved_bytes(String.t()) :: binary() | nil
  defp saved_bytes(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> nil
    end
  end

  @spec read_chains([Ledger.job()], ReviewIdentity.ref()) :: chains()
  defp read_chains(jobs, tip) do
    jobs
    |> Enum.flat_map(fn {_image, observations} -> Enum.map(observations, &elem(&1, 0)) end)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn {root, _path, ref} = baseline, chains ->
      case Git.review_transitions(root, ref, tip) do
        {:ok, transitions} -> Map.put(chains, baseline, transitions)
        :error -> chains
      end
    end)
  end

  @spec prove_images(
          [Ledger.job()],
          chains(),
          String.t(),
          String.t(),
          Observation.cache_entries()
        ) ::
          {[Provenance.keep_interval()], Observation.cache_entries()}
  defp prove_images(jobs, chains, root, path, cache) do
    transitions = chains |> Map.values() |> Enum.max_by(&length/1, fn -> [] end)
    images = jobs |> Enum.map(&prepare_image(&1, chains)) |> Enum.with_index()

    {proof, entries, _last} =
      Enum.reduce(transitions, {[], %{}, nil}, fn edge, acc ->
        scan_edge(images, root, path, edge, cache, acc)
      end)

    {proof, entries}
  end

  @typep scan ::
           {[Provenance.keep_interval()], Observation.cache_entries(),
            {String.t(), bytes()} | nil}

  @spec scan_edge(
          [{image(), non_neg_integer()}],
          String.t(),
          String.t(),
          Observation.transition(),
          Observation.cache_entries(),
          scan()
        ) :: scan()
  defp scan_edge(images, root, path, edge, cache, {proof, entries, last} = scan) do
    eligible = for {{_, _, %{^edge => keys}}, index} <- images, do: {index, keys}

    case cache do
      %{^edge => {^eligible, intervals} = previous} ->
        {intervals ++ proof, Map.put(entries, edge, previous), last}

      _new_or_changed ->
        scan_uncached_edge(images, {root, path}, edge, eligible, scan)
    end
  end

  @spec scan_uncached_edge(
          [{image(), non_neg_integer()}],
          {String.t(), String.t()},
          Observation.transition(),
          Observation.eligibility(),
          scan()
        ) :: scan()
  defp scan_uncached_edge(
         images,
         {root, path},
         {parent, child} = edge,
         eligible,
         {proof, entries, last}
       ) do
    before =
      case last do
        {^parent, bytes} -> bytes
        _ -> blob(root, parent, path)
      end

    after_commit = blob(root, child, path)

    if before == :unavailable or after_commit == :unavailable do
      {proof, entries, nil}
    else
      intervals = edge_intervals(images, edge, before, after_commit)
      {intervals ++ proof, Map.put(entries, edge, {eligible, intervals}), {child, after_commit}}
    end
  end

  @spec edge_intervals([{image(), non_neg_integer()}], Observation.transition(), bytes(), bytes()) ::
          [Provenance.keep_interval()]
  defp edge_intervals(_images, _edge, same, same), do: []

  defp edge_intervals(images, edge, before, after_commit) do
    Enum.reduce(images, [], fn {image, _index}, intervals ->
      prove_image(image, intervals, edge, before, after_commit)
    end)
  end

  @spec prepare_image(Ledger.job(), chains()) :: image()
  defp prepare_image({saved, observations}, chains) do
    sources =
      observations |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq() |> Source.in_postimage_order()

    eligibility =
      Enum.reduce(observations, %{}, fn {baseline, sources}, eligibility ->
        keys = MapSet.new(sources, &Source.key/1)

        Enum.reduce(Map.get(chains, baseline, []), eligibility, fn edge, eligibility ->
          Map.update(eligibility, edge, keys, &MapSet.union(&1, keys))
        end)
      end)

    {saved, sources, eligibility}
  end

  @spec prove_image(
          image(),
          [Provenance.keep_interval()],
          Observation.transition(),
          bytes(),
          bytes()
        ) ::
          [Provenance.keep_interval()]
  defp prove_image({saved, sources, eligibility}, proof, edge, before, after_commit) do
    case eligibility do
      %{^edge => eligible} ->
        for {kind, id, _, _} = interval <- Proof.included(saved, sources, before, after_commit),
            MapSet.member?(eligible, {kind, id}),
            reduce: proof do
          proof -> [interval | proof]
        end

      _not_eligible ->
        proof
    end
  end

  @spec blob(String.t(), String.t() | :unborn, String.t()) :: bytes()
  defp blob(root, commit, path) do
    case Git.review_blob(root, commit, path) do
      {:ok, bytes} -> bytes
      :error -> :unavailable
    end
  end
end
