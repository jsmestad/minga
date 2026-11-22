defmodule MingaEditor.Agent.ChatSearchTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.ChatSearch

  test "returns matching stable IDs in display order, not the source or display position" do
    items = [
      {101, {:assistant, "pinned result"}, nil},
      {4_000_000_001, {:system, "── pinned ──", :info}, nil},
      {205, {:user, "result result"}, nil},
      {130, {:thinking, "Another RESULT", false}, nil}
    ]

    assert ChatSearch.find_matches(items, "result") == [
             {101, 7, 13},
             {205, 0, 6},
             {205, 7, 13},
             {130, 8, 14}
           ]
  end

  test "handles an empty query, Unicode byte positions, and the case-sensitive suffix" do
    items = [{42, {:assistant, "é É"}, nil}]
    assert ChatSearch.find_matches(items, "") == []
    assert ChatSearch.find_matches(items, "absent") == []
    assert ChatSearch.find_matches(items, "É\\C") == [{42, 3, 5}]
    assert ChatSearch.find_matches(items, "É") == [{42, 0, 2}, {42, 3, 5}]
  end

  test "searches system messages and tool results" do
    call =
      MingaAgent.ToolCall.new("read", "read_file") |> MingaAgent.ToolCall.complete("file result")

    items = [{5, {:system, "Session started", :info}, nil}, {9, {:tool_call, call}, nil}]
    assert ChatSearch.find_matches(items, "started") == [{5, 8, 15}]
    assert [{9, _, _}] = ChatSearch.find_matches(items, "file result")
  end
end
