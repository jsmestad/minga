defmodule MingaAgent.Tools.ListDirectoryHeavyTest do
  # ListDirectory runs git-backed ignore checks, which spawn OS processes and must remain serialized.
  use ExUnit.Case, async: false

  alias MingaAgent.Tools.ListDirectory

  @moduletag :heavy

  setup do
    dir =
      Path.join(System.tmp_dir!(), "minga-list-directory-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, tmp_dir: dir}
  end

  test "lists filesystem entries through the production ignore boundary", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "file.txt"), "")
    File.mkdir_p!(Path.join(dir, "subdir"))

    assert {:ok, listing} = ListDirectory.execute(dir)
    assert String.split(listing, "\n") == ["subdir/", "file.txt"]
  end

  test "returns an empty listing for a gitignored directory", %{tmp_dir: dir} do
    {_output, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    File.write!(Path.join(dir, ".gitignore"), "ignored_dir/\n")
    ignored_dir = Path.join(dir, "ignored_dir")
    File.mkdir_p!(ignored_dir)
    File.write!(Path.join(ignored_dir, "leaked.txt"), "")

    assert {:ok, ""} = ListDirectory.execute(ignored_dir)
  end
end
