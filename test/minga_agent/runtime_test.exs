defmodule MingaAgent.RuntimeTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Runtime

  describe "tool operations" do
    test "list_tools returns tool specs" do
      tools = Runtime.list_tools()
      assert is_list(tools)
    end

    test "tool_registered? checks registration" do
      assert is_boolean(Runtime.tool_registered?("nonexistent_tool_xyz"))
    end

    test "get_tool returns error for unknown tool" do
      assert :error == Runtime.get_tool("nonexistent_tool_xyz")
    end
  end

  describe "session operations" do
    test "list_sessions returns a list" do
      sessions = Runtime.list_sessions()
      assert is_list(sessions)
    end

    test "get_session returns error for unknown session" do
      assert {:error, :not_found} == Runtime.get_session("nonexistent-session")
    end
  end

  describe "introspection" do
    test "capabilities returns a map with required fields" do
      caps = Runtime.capabilities()
      assert is_map(caps)
      assert Map.has_key?(caps, :tool_count)
      assert Map.has_key?(caps, :version)
    end

    test "describe_tools returns a list" do
      tools = Runtime.describe_tools()
      assert is_list(tools)
    end

    test "describe_sessions returns a list" do
      sessions = Runtime.describe_sessions()
      assert is_list(sessions)
    end
  end
end
