defmodule Minga.Agent.BufferSyncTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.BufferSync
  alias Minga.Buffer.Server, as: BufferServer

  describe "start_buffer/0" do
    test "creates a nofile markdown buffer" do
      pid = BufferSync.start_buffer()

      assert is_pid(pid)
      assert BufferServer.buffer_type(pid) == :nofile
      assert BufferServer.read_only?(pid)
      assert BufferServer.buffer_name(pid) == "*Agent*"
      assert BufferServer.filetype(pid) == :markdown
      assert BufferServer.unlisted?(pid)
      assert BufferServer.persistent?(pid)
    end
  end

  describe "sync/2" do
    test "writes user message content (no markdown header)" do
      pid = BufferSync.start_buffer()
      BufferSync.sync(pid, [{:user, "Hello agent"}])

      content = BufferServer.content(pid)
      refute content =~ "## You", "block decorations handle headers, not buffer text"
      assert content =~ "Hello agent"
    end

    test "writes assistant message content (no markdown header)" do
      pid = BufferSync.start_buffer()
      BufferSync.sync(pid, [{:assistant, "Here is my response"}])

      content = BufferServer.content(pid)
      refute content =~ "## Agent", "block decorations handle headers, not buffer text"
      assert content =~ "Here is my response"
    end

    test "writes thinking block content (no blockquote prefix)" do
      pid = BufferSync.start_buffer()
      BufferSync.sync(pid, [{:thinking, "Let me think about this", false}])

      content = BufferServer.content(pid)
      refute content =~ "> **Thinking**", "fold decorations handle thinking display"
      assert content =~ "Let me think about this"
    end

    test "writes tool call result (no status header)" do
      pid = BufferSync.start_buffer()

      tc = %{
        name: "read_file",
        status: :complete,
        result: "file content here",
        args: %{},
        collapsed: false
      }

      BufferSync.sync(pid, [{:tool_call, tc}])

      content = BufferServer.content(pid)
      refute content =~ "### ✓ read_file", "block decorations handle tool headers"
      assert content =~ "file content here"
    end

    test "handles full conversation" do
      pid = BufferSync.start_buffer()

      messages = [
        {:user, "Fix the bug"},
        {:assistant, "I'll look at the code"},
        {:tool_call,
         %{name: "read", status: :complete, result: "code", args: %{}, collapsed: false}},
        {:assistant, "Found and fixed it"}
      ]

      BufferSync.sync(pid, messages)
      content = BufferServer.content(pid)

      assert content =~ "Fix the bug"
      assert content =~ "I'll look at the code"
      assert content =~ "code"
      assert content =~ "Found and fixed it"
      refute content =~ "## You"
      refute content =~ "## Agent"
    end
  end

  describe "messages_to_markdown_with_offsets/1" do
    test "computes correct line offsets for single-line messages" do
      messages = [
        {:user, "hey"},
        {:assistant, "response"},
        {:usage, %{input: 1, output: 2, cost: 0.01}}
      ]

      {text, offsets} = BufferSync.messages_to_markdown_with_offsets(messages)

      assert offsets == [{0, 0, 1}, {1, 2, 1}, {2, 4, 1}]
      assert text == "hey\n\nresponse\n\n↑1 ↓2 $0.01"
    end

    test "computes correct offsets for multi-line messages" do
      messages = [{:user, "line1\nline2"}, {:assistant, "a\nb\nc"}]
      {_text, offsets} = BufferSync.messages_to_markdown_with_offsets(messages)

      # user: 2 lines at 0, assistant: 3 lines at 0+2+1=3
      assert offsets == [{0, 0, 2}, {1, 3, 3}]
    end

    test "handles single message with no separator" do
      {_text, offsets} = BufferSync.messages_to_markdown_with_offsets([{:user, "solo"}])
      assert offsets == [{0, 0, 1}]
    end

    test "handles empty message list" do
      {text, offsets} = BufferSync.messages_to_markdown_with_offsets([])
      assert offsets == []
      assert text == ""
    end

    test "offset start_line matches actual position in joined text" do
      messages = [{:user, "hello"}, {:assistant, "world"}, {:user, "again"}]
      {text, offsets} = BufferSync.messages_to_markdown_with_offsets(messages)
      lines = String.split(text, "\n")

      for {_idx, start, _count} <- offsets do
        # The line at the computed offset should be non-empty message content
        assert Enum.at(lines, start) != "", "line at offset #{start} should have content"
      end
    end

    test "cursor moves to end after sync" do
      pid = BufferSync.start_buffer()
      messages = [{:user, "line 1"}, {:assistant, "line 2\nline 3\nline 4"}]
      BufferSync.sync(pid, messages)

      {cursor_line, _col} = BufferServer.cursor(pid)
      line_count = BufferServer.line_count(pid)
      assert cursor_line == line_count - 1
    end
  end
end
