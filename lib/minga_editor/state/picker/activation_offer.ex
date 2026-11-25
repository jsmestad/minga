defmodule MingaEditor.State.Picker.ActivationOffer do
  @moduledoc """
  Owns the bounded, opaque identities offered by the current picker snapshot.

  Native frontends return the generation and activation id exactly as rendered.
  The editor resolves that pair back to the item or source action captured here.

  The offer also names the list it shows. `revision` changes whenever the offered rows change: another row, another order, or another window of a long list. A frontend that moved its highlight ahead of the editor keeps that highlight only while the revision is the one it was made under, because the editor's selection is a position in the list and a changed list puts another row there.
  """

  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  @max_items 100
  @max_u32 4_294_967_295

  @type generation :: non_neg_integer()
  @type activation_id :: pos_integer()
  @type item_entry :: {activation_id(), non_neg_integer(), Item.t()}
  @type action_entry :: {activation_id(), Source.action_entry(), Item.t()}

  @type revision :: non_neg_integer()

  @type t :: %__MODULE__{
          generation: generation(),
          revision: revision(),
          items: [item_entry()],
          actions: [action_entry()],
          next_activation_id: activation_id()
        }

  @enforce_keys [:generation]
  defstruct generation: 1, revision: 0, items: [], actions: [], next_activation_id: 1

  @doc "Reconciles a picker offer while preserving opaque ids for retained semantic items."
  @spec refresh(t(), Picker.t() | nil, MingaEditor.State.Picker.action_menu(), generation()) ::
          t()
  def refresh(%__MODULE__{generation: generation} = offer, picker, action_menu, generation) do
    {items, next_id} = build_item_entries(picker, offer.items, offer.next_activation_id)
    {actions, next_id} = action_entries(action_menu, offer.actions, next_id)

    %{
      offer
      | revision: next_revision(offer, items),
        items: items,
        actions: actions,
        next_activation_id: next_id
    }
  end

  def refresh(%__MODULE__{}, picker, action_menu, generation) do
    {items, next_id} = build_item_entries(picker, [], 1)
    {actions, next_id} = action_entries(action_menu, [], next_id)

    %__MODULE__{
      generation: generation,
      items: items,
      actions: actions,
      next_activation_id: next_id
    }
  end

  @doc "Returns the revision of the offered rows. It changes when the rows, their order or their window change, and never for a selection move or the action menu."
  @spec revision(t()) :: revision()
  def revision(%__MODULE__{revision: revision}), do: revision

  # The rows are the same list when every row keeps its identity and its position.
  # The comparison is made here, by the owner, so no caller can forget to report a change.
  @spec next_revision(t(), [item_entry()]) :: revision()
  defp next_revision(%__MODULE__{revision: revision, items: previous}, items) do
    if same_rows?(previous, items), do: revision, else: rem(revision + 1, @max_u32 + 1)
  end

  @spec same_rows?([item_entry()], [item_entry()]) :: boolean()
  defp same_rows?([], []), do: true

  defp same_rows?([{id, index, _was} | previous], [{id, index, _is} | items]),
    do: same_rows?(previous, items)

  defp same_rows?(_previous, _items), do: false

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

  @spec action_entries(
          MingaEditor.State.Picker.action_menu(),
          [action_entry()],
          activation_id()
        ) :: {[action_entry()], activation_id()}
  defp action_entries(nil, _previous, next_id), do: {[], next_id}

  defp action_entries({actions, _selected_index, item}, previous, next_id) do
    prior_ids =
      Map.new(previous, fn {activation_id, {_name, action_id}, prior_item} ->
        {{prior_item.id, action_id}, activation_id}
      end)

    Enum.map_reduce(actions, next_id, fn {_name, action_id} = action, candidate_id ->
      case Map.fetch(prior_ids, {item.id, action_id}) do
        {:ok, activation_id} -> {{activation_id, action, item}, candidate_id}
        :error -> {{candidate_id, action, item}, advance(candidate_id)}
      end
    end)
  end

  defp action_entries({_actions, _selected_index}, _previous, next_id), do: {[], next_id}

  @spec advance(activation_id()) :: activation_id()
  defp advance(@max_u32), do: 1
  defp advance(id), do: id + 1
end
