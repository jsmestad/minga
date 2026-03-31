defmodule MingaAgent.Tools.DiagnosticFeedbackTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.DiagnosticFeedback

  describe "await/2 without LSP" do
    test "returns skip when no buffer exists for the path" do
      assert {:skip, reason} = DiagnosticFeedback.await("/nonexistent/file.ex")
      assert reason =~ "No LSP diagnostics"
    end

    test "respects custom timeout" do
      # Should return quickly since there's no LSP client
      {time_us, {:skip, _}} =
        :timer.tc(fn ->
          DiagnosticFeedback.await("/nonexistent/file.ex", timeout: 100)
        end)

      # Should complete in well under 1 second (no waiting)
      assert time_us < 500_000
    end
  end

  describe "append_to_result/2" do
    test "appends ok result with diagnostics" do
      result =
        DiagnosticFeedback.append_to_result(
          "edited foo.ex",
          {:ok, "Diagnostics: clean"}
        )

      assert result == "edited foo.ex\n\nDiagnostics: clean"
    end

    test "appends skip result in parentheses" do
      result =
        DiagnosticFeedback.append_to_result(
          "edited foo.ex",
          {:skip, "No LSP diagnostics available for this file."}
        )

      assert result == "edited foo.ex\n\n(No LSP diagnostics available for this file.)"
    end
  end
end
