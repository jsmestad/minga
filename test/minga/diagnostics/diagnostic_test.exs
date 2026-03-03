defmodule Minga.Diagnostics.DiagnosticTest do
  use ExUnit.Case, async: true

  alias Minga.Diagnostics.Diagnostic

  defp make_diag(opts \\ []) do
    %Diagnostic{
      range: Keyword.get(opts, :range, %{start_line: 0, start_col: 0, end_line: 0, end_col: 5}),
      severity: Keyword.get(opts, :severity, :error),
      message: Keyword.get(opts, :message, "something went wrong"),
      source: Keyword.get(opts, :source, "test"),
      code: Keyword.get(opts, :code, nil)
    }
  end

  describe "compare_severity/2" do
    test "error is more severe than warning" do
      assert Diagnostic.compare_severity(:error, :warning) == :lt
    end

    test "warning is more severe than info" do
      assert Diagnostic.compare_severity(:warning, :info) == :lt
    end

    test "info is more severe than hint" do
      assert Diagnostic.compare_severity(:info, :hint) == :lt
    end

    test "equal severities return :eq" do
      assert Diagnostic.compare_severity(:error, :error) == :eq
      assert Diagnostic.compare_severity(:hint, :hint) == :eq
    end

    test "less severe returns :gt" do
      assert Diagnostic.compare_severity(:hint, :error) == :gt
      assert Diagnostic.compare_severity(:info, :warning) == :gt
    end
  end

  describe "more_severe/2" do
    test "returns the more severe of two severities" do
      assert Diagnostic.more_severe(:warning, :error) == :error
      assert Diagnostic.more_severe(:error, :warning) == :error
      assert Diagnostic.more_severe(:info, :hint) == :info
    end

    test "returns either when equal" do
      assert Diagnostic.more_severe(:error, :error) == :error
    end
  end

  describe "sort/1" do
    test "sorts by line number" do
      d1 = make_diag(range: %{start_line: 5, start_col: 0, end_line: 5, end_col: 1})
      d2 = make_diag(range: %{start_line: 1, start_col: 0, end_line: 1, end_col: 1})
      d3 = make_diag(range: %{start_line: 10, start_col: 0, end_line: 10, end_col: 1})

      assert Diagnostic.sort([d1, d2, d3]) == [d2, d1, d3]
    end

    test "sorts by column within same line" do
      d1 = make_diag(range: %{start_line: 1, start_col: 10, end_line: 1, end_col: 15})
      d2 = make_diag(range: %{start_line: 1, start_col: 2, end_line: 1, end_col: 5})

      assert Diagnostic.sort([d1, d2]) == [d2, d1]
    end

    test "sorts by severity within same position (most severe first)" do
      d1 =
        make_diag(
          severity: :warning,
          range: %{start_line: 1, start_col: 0, end_line: 1, end_col: 1}
        )

      d2 =
        make_diag(
          severity: :error,
          range: %{start_line: 1, start_col: 0, end_line: 1, end_col: 1}
        )

      assert Diagnostic.sort([d1, d2]) == [d2, d1]
    end

    test "empty list returns empty" do
      assert Diagnostic.sort([]) == []
    end

    test "single element returns as-is" do
      d = make_diag()
      assert Diagnostic.sort([d]) == [d]
    end
  end
end
