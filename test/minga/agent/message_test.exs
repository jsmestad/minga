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
      assert {:thinking, "reasoning...", false} = msg
    end

    test "creates an empty thinking message by default" do
      msg = Message.thinking()
      assert {:thinking, "", false} = msg
    end

    test "creates a collapsed thinking message" do
      msg = Message.thinking("done", true)
      assert {:thinking, "done", true} = msg
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

  describe "text/1" do
    test "extracts text from user message" do
      assert Message.text({:user, "hello"}) == "hello"
    end

    test "extracts text from assistant message" do
      assert Message.text({:assistant, "response"}) == "response"
    end

    test "extracts text from thinking message" do
      assert Message.text({:thinking, "reasoning", false}) == "reasoning"
    end

    test "extracts text from tool call" do
      tc = %{
        name: "bash",
        result: "output",
        id: "1",
        args: %{},
        status: :complete,
        is_error: false,
        collapsed: true
      }

      assert Message.text({:tool_call, tc}) == "bash: output"
    end

    test "extracts text from system message" do
      assert Message.text({:system, "info", :info}) == "info"
    end
  end

  describe "usage/1" do
    test "creates a usage message" do
      data = %{input: 100, output: 50, cache_read: 0, cache_write: 0, cost: 0.01}
      msg = Message.usage(data)
      assert {:usage, ^data} = msg
    end
  end

  describe "system/2" do
    test "creates an info system message by default" do
      msg = Message.system("Session started")
      assert {:system, "Session started", :info} = msg
    end

    test "creates an error system message" do
      msg = Message.system("Connection failed", :error)
      assert {:system, "Connection failed", :error} = msg
    end
  end
end
