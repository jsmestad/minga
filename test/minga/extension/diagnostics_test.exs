defmodule Minga.Extension.DiagnosticsTest do
  # Touches the globally-supervised Minga.Diagnostics singleton, so not async.
  use ExUnit.Case, async: false

  alias Minga.Diagnostics
  alias Minga.Extension.Diagnostics, as: ExtDiagnostics

  setup do
    ext = :"ext_test_#{System.unique_integer([:positive])}"
    uri = "file:///tmp/ext_diag_#{System.unique_integer([:positive])}.ex"
    on_exit(fn -> ExtDiagnostics.clear_all(ext) end)
    %{ext: ext, uri: uri}
  end

  test "publishes findings clamped to :hint and namespaced by extension", %{ext: ext, uri: uri} do
    :ok = ExtDiagnostics.publish(ext, uri, [%{line: 4, concern: "assumes list non-empty"}])

    assert [diag] = Diagnostics.for_uri(uri)
    assert diag.severity == :hint
    assert diag.message == "assumes list non-empty"
    assert diag.source == "ext:#{ext}"
    assert diag.range.start_line == 4
  end

  test "findings render as :diag_advisory in the gutter", %{ext: ext, uri: uri} do
    :ok = ExtDiagnostics.publish(ext, uri, [%{line: 1, concern: "P99 is 340ms"}])

    assert Diagnostics.gutter_signs_by_line(uri)[1] == :diag_advisory
  end

  test "does not clobber another producer's diagnostics on the same URI", %{ext: ext, uri: uri} do
    real = %Diagnostics.Diagnostic{
      range: %{start_line: 0, start_col: 0, end_line: 0, end_col: 1},
      severity: :error,
      message: "real compiler error",
      source: "mix_compile"
    }

    Diagnostics.publish(:mix_compile, uri, [real])
    :ok = ExtDiagnostics.publish(ext, uri, [%{line: 9, concern: "advice"}])

    messages = uri |> Diagnostics.for_uri() |> Enum.map(& &1.message) |> Enum.sort()
    assert messages == ["advice", "real compiler error"]

    # Clearing the extension leaves the compiler diagnostic intact.
    :ok = ExtDiagnostics.clear(ext, uri)
    assert [%{message: "real compiler error"}] = Diagnostics.for_uri(uri)

    Diagnostics.clear(:mix_compile, uri)
  end

  test "accepts an absolute path as well as a file URI", %{ext: ext} do
    path = "/tmp/ext_diag_path_#{System.unique_integer([:positive])}.ex"
    :ok = ExtDiagnostics.publish(ext, path, [%{line: 0, concern: "via path"}])

    uri = Minga.LSP.SyncServer.path_to_uri(path)
    assert [%{message: "via path"}] = Diagnostics.for_uri(uri)
  end
end
