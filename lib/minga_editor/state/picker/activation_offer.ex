defmodule MingaEditor.State.Picker.ActivationOffer do
  @moduledoc """
  Owns the bounded, opaque identities offered by the current picker snapshot.

  Native frontends return the generation and activation id exactly as rendered.
  The editor resolves that pair back to the item captured here.
  """

  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item

  @max_items 100
  @max_u32 4_294_967_295

  @type generation :: non_neg_integer()
  @type activation_id :: pos_integer()
  @type item_entry :: {activation_id(), non_neg_integer(), Item.t()}

  @type t :: %__MODULE__{
          generation: generation(),
          items: [item_entry()],
          next_activation_id: activation_id()
        }

  @enforce_keys [:generation]
  defstruct generation: 1, items: [], next_activation_id: 1

  @doc "Reconciles a picker offer while preserving opaque ids for retained semantic items."
  @spec refresh(t(), Picker.t() | nil, generation()) :: t()
  def refresh(%__MODULE__{generation: generation} = offer, picker, generation) do
    {items, next_id} = build_item_entries(picker, offer.items, offer.next_activation_id)
    %{offer | items: items, next_activation_id: next_id}
  end

  def refresh(%__MODULE__{}, picker, generation) do
    {items, next_id} = build_item_entries(picker, [], 1)

    %__MODULE__{
      generation: generation,
      items: items,
      next_activation_id: next_id
    }
  end

  @doc "Returns the exact bounded item window represented by this offer."
  @spec offered_items(t()) :: [item_entry()]
  def offered_items(%__MODULE__{items: items}), do: items

  @doc "Resolves an item only when both opaque identity components match this offer."
  @spec resolve_item(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer(), Item.t()} | :error
  def resolve_item(%__MODULE__{generation: generation, items: items}, generation, activation_id) do
    case List.keyfind(items, activation_id, 0) do
      {^activation_id, index, item} -> {:ok, index, item}
      nil -> :error
    end
  end

  def resolve_item(%__MODULE__{}, _generation, _activation_id), do: :error

  @spec build_item_entries(Picker.t() | nil, [item_entry()], activation_id()) ::
          {[item_entry()], activation_id()}
  defp build_item_entries(nil, _previous, next_id), do: {[], next_id}

  defp build_item_entries(%Picker{} = picker, previous, next_id) do
    prior_ids =
      Map.new(previous, fn {activation_id, _index, item} -> {item.id, activation_id} end)

    {items, start_index} = offered_window(picker)

    items
    |> Enum.with_index(start_index)
    |> Enum.map_reduce(next_id, fn {item, index}, candidate_id ->
      case Map.fetch(prior_ids, item.id) do
        {:ok, activation_id} -> {{activation_id, index, item}, candidate_id}
        :error -> {{candidate_id, index, item}, advance(candidate_id)}
      end
    end)
  end

  @spec offered_window(Picker.t()) :: {[Item.t()], non_neg_integer()}
  defp offered_window(%Picker{results: :all, filtered: filtered, selected: selected}) do
    start_index = selected - rem(selected, @max_items)
    {Enum.slice(filtered, start_index, @max_items), start_index}
  end

  defp offered_window(%Picker{filtered: filtered}), do: {Enum.take(filtered, @max_items), 0}

  @spec advance(activation_id()) :: activation_id()
  defp advance(@max_u32), do: 1
  defp advance(id), do: id + 1
end
