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
    test "returns the expected number of tools", %{tmp_dir: dir} do
      tools = Tools.all(project_root: dir)
      assert length(tools) == 9

      names = Enum.map(tools, & &1.name)
      assert "read_file" in names
      assert "write_file" in names
      assert "edit_file" in names
      assert "multi_edit_file" in names
      assert "list_directory" in names
      assert "find" in names
      assert "grep" in names
      assert "shell" in names
      assert "subagent" in names
    end

    test "all tools have descriptions and callbacks", %{tmp_dir: dir} do
      for tool <- Tools.all(project_root: dir) do
        assert is_binary(tool.description)
        assert String.length(tool.description) > 0
        assert is_function(tool.callback, 1)
      end
    end
  end

  describe "destructive?/1" do
    test "write_file is destructive by default" do
      assert Tools.destructive?("write_file")
    end

    test "edit_file is destructive by default" do
      assert Tools.destructive?("edit_file")
    end

    test "shell is destructive by default" do
      assert Tools.destructive?("shell")
    end

    test "read_file is not destructive by default" do
      refute Tools.destructive?("read_file")
    end

    test "list_directory is not destructive by default" do
      refute Tools.destructive?("list_directory")
    end

    test "unknown tools are not destructive" do
      refute Tools.destructive?("foobar")
    end

    test "accepts a custom destructive list" do
      assert Tools.destructive?("read_file", ["read_file", "shell"])
      refute Tools.destructive?("write_file", ["read_file", "shell"])
    end

    test "empty list makes nothing destructive" do
      refute Tools.destructive?("write_file", [])
      refute Tools.destructive?("shell", [])
    end
  end
end
