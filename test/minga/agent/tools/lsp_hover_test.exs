defmodule Minga.Agent.Tools.LspHoverTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.LspHover

  describe "execute/3 without LSP client" do
    test "returns helpful message when no buffer exists" do
      {:ok, result} = LspHover.execute("/nonexistent/file.ex", 10, 5)
      assert result =~ "No buffer open"
      assert result =~ "file must be open"
    end
  end
end
