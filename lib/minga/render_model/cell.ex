defmodule Minga.RenderModel.Cell do
  @moduledoc """
  Cell-grid draw primitive used by frontend adapters.

  This is the shared visible model shape for terminal-style output. It is deliberately smaller than `MingaEditor.DisplayList`: it carries only absolute screen coordinates, text, and a resolved `Minga.Core.Face`. The TUI adapter can turn these cells into protocol commands without treating `DisplayList.Frame` as the pipeline-level render product.
  """

  alias Minga.Core.Face

  @enforce_keys [:row, :col, :text, :face]
  defstruct [:row, :col, :text, :face]

  @type t :: %__MODULE__{
          row: non_neg_integer(),
          col: non_neg_integer(),
          text: String.t(),
          face: Face.t()
        }

  @doc "Creates an absolute cell-grid draw primitive."
  @spec new(non_neg_integer(), non_neg_integer(), String.t(), Face.t()) :: t()
  def new(row, col, text, %Face{} = face)
      when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 and is_binary(text) do
    %__MODULE__{row: row, col: col, text: text, face: face}
  end
end
