defmodule MingaAgent.ToolsReadOnlyTest do
  use ExUnit.Case, async: true

  alias MingaAgent.EphemeralSession
  alias MingaAgent.Tools

  test "read_only excludes write and execution tools" do
    names = Tools.read_only(project_root: File.cwd!()) |> Enum.map(& &1.name)

    assert "read_file" in names
    assert "grep" in names
    assert "fetch_url" in names
    assert "git_diff" in names
    refute "write_file" in names
    refute "edit_file" in names
    refute "multi_edit_file" in names
    refute "apply_diff" in names
    refute "delete_file" in names
    refute "shell" in names
    refute "subagent" in names
    refute "git_commit" in names
    refute "memory_write" in names
  end

  test "inline ask exposes no tools" do
    assert EphemeralSession.read_only_tools(File.cwd!()) == []
  end
end
