defmodule MingaAgent.IntrospectionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Introspection

  describe "capabilities/0" do
    test "returns a capabilities manifest with required fields" do
      caps = Introspection.capabilities()

      assert is_binary(caps.version)
      assert is_integer(caps.tool_count)
      assert caps.tool_count >= 0
      assert is_integer(caps.session_count)
      assert caps.session_count >= 0
      assert is_list(caps.tool_categories)
      assert is_list(caps.features)
      assert :tools in caps.features
      assert :sessions in caps.features
      assert :events in caps.features
    end
  end

  describe "describe_tools/0" do
    test "returns a list of tool descriptions" do
      tools = Introspection.describe_tools()

      assert is_list(tools)

      if tools != [] do
        tool = hd(tools)
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.parameter_schema)
        assert is_atom(tool.category)
        assert tool.approval_level in [:auto, :ask, :deny]
      end
    end

    test "includes introspection tools themselves" do
      tools = Introspection.describe_tools()
      names = Enum.map(tools, & &1.name)
      assert "describe_runtime" in names
      assert "describe_tools" in names
    end
  end

  describe "describe_sessions/0" do
    test "returns a list of session description maps" do
      sessions = Introspection.describe_sessions()
      assert is_list(sessions)

      for session <- sessions do
        assert Map.has_key?(session, :session_id)
        assert Map.has_key?(session, :model_name)
        assert Map.has_key?(session, :status)
        assert Map.has_key?(session, :created_at)
      end
    end
  end
end
