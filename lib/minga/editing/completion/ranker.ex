defmodule Minga.Editing.Completion.Ranker do
  @moduledoc "Pure exact, prefix, and fuzzy completion matching and ranking."

  alias Minga.Editing.Completion.Item

  @typedoc "Match category ordered from strongest to weakest."
  @type match_kind :: :exact | :prefix | :fuzzy

  @typedoc "Cheap score used while maintaining a bounded top-K set."
  @type score :: {match_kind(), non_neg_integer()}

  @doc "Scores a normalized candidate without retaining match ranges."
  @spec score(String.t(), String.t()) :: {:ok, score()} | :nomatch
  def score("", _candidate), do: {:ok, {:prefix, 0}}
  def score(query, query), do: {:ok, {:exact, 0}}

  def score(query, candidate) do
    if String.starts_with?(candidate, query) do
      {:ok, {:prefix, 0}}
    else
      fuzzy_score(String.to_charlist(query), String.to_charlist(candidate), 0, nil, nil, 0)
    end
  end

  @doc "Returns compact contiguous ranges for an already-matched candidate."
  @spec match_ranges(String.t(), String.t(), score()) :: [Item.match_range()]
  def match_ranges("", _candidate, _score), do: []

  def match_ranges(query, _candidate, {kind, _score}) when kind in [:exact, :prefix],
    do: [{0, String.length(query)}]

  def match_ranges(query, candidate, {:fuzzy, _score}) do
    query
    |> String.to_charlist()
    |> fuzzy_positions(String.to_charlist(candidate), 0, [])
    |> positions_to_ranges()
  end

  @doc "Returns a deterministic sortable key for one scored item."
  @spec rank_key(Item.t(), score()) :: tuple()
  def rank_key(%Item{} = item, {kind, score}) do
    {preselect_rank(item.preselect), kind_rank(kind), score, item.normalized_sort_text,
     item.normalized_label, item.source, Item.wire_id(item)}
  end

  @spec preselect_rank(boolean()) :: 0 | 1
  defp preselect_rank(true), do: 0
  defp preselect_rank(false), do: 1

  @spec kind_rank(match_kind()) :: 0 | 1 | 2
  defp kind_rank(:exact), do: 0
  defp kind_rank(:prefix), do: 1
  defp kind_rank(:fuzzy), do: 2

  @spec fuzzy_score(
          [char()],
          [char()],
          non_neg_integer(),
          integer() | nil,
          integer() | nil,
          non_neg_integer()
        ) ::
          {:ok, score()} | :nomatch
  defp fuzzy_score([], _candidate, _index, first, last, gaps) do
    start = first || 0
    span = if is_integer(last), do: last - start + 1, else: 0
    {:ok, {:fuzzy, start * 2 + gaps + span}}
  end

  defp fuzzy_score(_query, [], _index, _first, _last, _gaps), do: :nomatch

  defp fuzzy_score([char | query], [char | candidate], index, first, last, gaps) do
    next_first = first || index
    next_gaps = if is_integer(last), do: gaps + index - last - 1, else: gaps
    fuzzy_score(query, candidate, index + 1, next_first, index, next_gaps)
  end

  defp fuzzy_score(query, [_candidate | rest], index, first, last, gaps),
    do: fuzzy_score(query, rest, index + 1, first, last, gaps)

  @spec fuzzy_positions([char()], [char()], non_neg_integer(), [non_neg_integer()]) ::
          [non_neg_integer()]
  defp fuzzy_positions([], _candidate, _index, positions), do: Enum.reverse(positions)
  defp fuzzy_positions(_query, [], _index, positions), do: Enum.reverse(positions)

  defp fuzzy_positions([char | query], [char | candidate], index, positions),
    do: fuzzy_positions(query, candidate, index + 1, [index | positions])

  defp fuzzy_positions(query, [_candidate | rest], index, positions),
    do: fuzzy_positions(query, rest, index + 1, positions)

  @spec positions_to_ranges([non_neg_integer()]) :: [Item.match_range()]
  defp positions_to_ranges([]), do: []

  defp positions_to_ranges([first | rest]) do
    rest
    |> Enum.reduce([{first, 1}], fn position, [{start, length} | ranges] ->
      if position == start + length,
        do: [{start, length + 1} | ranges],
        else: [{position, 1}, {start, length} | ranges]
    end)
    |> Enum.reverse()
  end
end
