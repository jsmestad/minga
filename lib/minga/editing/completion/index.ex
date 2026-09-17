defmodule Minga.Editing.Completion.Index do
  @moduledoc "Provider-aware normalized completion index with bounded deterministic snapshots."

  alias Minga.Editing.Completion.Item
  alias Minga.Editing.Completion.Ranker

  @default_limit 200

  defmodule Provider do
    @moduledoc false
    @enforce_keys [:id, :source, :items, :incomplete?]
    defstruct [:id, :source, :items, :incomplete?]

    @type t :: %__MODULE__{
            id: Item.provider_id(),
            source: String.t(),
            items: %{Item.id() => Item.t()},
            incomplete?: boolean()
          }
  end

  defmodule Snapshot do
    @moduledoc "Bounded semantic result set for one query."
    @enforce_keys [:items, :total_count, :matched_count, :work_count, :incomplete?]
    defstruct [:items, :total_count, :matched_count, :work_count, :incomplete?]

    @type t :: %__MODULE__{
            items: [Item.t()],
            total_count: non_neg_integer(),
            matched_count: non_neg_integer(),
            work_count: non_neg_integer(),
            incomplete?: boolean()
          }
  end

  defstruct providers: %{}, total_count: 0

  @type t :: %__MODULE__{
          providers: %{Item.provider_id() => Provider.t()},
          total_count: non_neg_integer()
        }

  @typep ranked_entry :: {tuple(), String.t(), Ranker.score(), Item.t()}
  @typep snapshot_acc :: {:gb_sets.set(ranked_entry()), non_neg_integer(), non_neg_integer()}

  @doc "Returns an empty completion index."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "Builds an index from candidates grouped by their provider identity."
  @spec from_items([Item.t()]) :: t()
  def from_items(items) do
    items
    |> Enum.group_by(& &1.provider_id)
    |> Enum.reduce(empty(), fn {provider_id, provider_items}, index ->
      put_provider(index, provider_id, provider_items, false)
    end)
  end

  @doc "Replaces one provider batch after collapsing true provider-local duplicates."
  @spec put_provider(t(), Item.provider_id(), [Item.t()], boolean()) :: t()
  def put_provider(%__MODULE__{} = index, provider_id, items, incomplete?) when is_list(items) do
    entries = Map.new(items, &{Item.semantic_key(&1), &1})
    source = items |> List.first() |> source_or_provider(provider_id)

    provider = %Provider{
      id: provider_id,
      source: source,
      items: entries,
      incomplete?: incomplete?
    }

    providers = Map.put(index.providers, provider_id, provider)
    %{index | providers: providers, total_count: count_items(providers)}
  end

  @doc "Returns a bounded deterministic semantic snapshot without building a full match list."
  @spec snapshot(t(), String.t(), pos_integer()) :: Snapshot.t()
  def snapshot(%__MODULE__{} = index, query, limit \\ @default_limit)
      when is_binary(query) and is_integer(limit) and limit > 0,
      do: snapshot(index, query, limit, nil)

  @doc "Returns a bounded snapshot that retains a matching selected identity across reranking."
  @spec snapshot(t(), String.t(), pos_integer(), Item.id() | nil) :: Snapshot.t()
  def snapshot(%__MODULE__{} = index, query, limit, selected_item_id)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    normalized_query = String.downcase(query)

    {top, matched_count, work_count} =
      Enum.reduce(index.providers, {:gb_sets.empty(), 0, 0}, fn {_provider_id, provider}, acc ->
        reduce_provider(provider, acc, normalized_query, limit)
      end)

    retained_top = retain_selected(top, index, selected_item_id, normalized_query, limit)

    retained =
      Enum.map(:gb_sets.to_list(retained_top), fn {_rank, _wire_id, score, item} ->
        ranges = Ranker.match_ranges(normalized_query, item.search.filter_text, score)
        Item.with_normalized_match_ranges(item, ranges)
      end)

    %Snapshot{
      items: retained,
      total_count: index.total_count,
      matched_count: matched_count,
      work_count: work_count,
      incomplete?: Enum.any?(index.providers, fn {_id, provider} -> provider.incomplete? end)
    }
  end

  @doc "Finds one exact stable item identity."
  @spec find_item(t(), Item.id() | nil) :: Item.t() | nil
  def find_item(%__MODULE__{}, nil), do: nil

  def find_item(%__MODULE__{} = index, {provider_id, _semantic} = item_id) do
    with %Provider{} = provider <- Map.get(index.providers, provider_id) do
      Map.get(provider.items, item_id)
    end
  end

  @doc "Updates one exact stable item identity while preserving index ownership."
  @spec update_item(t(), Item.id(), (Item.t() -> Item.t())) :: t()
  def update_item(%__MODULE__{} = index, {provider_id, _semantic} = item_id, update)
      when is_function(update, 1) do
    case Map.get(index.providers, provider_id) do
      %Provider{} = provider ->
        items =
          if Map.has_key?(provider.items, item_id),
            do: Map.update!(provider.items, item_id, update),
            else: provider.items

        providers = Map.put(index.providers, provider_id, %{provider | items: items})
        %{index | providers: providers}

      nil ->
        index
    end
  end

  @doc "Returns all indexed items in deterministic order for compatibility callers."
  @spec all_items(t()) :: [Item.t()]
  def all_items(%__MODULE__{} = index) do
    index.providers
    |> Enum.flat_map(fn {_id, provider} -> Map.values(provider.items) end)
    |> Enum.sort_by(&{&1.search.sort_text, &1.search.label, &1.source, Item.wire_id(&1)})
  end

  @spec reduce_provider(Provider.t(), snapshot_acc(), String.t(), pos_integer()) :: snapshot_acc()
  defp reduce_provider(provider, acc, normalized_query, limit) do
    Enum.reduce(provider.items, acc, fn {_key, item}, current ->
      score_item(item, current, normalized_query, limit)
    end)
  end

  @spec score_item(Item.t(), snapshot_acc(), String.t(), pos_integer()) :: snapshot_acc()
  defp score_item(item, {set, matched, work}, normalized_query, limit) do
    case Ranker.score(normalized_query, item.search.filter_text) do
      {:ok, score} ->
        entry = {Ranker.rank_key(item, score), Item.wire_id(item), score, item}
        {bounded_insert(set, entry, limit), matched + 1, work + 1}

      :nomatch ->
        {set, matched, work + 1}
    end
  end

  @spec retain_selected(
          :gb_sets.set(ranked_entry()),
          t(),
          Item.id() | nil,
          String.t(),
          pos_integer()
        ) :: :gb_sets.set(ranked_entry())
  defp retain_selected(set, _index, nil, _normalized_query, _limit), do: set

  defp retain_selected(set, index, selected_item_id, normalized_query, limit) do
    with %Item{} = item <- find_item(index, selected_item_id),
         {:ok, score} <- Ranker.score(normalized_query, item.search.filter_text) do
      entry = {Ranker.rank_key(item, score), Item.wire_id(item), score, item}
      force_bounded_insert(set, entry, limit)
    else
      _ -> set
    end
  end

  @spec force_bounded_insert(:gb_sets.set(ranked_entry()), ranked_entry(), pos_integer()) ::
          :gb_sets.set(ranked_entry())
  defp force_bounded_insert(set, entry, limit) do
    next = :gb_sets.add(entry, set)

    if :gb_sets.size(next) > limit do
      without_selected = :gb_sets.delete_any(entry, next)
      trimmed = :gb_sets.delete(:gb_sets.largest(without_selected), without_selected)
      :gb_sets.add(entry, trimmed)
    else
      next
    end
  end

  @spec bounded_insert(:gb_sets.set(ranked_entry()), ranked_entry(), pos_integer()) ::
          :gb_sets.set(ranked_entry())
  defp bounded_insert(set, entry, limit) do
    next = :gb_sets.add(entry, set)

    if :gb_sets.size(next) > limit do
      :gb_sets.delete(:gb_sets.largest(next), next)
    else
      next
    end
  end

  @spec source_or_provider(Item.t() | nil, Item.provider_id()) :: String.t()
  defp source_or_provider(%Item{source: source}, _provider_id), do: source
  defp source_or_provider(nil, provider_id), do: inspect(provider_id)

  @spec count_items(%{Item.provider_id() => Provider.t()}) :: non_neg_integer()
  defp count_items(providers),
    do:
      Enum.reduce(providers, 0, fn {_id, provider}, count -> count + map_size(provider.items) end)
end
