defmodule Minga.RenderModel.Window.DiagnosticRangeTest do
  use ExUnit.Case, async: true

  alias Minga.Diagnostics.Diagnostic
  alias Minga.RenderModel.Window.DiagnosticRange

  describe "from_diagnostics/4" do
    test "converts UTF-16 diagnostic columns to byte columns" do
      diagnostic = diagnostic(:utf16, 17, 30)
      line_texts = %{0 => "\"héllo wörld\" <> undefined_var"}

      assert [range] = DiagnosticRange.from_diagnostics([diagnostic], 0, 1, line_texts)
      assert range.start_row == 0
      assert range.start_col == 19
      assert range.end_row == 0
      assert range.end_col == 32
      assert range.severity == :error
    end

    test "keeps UTF-8 diagnostic columns unchanged" do
      diagnostic = diagnostic(:utf8, 19, 32)
      line_texts = %{0 => "\"héllo wörld\" <> undefined_var"}

      assert [range] = DiagnosticRange.from_diagnostics([diagnostic], 0, 1, line_texts)
      assert range.start_col == 19
      assert range.end_col == 32
    end
  end

  @spec diagnostic(Diagnostic.encoding(), non_neg_integer(), non_neg_integer()) :: Diagnostic.t()
  defp diagnostic(encoding, start_col, end_col) do
    %Diagnostic{
      range: %{start_line: 0, start_col: start_col, end_line: 0, end_col: end_col},
      severity: :error,
      message: "undefined variable",
      encoding: encoding
    }
  end
end
