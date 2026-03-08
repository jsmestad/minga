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
    test "writes user messages as markdown" do
      pid = BufferSync.start_buffer()
      BufferSync.sync(pid, [{:user, "Hello agent"}])

      content = BufferServer.content(pid)
      assert content =~ "## You"
      assert content =~ "Hello agent"
    end

    test "writes assistant messages as markdown" do
      pid = BufferSync.start_buffer()
      BufferSync.sync(pid, [{:assistant, "Here is my response"}])

      content = BufferServer.content(pid)
      assert content =~ "## Agent"
      assert content =~ "Here is my response"
    end

    test "writes thinking blocks as blockquotes" do
      pid = BufferSync.start_buffer()
      BufferSync.sync(pid, [{:thinking, "Let me think about this", false}])

      content = BufferServer.content(pid)
      assert content =~ "> **Thinking**"
      assert content =~ "Let me think about this"
    end

    test "writes tool calls with status" do
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
      assert content =~ "### ✓ read_file"
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

      assert content =~ "## You"
      assert content =~ "Fix the bug"
      assert content =~ "## Agent"
      assert content =~ "### ✓ read"
      assert content =~ "Found and fixed it"
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
