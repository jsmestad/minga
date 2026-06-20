defmodule MingaEditor.FileTree.FilterWalkTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.FilterWalk

  describe "fresh?/3" do
    test "a result for the current root and filter is fresh" do
      tree = "/root" |> FileTree.new() |> FileTree.set_filter("needle")

      assert FilterWalk.fresh?(tree, "/root", "needle")
    end

    test "a result for a superseded filter is stale" do
      tree = "/root" |> FileTree.new() |> FileTree.set_filter("newer")

      refute FilterWalk.fresh?(tree, "/root", "older")
    end

    test "a result for a different root is stale" do
      tree = "/current" |> FileTree.new() |> FileTree.set_filter("needle")

      refute FilterWalk.fresh?(tree, "/previous", "needle")
    end
  end

  describe "start/2 async walk" do
    @tag :tmp_dir
    test "walks off-process and replies with entries keyed by root and filter",
         %{tmp_dir: tmp_dir} do
      mkdir = fn p -> File.mkdir_p!(p) end
      mkdir.(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "target.ex"]), "")
      File.write!(Path.join(tmp_dir, "other.txt"), "")

      tree = tmp_dir |> FileTree.new() |> FileTree.set_filter("target")

      assert :ok = FilterWalk.start(tree, self())

      root = tree.root
      assert_receive {:file_tree_filter_walk, ^root, "target", entries}, 5_000
      assert Enum.map(entries, & &1.name) == ["target.ex"]
    end
  end
end
