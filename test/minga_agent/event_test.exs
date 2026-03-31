defmodule MingaAgent.EventTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Event

  describe "AgentStart" do
    test "creates a start event" do
      event = %Event.AgentStart{}
      assert %Event.AgentStart{} = event
    end
  end

  describe "AgentEnd" do
    test "creates an end event with no usage" do
      event = %Event.AgentEnd{}
      assert event.usage == nil
    end

    test "creates an end event with usage" do
      usage = %MingaAgent.TurnUsage{
        input: 100,
        output: 50,
        cache_read: 0,
        cache_write: 0,
        cost: 0.01
      }

      event = %Event.AgentEnd{usage: usage}
      assert event.usage.input == 100
      assert event.usage.cost == 0.01
    end
  end

  describe "TextDelta" do
    test "requires delta field" do
      event = %Event.TextDelta{delta: "hello"}
      assert event.delta == "hello"
    end
  end

  describe "ThinkingDelta" do
    test "creates a thinking delta" do
      event = %Event.ThinkingDelta{delta: "reasoning..."}
      assert event.delta == "reasoning..."
    end
  end

  describe "ToolStart" do
    test "creates a tool start event" do
      event = %Event.ToolStart{tool_call_id: "call_1", name: "bash", args: %{"command" => "ls"}}
      assert event.name == "bash"
      assert event.args == %{"command" => "ls"}
    end

    test "defaults args to empty map" do
      event = %Event.ToolStart{tool_call_id: "call_1", name: "read"}
      assert event.args == %{}
    end
  end

  describe "ToolUpdate" do
    test "creates a tool update event" do
      event = %Event.ToolUpdate{tool_call_id: "call_1", name: "bash", partial_result: "output..."}
      assert event.partial_result == "output..."
    end
  end

  describe "ToolEnd" do
    test "creates a successful tool end" do
      event = %Event.ToolEnd{
        tool_call_id: "call_1",
        name: "bash",
        result: "done",
        is_error: false
      }

      assert event.result == "done"
      refute event.is_error
    end

    test "creates an error tool end" do
      event = %Event.ToolEnd{
        tool_call_id: "call_1",
        name: "bash",
        result: "failed",
        is_error: true
      }

      assert event.is_error
    end
  end

  describe "Error" do
    test "creates an error event" do
      event = %Event.Error{message: "API timeout"}
      assert event.message == "API timeout"
    end
  end
end
