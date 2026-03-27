defmodule Minga.Shell.Board.State do
  @moduledoc """
  Presentation state for The Board shell.

  Holds the card grid, focus tracking, zoom state, and an ID counter.
  All operations are pure functions on this struct; the Editor GenServer
  calls them from Shell.Board callbacks.

  ## Zoom lifecycle

  The Board has two modes: grid view (showing all cards) and zoomed view
  (showing one card's workspace). The `zoomed_into` field tracks which
  card is currently expanded. When `nil`, the grid is showing.

  Zooming in: the caller snapshots the current workspace onto the card,
  then restores the target card's workspace as the live workspace.

  Zooming out: the caller snapshots the live workspace back onto the card,
  then either clears the live workspace or restores a minimal Board workspace.
  """

  alias Minga.Shell.Board.Card

  @type t :: %__MODULE__{
          cards: %{Card.id() => Card.t()},
          card_order: [Card.id()],
          focused_card: Card.id() | nil,
          zoomed_into: Card.id() | nil,
          filter_mode: boolean(),
          filter_text: String.t(),
          next_id: pos_integer(),
          # Compatibility fields: EditorState accessors read these from
          # shell_state during render/command dispatch. Board doesn't use
          # them, but they need to exist to prevent KeyError crashes when
          # transitioning between shells or when the render pipeline runs
          # before the Board-specific renderer takes over.
          whichkey: Minga.Editor.State.WhichKey.t(),
          picker_ui: Minga.Editor.State.Picker.t(),
          prompt_ui: Minga.Editor.State.Prompt.t(),
          status_msg: String.t() | nil,
          dashboard: nil,
          nav_flash: nil,
          hover_popup: nil,
          tab_bar: nil,
          agent: Minga.Editor.State.Agent.t(),
          bottom_panel: Minga.Editor.BottomPanel.t(),
          git_status_panel: nil,
          modeline_click_regions: [],
          tab_bar_click_regions: [],
          warning_popup_timer: nil,
          signature_help: nil,
          tool_declined: MapSet.t(),
          tool_prompt_queue: [atom()],
          suppress_tool_prompts: boolean()
        }

  defstruct cards: %{},
            card_order: [],
            focused_card: nil,
            zoomed_into: nil,
            filter_mode: false,
            filter_text: "",
            next_id: 1,
            # Compatibility fields (see type doc above)
            whichkey: %Minga.Editor.State.WhichKey{},
            picker_ui: %Minga.Editor.State.Picker{},
            prompt_ui: %Minga.Editor.State.Prompt{},
            status_msg: nil,
            dashboard: nil,
            nav_flash: nil,
            hover_popup: nil,
            tab_bar: nil,
            agent: %Minga.Editor.State.Agent{},
            bottom_panel: %Minga.Editor.BottomPanel{},
            git_status_panel: nil,
            modeline_click_regions: [],
            tab_bar_click_regions: [],
            warning_popup_timer: nil,
            signature_help: nil,
            tool_declined: MapSet.new(),
            tool_prompt_queue: [],
            suppress_tool_prompts: false

  @doc "Creates a fresh Board state with an empty card grid."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new card and adds it to the board.

  Returns `{updated_state, card}`. The card gets a unique monotonic ID.
  If no card was focused, the new card becomes focused.
  """
  @spec create_card(t(), keyword()) :: {t(), Card.t()}
  def create_card(%__MODULE__{} = state, attrs \\ []) do
    card = Card.new(state.next_id, attrs)

    focused =
      if state.focused_card == nil do
        card.id
      else
        state.focused_card
      end

    state = %{
      state
      | cards: Map.put(state.cards, card.id, card),
        card_order: state.card_order ++ [card.id],
        next_id: state.next_id + 1,
        focused_card: focused
    }

    {state, card}
  end

  @doc """
  Removes a card from the board.

  If the removed card was focused, focus moves to the next card in ID
  order, or `nil` if the board is now empty. If the removed card was
  zoomed into, zoom is cleared.
  """
  @spec remove_card(t(), Card.id()) :: t()
  def remove_card(%__MODULE__{} = state, card_id) do
    cards = Map.delete(state.cards, card_id)
    card_order = Enum.reject(state.card_order, &(&1 == card_id))

    focused =
      if state.focused_card == card_id do
        # Pick the next card in display order, or nil if empty
        List.first(card_order)
      else
        state.focused_card
      end

    zoomed =
      if state.zoomed_into == card_id do
        nil
      else
        state.zoomed_into
      end

    %{state | cards: cards, card_order: card_order, focused_card: focused, zoomed_into: zoomed}
  end

  @doc "Updates a card by applying a function to it."
  @spec update_card(t(), Card.id(), (Card.t() -> Card.t())) :: t()
  def update_card(%__MODULE__{} = state, card_id, fun) when is_function(fun, 1) do
    case Map.get(state.cards, card_id) do
      nil -> state
      card -> %{state | cards: Map.put(state.cards, card_id, fun.(card))}
    end
  end

  @doc "Returns the currently focused card, or nil."
  @spec focused(t()) :: Card.t() | nil
  def focused(%__MODULE__{focused_card: nil}), do: nil
  def focused(%__MODULE__{focused_card: id, cards: cards}), do: Map.get(cards, id)

  @doc "Returns the currently zoomed-into card, or nil."
  @spec zoomed(t()) :: Card.t() | nil
  def zoomed(%__MODULE__{zoomed_into: nil}), do: nil
  def zoomed(%__MODULE__{zoomed_into: id, cards: cards}), do: Map.get(cards, id)

  @doc "Returns true when the grid is showing (not zoomed into a card)."
  @spec grid_view?(t()) :: boolean()
  def grid_view?(%__MODULE__{zoomed_into: nil}), do: true
  def grid_view?(%__MODULE__{}), do: false

  @doc "Sets focus to the given card ID."
  @spec focus_card(t(), Card.id()) :: t()
  def focus_card(%__MODULE__{} = state, card_id) do
    if Map.has_key?(state.cards, card_id) do
      %{state | focused_card: card_id}
    else
      state
    end
  end

  @doc """
  Zooms into a card, storing the given workspace snapshot on it.

  The caller is responsible for restoring the card's workspace as the
  live `state.workspace` on EditorState.
  """
  @spec zoom_into(t(), Card.id(), map()) :: t()
  def zoom_into(%__MODULE__{} = state, card_id, workspace_snapshot) do
    state = update_card(state, card_id, &Card.store_workspace(&1, workspace_snapshot))
    %{state | zoomed_into: card_id, focused_card: card_id}
  end

  @doc """
  Zooms out of the current card, returning {state, workspace_snapshot}.

  The returned snapshot is the workspace that was stored on the card
  when it was zoomed into. Returns `{state, nil}` if not zoomed.
  """
  @spec zoom_out(t()) :: {t(), map() | nil}
  def zoom_out(%__MODULE__{zoomed_into: nil} = state), do: {state, nil}

  def zoom_out(%__MODULE__{zoomed_into: card_id} = state) do
    card = Map.get(state.cards, card_id)
    snapshot = if card, do: card.workspace, else: nil

    state =
      if card do
        update_card(%{state | zoomed_into: nil}, card_id, &Card.clear_workspace/1)
      else
        %{state | zoomed_into: nil}
      end

    {state, snapshot}
  end

  @doc "Returns all cards in display order (respecting user reordering)."
  @spec sorted_cards(t()) :: [Card.t()]
  def sorted_cards(%__MODULE__{cards: cards, card_order: order}) do
    # Return cards in the order specified by card_order, filtering out any stale IDs
    Enum.map(order, &Map.get(cards, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc "Returns cards filtered by the current filter text, in display order."
  @spec filtered_cards(t()) :: [Card.t()]
  def filtered_cards(%__MODULE__{filter_mode: false} = state), do: sorted_cards(state)

  def filtered_cards(%__MODULE__{filter_text: ""} = state), do: sorted_cards(state)

  def filtered_cards(%__MODULE__{filter_text: filter} = state) do
    needle = String.downcase(filter)

    state
    |> sorted_cards()
    |> Enum.filter(fn card ->
      String.downcase(card.task) |> String.contains?(needle) or
        (card.model && String.downcase(card.model) |> String.contains?(needle))
    end)
  end

  @doc "Returns the number of cards on the board."
  @spec card_count(t()) :: non_neg_integer()
  def card_count(%__MODULE__{cards: cards}), do: map_size(cards)

  @doc """
  Reorders a card to a new position in the display order.

  Moves the card with the given ID to the specified index in the card_order list.
  If the card or index is invalid, returns the state unchanged.
  """
  @spec reorder_card(t(), Card.id(), non_neg_integer()) :: t()
  def reorder_card(%__MODULE__{} = state, card_id, new_index) do
    # Check if the card exists
    if Map.has_key?(state.cards, card_id) do
      # Remove the card from its current position
      order_without_card = Enum.reject(state.card_order, &(&1 == card_id))

      # Clamp the new index to valid range
      max_index = length(order_without_card)
      clamped_index = min(new_index, max_index)

      # Insert the card at the new position
      new_order = List.insert_at(order_without_card, clamped_index, card_id)

      %{state | card_order: new_order}
    else
      state
    end
  end

  @doc """
  Moves focus in the given direction within the grid.

  Direction is `:up`, `:down`, `:left`, or `:right`. The grid is
  computed from sorted card IDs laid out in rows of `cols` columns.
  """
  @spec move_focus(t(), :up | :down | :left | :right, pos_integer()) :: t()
  def move_focus(%__MODULE__{focused_card: nil} = state, _dir, _cols), do: state

  def move_focus(%__MODULE__{} = state, direction, cols) when cols > 0 do
    cards = sorted_cards(state)
    ids = Enum.map(cards, & &1.id)
    count = length(ids)

    case Enum.find_index(ids, &(&1 == state.focused_card)) do
      nil ->
        state

      idx ->
        new_idx =
          case direction do
            :right -> min(idx + 1, count - 1)
            :left -> max(idx - 1, 0)
            :down -> min(idx + cols, count - 1)
            :up -> max(idx - cols, 0)
          end

        %{state | focused_card: Enum.at(ids, new_idx)}
    end
  end
end
