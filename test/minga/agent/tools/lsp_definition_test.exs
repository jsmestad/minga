defmodule Minga.Agent.Tools.LspDefinitionTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.LspDefinition

  describe "execute/3 without LSP client" do
    test "returns helpful message when no buffer exists" do
      {:ok, result} = LspDefinition.execute("/nonexistent/file.ex", 10, 5)
      assert result =~ "No buffer open"
      assert result =~ "file must be open"
    end
  end

  # Integration tests with a mock LSP client would go here.
  # The unit tests above verify the graceful degradation path.
  # Full integration testing requires an Editor + LSP client running.
end
