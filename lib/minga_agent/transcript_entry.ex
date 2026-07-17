defmodule MingaAgent.TranscriptEntry do
  @moduledoc """
  Couples one transcript message to its stable identity.

  A message can change while it is streaming or while tool state is updated, but
  its identity never changes. Keeping both values in this struct makes it
  impossible to reorder content independently from its ID.
  """

  alias MingaAgent.Message

  @enforce_keys [:id, :message]
  defstruct [:id, :message]

  @type t :: %__MODULE__{
          id: pos_integer(),
          message: Message.t()
        }

  @doc "Creates an identified transcript entry."
  @spec new(pos_integer(), Message.t()) :: t()
  def new(id, message) when is_integer(id) and id > 0 do
    %__MODULE__{id: id, message: message}
  end

  @doc "Replaces an entry's content while preserving its stable identity."
  @spec replace(t(), Message.t()) :: t()
  def replace(%__MODULE__{} = entry, message), do: %__MODULE__{entry | message: message}
end
