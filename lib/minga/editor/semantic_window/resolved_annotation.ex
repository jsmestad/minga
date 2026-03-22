defmodule Minga.Editor.SemanticWindow.ResolvedAnnotation do
  @moduledoc """
  A line annotation resolved to display coordinates for GUI rendering.

  Built by the SemanticWindow.Builder from buffer decorations, this struct
  contains the display row and the annotation's visual properties. Consumed
  by the GUI protocol encoder (0x80 wire format) and the TUI render pipeline.
  """

  alias Minga.Buffer.Decorations.LineAnnotation

  @enforce_keys [:row, :kind, :fg, :bg, :text]
  defstruct [:row, :kind, :fg, :bg, :text]

  @type t :: %__MODULE__{
          row: non_neg_integer(),
          kind: LineAnnotation.kind(),
          fg: non_neg_integer(),
          bg: non_neg_integer(),
          text: String.t()
        }
end
