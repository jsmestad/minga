defmodule MingaAgent.Tools.LspWorkspaceSymbolsTest do
  # Uses the global LSP supervisor to verify the no-active-server fallback.
  use ExUnit.Case, async: false

  alias Minga.Test.LspIsolation
  alias MingaAgent.Tools.LspWorkspaceSymbols

  setup do
    LspIsolation.stop_lsp_clients()
    on_exit(&LspIsolation.stop_lsp_clients/0)
    :ok
  end

  describe "execute/1 without running LSP servers" do
    test "returns helpful message when no LSP servers are running" do
      {:ok, result} = LspWorkspaceSymbols.execute("MyModule")
      # No LSP supervisor or clients running in test
      assert result =~ "No language servers" or result =~ "LSP supervisor"
    end
  end
end
