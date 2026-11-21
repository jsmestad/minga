defmodule MingaAgent.Tools.ListDirectoryHeavyTest do
  # ListDirectory runs git-backed ignore checks, which spawn OS processes and must remain serialized.
  use ExUnit.Case, async: false

  alias MingaAgent.Tools.DirectoryListing
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

  test "returns an empty listing for statically ignored roots", %{tmp_dir: dir} do
    for ignored <- ["node_modules", ".env.local"] do
      ignored_dir = Path.join(dir, ignored)
      File.mkdir_p!(ignored_dir)
      File.write!(Path.join(ignored_dir, "leaked.txt"), "")

      assert {:ok, ""} = ListDirectory.execute(ignored_dir)
    end
  end

  test "returns an empty listing for a gitignored directory", %{tmp_dir: dir} do
    root = init_repo(dir)
    File.write!(Path.join(root, ".gitignore"), "ignored_dir/\n")
    ignored_dir = Path.join(root, "ignored_dir")
    File.mkdir_p!(ignored_dir)
    File.write!(Path.join(ignored_dir, "leaked.txt"), "")

    assert {:ok, ""} = ListDirectory.execute(ignored_dir)
  end

  test "caps the filtered typed listing without losing overlay-only directory types",
       %{tmp_dir: dir} do
    root = Path.join([dir, "deps", "repo"])
    File.mkdir_p!(root)
    root = init_repo(root)
    File.write!(Path.join(root, ".gitignore"), "*.log\n")

    files = for number <- 100..599, do: "file_#{number}.txt"

    entries = [
      %{name: "new_dir", type: :directory},
      %{name: ".env.local", type: :file},
      %{name: "build.log", type: :file}
      | Enum.map(Enum.reverse(files), &%{name: &1, type: :file})
    ]

    listing = DirectoryListing.format_entries(Path.join(root, "overlay_only"), entries)
    expected = ["new_dir/" | Enum.take(files, 499)] ++ ["... (truncated, 1 more entries)"]

    assert String.split(listing, "\n") == expected
  end

  test "hides entries when Git cannot check their ignore status", %{tmp_dir: dir} do
    root = init_repo(dir)
    File.write!(Path.join(root, ".git/index"), "invalid")
    File.write!(Path.join(root, "file.txt"), "")

    assert {:ok, ""} = ListDirectory.execute(root)
  end

  defp init_repo(dir) do
    {_, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"], cd: dir)
    String.trim(root)
  end
end
