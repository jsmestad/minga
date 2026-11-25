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

      assert ToolArgSummary.summarize("edit_file", %{"path" => "lib/app.ex", "edits" => []}) ==
               "lib/app.ex"

      assert ToolArgSummary.summarize("delete_file", %{path: "old.txt"}) == "old.txt"

      assert ToolArgSummary.summarize("git_stage", %{"paths" => ["lib/a.ex", "test/a_test.exs"]}) ==
               "lib/a.ex, test/a_test.exs"

      assert ToolArgSummary.summarize("git_commit", %{message: "refactor(agent): consolidate"}) ==
               "refactor(agent): consolidate"
    end

    test "removed mutation tool names use the ordinary fallback" do
      for name <- ["multi_edit_file", "apply_diff"] do
        assert ToolArgSummary.summarize(name, %{"path" => "lib/app.ex"}) == "lib/app.ex"
      end
    end

    test "a value that is not text names nothing, for every tool" do
      for {name, args} <- [
            {"find", %{"pattern" => 1000}},
            {"find", %{"name" => %{"x" => 1}, "path" => "lib"}},
            {"grep", %{"pattern" => %{"x" => 1}, "path" => "lib"}},
            {"grep", %{"query" => ["a"], "path" => "lib"}},
            {"grep", %{"pattern" => 7}},
            {"git_stage", %{"paths" => [%{}]}},
            {"git_stage", %{"paths" => ["lib/a.ex", 3]}},
            {"subagent", %{"task" => %{"nested" => true}}},
            {"read_file", %{"path" => %{"nested" => true}}},
            {"shell", %{"command" => 1.5}},
            {"git_commit", %{"message" => nil}}
          ] do
        assert ToolArgSummary.summarize(name, args) == ""
      end
    end

    test "a place that is not text is left out and the subject still reads" do
      assert ToolArgSummary.summarize("grep", %{"pattern" => "TODO", "path" => 3}) == "TODO"
      assert ToolArgSummary.summarize("find", %{"name" => "*.ex", "path" => %{}}) == "*.ex"
    end

    test "a search without a path names what it searches for, whatever else it carries" do
      assert ToolArgSummary.summarize("grep", %{"pattern" => "TODO", "case_sensitive" => false}) ==
               "TODO"

      assert ToolArgSummary.summarize("grep", %{query: "TODO", glob: "*.ex"}) == "TODO"
    end

    test "a subagent names its task, not its settings" do
      args = %{"task" => "Audit the tests", "background" => true, "model" => "small"}

      assert ToolArgSummary.summarize("subagent", args) == "Audit the tests"
    end

    test "a find by pattern alone names the pattern" do
      assert ToolArgSummary.summarize("find", %{"pattern" => "lib/other.ex"}) == "lib/other.ex"
      assert ToolArgSummary.summarize("find", %{name: "*.ex"}) == "*.ex"
    end

    test "any other tool reads as its plain arguments, never as an Elixir map" do
      for {args, summary} <- [
            {%{"query" => "drafts"}, "drafts"},
            {%{"limit" => 5, "query" => "drafts"}, "limit: 5, query: drafts"},
            {%{"files" => ["a.ex", "b.ex"]}, "a.ex, b.ex"},
            {%{"options" => %{"deep" => true}, "query" => "x"}, "x"},
            {%{"query" => nil}, ""}
          ] do
        assert ToolArgSummary.summarize("lsp_symbols", args) == summary
        refute summary =~ "%{"
      end
    end
  end
end
