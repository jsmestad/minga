defmodule Minga.Parser.StructuralNavResult do
  @moduledoc """
  Result returned by tree-sitter structural navigation.

  Positions are zero-indexed tree-sitter points. Columns are byte offsets within the line, matching the rest of the parser protocol.
  """

  @enforce_keys [:start_row, :start_col, :end_row, :end_col, :type_name]
  defstruct [:start_row, :start_col, :end_row, :end_col, :type_name]

  @type t :: %__MODULE__{
          start_row: non_neg_integer(),
          start_col: non_neg_integer(),
          end_row: non_neg_integer(),
          end_col: non_neg_integer(),
          type_name: String.t()
        }

  @doc "Builds a structural navigation result."
  @spec new(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: t()
  def new(start_row, start_col, end_row, end_col, type_name)
      when is_integer(start_row) and start_row >= 0 and is_integer(start_col) and start_col >= 0 and
             is_integer(end_row) and end_row >= 0 and is_integer(end_col) and end_col >= 0 and
             is_binary(type_name) do
    %__MODULE__{
      start_row: start_row,
      start_col: start_col,
      end_row: end_row,
      end_col: end_col,
      type_name: type_name
    }
  end

  @doc "Returns the cursor position for the start of the node."
  @spec start_position(t()) :: {non_neg_integer(), non_neg_integer()}
  def start_position(%__MODULE__{start_row: row, start_col: col}), do: {row, col}
end
