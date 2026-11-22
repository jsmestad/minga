defmodule MingaEditor.Agent.TranscriptTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Transcript

  test "classifies only assistant fences and keeps the trailing blank line" do
    assert types({:assistant, "lead\n  ```elixir\ncode\n```\n"}) == [
             :text,
             :code,
             :code,
             :code,
             :text
           ]

    assert types({:user, "```\nnot assistant code"}) == [:text, :text]
    assert types({:assistant, "x ```inline\nplain"}) == [:text, :text]
  end

  test "a tool result uses the first 500 graphemes, including only the newlines in that range" do
    tool =
      MingaAgent.ToolCall.new("tool", "read_file")
      |> MingaAgent.ToolCall.complete(String.duplicate("e\u0301", 499) <> "\nextra\nhidden")

    assert types({:tool_call, tool}) == [:tool, :tool]
    assert types({:tool_call, MingaAgent.ToolCall.new("empty", "read_file")}) == [:tool]
  end

  test "separates thinking, notices and usage from regular text" do
    assert types({:thinking, "one\ntwo", false}) == [:thinking, :thinking]
    assert types({:system, "API key status:\n  ✗ Anthropic", :info}) == [:system, :system]
    assert types({:usage, MingaAgent.TurnUsage.new()}) == [:usage]
  end

  defp types(message) do
    {count, _type} = profile = Transcript.line_profile(message)
    Enum.map(0..(count - 1), &Transcript.line_type_at(profile, &1))
  end
end
