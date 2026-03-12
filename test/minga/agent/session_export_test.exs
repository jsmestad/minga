defmodule Minga.Agent.SessionExportTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.SessionExport
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

  defp tool_result_msg(name, tool_call_id, result) do
    %Message{
      role: :tool,
      name: name,
      tool_call_id: tool_call_id,
      content: [ContentPart.text(result)]
    }
  end

  describe "to_markdown/2" do
    test "formats a simple conversation" do
      messages = [
        user_msg("What is 2+2?"),
        assistant_msg("The answer is 4.")
      ]

      assert {:ok, md, filename} = SessionExport.to_markdown(messages, model: "claude-sonnet-4")
      assert md =~ "# Minga Session Export"
      assert md =~ "claude-sonnet-4"
      assert md =~ "## 👤 User"
      assert md =~ "> What is 2+2?"
      assert md =~ "## 🤖 Assistant"
      assert md =~ "The answer is 4."
      assert filename =~ "minga-session-"
      assert filename =~ ".md"
    end

    test "excludes system messages from export" do
      messages = [
        system_msg("You are a helpful assistant"),
        user_msg("Hello"),
        assistant_msg("Hi!")
      ]

      assert {:ok, md, _} = SessionExport.to_markdown(messages, [])
      refute md =~ "You are a helpful assistant"
      assert md =~ "Hello"
      assert md =~ "Hi!"
    end

    test "returns error for empty messages" do
      assert {:error, "Nothing to export" <> _} = SessionExport.to_markdown([], [])
    end

    test "returns error for system-only messages" do
      messages = [system_msg("system prompt")]
      assert {:error, "Nothing to export" <> _} = SessionExport.to_markdown(messages, [])
    end

    test "formats tool results as collapsible details" do
      messages = [
        user_msg("Read the file"),
        tool_result_msg("read_file", "tc_1", "defmodule Foo do\nend")
      ]

      assert {:ok, md, _} = SessionExport.to_markdown(messages, [])
      assert md =~ "<details>"
      assert md =~ "read_file"
      assert md =~ "defmodule Foo"
    end

    test "formats assistant messages with thinking" do
      messages = [
        user_msg("Think about this"),
        %Message{
          role: :assistant,
          content: [
            ContentPart.thinking("Let me consider..."),
            ContentPart.text("Here is my answer.")
          ]
        }
      ]

      assert {:ok, md, _} = SessionExport.to_markdown(messages, [])
      assert md =~ "💭 Thinking"
      assert md =~ "Let me consider..."
      assert md =~ "Here is my answer."
    end

    test "notes image attachments in user messages" do
      messages = [
        %Message{
          role: :user,
          content: [
            ContentPart.text("What is this?"),
            ContentPart.image(<<1, 2, 3>>, "image/png")
          ]
        }
      ]

      assert {:ok, md, _} = SessionExport.to_markdown(messages, [])
      assert md =~ "1 image attached"
    end
  end

  describe "export_to_file/2" do
    test "writes markdown file to project root", %{tmp_dir: dir} do
      messages = [
        user_msg("Hello"),
        assistant_msg("Hi!")
      ]

      assert {:ok, path} = SessionExport.export_to_file(messages, project_root: dir)
      assert File.exists?(path)
      assert String.starts_with?(path, dir)

      content = File.read!(path)
      assert content =~ "# Minga Session Export"
      assert content =~ "Hello"
    end

    test "returns error for empty session", %{tmp_dir: dir} do
      assert {:error, _} = SessionExport.export_to_file([], project_root: dir)
    end
  end
end
