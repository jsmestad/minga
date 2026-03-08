defmodule Minga.Agent.ToolsTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools

  @moduletag :tmp_dir

  describe "resolve_and_validate_path!/2" do
    test "resolves relative paths within the root", %{tmp_dir: dir} do
      result = Tools.resolve_and_validate_path!(dir, "lib/foo.ex")
      assert result == Path.join(dir, "lib/foo.ex")
    end

    test "allows the root directory itself", %{tmp_dir: dir} do
      result = Tools.resolve_and_validate_path!(dir, ".")
      assert result == Path.expand(dir)
    end

    test "raises on path traversal that escapes root", %{tmp_dir: dir} do
      assert_raise ArgumentError, ~r/escapes project root/, fn ->
        Tools.resolve_and_validate_path!(dir, "../../etc/passwd")
      end
    end

    test "raises on absolute paths outside root", %{tmp_dir: dir} do
      assert_raise ArgumentError, ~r/escapes project root/, fn ->
        Tools.resolve_and_validate_path!(dir, "/etc/passwd")
      end
    end

    test "allows paths with .. that stay within root", %{tmp_dir: dir} do
      result = Tools.resolve_and_validate_path!(dir, "a/b/../c")
      assert result == Path.join(dir, "a/c")
    end
  end

  describe "all/1" do
    test "returns a list of five tools", %{tmp_dir: dir} do
      tools = Tools.all(project_root: dir)
      assert length(tools) == 5

      names = Enum.map(tools, & &1.name)
      assert "read_file" in names
      assert "write_file" in names
      assert "edit_file" in names
      assert "list_directory" in names
      assert "shell" in names
    end

    test "all tools have descriptions and callbacks", %{tmp_dir: dir} do
      for tool <- Tools.all(project_root: dir) do
        assert is_binary(tool.description)
        assert String.length(tool.description) > 0
        assert is_function(tool.callback, 1)
      end
    end
  end
end
