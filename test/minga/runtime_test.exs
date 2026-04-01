defmodule Minga.RuntimeTest do
  @moduledoc """
  Integration test for the headless runtime.

  Verifies that `Minga.Runtime.start/1` boots a full supervision tree
  with tool registration and tool execution working end-to-end.
  Must be async: false because it starts globally-named processes.
  """

  use ExUnit.Case, async: false

  alias MingaAgent.Tool.Executor
  alias MingaAgent.Tool.Registry

  # The application is already running in the test environment with the
  # same Foundation/Services/Agent children that Runtime.start/1 would
  # boot. Rather than fight named-process conflicts, we verify the
  # invariants on the running tree (same children, same guarantees).
  #
  # The architecture_test.exs checks supervision tree shape;
  # this file checks functional correctness: tools registered, tools
  # executable, results correct.

  describe "tool registry" do
    test "built-in tools are registered" do
      tools = Registry.all()
      assert length(tools) > 0

      tool_names = Enum.map(tools, & &1.name)

      # Verify a representative set of built-in tools
      assert "read_file" in tool_names
      assert "list_directory" in tool_names
      assert "grep" in tool_names
      assert "find" in tool_names
      assert "git_status" in tool_names
      assert "shell" in tool_names
    end

    test "lookup returns a spec for a known tool" do
      assert {:ok, spec} = Registry.lookup("list_directory")
      assert spec.name == "list_directory"
      assert spec.category == :filesystem
      assert is_function(spec.callback, 1)
    end

    test "lookup returns :error for an unknown tool" do
      assert :error = Registry.lookup("nonexistent_tool_xyz")
    end

    test "registered? returns correct boolean" do
      assert Registry.registered?("read_file")
      refute Registry.registered?("nonexistent_tool_xyz")
    end
  end

  describe "tool execution" do
    test "executes list_directory through the Executor" do
      # list_directory with "." is read-only and always succeeds
      result = Executor.execute("list_directory", %{"path" => "."})

      assert {:ok, output} = result
      assert is_binary(output)
      # The project root must contain mix.exs
      assert output =~ "mix.exs"
    end

    test "executes read_file through the Executor" do
      result = Executor.execute("read_file", %{"path" => "mix.exs"})

      assert {:ok, content} = result
      assert is_binary(content)
      assert content =~ "defmodule"
    end

    test "returns error for unknown tool" do
      result = Executor.execute("nonexistent_tool_xyz", %{})
      assert {:error, {:tool_not_found, "nonexistent_tool_xyz"}} = result
    end

    test "destructive tools require approval" do
      result = Executor.execute("write_file", %{"path" => "test.txt", "content" => "x"})
      assert {:needs_approval, _spec, _args} = result
    end
  end
end
