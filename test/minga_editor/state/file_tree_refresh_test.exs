defmodule MingaEditor.State.FileTree.RefreshTest do
  @moduledoc "Behavior tests for pure file-tree refresh ownership and correlation."

  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias MingaEditor.State.FileTree, as: FileTreeState

  test "one debounce intent is consumed only by its correlated timer" do
    file_tree = open_tree("/tmp/minga-refresh-debounce")
    timer = make_ref()

    assert {:scheduled, file_tree} = FileTreeState.request_refresh_debounce(file_tree, timer)

    assert {:already_scheduled, ^file_tree} =
             FileTreeState.request_refresh_debounce(file_tree, make_ref())

    assert {:stale, ^file_tree} = FileTreeState.refresh_debounce_elapsed(file_tree, make_ref())

    assert {:ready, %FileTree{}, elapsed} =
             FileTreeState.refresh_debounce_elapsed(file_tree, timer)

    assert {:stale, ^elapsed} = FileTreeState.refresh_debounce_elapsed(elapsed, timer)
  end

  test "a newer debounce intent immediately invalidates older result authority" do
    root = "/tmp/minga-refresh-newer-intent"
    request = make_ref()
    timer = make_ref()

    tracked = open_tree(root) |> FileTreeState.track_refresh_request(root, request)
    assert tracked.refresh.current.token == request

    assert {:scheduled, pending} = FileTreeState.request_refresh_debounce(tracked, timer)
    assert pending.refresh.current == nil
    assert pending.refresh.debounce == timer
  end

  test "an admission retry keeps one correlated pending intent and advances backoff" do
    file_tree = open_tree("/tmp/minga-refresh-retry")
    first_timer = make_ref()
    second_timer = make_ref()

    assert {1, first} = FileTreeState.track_refresh_retry(file_tree, first_timer)
    assert first.refresh.debounce == first_timer
    assert first.refresh.retry_attempt == 1

    assert {:ready, _tree, elapsed} =
             FileTreeState.refresh_debounce_elapsed(first, first_timer)

    assert {2, second} = FileTreeState.track_refresh_retry(elapsed, second_timer)
    assert second.refresh.debounce == second_timer
    assert second.refresh.retry_attempt == 2
  end

  test "a current request atomically replaces the tree and clears correlation" do
    root = "/tmp/minga-refresh-current"
    original = open_tree(root)
    request = make_ref()
    refreshed = tree(root, [entry(root, "new.ex")])

    tracked = FileTreeState.track_refresh_request(original, root, request)

    assert {:accepted, accepted} =
             FileTreeState.accept_refresh_result(tracked, root, request, refreshed)

    assert accepted.tree == refreshed

    assert {:stale, ^accepted} =
             FileTreeState.accept_refresh_result(accepted, root, request, refreshed)
  end

  test "a stale result cannot consume or replace the semantic current request" do
    root = "/tmp/minga-refresh-stale"
    current = make_ref()
    stale = make_ref()
    file_tree = open_tree(root) |> FileTreeState.track_refresh_request(root, current)
    refreshed = tree(root, [entry(root, "fresh.ex")])

    assert {:stale, unchanged} =
             FileTreeState.accept_refresh_result(file_tree, root, stale, refreshed)

    assert unchanged.tree == file_tree.tree

    assert {:accepted, accepted} =
             FileTreeState.accept_refresh_result(unchanged, root, current, refreshed)

    assert accepted.tree == refreshed
  end

  test "closing and reopening the same root invalidates the old result" do
    root = "/tmp/minga-refresh-closed"
    request = make_ref()

    closed =
      root
      |> open_tree()
      |> FileTreeState.track_refresh_request(root, request)
      |> FileTreeState.close()

    assert {:stale, unchanged} =
             FileTreeState.accept_refresh_result(closed, root, request, tree(root, []))

    assert unchanged.tree == nil

    reopened = FileTreeState.open(closed, tree(root, [entry(root, "current.ex")]), nil)
    old_result = tree(root, [entry(root, "old.ex")])

    assert {:stale, still_current} =
             FileTreeState.accept_refresh_result(reopened, root, request, old_result)

    assert Enum.map(still_current.tree.entries, & &1.name) == ["current.ex"]
  end

  test "rerooting away and back invalidates the old result" do
    old_root = "/tmp/minga-refresh-old-root"
    new_root = "/tmp/minga-refresh-new-root"
    request = make_ref()

    file_tree =
      old_root
      |> open_tree()
      |> FileTreeState.track_refresh_request(old_root, request)
      |> FileTreeState.replace_tree(tree(new_root, []))
      |> FileTreeState.replace_tree(tree(old_root, [entry(old_root, "current.ex")]))

    assert {:stale, current} =
             FileTreeState.accept_refresh_result(
               file_tree,
               old_root,
               request,
               tree(old_root, [entry(old_root, "old.ex")])
             )

    assert Enum.map(current.tree.entries, & &1.name) == ["current.ex"]
  end

  test "metadata replacement preserves root errors and refresh correlation" do
    root = "/tmp/minga-refresh-metadata"
    request = make_ref()

    file_tree =
      root
      |> open_tree()
      |> FileTreeState.track_refresh_request(root, request)
      |> FileTreeState.refresh_failed(:enoent)

    metadata_tree = tree(root, [entry(root, "badged.ex")])
    replaced = FileTreeState.replace_tree_metadata(file_tree, metadata_tree)

    assert replaced.tree == metadata_tree
    assert FileTreeState.status(replaced) == FileTreeState.status(file_tree)
    assert replaced.refresh == file_tree.refresh
  end

  test "failed and canceled terminals clear only the matching request" do
    root = "/tmp/minga-refresh-terminal"
    first = make_ref()
    second = make_ref()

    file_tree = open_tree(root) |> FileTreeState.track_refresh_request(root, first)
    assert {:stale, ^file_tree} = FileTreeState.finish_refresh(file_tree, root, second)
    assert {:current, finished} = FileTreeState.finish_refresh(file_tree, root, first)

    reusable = FileTreeState.track_refresh_request(finished, root, second)
    assert {:current, _finished_again} = FileTreeState.finish_refresh(reusable, root, second)
  end

  defp open_tree(root) do
    FileTreeState.open(%FileTreeState{}, tree(root, []), nil)
  end

  defp tree(root, entries), do: root |> FileTree.new() |> FileTree.put_entries(entries)

  defp entry(root, name) do
    %{
      name: name,
      path: Path.join(root, name),
      dir?: false,
      depth: 0,
      last_child?: true,
      guides: []
    }
  end
end
