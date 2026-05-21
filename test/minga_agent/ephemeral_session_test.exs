defmodule MingaAgent.EphemeralSessionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.EphemeralSession

  test "rewrite tools include only file read tools and produce_rewrite" do
    names = EphemeralSession.rewrite_tools(File.cwd!()) |> Enum.map(& &1.name)

    assert names == ["read_file", "list_directory", "find", "grep", "produce_rewrite"]
    refute "diagnostics" in names
    refute "definition" in names
    refute "git_status" in names
    refute "write_file" in names
    refute "multi_edit_file" in names
    refute "shell" in names
    refute "delete_file" in names
  end
end
