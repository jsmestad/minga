defmodule MingaAgent.Tools.IntrospectionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.Introspection

  describe "describe_runtime/1" do
    test "returns {:ok, text} with runtime info" do
      {:ok, text} = Introspection.describe_runtime(%{})

      assert is_binary(text)
      assert text =~ "Minga Runtime"
      assert text =~ "Tools:"
      assert text =~ "Sessions:"
      assert text =~ "Features:"
    end

    test "includes tool count" do
      {:ok, text} = Introspection.describe_runtime(%{})
      # Should have at least the built-in tools
      assert text =~ ~r/Tools: \d+/
    end
  end

  describe "describe_tools/1" do
    test "returns {:ok, text} listing all tools" do
      {:ok, text} = Introspection.describe_tools(%{})

      assert is_binary(text)
      # Should include some known built-in tools
      assert text =~ "read_file"
      assert text =~ "write_file"
    end

    test "includes the introspection tools themselves" do
      {:ok, text} = Introspection.describe_tools(%{})

      assert text =~ "describe_runtime"
      assert text =~ "describe_tools"
    end

    test "each line has the expected format" do
      {:ok, text} = Introspection.describe_tools(%{})

      lines = String.split(text, "\n", trim: true)
      assert lines != []

      for line <- lines do
        # Each line should match: "- tool_name [category]: description"
        assert line =~ ~r/^- \S+ \[\w+\]: .+/
      end
    end
  end
end
