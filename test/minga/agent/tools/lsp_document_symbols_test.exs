defmodule Minga.Agent.Tools.LspDocumentSymbolsTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.LspDocumentSymbols

  describe "execute/1 without LSP client" do
    test "returns helpful message when no buffer exists" do
      {:ok, result} = LspDocumentSymbols.execute("/nonexistent/file.ex")
      assert result =~ "No buffer open"
      assert result =~ "file must be open"
    end
  end
end
