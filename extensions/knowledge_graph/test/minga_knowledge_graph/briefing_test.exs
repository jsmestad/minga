defmodule MingaKnowledgeGraph.BriefingTest do
  use ExUnit.Case, async: true

  alias MingaKnowledgeGraph.Briefing

  test "truncated unicode content stays valid UTF-8" do
    content = String.duplicate("a", 7_999) <> "é" <> String.duplicate("z", 100)

    assert [%{role: "system"}, %{role: "user", content: prompt}] =
             Briefing.messages("/tmp/unicode.ex", content)

    assert String.valid?(prompt)
    assert prompt =~ "[file truncated]"
  end
end
