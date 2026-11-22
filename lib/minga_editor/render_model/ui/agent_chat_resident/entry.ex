defmodule MingaEditor.RenderModel.UI.AgentChatResident.Entry do
  @moduledoc """
  One derived resident transcript entry.

  `item` is the Editor display item the entry was derived from, retained so decoration changes and renderer recovery re-derive from renderer-local data. Footer enrichments have no display item. `message` is the semantic message the adapter encodes and `weight` is its exact resident wire size. `fallback?` marks an entry whose own body exceeded a codec limit and was replaced by a bounded notice keyed by the same message ID.
  """

  alias Minga.RenderModel.UI.AgentChat
  alias MingaEditor.Agent.UIState.TranscriptProjection.Index

  @enforce_keys [:item, :message, :weight]
  defstruct [:item, :message, :weight, fallback?: false]

  @type t :: %__MODULE__{
          item: Index.item() | nil,
          message: AgentChat.message(),
          weight: pos_integer(),
          fallback?: boolean()
        }

  @spec new(Index.item() | nil, AgentChat.message(), pos_integer()) :: t()
  def new(item, message, weight) when is_integer(weight) and weight > 0,
    do: %__MODULE__{item: item, message: message, weight: weight}

  @doc "Builds an entry whose original body could not be encoded and shows a bounded notice instead."
  @spec fallback(Index.item() | nil, AgentChat.message(), pos_integer()) :: t()
  def fallback(item, message, weight) when is_integer(weight) and weight > 0,
    do: %__MODULE__{item: item, message: message, weight: weight, fallback?: true}
end
