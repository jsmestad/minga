defmodule Minga.Agent.BufferSyncTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.BufferSync

  describe "line_message_index/1" do
    test "returns empty list for no messages" do
      assert BufferSync.line_message_index([]) == []
    end

    test "maps a single user message" do
      messages = [{:user, "hello world"}]
      index = BufferSync.line_message_index(messages)

      assert [{0, :text}] = index
    end

    test "maps a multiline user message" do
      messages = [{:user, "line 1\nline 2\nline 3"}]
      index = BufferSync.line_message_index(messages)

      assert [{0, :text}, {0, :text}, {0, :text}] = index
    end

    test "maps multiple messages with separator lines" do
      messages = [{:user, "hello"}, {:assistant, "world"}]
      index = BufferSync.line_message_index(messages)

      # "hello\n\nworld" → ["hello", "", "world"]
      # Line 0: user msg (idx 0), Line 1: separator, Line 2: assistant msg (idx 1)
      assert [{0, :text}, {0, :empty}, {1, :text}] = index
    end

    test "classifies assistant code blocks as :code" do
      messages = [{:assistant, "text\n```elixir\ncode here\n```\nmore text"}]
      index = BufferSync.line_message_index(messages)

      assert [
               {0, :text},
               {0, :code},
               {0, :code},
               {0, :code},
               {0, :text}
             ] = index
    end

    test "classifies tool_call lines as :tool" do
      tc = %{name: "bash", args: %{}, result: "output", status: :complete, collapsed: false}
      messages = [{:tool_call, tc}]
      index = BufferSync.line_message_index(messages)

      assert [{0, :tool}] = index
    end

    test "classifies thinking lines as :thinking" do
      messages = [{:thinking, "hmm...\nlet me think", false}]
      index = BufferSync.line_message_index(messages)

      assert [{0, :thinking}, {0, :thinking}] = index
    end

    test "classifies usage lines as :usage" do
      messages = [{:usage, %{input: 100, output: 50, cost: 0.01}}]
      index = BufferSync.line_message_index(messages)

      assert [{0, :usage}] = index
    end

    test "handles mixed message types" do
      messages = [
        {:user, "question"},
        {:assistant, "answer with\n```\ncode\n```"}
      ]

      index = BufferSync.line_message_index(messages)

      assert [
               {0, :text},
               {0, :empty},
               {1, :text},
               {1, :code},
               {1, :code},
               {1, :code}
             ] = index
    end

    test "empty tool_call result produces single line" do
      tc = %{name: "bash", args: %{}, result: "", status: :running, collapsed: false}
      messages = [{:tool_call, tc}]
      index = BufferSync.line_message_index(messages)

      assert [{0, :tool}] = index
    end
  end

  describe "message_start_line/2" do
    test "returns 0 for first message" do
      messages = [{:user, "hello"}, {:assistant, "world"}]
      assert BufferSync.message_start_line(messages, 0) == 0
    end

    test "returns correct start for second message" do
      messages = [{:user, "hello"}, {:assistant, "world"}]
      # "hello\n\nworld" → line 0: hello, line 1: separator, line 2: world
      assert BufferSync.message_start_line(messages, 1) == 2
    end

    test "returns nil for out-of-range index" do
      messages = [{:user, "hello"}]
      assert BufferSync.message_start_line(messages, 5) == nil
    end

    test "accounts for multiline messages" do
      messages = [{:user, "line 1\nline 2\nline 3"}, {:assistant, "response"}]
      # Lines: 0-2 user (3 lines), 3 separator, 4 response
      assert BufferSync.message_start_line(messages, 1) == 4
    end

    test "returns nil for empty message list" do
      assert BufferSync.message_start_line([], 0) == nil
    end
  end
end
