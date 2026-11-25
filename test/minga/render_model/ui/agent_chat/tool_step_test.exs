defmodule Minga.RenderModel.UI.AgentChat.ToolStepTest do
  use ExUnit.Case, async: true

  alias Minga.Design.Tokens
  alias Minga.RenderModel.UI.AgentChat.ToolStep

  @statuses [:running, :complete, :error, :denied, :cancelled, :approval_expired]

  test "every status is drawn in a shared state" do
    for status <- @statuses do
      assert ToolStep.state(status) in Tokens.state_ids(), "#{status}"
    end

    assert Enum.map(@statuses, &ToolStep.state/1) ==
             [:working, :done, :failed, :stopped, :stopped, :failed]
  end

  test "one sentence per status names the tool's action and its target" do
    args = %{"path" => "lib/native.ex"}

    for {status, sentence} <- [
          {:running, "Reading lib/native.ex"},
          {:complete, "Read lib/native.ex"},
          {:error, "Could not read lib/native.ex"},
          {:denied, "You denied reading lib/native.ex"},
          {:cancelled, "Stopped while reading lib/native.ex"},
          {:approval_expired, "Approval expired for reading lib/native.ex"}
        ] do
      assert ToolStep.sentence("read_file", args, status) == sentence
    end
  end

  test "shell commands are quoted, and a multi-line command keeps its first line" do
    assert ToolStep.sentence("shell", %{"command" => "mix test"}, :complete) == "Ran `mix test`"

    assert ToolStep.sentence("shell", %{"command" => "cd lib &&\n  mix test\n"}, :running) ==
             "Running `cd lib &&`"
  end

  test "each named tool reads as a verb; an unknown tool is named by its words" do
    for {name, args, sentence} <- [
          {"edit_file", %{"path" => "retry.ex"}, "Edited retry.ex"},
          {"write_file", %{"path" => "new.ex"}, "Wrote new.ex"},
          {"grep", %{"pattern" => "429", "path" => "lib"}, "Searched for 429 in lib"},
          {"git_commit", %{"message" => "fix it"}, "Committed fix it"},
          {"lsp_diagnostics", %{}, "Ran lsp diagnostics"},
          {"ask_user", %{"question" => "Which file?"}, "Asked you a question"},
          {"", %{}, "Ran a tool"}
        ] do
      assert ToolStep.sentence(name, args, :complete) == sentence
    end
  end

  test "a long target is cut with an ellipsis so the line stays one line" do
    sentence = ToolStep.sentence("read_file", %{"path" => String.duplicate("a", 300)}, :complete)

    assert String.ends_with?(sentence, "…")
    assert String.length(sentence) < 120
    refute sentence =~ "\n"
  end

  test "an argument that is not text names nothing instead of failing" do
    for {name, args, sentence} <- [
          {"read_file", %{"path" => nil}, "Read"},
          {"shell", %{"command" => ["ls", "-la"]}, "Ran"},
          {"find", %{"pattern" => 42}, "Found"}
        ] do
      assert ToolStep.sentence(name, args, :complete) == sentence
    end
  end
end
