defmodule Minga.Editor.SemanticWindow.SearchMatch do
  @moduledoc """
  A search match in display coordinates.

  The GUI renders these as highlight quads behind text. The `is_current`
  flag indicates the currently confirmed match (rendered with a distinct
  color).
  """

  @enforce_keys [:row, :start_col, :end_col]
  defstruct row: 0,
            start_col: 0,
            end_col: 0,
            is_current: false

  @type t :: %__MODULE__{
          row: non_neg_integer(),
          start_col: non_neg_integer(),
          end_col: non_neg_integer(),
          is_current: boolean()
        }

  @doc "Converts search matches from the render context to display coordinates."
  @spec from_context_matches(
          [Minga.Search.Match.t()],
          Minga.Search.Match.t() | nil,
          non_neg_integer(),
          non_neg_integer()
        ) :: [t()]
  def from_context_matches(matches, confirm_match, viewport_top, viewport_bottom) do
    matches
    |> Enum.filter(fn %{line: line} ->
      line >= viewport_top and line < viewport_bottom
    end)
    |> Enum.map(fn %{line: line, col: col, length: len} = match ->
      %__MODULE__{
        row: line - viewport_top,
        start_col: col,
        end_col: col + len,
        is_current: confirm_match != nil and match == confirm_match
      }
    end)
  end
end
