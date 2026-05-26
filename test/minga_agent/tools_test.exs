defmodule MingaAgent.ToolsTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools

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

    test "raises when a symlink escapes root", %{tmp_dir: dir} do
      outside = Path.join(dir, "../outside-secret") |> Path.expand()
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "secret")
      File.ln_s!(outside, Path.join(dir, "link"))

      assert_raise ArgumentError, ~r/escapes project root/, fn ->
        Tools.resolve_and_validate_path!(dir, "link/secret.txt")
      end
    end

    test "raises when a missing path would be created through an escaping symlink", %{
      tmp_dir: dir
    } do
      outside = Path.join(dir, "../outside-write") |> Path.expand()
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(dir, "link"))

      assert_raise ArgumentError, ~r/escapes project root/, fn ->
        Tools.resolve_and_validate_path!(dir, "link/new.txt")
      end
    end

    test "raises when chained symlinks escape root", %{tmp_dir: dir} do
      outside = Path.join(dir, "../outside-chain") |> Path.expand()
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "secret")
      File.ln_s!("second", Path.join(dir, "first"))
      File.ln_s!(outside, Path.join(dir, "second"))

      assert_raise ArgumentError, ~r/escapes project root/, fn ->
        Tools.resolve_and_validate_path!(dir, "first/secret.txt")
      end
    end

    test "raises when an intermediate symlink target later escapes root", %{tmp_dir: dir} do
      outside = Path.join(dir, "../outside-intermediate") |> Path.expand()
      safe = Path.join(dir, "safe")
      File.mkdir_p!(outside)
      File.mkdir_p!(safe)
      File.write!(Path.join(outside, "secret.txt"), "secret")
      File.ln_s!("safe", Path.join(dir, "dir_link"))
      File.ln_s!(outside, Path.join(safe, "escape"))

      assert_raise ArgumentError, ~r/escapes project root/, fn ->
        Tools.resolve_and_validate_path!(dir, "dir_link/escape/secret.txt")
      end
    end

    test "resolves missing descendants through safe symlink chains", %{tmp_dir: dir} do
      safe = Path.join(dir, "safe")
      nested = Path.join(safe, "nested")
      File.mkdir_p!(nested)
      File.ln_s!("nested", Path.join(safe, "next"))
      File.ln_s!("safe", Path.join(dir, "first"))

      assert Tools.resolve_and_validate_path!(dir, "first/next/new/file.txt") ==
               Path.join(nested, "new/file.txt")
    end

    test "raises on symlink loops", %{tmp_dir: dir} do
      File.ln_s!("b", Path.join(dir, "a"))
      File.ln_s!("a", Path.join(dir, "b"))

      assert_raise ArgumentError, ~r/symlink loop/, fn ->
        Tools.resolve_and_validate_path!(dir, "a/file.txt")
      end
    end
  end

  describe "all/1" do
    test "returns the expected number of tools", %{tmp_dir: dir} do
      tools = Tools.all(project_root: dir)
      assert length(tools) == 27

      names = Enum.map(tools, & &1.name)
      assert "read_file" in names
      assert "write_file" in names
      assert "edit_file" in names
      assert "multi_edit_file" in names
      assert "apply_diff" in names
      assert "delete_file" in names
      assert "list_directory" in names
      assert "find" in names
      assert "grep" in names
      assert "shell" in names
      assert "subagent" in names

      # LSP tools
      assert "diagnostics" in names
      assert "definition" in names
      assert "references" in names
      assert "hover" in names
      assert "document_symbols" in names
      assert "workspace_symbols" in names
      assert "rename" in names
      assert "code_actions" in names
    end

    test "all tools have descriptions and callbacks", %{tmp_dir: dir} do
      for tool <- Tools.all(project_root: dir) do
        assert is_binary(tool.description)
        assert String.length(tool.description) > 0
        assert is_function(tool.callback, 1)
      end
    end

    test "subagent schema accepts optional background flag and provider overrides", %{
      tmp_dir: dir
    } do
      subagent = Tools.all(project_root: dir) |> Enum.find(&(&1.name == "subagent"))
      schema = subagent.parameter_schema

      assert schema["required"] == ["task"]
      assert Map.has_key?(schema["properties"], "task")

      # Background flag
      assert schema["properties"]["background"]["type"] == "boolean"
      refute "background" in schema["required"]
      assert subagent.description =~ "Background mode"

      # Provider and model overrides
      assert schema["properties"]["model"]["description"] =~ "Defaults to the parent's model"
      assert schema["properties"]["provider"]["enum"] == ["native", "pi_rpc"]

      assert schema["properties"]["provider"]["description"] =~
               "Defaults to the parent's provider"
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

    test "delete_file is destructive by default" do
      assert Tools.destructive?("delete_file")
    end

    test "apply_diff is destructive by default" do
      assert Tools.destructive?("apply_diff")
    end

    test "read_file is not destructive by default" do
      refute Tools.destructive?("read_file")
    end

    test "list_directory is not destructive by default" do
      refute Tools.destructive?("list_directory")
    end

    test "rename is destructive by default" do
      assert Tools.destructive?("rename")
    end

    test "diagnostics is not destructive" do
      refute Tools.destructive?("diagnostics")
    end

    test "definition is not destructive" do
      refute Tools.destructive?("definition")
    end

    test "code_actions listing is not destructive" do
      refute Tools.destructive?("code_actions", %{"path" => "foo.ex", "line" => 0})
    end

    test "code_actions with apply is destructive" do
      assert Tools.destructive?("code_actions", %{"path" => "foo.ex", "line" => 0, "apply" => 1})
    end

    test "code_actions with apply title is destructive" do
      assert Tools.destructive?("code_actions", %{
               "path" => "foo.ex",
               "line" => 0,
               "apply" => "Add missing import"
             })
    end

    test "unknown tools are not destructive" do
      refute Tools.destructive?("foobar")
    end

    test "MCP tools are destructive by default" do
      assert Tools.destructive?("mcp_workspace__lookup", %{}, [])
    end

    test "list_mcp_tools is destructive because it starts MCP servers lazily" do
      assert Tools.destructive?("list_mcp_tools", %{}, [])
    end

    test "call_mcp_tool is destructive because it invokes remote side effects" do
      assert Tools.destructive?("call_mcp_tool", %{}, [])
    end

    test "accepts a custom destructive list" do
      assert Tools.destructive?("read_file", %{}, ["read_file", "shell"])
      refute Tools.destructive?("write_file", %{}, ["read_file", "shell"])
    end

    test "empty list makes nothing destructive" do
      refute Tools.destructive?("write_file", %{}, [])
      refute Tools.destructive?("shell", %{}, [])
    end
  end
end
