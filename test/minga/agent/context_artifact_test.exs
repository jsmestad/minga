defmodule Minga.Agent.ContextArtifactTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.ContextArtifact
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @moduletag :tmp_dir

  defp user_msg(text) do
    %Message{role: :user, content: [ContentPart.text(text)]}
  end

  defp assistant_msg(text) do
    %Message{role: :assistant, content: [ContentPart.text(text)]}
  end

  defp system_msg(text) do
    %Message{role: :system, content: [ContentPart.text(text)]}
  end

  describe "summary_prompt/0" do
    test "returns a non-empty string" do
      prompt = ContextArtifact.summary_prompt()
      assert is_binary(prompt)
      assert String.length(prompt) > 100
      assert prompt =~ "Decisions"
      assert prompt =~ "Changes Made"
    end
  end

  describe "summarizable?/1" do
    test "returns true with user + assistant messages" do
      messages = [user_msg("Hello"), assistant_msg("Hi!")]
      assert ContextArtifact.summarizable?(messages)
    end

    test "returns true ignoring system messages" do
      messages = [
        system_msg("System"),
        user_msg("Hello"),
        assistant_msg("Hi!")
      ]

      assert ContextArtifact.summarizable?(messages)
    end

    test "returns false for system-only messages" do
      messages = [system_msg("System")]
      refute ContextArtifact.summarizable?(messages)
    end

    test "returns false for single non-system message" do
      messages = [user_msg("Hello")]
      refute ContextArtifact.summarizable?(messages)
    end

    test "returns false for empty list" do
      refute ContextArtifact.summarizable?([])
    end
  end

  describe "save/2" do
    test "saves summary to .minga/context directory", %{tmp_dir: dir} do
      summary = "# Session Context: Test\n\n## Decisions\n- Chose Elixir"

      assert {:ok, path} =
               ContextArtifact.save(summary, project_root: dir, session_id: "abc123")

      assert File.exists?(path)
      assert path =~ ".minga/context/session-summary-abc123-"
      assert path =~ ".md"

      content = File.read!(path)
      assert content == summary
    end

    test "creates .minga/context directory if missing", %{tmp_dir: dir} do
      refute File.dir?(Path.join(dir, ".minga/context"))

      assert {:ok, _path} =
               ContextArtifact.save("test", project_root: dir)

      assert File.dir?(Path.join(dir, ".minga/context"))
    end

    test "generates session_id when not provided", %{tmp_dir: dir} do
      assert {:ok, path} = ContextArtifact.save("test", project_root: dir)
      assert path =~ "session-summary-"
    end
  end

  describe "list/1" do
    test "lists existing context artifacts", %{tmp_dir: dir} do
      context_dir = Path.join(dir, ".minga/context")
      File.mkdir_p!(context_dir)
      File.write!(Path.join(context_dir, "session-summary-a.md"), "summary a")
      File.write!(Path.join(context_dir, "session-summary-b.md"), "summary b")
      File.write!(Path.join(context_dir, "other.txt"), "not a summary")

      artifacts = ContextArtifact.list(dir)
      assert length(artifacts) == 2
      assert Enum.all?(artifacts, &String.ends_with?(&1, ".md"))
    end

    test "returns empty list when no context directory", %{tmp_dir: dir} do
      assert ContextArtifact.list(dir) == []
    end
  end
end
