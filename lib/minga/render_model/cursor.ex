defmodule Minga.RenderModel.Cursor do
  @moduledoc """
  Cursor state for one rendered frame.

  The editor owns cursor semantics. The render model carries the resolved cursor position and shape so frontend adapters can encode or draw it without reaching back into editor state.
  """

  @type shape :: :block | :beam | :underline

  @enforce_keys [:row, :col, :shape]
  defstruct row: 0,
            col: 0,
            shape: :block

  @type t :: %__MODULE__{
          row: non_neg_integer(),
          col: non_neg_integer(),
          shape: shape()
        }

  @doc "Creates a cursor model."
  @spec new(non_neg_integer(), non_neg_integer(), shape()) :: t()
  def new(row, col, shape)
      when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 and
             shape in [:block, :beam, :underline] do
    %__MODULE__{row: row, col: col, shape: shape}
  end
end
