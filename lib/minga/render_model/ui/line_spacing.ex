defmodule Minga.RenderModel.UI.LineSpacing do
  @moduledoc false

  # GUI line spacing multiplier. The multiplier is at least 1.0; the encoder
  # quantizes it to spacing_x100 on the wire (1.2 -> 120).
  @type t :: %__MODULE__{
          multiplier: number()
        }

  @enforce_keys [:multiplier]
  defstruct multiplier: 1.0
end
