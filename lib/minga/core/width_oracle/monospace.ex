defmodule Minga.Core.WidthOracle.Monospace do
  @moduledoc """
  Width oracle for monospace cell-based frontends.

  This is the default oracle for TUI rendering and for GUI rendering until proportional font measurements are available.
  """

  defstruct []

  @type t :: %__MODULE__{}
end

defimpl Minga.Core.WidthOracle, for: Minga.Core.WidthOracle.Monospace do
  @moduledoc false

  alias Minga.Core.Unicode
  alias Minga.Core.WidthOracle.Monospace

  @spec grapheme_width(Monospace.t(), String.t()) :: non_neg_integer()
  def grapheme_width(%Monospace{}, grapheme), do: Unicode.grapheme_width(grapheme)

  @spec display_width(Monospace.t(), String.t()) :: non_neg_integer()
  def display_width(%Monospace{}, text), do: Unicode.display_width(text)
end
