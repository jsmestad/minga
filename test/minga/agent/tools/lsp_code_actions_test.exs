defmodule Minga.Agent.Tools.LspCodeActionsTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.LspCodeActions

  describe "execute/3 without LSP client" do
    test "returns error when no buffer exists" do
      {:error, result} = LspCodeActions.execute("/nonexistent/file.ex", 10)
      assert result =~ "No buffer open"
      assert result =~ "file must be open"
    end
  end
end
