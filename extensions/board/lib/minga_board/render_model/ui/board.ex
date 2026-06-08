defmodule MingaBoard.RenderModel.UI.Board do
  @moduledoc """
  Extension-owned semantic board model for the agent card grid.

  This model intentionally lives under `MingaBoard` instead of the shared `Minga.RenderModel.UI` namespace. Board can keep its experiment-specific data shape without making every frontend treat it as required core semantic UI.
  """

  alias __MODULE__.Card

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
          cards: [Card.t()]
        }

  @doc "Builds the hidden board model used to dismiss native board chrome."
  @spec hidden() :: t()
  def hidden, do: %__MODULE__{visible?: false, cards: []}

  @doc "Appends cards while preserving the board's existing state."
  @spec append_cards(t(), [Card.t()]) :: t()
  def append_cards(%__MODULE__{} = board, cards) when is_list(cards) do
    %{board | cards: board.cards ++ cards}
  end

  @doc "Returns the card currently zoomed in, if any."
  @spec zoomed_card(t()) :: Card.t() | nil
  def zoomed_card(%__MODULE__{zoomed_card_id: nil}), do: nil

  def zoomed_card(%__MODULE__{zoomed_card_id: id, cards: cards}) do
    Enum.find(cards, &(&1.id == id))
  end

  defmodule Card do
    @moduledoc """
    One Board card: an agent or user workspace with status, task, model, recent files, and activity sparkline.
    """

    @type status :: :idle | :working | :iterating | :needs_you | :done | :errored
    @type kind :: :you | :agent

    @enforce_keys [:id, :status, :kind, :task, :display_task, :created_at]
    defstruct [
      :id,
      :status,
      :kind,
      :task,
      :display_task,
      :created_at,
      model: nil,
      recent_files: [],
      sparkline: []
    ]

    @type t :: %__MODULE__{
            id: pos_integer(),
            status: status(),
            kind: kind(),
            task: String.t(),
            display_task: String.t(),
            model: String.t() | nil,
            created_at: DateTime.t(),
            recent_files: [String.t()],
            sparkline: [float()]
          }

    @doc "Returns true when this card is the user's own workspace card."
    @spec you_card?(t()) :: boolean()
    def you_card?(%__MODULE__{kind: :you}), do: true
    def you_card?(_card), do: false
  end
end
