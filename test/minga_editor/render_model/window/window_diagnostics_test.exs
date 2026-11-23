defmodule MingaEditor.RenderModel.Window.WindowDiagnosticsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Diagnostics.Diagnostic
  alias Minga.RenderModel.Window.DiagnosticRange
  alias MingaEditor.RenderModel.Window.WindowDiagnostics

  defp diagnostic(start_line, end_line, message \\ "d") do
    %Diagnostic{
      range: %{start_line: start_line, start_col: 0, end_line: end_line, end_col: 3},
      severity: :error,
      message: message
    }
  end

  defp view(diagnostics, revision \\ 7),
    do:
      WindowDiagnostics.apply_change(
        WindowDiagnostics.empty(),
        {:changed, revision, diagnostics, %{}}
      )

  test "an unchanged revision keeps the same retained terms" do
    current = view([diagnostic(1, 1), diagnostic(4, 6)])
    next = WindowDiagnostics.apply_change(current, :unchanged)

    assert :erts_debug.same(current, next)
    assert :erts_debug.same(current.diagnostics, next.diagnostics)
  end

  test "a change to revision 0 resets to the empty view" do
    current = view([diagnostic(1, 1)])

    assert WindowDiagnostics.apply_change(current, {:changed, 0, [], %{}}) ==
             WindowDiagnostics.empty()

    assert WindowDiagnostics.snapshot(WindowDiagnostics.empty()) == {0, []}
    assert WindowDiagnostics.visible(WindowDiagnostics.empty(), 0, 100) == []
  end

  test "visible keeps published order, duplicates and malformed spans" do
    late = diagnostic(9, 9, "late")
    duplicate = diagnostic(9, 9, "late")
    malformed = diagnostic(12, 8, "malformed")
    spanning = diagnostic(0, 20, "spanning")
    outside = diagnostic(30, 31, "outside")
    current = view([late, outside, malformed, duplicate, spanning])

    assert WindowDiagnostics.visible(current, 9, 9) == [late, malformed, duplicate, spanning]
    assert WindowDiagnostics.visible(current, 21, 29) == []
    assert WindowDiagnostics.visible(current, 5, 4) == []
  end

  property "viewport ranges from visible candidates equal ranges from the full list" do
    line = integer(0..60)

    check all(
            spans <- list_of(tuple({line, line}), max_length: 60),
            top <- line,
            rows <- integer(0..25)
          ) do
      diagnostics =
        spans
        |> Enum.with_index()
        |> Enum.map(fn {{first, last}, i} -> diagnostic(first, last, "d#{rem(i, 3)}") end)

      bottom = top + rows
      current = view(diagnostics)
      candidates = WindowDiagnostics.visible(current, top, top + max(rows - 1, 0))

      assert DiagnosticRange.from_diagnostics(candidates, top, bottom) ==
               DiagnosticRange.from_diagnostics(diagnostics, top, bottom)
    end
  end
end
