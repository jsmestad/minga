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

  test "shell commands are quoted, and a multi-line command keeps its first line and says there is more" do
    assert ToolStep.sentence("shell", %{"command" => "mix test"}, :complete) == "Ran `mix test`"

    assert ToolStep.sentence("shell", %{"command" => "cd lib &&\n  mix test\n"}, :running) ==
             "Running `cd lib && …`"

    # The question never reads as the whole command when a later line does something else.
    assert ToolStep.question("shell", %{"command" => "echo ok\nrm -rf ~/work"}) ==
             "Run `echo ok …`?"

    assert ToolStep.question("shell", %{"command" => "\n  mix test\n"}) == "Run `mix test`?"
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

  test "a call that waits for approval is named in its step's words" do
    for {name, args, sentence} <- [
          {"write_file", %{"path" => "./notes.txt"}, "Asking to write ./notes.txt"},
          {"shell", %{"command" => "mix test"}, "Asking to run `mix test`"},
          {"lsp_rename", %{}, "Asking to run lsp rename"},
          {"edit_file", %{"path" => 3}, "Asking to edit"}
        ] do
      assert ToolStep.asking(name, args) == sentence
    end
  end

  test "an approval card asks its question in the decision's words, never by the tool's name" do
    for {name, args, question} <- [
          {"write_file", %{"path" => "./notes.txt"}, "Write ./notes.txt?"},
          {"shell", %{"command" => "mix ecto.reset"}, "Run `mix ecto.reset`?"},
          {"edit_file", %{"path" => "lib/retry.ex"}, "Edit lib/retry.ex?"},
          {"git_commit", %{"message" => "fix it"}, "Commit fix it?"},
          {"lsp_rename", %{}, "Run lsp rename?"},
          {"delete_file", %{"path" => 7}, "Delete?"}
        ] do
      assert ToolStep.question(name, args) == question
      refute question =~ "_"
    end
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
