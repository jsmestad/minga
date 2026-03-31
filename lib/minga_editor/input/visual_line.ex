defmodule MingaEditor.Input.VisualLine do
  @moduledoc """
  A single visual line produced by word wrapping.

  When a logical line is wider than the viewport, the wrap module splits it
  into multiple visual lines. Each carries the text fragment and its column
  offset within the original logical line. Used by the rendering pipeline
  and cursor math to map between logical and visual coordinates.
  """

  @typedoc "A visual line from word wrapping."
  @type t :: %__MODULE__{
          text: String.t(),
          col_offset: non_neg_integer()
        }

  @enforce_keys [:text]
  defstruct text: "",
            col_offset: 0
end
