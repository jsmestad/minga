defmodule Minga.Editor.SemanticWindow.DiagnosticRange do
  @moduledoc """
  A diagnostic inline range in display coordinates.

  The GUI renders these as underlines (wavy for errors, straight for
  warnings, etc.) beneath the affected text. Severity determines the
  underline style and color.
  """

  @enforce_keys [:start_row, :start_col, :end_row, :end_col, :severity]
  defstruct start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 0,
            severity: :error

  @type t :: %__MODULE__{
          start_row: non_neg_integer(),
          start_col: non_neg_integer(),
          end_row: non_neg_integer(),
          end_col: non_neg_integer(),
          severity: Minga.Diagnostics.Diagnostic.severity()
        }

  @doc "Converts diagnostics to display-coordinate ranges for visible lines."
  @spec from_diagnostics(
          [Minga.Diagnostics.Diagnostic.t()],
          non_neg_integer(),
          non_neg_integer()
        ) :: [t()]
  def from_diagnostics(diagnostics, viewport_top, viewport_bottom) do
    diagnostics
    |> Enum.filter(fn %{range: r} ->
      r.start_line < viewport_bottom and r.end_line >= viewport_top
    end)
    |> Enum.map(fn %{range: r, severity: severity} ->
      %__MODULE__{
        start_row: max(r.start_line - viewport_top, 0),
        start_col: r.start_col,
        end_row: max(r.end_line - viewport_top, 0),
        end_col: r.end_col,
        severity: severity
      }
    end)
  end
end
