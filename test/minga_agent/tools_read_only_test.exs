defmodule MingaAgent.ToolsReadOnlyTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools

  test "read_only excludes write and execution tools" do
    names = Tools.read_only(project_root: File.cwd!()) |> Enum.map(& &1.name)

    assert "read_file" in names
    assert "grep" in names
    assert "git_diff" in names
    refute "write_file" in names
    refute "edit_file" in names
    refute "multi_edit_file" in names
    refute "delete_file" in names
    refute "shell" in names
    refute "subagent" in names
    refute "git_commit" in names
    refute "memory_write" in names
  end
end
