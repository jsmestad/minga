defmodule Minga.RenderModel.UI.AgentChat.ToolArgSummaryTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.AgentChat.ToolArgSummary

  describe "summarize/2" do
    test "summarizes read-only tools without raw inspected maps" do
      assert ToolArgSummary.summarize("read_file", %{"path" => "lib/minga.ex"}) == "lib/minga.ex"
      assert ToolArgSummary.summarize("list_directory", %{path: "lib"}) == "lib"

      assert ToolArgSummary.summarize("find", %{"path" => "lib", "name" => "*.ex"}) ==
               "*.ex in lib"

      assert ToolArgSummary.summarize("grep", %{"path" => "lib", "pattern" => "defmodule"}) ==
               "defmodule in lib"
    end

    test "keeps existing mutation tool summaries" do
      assert ToolArgSummary.summarize("shell", %{"command" => "mix test"}) == "mix test"
      assert ToolArgSummary.summarize("write_file", %{path: "README.md"}) == "README.md"

      assert ToolArgSummary.summarize("git_stage", %{"paths" => ["lib/a.ex", "test/a_test.exs"]}) ==
               "lib/a.ex, test/a_test.exs"

      assert ToolArgSummary.summarize("git_commit", %{message: "refactor(agent): consolidate"}) ==
               "refactor(agent): consolidate"
    end
  end
end
