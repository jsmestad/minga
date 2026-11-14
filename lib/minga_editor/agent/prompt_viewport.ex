defmodule MingaEditor.Agent.PromptViewport do
  @moduledoc "Physical prompt capacity and source-anchored reading position, scoped to one prompt owner."

  @type position :: {logical_line :: non_neg_integer(), byte :: non_neg_integer()}
  @type anchor :: {logical_line :: non_neg_integer(), continuation :: non_neg_integer()}
  @type marker :: {source_version :: non_neg_integer(), position()}
  @type t :: %__MODULE__{
          fit: {pos_integer(), pos_integer()} | nil,
          reading: {marker(), anchor()} | nil,
          sequence: non_neg_integer()
        }
  defstruct fit: nil, reading: nil, sequence: 0

  @spec fit(t(), pos_integer(), pos_integer()) :: t()
  def fit(%__MODULE__{} = viewport, columns, rows)
      when columns > 0 and rows > 0,
      do: %{viewport | fit: {columns, min(rows, 8)}}

  @spec read_at(t(), marker(), anchor()) :: t()
  def read_at(%__MODULE__{} = viewport, marker, anchor),
    do: %{viewport | reading: {marker, anchor}, sequence: viewport.sequence + 1}

  @spec follow(t()) :: t()
  def follow(%__MODULE__{reading: nil} = viewport), do: viewport

  def follow(%__MODULE__{} = viewport),
    do: %{viewport | reading: nil, sequence: viewport.sequence + 1}

  @spec capacity(t(), pos_integer()) :: {pos_integer(), pos_integer()}
  def capacity(%__MODULE__{fit: nil}, columns), do: {columns, 8}
  def capacity(%__MODULE__{fit: fit}, _columns), do: fit

  @spec reading_anchor(t(), marker()) :: anchor() | nil
  def reading_anchor(%__MODULE__{reading: {marker, anchor}}, marker), do: anchor
  def reading_anchor(%__MODULE__{}, _marker), do: nil
end
