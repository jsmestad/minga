defmodule MingaEditor.Frontend.Protocol.GUI.BoardCardPayload do
  @moduledoc "Typed semantic payload for one GUI Board card."

  @type status :: :idle | :working | :iterating | :needs_you | :done | :errored
  @type kind :: :you | :agent | atom()

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
          status: status() | atom(),
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
