defmodule Minga.Agent.Tools.LspRenameTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.LspRename

  describe "execute/4 without LSP client" do
    test "returns error when no buffer exists" do
      {:error, result} = LspRename.execute("/nonexistent/file.ex", 10, 5, "new_name")
      assert result =~ "No buffer open"
      assert result =~ "file must be open"
    end
  end
end
