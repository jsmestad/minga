defmodule MingaEditor.Frontend.Protocol.GUI.BoardPayload do
  @moduledoc "Typed semantic payload for GUI Board chrome."

  alias MingaEditor.Frontend.Protocol.GUI.BoardCardPayload

  @enforce_keys [:visible?, :cards]
  defstruct visible?: false,
            focused_card_id: nil,
            zoomed_card_id: nil,
            filter_mode?: false,
            filter_text: "",
            cards: []

  @type t :: %__MODULE__{
          visible?: boolean(),
          focused_card_id: pos_integer() | nil,
          zoomed_card_id: pos_integer() | nil,
          filter_mode?: boolean(),
          filter_text: String.t(),
          cards: [BoardCardPayload.t()]
        }

  @doc "Builds the hidden Board payload used to dismiss native Board chrome."
  @spec hidden() :: t()
  def hidden, do: %__MODULE__{visible?: false, cards: []}

  @doc "Returns the card currently zoomed in, if any."
  @spec zoomed_card(t()) :: BoardCardPayload.t() | nil
  def zoomed_card(%__MODULE__{zoomed_card_id: nil}), do: nil

  def zoomed_card(%__MODULE__{zoomed_card_id: id, cards: cards}) do
    Enum.find(cards, &(&1.id == id))
  end
end
