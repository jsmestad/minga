defmodule Minga.Agent.Tools.LspWorkspaceSymbolsTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.LspWorkspaceSymbols

  describe "execute/1 without running LSP servers" do
    test "returns helpful message when no LSP servers are running" do
      {:ok, result} = LspWorkspaceSymbols.execute("MyModule")
      # No LSP supervisor or clients running in test
      assert result =~ "No language servers" or result =~ "LSP supervisor"
    end
  end
end
