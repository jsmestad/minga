defmodule Minga.RenderModel.Window.DiagnosticRange do
  @moduledoc """
  A diagnostic inline range in display coordinates.

  The GUI renders these as underlines (wavy for errors, straight for
  warnings, etc.) beneath the affected text. Severity determines the
  underline style and color.
  """

  alias Minga.Diagnostics.Diagnostic

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
          severity: Diagnostic.severity()
        }

  @doc "Converts diagnostics to display-coordinate ranges for visible lines."
  @spec from_diagnostics([Diagnostic.t()], non_neg_integer(), non_neg_integer()) :: [t()]
  def from_diagnostics([], _viewport_top, _viewport_bottom), do: []

  def from_diagnostics(diagnostics, viewport_top, viewport_bottom) do
    from_diagnostics(diagnostics, viewport_top, viewport_bottom, %{})
  end

  @doc "Converts diagnostics to display-coordinate ranges for visible lines using line text for encoded columns."
  @spec from_diagnostics(
          [Diagnostic.t()],
          non_neg_integer(),
          non_neg_integer(),
          %{non_neg_integer() => String.t()}
        ) :: [t()]
  def from_diagnostics([], _viewport_top, _viewport_bottom, _line_texts), do: []

  def from_diagnostics(diagnostics, viewport_top, viewport_bottom, line_texts) do
    diagnostics
    |> Enum.filter(fn %{range: r} ->
      r.start_line < viewport_bottom and r.end_line >= viewport_top
    end)
    |> Enum.map(&from_diagnostic(&1, viewport_top, line_texts))
  end

  @spec from_diagnostic(Diagnostic.t(), non_neg_integer(), %{non_neg_integer() => String.t()}) ::
          t()
  defp from_diagnostic(%Diagnostic{} = diag, viewport_top, line_texts) do
    {start_line, start_col} =
      Diagnostic.start_position(diag, Map.get(line_texts, diag.range.start_line, ""))

    {end_line, end_col} =
      Diagnostic.end_position(diag, Map.get(line_texts, diag.range.end_line, ""))

    %__MODULE__{
      start_row: max(start_line - viewport_top, 0),
      start_col: start_col,
      end_row: max(end_line - viewport_top, 0),
      end_col: end_col,
      severity: diag.severity
    }
  end
end
