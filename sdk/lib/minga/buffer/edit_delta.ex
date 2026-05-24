defmodule Minga.Buffer.EditDelta do
  @moduledoc """
  Describes a single edit applied to a buffer.

  Extensions receive this in `BufferChangedEvent.delta` when tracking
  agent edit positions. The `new_end_position` field gives the cursor
  position after the edit.

  This is a compile-time stub.
  """

  @enforce_keys [
    :start_byte,
    :old_end_byte,
    :new_end_byte,
    :start_position,
    :old_end_position,
    :new_end_position,
    :inserted_text
  ]
  defstruct [
    :start_byte,
    :old_end_byte,
    :new_end_byte,
    :start_position,
    :old_end_position,
    :new_end_position,
    :inserted_text
  ]

  @type t :: %__MODULE__{
          start_byte: non_neg_integer(),
          old_end_byte: non_neg_integer(),
          new_end_byte: non_neg_integer(),
          start_position: {non_neg_integer(), non_neg_integer()},
          old_end_position: {non_neg_integer(), non_neg_integer()},
          new_end_position: {non_neg_integer(), non_neg_integer()},
          inserted_text: String.t()
        }
end
