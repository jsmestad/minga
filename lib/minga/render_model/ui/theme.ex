defmodule Minga.RenderModel.UI.Theme do
  @moduledoc false

  @type color_slot :: {slot_id :: non_neg_integer(), rgb :: non_neg_integer()}

  @type t :: %__MODULE__{
          name: atom(),
          color_slots: [color_slot()]
        }

  @enforce_keys [:name, :color_slots]
  defstruct [:name, :color_slots]
end
