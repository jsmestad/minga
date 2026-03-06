defmodule Minga.Agent.MessageTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Message

  describe "user/1" do
    test "creates a user message" do
      msg = Message.user("Hello")
      assert {:user, "Hello"} = msg
    end
  end

  describe "assistant/1" do
    test "creates an assistant message" do
      msg = Message.assistant("Response")
      assert {:assistant, "Response"} = msg
    end

    test "creates an empty assistant message by default" do
      msg = Message.assistant()
      assert {:assistant, ""} = msg
    end
  end

  describe "thinking/1" do
    test "creates a thinking message" do
      msg = Message.thinking("reasoning...")
      assert {:thinking, "reasoning..."} = msg
    end

    test "creates an empty thinking message by default" do
      msg = Message.thinking()
      assert {:thinking, ""} = msg
    end
  end

  describe "tool_call/3" do
    test "creates a tool call message" do
      msg = Message.tool_call("tc1", "bash", %{"command" => "ls"})
      assert {:tool_call, tc} = msg
      assert tc.id == "tc1"
      assert tc.name == "bash"
      assert tc.args == %{"command" => "ls"}
      assert tc.status == :running
      assert tc.result == ""
      assert tc.is_error == false
      assert tc.collapsed == true
    end

    test "defaults args to empty map" do
      msg = Message.tool_call("tc1", "read")
      assert {:tool_call, tc} = msg
      assert tc.args == %{}
    end
  end
end
