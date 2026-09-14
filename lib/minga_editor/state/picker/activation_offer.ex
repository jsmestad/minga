defmodule MingaEditor.State.Picker.ActivationOffer do
  @moduledoc """
  Owns the bounded, opaque identities offered by the current picker snapshot.

  Native frontends return the generation and activation id exactly as rendered.
  The editor resolves that pair back to the item or source action captured here.
  """

  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  @max_items 100
  @max_u32 4_294_967_295

  @type generation :: pos_integer()
  @type activation_id :: pos_integer()
  @type item_entry :: {activation_id(), non_neg_integer(), Item.t()}
  @type action_entry :: {activation_id(), Source.action_entry(), Item.t()}

  @type t :: %__MODULE__{
          generation: generation(),
          items: [item_entry()],
          actions: [action_entry()]
        }

  @enforce_keys [:generation]
  defstruct generation: 1, items: [], actions: []

  @doc "Builds a fresh activation offer for the picker's currently rendered result window."
  @spec new(Picker.t() | nil, MingaEditor.State.Picker.action_menu()) :: t()
  def new(picker, action_menu) do
    %__MODULE__{
      generation: next_generation(),
      items: build_item_entries(picker),
      actions: action_entries(action_menu)
    }
  end

  @doc "Returns the exact bounded item window represented by this offer."
  @spec offered_items(t()) :: [item_entry()]
  def offered_items(%__MODULE__{items: items}), do: items

  @doc "Returns the activation ids for source actions in their rendered order."
  @spec action_activation_ids(t()) :: [activation_id()]
  def action_activation_ids(%__MODULE__{actions: actions}) do
    Enum.map(actions, &elem(&1, 0))
  end

  @doc "Returns the exact bounded action window represented by this offer."
  @spec offered_actions(t()) :: [action_entry()]
  def offered_actions(%__MODULE__{actions: actions}), do: actions

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

  @doc "Resolves a source action only when both opaque identity components match this offer."
  @spec resolve_action(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Source.action_entry(), Item.t()} | :error
  def resolve_action(
        %__MODULE__{generation: generation, actions: actions},
        generation,
        activation_id
      ) do
    case List.keyfind(actions, activation_id, 0) do
      {^activation_id, action, item} -> {:ok, action, item}
      nil -> :error
    end
  end

  def resolve_action(%__MODULE__{}, _generation, _activation_id), do: :error

  @spec build_item_entries(Picker.t() | nil) :: [item_entry()]
  defp build_item_entries(nil), do: []

  defp build_item_entries(%Picker{filtered: filtered}) do
    filtered
    |> Enum.take(@max_items)
    |> Enum.with_index(1)
    |> Enum.map(fn {item, activation_id} -> {activation_id, activation_id - 1, item} end)
  end

  @spec action_entries(MingaEditor.State.Picker.action_menu()) :: [action_entry()]
  defp action_entries(nil), do: []

  defp action_entries({actions, _selected_index, item}) do
    actions
    |> Enum.with_index(1)
    |> Enum.map(fn {action, activation_id} -> {activation_id, action, item} end)
  end

  defp action_entries({_actions, _selected_index}), do: []

  @spec next_generation() :: generation()
  defp next_generation do
    Integer.mod(System.unique_integer([:positive, :monotonic]), @max_u32) + 1
  end
end
