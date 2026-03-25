defmodule Minga.Buffer.Decorations.HighlightRange do
  @moduledoc """
  A highlight range decoration: custom visual styling on an arbitrary
  buffer span without modifying the buffer text.

  Composes with tree-sitter syntax highlighting. A range that sets `bg`
  but not `fg` preserves the syntax foreground color. Multiple ranges
  can overlap on the same character; higher-priority ranges win
  per-property.
  """

  alias Minga.Buffer.IntervalTree
  alias Minga.UI.Face

  @enforce_keys [:id, :start, :end_, :style]
  defstruct id: nil,
            start: {0, 0},
            end_: {0, 0},
            style: %Face{name: "_"},
            priority: 0,
            group: nil

  @type t :: %__MODULE__{
          id: reference(),
          start: IntervalTree.position(),
          end_: IntervalTree.position(),
          style: Face.t(),
          priority: integer(),
          group: atom() | nil
        }
end
