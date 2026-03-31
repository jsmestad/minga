defmodule MingaEditor.Agent.ChatSearchTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.ChatSearch

  describe "find_matches/2" do
    test "returns empty list for empty query" do
      assert ChatSearch.find_matches([{:user, "hello"}], "") == []
    end

    test "finds matches in user messages" do
      messages = [{:user, "hello world"}]
      matches = ChatSearch.find_matches(messages, "hello")
      assert [{0, 0, 5}] = matches
    end

    test "finds matches in assistant messages" do
      messages = [{:assistant, "The answer is 42"}]
      matches = ChatSearch.find_matches(messages, "answer")
      assert [{0, 4, 10}] = matches
    end

    test "finds multiple matches in one message" do
      messages = [{:user, "hello hello hello"}]
      matches = ChatSearch.find_matches(messages, "hello")
      assert length(matches) == 3
    end

    test "finds matches across multiple messages" do
      messages = [
        {:user, "first message"},
        {:assistant, "second message"},
        {:user, "third message"}
      ]

      matches = ChatSearch.find_matches(messages, "message")
      assert length(matches) == 3
      assert [{0, _, _}, {1, _, _}, {2, _, _}] = matches
    end

    test "case-insensitive by default" do
      messages = [{:user, "Hello HELLO hello"}]
      matches = ChatSearch.find_matches(messages, "hello")
      assert length(matches) == 3
    end

    test "case-sensitive with \\C suffix" do
      messages = [{:user, "Hello HELLO hello"}]
      matches = ChatSearch.find_matches(messages, "Hello\\C")
      assert length(matches) == 1
      assert [{0, 0, 5}] = matches
    end

    test "searches system messages" do
      messages = [{:system, "Session started", :info}]
      matches = ChatSearch.find_matches(messages, "started")
      assert [{0, 8, 15}] = matches
    end

    test "searches thinking messages" do
      messages = [{:thinking, "I need to think about this", false}]
      matches = ChatSearch.find_matches(messages, "think")
      assert [{0, _, _}] = matches
    end

    test "searches tool call messages" do
      tool_call = %{
        name: "read_file",
        args: %{"path" => "lib/foo.ex"},
        result: "defmodule Foo",
        started_at: nil,
        duration_ms: nil,
        collapsed: false
      }

      messages = [{:tool_call, tool_call}]
      matches = ChatSearch.find_matches(messages, "read_file")
      assert matches != []
    end

    test "returns empty for no matches" do
      messages = [{:user, "hello world"}]
      assert ChatSearch.find_matches(messages, "xyz") == []
    end
  end

  describe "match_message_index/1" do
    test "extracts message index from match tuple" do
      assert ChatSearch.match_message_index({5, 10, 15}) == 5
    end
  end
end
