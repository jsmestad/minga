defmodule Minga.Core.ByteAlignment do
  @moduledoc """
  Classifies selected source bytes across all minimum insert/delete alignments. An arbitrary diff traceback cannot distinguish a byte that changed from an adjacent identical byte that could have changed instead.

  The edit bound limits the diagonal band. A result is conclusive only if a shortest path fits within that bound: every path with that cost fits the same band. Rows that do not touch a requested byte are not retained. No path is reconstructed.
  """

  @type classification ::
          {:matched, non_neg_integer()}
          | :unmatched
          | {:ambiguous, first_destination :: non_neg_integer(),
             last_destination :: non_neg_integer()}
  @typep row :: {non_neg_integer(), tuple(), 1 | -1}
  @typep matrix :: {binary(), binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @typep rows :: %{non_neg_integer() => row()}

  @doc "Returns forced matches, forced deletions, or the range of possible match destinations."
  @spec classify(binary(), binary(), MapSet.t(non_neg_integer()), non_neg_integer()) ::
          {:ok, %{non_neg_integer() => classification()}} | :over_budget
  def classify(source, destination, offsets, limit)
      when is_binary(source) and is_binary(destination) and is_integer(limit) and limit >= 0 do
    cond do
      MapSet.size(offsets) == 0 -> {:ok, %{}}
      source == destination -> {:ok, identity(source, offsets)}
      abs(byte_size(source) - byte_size(destination)) > limit -> :over_budget
      true -> classify_within(source, destination, offsets, limit)
    end
  end

  @doc "Classifies embeddings in linear scans when the size difference is the full edit distance."
  @spec classify_subsequence(binary(), binary(), MapSet.t(non_neg_integer())) ::
          {:ok, %{non_neg_integer() => classification()}} | :not_subsequence
  def classify_subsequence(source, destination, offsets) when source == destination,
    do: {:ok, identity(source, offsets)}

  def classify_subsequence(source, destination, offsets)
      when byte_size(source) < byte_size(destination) do
    with {:ok, earliest, latest} <- embeddings(source, destination, {:short, offsets}) do
      {:ok,
       Map.new(earliest, fn {offset, first} ->
         last = Map.fetch!(latest, offset)

         if last == first,
           do: {offset, {:matched, first}},
           else: {offset, {:ambiguous, first, last}}
       end)}
    end
  end

  def classify_subsequence(source, destination, offsets)
      when byte_size(source) > byte_size(destination) do
    with {:ok, prefix, suffix} <- embeddings(destination, source, {:long, offsets}) do
      {:ok,
       Map.new(prefix, fn {offset, before} ->
         after_at = Map.fetch!(suffix, offset)
         byte = :binary.at(source, offset)
         {offset, embedding_position(destination, byte, before, after_at)}
       end)}
    end
  end

  def classify_subsequence(_source, _destination, _offsets), do: :not_subsequence

  @typep embedding_query :: {:short | :long, MapSet.t(non_neg_integer())}
  @typep positions :: %{non_neg_integer() => integer()}

  @spec embeddings(binary(), binary(), embedding_query()) ::
          {:ok, positions(), positions()} | :not_subsequence
  defp embeddings(short, long, query) do
    lengths = {byte_size(short), byte_size(long)}
    reverse = {byte_size(short) - 1, byte_size(long) - 1}

    with {:ok, forward} <- scan_embedding(short, long, {0, 0}, lengths, 1, query, %{}),
         {:ok, backward} <- scan_embedding(short, long, reverse, {-1, -1}, -1, query, %{}) do
      {:ok, forward, backward}
    end
  end

  @spec scan_embedding(
          binary(),
          binary(),
          {integer(), integer()},
          {integer(), integer()},
          1 | -1,
          embedding_query(),
          positions()
        ) :: {:ok, positions()} | :not_subsequence
  defp scan_embedding(_short, _long, {i, j}, {finish, j}, _step, _query, found) do
    if i == finish, do: {:ok, found}, else: :not_subsequence
  end

  defp scan_embedding(_short, _long, {i, _j}, {i, _finish}, _step, {:short, _}, found),
    do: {:ok, found}

  defp scan_embedding(
         short,
         long,
         {i, j},
         {finish, _} = ends,
         step,
         {side, offsets} = query,
         found
       ) do
    match? = i != finish and :binary.at(short, i) == :binary.at(long, j)

    found =
      case side do
        :long -> put_queried(found, offsets, j, i)
        :short -> if match?, do: put_queried(found, offsets, i, j), else: found
      end

    next = if match?, do: i + step, else: i
    scan_embedding(short, long, {next, j + step}, ends, step, query, found)
  end

  @spec put_queried(positions(), MapSet.t(non_neg_integer()), non_neg_integer(), integer()) ::
          positions()
  defp put_queried(positions, offsets, offset, match) do
    if MapSet.member?(offsets, offset), do: Map.put(positions, offset, match), else: positions
  end

  # `before` is the largest target prefix matched before this byte. `after_at` is the last byte
  # not covered by the largest suffix matched after it. If there is one uncovered byte, it must
  # match here. Otherwise this byte can be skipped; check whether matching it is also possible.
  @spec embedding_position(binary(), byte(), non_neg_integer(), integer()) :: classification()
  defp embedding_position(_target, _byte, before, before), do: {:matched, before}

  defp embedding_position(target, byte, before, after_at) do
    first = max(0, after_at)
    last = min(before, byte_size(target) - 1)

    case first <= last && :binary.match(target, <<byte>>, scope: {first, last - first + 1}) do
      {start, 1} -> {:ambiguous, start, last_byte(target, byte, last)}
      _none -> :unmatched
    end
  end

  @spec last_byte(binary(), byte(), non_neg_integer()) :: non_neg_integer()
  defp last_byte(target, byte, last) do
    if :binary.at(target, last) == byte, do: last, else: last_byte(target, byte, last - 1)
  end

  @spec identity(binary(), MapSet.t(non_neg_integer())) :: %{
          non_neg_integer() => classification()
        }
  defp identity(source, offsets) do
    size = byte_size(source)
    for offset <- offsets, offset < size, into: %{}, do: {offset, {:matched, offset}}
  end

  @spec classify_within(binary(), binary(), MapSet.t(non_neg_integer()), non_neg_integer()) ::
          {:ok, %{non_neg_integer() => classification()}} | :over_budget
  defp classify_within(source, destination, offsets, limit) do
    size = byte_size(source)
    dest_size = byte_size(destination)
    matrix = {source, destination, size, dest_size, limit}
    empty = {0, {}, 1}
    {bottom, queried} = forward(matrix, offsets, 0, empty, %{})
    best = cost(bottom, dest_size, limit + 1)

    if best <= limit,
      do: {:ok, backward(matrix, queried, size, empty, best, %{})},
      else: :over_budget
  end

  @spec forward(matrix(), MapSet.t(non_neg_integer()), non_neg_integer(), row(), rows()) ::
          {row(), rows()}
  defp forward({_source, _destination, size, _, _} = matrix, offsets, i, previous, retained) do
    current = build_row(matrix, i, previous, 1)

    retained =
      if i < size and MapSet.member?(offsets, i),
        do: Map.put(retained, i, current),
        else: retained

    if i == size,
      do: {current, retained},
      else: forward(matrix, offsets, i + 1, current, retained)
  end

  @spec backward(matrix(), rows(), integer(), row(), non_neg_integer(), %{
          non_neg_integer() => classification()
        }) :: %{non_neg_integer() => classification()}
  defp backward(_matrix, queried, _i, _following, _best, result) when map_size(queried) == 0,
    do: result

  defp backward(matrix, queried, i, following, best, result) do
    {prefix, queried} = Map.pop(queried, i)

    result =
      if prefix,
        do: Map.put(result, i, classify_edges(matrix, i, prefix, following, best)),
        else: result

    backward(matrix, queried, i - 1, build_row(matrix, i, following, -1), best, result)
  end

  @spec classify_edges(matrix(), non_neg_integer(), row(), row(), non_neg_integer()) ::
          classification()
  defp classify_edges({source, destination, _, dest_size, limit}, i, prefix, suffix, best) do
    {first, costs, step} = prefix
    last = first + step * (tuple_size(costs) - 1)
    byte = :binary.at(source, i)
    missing = limit + 1

    first..last//step
    |> Enum.reduce({false, nil, nil}, fn j, {can_delete?, first_match, last_match} ->
      before = cost(prefix, j, missing)
      can_delete? = can_delete? or before + 1 + cost(suffix, j, missing) == best

      if j < dest_size and byte == :binary.at(destination, j) and
           before + cost(suffix, j + 1, missing) == best do
        {can_delete?, min(first_match || j, j), max(last_match || j, j)}
      else
        {can_delete?, first_match, last_match}
      end
    end)
    |> classify_destinations()
  end

  @spec classify_destinations({boolean(), non_neg_integer() | nil, non_neg_integer() | nil}) ::
          classification()
  defp classify_destinations({_, nil, nil}), do: :unmatched
  defp classify_destinations({false, at, at}), do: {:matched, at}
  defp classify_destinations({_, first, last}), do: {:ambiguous, first, last}

  @spec build_row(matrix(), non_neg_integer(), row(), 1 | -1) :: row()
  defp build_row({source, destination, size, dest_size, limit}, i, adjacent, direction) do
    shift = dest_size - size
    first = max(0, i + max(-limit, shift - limit))
    last = min(dest_size, i + min(limit, shift + limit))
    missing = limit + 1
    {from, to} = if direction == 1, do: {first, last}, else: {last, first}
    {origin_row, origin_col} = if direction == 1, do: {0, 0}, else: {size, dest_size}
    byte_at = if direction == 1, do: i - 1, else: i
    byte = if i == origin_row, do: nil, else: :binary.at(source, byte_at)

    {costs, _last} =
      Enum.reduce(from..to//direction, {[], missing}, fn j, {values, prev} ->
        prev_j = j - direction
        other_byte = if direction == 1, do: j - 1, else: j

        value =
          cond do
            i == origin_row ->
              abs(j - origin_col)

            j == origin_col ->
              abs(i - origin_row)

            byte == :binary.at(destination, other_byte) ->
              min(cost(adjacent, prev_j, missing), min(prev + 1, cost(adjacent, j, missing) + 1))

            true ->
              min(prev + 1, cost(adjacent, j, missing) + 1)
          end

        value = min(value, missing)
        {[value | values], value}
      end)

    {to, List.to_tuple(costs), -direction}
  end

  @spec cost(row(), integer(), pos_integer()) :: non_neg_integer()
  defp cost({first, costs, step}, column, missing) do
    index = (column - first) * step
    if index >= 0 and index < tuple_size(costs), do: elem(costs, index), else: missing
  end
end
