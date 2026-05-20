defmodule MingaEditor.Mouse.Target.Buffer do
  @moduledoc "A buffer-content mouse hit target resolved from screen coordinates."

  alias MingaEditor.Viewport
  alias MingaEditor.Window

  @type position :: {line :: non_neg_integer(), col :: non_neg_integer()}
  @type t :: %__MODULE__{
          window_id: Window.id(),
          buffer: pid(),
          line: non_neg_integer(),
          col: non_neg_integer(),
          local_row: non_neg_integer(),
          local_col: non_neg_integer(),
          viewport: Viewport.t()
        }

  @enforce_keys [:window_id, :buffer, :line, :col, :local_row, :local_col, :viewport]
  defstruct [:window_id, :buffer, :line, :col, :local_row, :local_col, :viewport]

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @spec position(t()) :: position()
  def position(%__MODULE__{line: line, col: col}), do: {line, col}
end
