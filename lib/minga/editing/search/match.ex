defmodule Minga.Editing.Search.Match do
  @moduledoc """
  A search match: a pattern occurrence at a specific buffer position.

  Replaces the raw `{line, col, length}` tuple that previously crossed
  module boundaries between Search, Renderer, ContentHelpers, and
  Agent.UIState.
  """

  @enforce_keys [:line, :col, :length]
  defstruct [:line, :col, :length]

  @type t :: %__MODULE__{
          line: non_neg_integer(),
          col: non_neg_integer(),
          length: non_neg_integer()
        }

  @doc "Creates a match from positional values."
  @spec new(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def new(line, col, length) do
    %__MODULE__{line: line, col: col, length: length}
  end
end
