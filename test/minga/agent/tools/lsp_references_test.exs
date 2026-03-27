defmodule Minga.Agent.Tools.LspReferencesTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.LspReferences

  describe "execute/3 without LSP client" do
    test "returns helpful message when no buffer exists" do
      {:ok, result} = LspReferences.execute("/nonexistent/file.ex", 10, 5)
      assert result =~ "No buffer open"
      assert result =~ "file must be open"
    end
  end
end
