defmodule MingaEditor.State.FileTreeFilterTest do
  @moduledoc """
  Covers the cache-vs-walk filtering decision and async no-cache stale-drop in
  MingaEditor.State.FileTree (#2377).
  """

  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias MingaEditor.State.FileTree, as: FileTreeState

  # These tests run without the Minga.Project GenServer, so ProjectCache treats
  # every root as "not the active project" (the :exit guard returns false). That
  # is exactly the no-cache fallback path we want to exercise here.

  defp open_tree(root) do
    %FileTreeState{}
    |> FileTreeState.open(FileTree.new(root), nil)
  end

  test "filtering a no-cache root marks the tree loading pending the async walk" do
    ft = open_tree("/nonexistent_root") |> FileTreeState.update_filter("needle")

    assert ft.tree.filter == "needle"
    assert ft.tree_status == :loading
    assert FileTreeState.needs_filter_walk?(ft)
  end

  test "an empty filter never needs an async walk" do
    ft = open_tree("/nonexistent_root") |> FileTreeState.start_filtering()

    assert ft.tree.filter == ""
    refute FileTreeState.needs_filter_walk?(ft)
  end

  test "apply_filter_walk installs entries for the current root and filter" do
    ft = open_tree("/nonexistent_root") |> FileTreeState.update_filter("needle")
    root = ft.tree.root

    entries = [
      %{
        path: "/nonexistent_root/needle.ex",
        name: "needle.ex",
        dir?: false,
        depth: 0,
        last_child?: true,
        guides: []
      }
    ]

    updated = FileTreeState.apply_filter_walk(ft, root, "needle", entries)

    assert FileTree.visible_entries(updated.tree) == entries
    assert updated.tree_status == :ready
  end

  test "apply_filter_walk drops a stale result for a superseded filter" do
    ft = open_tree("/nonexistent_root") |> FileTreeState.update_filter("newer")
    root = ft.tree.root
    before = ft.tree.entries

    stale = [
      %{
        path: "/nonexistent_root/old.ex",
        name: "old.ex",
        dir?: false,
        depth: 0,
        last_child?: true,
        guides: []
      }
    ]

    updated = FileTreeState.apply_filter_walk(ft, root, "older", stale)

    # The stale walk result is discarded; the tree keeps its prior entries.
    assert updated.tree.entries == before
  end
end
