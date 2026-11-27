defmodule Minga.Buffer.KeptReview.Proof do
  @moduledoc """
  Proves kept source intervals against one immutable Git parent-to-child transition. It inverts the direct saved splices to locate their original sites, then checks every shortest correspondence of the surrounding bytes. A neighboring operation can be staged separately. Repeated text, conflicting assignments and unobserved bytes are not evidence.
  """

  alias Minga.Buffer.KeptReview.Source
  alias Minga.Core.ByteAlignment

  @alignment_cells 2_000_000
  @max_variant_edges 8_192
  @anchor_context 32

  @type interval ::
          {:insert | :replace | :delete, pos_integer(), non_neg_integer(), pos_integer()}
  @typep cluster :: {non_neg_integer(), non_neg_integer(), [Source.t()]}
  @typep edge :: {non_neg_integer(), non_neg_integer()}
  @typep located :: {non_neg_integer(), non_neg_integer()}
  @typep matches :: %{non_neg_integer() => ByteAlignment.classification()}

  @doc "Returns only source intervals introduced by this transition, not those already in the parent."
  @spec included(binary(), [Source.t()], binary() | nil, binary() | nil) :: [interval()]
  def included(_saved, _sources, same, same), do: []
  def included(_saved, _sources, _parent, nil), do: []
  def included(_saved, [], _parent, _child), do: []

  def included(saved, sources, parent, child) do
    {original, clusters} = invert(saved, sources)
    size = byte_size(original)
    probes = probe_offsets(clusters, size)

    with {:ok, old_matches} <- correspond(original, parent, probes),
         {:ok, new_matches} <- correspond(original, child, probes) do
      located = locate_clusters(clusters, size, {parent, old_matches}, {child, new_matches})

      old_probes =
        if parent, do: probe_offsets_for_parent(located, byte_size(parent)), else: MapSet.new()

      case correspond(parent, child, old_probes) do
        {:ok, stable} ->
          direct = verify_clusters(located, parent, child, stable)
          direct ++ outer_replacements(clusters, original, saved, parent, child, direct)

        :over_budget ->
          []
      end
    else
      :over_budget -> []
    end
  end

  @spec invert(binary(), [Source.t()]) :: {binary(), [cluster()]}
  defp invert(saved, sources) do
    {point, _position, pieces, clusters} =
      Enum.reduce(sources, {0, 0, [], []}, fn source, {previous, position, pieces, clusters} ->
        gap = source.point - previous
        start = position + gap
        stop = start + byte_size(source.old)
        kept = binary_part(saved, previous, gap)

        clusters =
          case clusters do
            [{from, ^start, earlier} | rest] when gap == 0 ->
              [{from, stop, [source | earlier]} | rest]

            _separate ->
              [{start, stop, [source]} | clusters]
          end

        {source.point + byte_size(source.new), stop, [source.old, kept | pieces], clusters}
      end)

    tail = binary_part(saved, point, byte_size(saved) - point)
    {:erlang.iolist_to_binary(Enum.reverse([tail | pieces])), Enum.reverse(clusters)}
  end

  @spec probe_offsets([cluster()], non_neg_integer()) :: MapSet.t(non_neg_integer())
  defp probe_offsets(clusters, size) do
    Enum.reduce(clusters, MapSet.new(), fn {start, stop, _sources}, probes ->
      add_probes(probes, start, stop, size)
    end)
  end

  @spec add_probes(
          MapSet.t(non_neg_integer()),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          MapSet.t(non_neg_integer())
  defp add_probes(probes, start, stop, size) do
    probes = if start > 0, do: MapSet.put(probes, start - 1), else: probes
    if stop < size, do: MapSet.put(probes, stop), else: probes
  end

  @spec correspond(binary() | nil, binary() | nil, MapSet.t(non_neg_integer())) ::
          {:ok, matches()} | :over_budget
  defp correspond(nil, _destination, _probes), do: {:ok, %{}}
  defp correspond(_source, nil, _probes), do: {:ok, %{}}

  defp correspond(source, destination, probes) do
    case ByteAlignment.classify_subsequence(source, destination, probes) do
      {:ok, matched} ->
        {:ok, matched}

      :not_subsequence ->
        size = max(byte_size(source), byte_size(destination))
        limit = max(0, div(div(@alignment_cells, max(size, 1)) - 1, 2))
        minimum = abs(byte_size(source) - byte_size(destination))
        align(source, destination, probes, min(limit, max(2, minimum)), limit)
    end
  end

  @spec align(
          binary(),
          binary(),
          MapSet.t(non_neg_integer()),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, matches()} | :over_budget
  defp align(source, destination, probes, width, limit) do
    case ByteAlignment.classify(source, destination, probes, width) do
      :over_budget when width < limit ->
        align(source, destination, probes, min(limit, width * 2), limit)

      result ->
        result
    end
  end

  @typep located_cluster :: {located() | nil, located(), [Source.t()]}

  @spec locate_clusters(
          [cluster()],
          non_neg_integer(),
          {binary() | nil, matches()},
          {binary(), matches()}
        ) ::
          [located_cluster()]
  defp locate_clusters(clusters, size, parent, child) do
    for {start, stop, sources} <- clusters,
        {:ok, left} <- [locate_parent(parent, start, stop, size, sources)],
        {:ok, right} <- [locate(child, start, stop, size)],
        do: {left, right, Enum.reverse(sources)}
  end

  @spec locate_parent(
          {binary() | nil, matches()},
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [Source.t()]
        ) ::
          {:ok, located() | nil} | :uncertain
  defp locate_parent({nil, _matches}, _start, _stop, _size, sources) do
    if Enum.all?(sources, &(&1.kind == :insert)), do: {:ok, nil}, else: :uncertain
  end

  defp locate_parent(parent, start, stop, size, _sources), do: locate(parent, start, stop, size)

  @spec locate({binary(), matches()}, non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, located()} | :uncertain
  defp locate({blob, matches}, start, stop, size) do
    left = if start == 0, do: {:matched, -1}, else: Map.get(matches, start - 1)
    right = if stop == size, do: {:matched, byte_size(blob)}, else: Map.get(matches, stop)

    case {left, right} do
      {{:matched, from}, {:matched, to}} when from < to -> {:ok, {from + 1, to}}
      _uncertain -> :uncertain
    end
  end

  @typep anchor :: {integer(), integer()}
  @typep anchor_probe :: anchor() | :bof | :eof
  @typep replacement :: {Source.t(), non_neg_integer(), [anchor_probe()], [anchor_probe()]}
  @typep located_replacement :: {Source.t(), located(), located(), [anchor()], [anchor()]}

  # Adjacent edits can remove an immediate anchor. Require forced old and new spans, stable
  # enclosing context, and an unchanged distance to at least one fence. The old span must not
  # survive elsewhere: inserting the replacement next to the original does not commit it.
  @spec outer_replacements([cluster()], binary(), binary(), binary() | nil, binary(), [interval()]) ::
          [interval()]
  defp outer_replacements(_clusters, _original, _saved, nil, _child, _direct), do: []

  defp outer_replacements(clusters, original, saved, parent, child, direct) do
    proved = MapSet.new(direct, &elem(&1, 1))
    sizes = {byte_size(original), byte_size(saved)}

    with [_ | _] = candidates <- replacement_candidates(clusters, 0, sizes, proved),
         {old_probes, new_probes} <- replacement_probes(candidates),
         {:ok, old_matches} <- correspond(original, parent, old_probes),
         {:ok, new_matches} <- correspond(saved, child, new_probes) do
      locations = locate_replacements(candidates, parent, child, old_matches, new_matches)
      ends = {byte_size(parent), byte_size(child)}

      case correspond(parent, child, stability_probes(locations, elem(ends, 0))) do
        {:ok, stable} -> fenced_intervals(locations, ends, stable)
        :over_budget -> []
      end
    else
      _unavailable -> []
    end
  end

  @spec replacement_candidates([cluster()], non_neg_integer(), located(), MapSet.t(pos_integer())) ::
          [replacement()]
  defp replacement_candidates([], _previous, _sizes, _proved), do: []

  defp replacement_candidates([{start, stop, reversed} | rest], previous, sizes, proved) do
    later = replacement_candidates(rest, stop, sizes, proved)

    if Enum.any?(reversed, &unproved_replacement?(&1, proved)) do
      {left, right} = enclosing_probes(reversed, {start, stop}, previous, rest, sizes)

      {_next, candidates} =
        Enum.reduce(
          Enum.reverse(reversed),
          {start, []},
          &add_replacement(&1, &2, left, right, proved)
        )

      Enum.reverse(candidates, later)
    else
      later
    end
  end

  @spec add_replacement(
          Source.t(),
          {non_neg_integer(), [replacement()]},
          [anchor_probe()],
          [anchor_probe()],
          MapSet.t(pos_integer())
        ) :: {non_neg_integer(), [replacement()]}
  defp add_replacement(source, {point, candidates}, left, right, proved) do
    candidates =
      if unproved_replacement?(source, proved),
        do: [{source, point, left, right} | candidates],
        else: candidates

    {point + byte_size(source.old), candidates}
  end

  @spec unproved_replacement?(Source.t(), MapSet.t(pos_integer())) :: boolean()
  defp unproved_replacement?(%Source{kind: :replace, id: id, old: old, new: new}, proved),
    do: old != new and not MapSet.member?(proved, id)

  defp unproved_replacement?(_source, _proved), do: false

  @spec enclosing_probes([Source.t()], located(), non_neg_integer(), [cluster()], located()) ::
          {[anchor_probe()], [anchor_probe()]}
  defp enclosing_probes(reversed, {start, stop}, previous, rest, {size, _saved}) do
    following =
      case rest do
        [{next, _, _} | _] -> next
        [] -> size
      end

    left_shift = List.last(reversed).point - start
    last = hd(reversed)
    right_shift = last.point + byte_size(last.new) - stop
    low = max(previous, start - @anchor_context)
    high = min(following, stop + @anchor_context)
    left = for offset <- (start - 1)..low//-1, do: {offset, left_shift + offset}
    right = for offset <- stop..(high - 1)//1, do: {offset, right_shift + offset}

    {if(low == 0, do: left ++ [:bof], else: left),
     if(high == size, do: right ++ [:eof], else: right)}
  end

  @spec replacement_probes([replacement()]) ::
          {MapSet.t(non_neg_integer()), MapSet.t(non_neg_integer())}
  defp replacement_probes(candidates) do
    Enum.reduce(candidates, {MapSet.new(), MapSet.new()}, fn {source, from, left, right},
                                                             {old, new} ->
      old = old |> MapSet.put(from) |> MapSet.put(from + byte_size(source.old) - 1)

      new =
        new |> MapSet.put(source.point) |> MapSet.put(source.point + byte_size(source.new) - 1)

      Enum.reduce(left ++ right, {old, new}, fn
        {a, b}, {old, new} -> {MapSet.put(old, a), MapSet.put(new, b)}
        _edge, acc -> acc
      end)
    end)
  end

  @spec locate_replacements([replacement()], binary(), binary(), matches(), matches()) ::
          [located_replacement()]
  defp locate_replacements(candidates, parent, child, old, new) do
    ends = {byte_size(parent), byte_size(child)}

    for {source, from, left, right} <- candidates,
        {:ok, a} <- [forced_span(old, from, source.old, parent)],
        {:ok, b} <- [forced_span(new, source.point, source.new, child)] do
      {source, a, b, matching_anchors(left, old, new, ends),
       matching_anchors(right, old, new, ends)}
    end
  end

  @spec forced_span(matches(), non_neg_integer(), binary(), binary()) ::
          {:ok, located()} | :uncertain
  defp forced_span(matches, from, bytes, observed) do
    length = byte_size(bytes)

    with {:matched, first} <- Map.get(matches, from),
         {:matched, last} <- Map.get(matches, from + length - 1) do
      if last - first + 1 == length and binary_part(observed, first, length) == bytes,
        do: {:ok, {first, last + 1}},
        else: :uncertain
    else
      _uncertain -> :uncertain
    end
  end

  @spec matching_anchors([anchor_probe()], matches(), matches(), located()) :: [anchor()]
  defp matching_anchors(pairs, old, new, ends) do
    Enum.flat_map(pairs, fn
      :bof ->
        [{-1, -1}]

      :eof ->
        [ends]

      {a, b} ->
        case {Map.get(old, a), Map.get(new, b)} do
          {{:matched, first}, {:matched, second}} -> [{first, second}]
          _uncertain -> []
        end
    end)
  end

  @spec stability_probes([located_replacement()], non_neg_integer()) ::
          MapSet.t(non_neg_integer())
  defp stability_probes(locations, size) do
    Enum.reduce(locations, MapSet.new(), fn {_, {from, to}, _, left, right}, probes ->
      # A forced surviving byte can disprove the site even when it is absent from either saved-side alignment.
      first = Enum.reduce(left, from, fn {old, _}, low -> min(low, max(old, 0)) end)
      last = Enum.reduce(right, to, fn {old, _}, high -> max(high, min(old + 1, size)) end)
      Enum.reduce(first..(last - 1)//1, probes, &MapSet.put(&2, &1))
    end)
  end

  @spec fenced_intervals([located_replacement()], located(), matches()) :: [interval()]
  defp fenced_intervals(locations, ends, stable) do
    for {source, {from, to}, {new_from, new_to}, left, right} <- locations,
        {a, b} <- [fence(left, {from, new_from}, :left, ends, stable)],
        {x, y} <- [fence(right, {to, new_to}, :right, ends, stable)],
        from - a == new_from - b or x - to == y - new_to,
        no_surviving_old_bytes?(from, to, {new_from, new_to}, stable),
        no_crossing?({a, from, to, x}, {new_from, new_to}, stable),
        do: interval(source, 0, byte_size(source.new))
  end

  @spec fence([anchor()], located(), :left | :right, located(), matches()) :: anchor() | nil
  defp fence(candidates, {a, b}, side, ends, stable) do
    Enum.find(candidates, fn {x, y} = candidate ->
      outside? = if side == :left, do: x < a and y < b, else: x >= a and y >= b
      outside? and stable_pair?(candidate, ends, stable)
    end)
  end

  @spec no_crossing?(
          {integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()},
          located(),
          matches()
        ) :: boolean()
  defp no_crossing?({left, from, to, right}, {new_from, new_to}, matches) do
    Enum.all?((left + 1)..(from - 1)//1, fn at ->
      case Map.get(matches, at) do
        :unmatched -> true
        {:matched, point} -> point < new_from
        {:ambiguous, _, last} -> last < new_from
        _uncertain -> false
      end
    end) and
      Enum.all?(to..(right - 1)//1, fn at ->
        case Map.get(matches, at) do
          :unmatched -> true
          {:matched, point} -> point >= new_to
          {:ambiguous, first, _} -> first >= new_to
          _uncertain -> false
        end
      end)
  end

  @spec no_surviving_old_bytes?(non_neg_integer(), pos_integer(), located(), matches()) ::
          boolean()
  defp no_surviving_old_bytes?(from, to, {new_from, new_to}, matches) do
    Enum.all?(from..(to - 1), fn at ->
      case Map.get(matches, at) do
        :unmatched -> true
        {:matched, point} -> new_from <= point and point < new_to
        _uncertain -> false
      end
    end)
  end

  @spec stable_pair?(anchor(), located(), matches()) :: boolean()
  defp stable_pair?({-1, -1}, _ends, _stable), do: true
  defp stable_pair?(ends, ends, _stable), do: true
  defp stable_pair?({old, new}, _ends, stable), do: Map.get(stable, old) == {:matched, new}

  @spec probe_offsets_for_parent([located_cluster()], non_neg_integer()) ::
          MapSet.t(non_neg_integer())
  defp probe_offsets_for_parent(clusters, size) do
    Enum.reduce(clusters, MapSet.new(), fn {{start, stop}, _right, _sources}, probes ->
      add_probes(probes, start, stop, size)
    end)
  end

  @spec verify_clusters([located_cluster()], binary() | nil, binary(), matches()) :: [interval()]
  defp verify_clusters(clusters, parent, child, stable) do
    Enum.flat_map(clusters, fn {left, right, sources} ->
      if stable_anchors?(left, right, parent, child, stable) do
        compare(sources, portion(parent, left), portion(child, right))
      else
        []
      end
    end)
  end

  @spec stable_anchors?(located() | nil, located(), binary() | nil, binary(), matches()) ::
          boolean()
  defp stable_anchors?(nil, _right, nil, _child, _matches), do: true

  defp stable_anchors?({from, to}, {child_from, child_to}, parent, child, matches) do
    left? = from == 0 or Map.get(matches, from - 1) == {:matched, child_from - 1}

    right? =
      (to == byte_size(parent) and child_to == byte_size(child)) or
        Map.get(matches, to) == {:matched, child_to}

    left? and right?
  end

  @spec portion(binary() | nil, located() | nil) :: binary()
  defp portion(nil, nil), do: ""
  defp portion(blob, {start, stop}), do: binary_part(blob, start, stop - start)

  @spec compare([Source.t()], binary(), binary()) :: [interval()]
  defp compare(_sources, equal, equal), do: []

  defp compare(sources, parent, child) do
    with {:ok, prior} <- assignments(sources, parent),
         {:ok, next} <- assignments(sources, child) do
      Enum.zip_with([sources, prior, next], fn [source, old, new] ->
        changes(source, extract(parent, old), extract(child, new))
      end)
      |> List.flatten()
    else
      :uncertain -> []
    end
  end

  # A forward edge is admissible only if a suffix path from it can also reach EOF.
  @spec assignments([Source.t()], binary()) :: {:ok, [edge() | nil]} | :uncertain
  defp assignments([source], observed) do
    if valid_variant?(source, observed), do: {:ok, [{0, byte_size(observed)}]}, else: :uncertain
  end

  defp assignments(sources, observed) do
    Enum.reduce_while(sources, {[0], [], @max_variant_edges}, fn source, {from, stages, budget} ->
      case variant_edges(from, source, observed, budget) do
        :uncertain -> {:halt, :uncertain}
        {edges, next, budget} -> {:cont, {MapSet.to_list(next), [edges | stages], budget}}
      end
    end)
    |> finish_assignments(byte_size(observed))
  end

  @spec variant_edges([non_neg_integer()], Source.t(), binary(), non_neg_integer()) ::
          {[edge()], MapSet.t(non_neg_integer()), non_neg_integer()} | :uncertain
  defp variant_edges(from, source, observed, budget) do
    Enum.reduce_while(from, {[], MapSet.new(), budget}, fn start, acc ->
      case variants(source, observed, start, acc) do
        :uncertain -> {:halt, :uncertain}
        next -> {:cont, next}
      end
    end)
  end

  @typep edges :: {[edge()], MapSet.t(non_neg_integer()), non_neg_integer()}

  @spec variants(Source.t(), binary(), non_neg_integer(), edges()) :: edges() | :uncertain
  defp variants(%Source{kind: :replace, old: old, new: new}, observed, start, acc) do
    with {:ok, acc} <- exact_variant(old, observed, start, acc),
         {:ok, acc} <- exact_variant(new, observed, start, acc),
         do: acc
  end

  defp variants(%Source{kind: :insert, new: bytes}, observed, start, acc),
    do: subsequence_variants(bytes, observed, start, start, acc)

  defp variants(%Source{kind: :delete, old: bytes}, observed, start, acc),
    do: subsequence_variants(bytes, observed, start, start, acc)

  @spec valid_variant?(Source.t(), binary()) :: boolean()
  defp valid_variant?(%Source{kind: :replace, old: old, new: new}, observed),
    do: observed == old or observed == new

  defp valid_variant?(%Source{kind: :insert, new: new}, observed), do: subsequence?(new, observed)
  defp valid_variant?(%Source{kind: :delete, old: old}, observed), do: subsequence?(old, observed)

  @spec subsequence?(binary(), binary()) :: boolean()
  defp subsequence?(_bytes, ""), do: true

  defp subsequence?(bytes, observed) when byte_size(bytes) == byte_size(observed),
    do: bytes == observed

  defp subsequence?(bytes, observed) when byte_size(bytes) < byte_size(observed), do: false

  defp subsequence?(bytes, <<byte, rest::binary>>) do
    case :binary.match(bytes, <<byte>>) do
      {index, 1} ->
        subsequence?(binary_part(bytes, index + 1, byte_size(bytes) - index - 1), rest)

      :nomatch ->
        false
    end
  end

  @spec exact_variant(binary(), binary(), non_neg_integer(), edges()) ::
          {:ok, edges()} | :uncertain
  defp exact_variant(bytes, observed, start, acc) do
    length = byte_size(bytes)

    if start + length <= byte_size(observed) and binary_part(observed, start, length) == bytes,
      do: add_edge(acc, start, start + length),
      else: {:ok, acc}
  end

  @spec subsequence_variants(binary(), binary(), non_neg_integer(), non_neg_integer(), edges()) ::
          edges() | :uncertain
  defp subsequence_variants(bytes, observed, start, stop, acc) do
    with {:ok, acc} <- add_edge(acc, start, stop) do
      advance_subsequence(bytes, observed, start, stop, acc)
    end
  end

  @spec advance_subsequence(binary(), binary(), non_neg_integer(), non_neg_integer(), edges()) ::
          edges() | :uncertain
  defp advance_subsequence(bytes, observed, _start, stop, acc)
       when stop == byte_size(observed) or bytes == "",
       do: acc

  defp advance_subsequence(bytes, observed, start, stop, acc) do
    case :binary.match(bytes, binary_part(observed, stop, 1)) do
      {index, 1} ->
        rest = binary_part(bytes, index + 1, byte_size(bytes) - index - 1)
        subsequence_variants(rest, observed, start, stop + 1, acc)

      :nomatch ->
        acc
    end
  end

  @spec add_edge(edges(), non_neg_integer(), non_neg_integer()) :: {:ok, edges()} | :uncertain
  defp add_edge({_edges, _next, 0}, _start, _stop), do: :uncertain

  defp add_edge({edges, next, budget}, start, stop),
    do: {:ok, {[{start, stop} | edges], MapSet.put(next, stop), budget - 1}}

  @spec finish_assignments(
          {[non_neg_integer()], [[edge()]], non_neg_integer()} | :uncertain,
          non_neg_integer()
        ) ::
          {:ok, [edge() | nil]} | :uncertain
  defp finish_assignments(:uncertain, _size), do: :uncertain

  defp finish_assignments({_from, stages, _budget}, size) do
    {starts, choices} =
      Enum.reduce(stages, {MapSet.new([size]), []}, fn edges, {allowed, choices} ->
        {from, choice} =
          Enum.reduce(edges, {MapSet.new(), nil}, &previous_boundary(allowed, &1, &2))

        {from, [if(choice == :ambiguous, do: nil, else: choice) | choices]}
      end)

    if MapSet.member?(starts, 0), do: {:ok, choices}, else: :uncertain
  end

  @spec previous_boundary(
          MapSet.t(non_neg_integer()),
          edge(),
          {MapSet.t(non_neg_integer()), edge() | :ambiguous | nil}
        ) :: {MapSet.t(non_neg_integer()), edge() | :ambiguous | nil}
  defp previous_boundary(allowed, {start, stop} = edge, {from, choice}) do
    if MapSet.member?(allowed, stop),
      do: {MapSet.put(from, start), common_edge(choice, edge)},
      else: {from, choice}
  end

  @spec common_edge(edge() | :ambiguous | nil, edge()) :: edge() | :ambiguous
  defp common_edge(nil, edge), do: edge
  defp common_edge(edge, edge), do: edge
  defp common_edge(_other, _edge), do: :ambiguous

  @spec extract(binary(), edge() | nil) :: binary() | nil
  defp extract(_bytes, nil), do: nil
  defp extract(bytes, {start, stop}), do: binary_part(bytes, start, stop - start)

  @spec changes(Source.t(), binary() | nil, binary() | nil) :: [interval()]
  defp changes(_source, nil, _child), do: []
  defp changes(_source, _parent, nil), do: []
  defp changes(_source, same, same), do: []

  defp changes(%Source{kind: :replace, old: parent, new: child} = source, parent, child),
    do: [interval(source, 0, byte_size(child))]

  defp changes(%Source{kind: :insert, new: image} = source, parent, child),
    do: partial(source, image, parent, child)

  defp changes(%Source{kind: :delete, old: image} = source, parent, child),
    do: partial(source, image, child, parent)

  defp changes(_source, _parent, _child), do: []

  @spec partial(Source.t(), binary(), binary(), binary()) :: [interval()]
  defp partial(source, complete, absent_from, present_in) do
    size = byte_size(complete)

    cond do
      present_in == "" -> []
      complete == present_in and absent_from == "" -> [interval(source, 0, size)]
      true -> partial_ranges(source, complete, absent_from, present_in, size)
    end
  end

  @spec partial_ranges(Source.t(), binary(), binary(), binary(), pos_integer()) :: [interval()]
  defp partial_ranges(source, complete, absent_from, present_in, size) do
    offsets = MapSet.new(0..(size - 1))

    with {:ok, absent} <- correspond(complete, absent_from, offsets),
         {:ok, present} <- correspond(complete, present_in, offsets) do
      collect_partial_ranges(source, size, absent, present)
    else
      :over_budget -> []
    end
  end

  @spec collect_partial_ranges(Source.t(), pos_integer(), matches(), matches()) :: [interval()]
  defp collect_partial_ranges(source, size, absent, present) do
    0..(size - 1)
    |> Enum.reduce({nil, []}, fn offset, {start, intervals} ->
      proven? =
        Map.get(absent, offset) == :unmatched and match?({:matched, _}, Map.get(present, offset))

      cond do
        proven? -> {start || offset, intervals}
        start != nil -> {nil, [interval(source, start, offset) | intervals]}
        true -> {nil, intervals}
      end
    end)
    |> finish_ranges(source, size)
  end

  @spec finish_ranges({non_neg_integer() | nil, [interval()]}, Source.t(), non_neg_integer()) :: [
          interval()
        ]
  defp finish_ranges({nil, ranges}, _source, _size), do: Enum.reverse(ranges)

  defp finish_ranges({start, ranges}, source, size),
    do: Enum.reverse(ranges, [interval(source, start, size)])

  @spec interval(Source.t(), non_neg_integer(), pos_integer()) :: interval()
  defp interval(%Source{kind: kind, id: id, offset: offset}, start, stop),
    do: {kind, id, offset + start, offset + stop}
end
