defmodule MingaEditor.State.FileTreeFilterTest do
  @moduledoc "Pure filter loading, correlation, and cache-value installation tests."

  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias MingaEditor.FileTree.FilterWalk.Result
  alias MingaEditor.FileTree.ProjectCache.Snapshot
  alias MingaEditor.State.FileTree, as: FileTreeState

  defp open_tree(root) do
    tree = root |> FileTree.new() |> FileTree.put_entries([])
    FileTreeState.open(%FileTreeState{}, tree, nil)
  end

  test "filter transition immediately publishes loading without resolving rows" do
    ft = open_tree("/nonexistent_root") |> FileTreeState.update_filter("needle")

    assert ft.tree.filter == "needle"
    assert ft.tree.entries == nil
    assert ft.tree_status == :loading
    assert ft.filter_request == nil
  end

  test "filter requests admit only matching live tree state" do
    token = make_ref()
    root = "/project"

    detached = FileTreeState.track_filter_request(%FileTreeState{}, root, "needle", token)
    assert detached.filter_request == nil

    mismatched_root =
      root
      |> open_tree()
      |> FileTreeState.update_filter("needle")
      |> FileTreeState.track_filter_request("/other", "needle", token)

    assert mismatched_root.filter_request == nil

    mismatched_filter =
      root
      |> open_tree()
      |> FileTreeState.update_filter("needle")
      |> FileTreeState.track_filter_request(root, "other", token)

    assert mismatched_filter.filter_request == nil

    admitted =
      root
      |> open_tree()
      |> FileTreeState.update_filter("needle")
      |> FileTreeState.track_filter_request(root, "needle", token)

    assert admitted.filter_request == %{root: Path.expand(root), filter: "needle", token: token}
  end

  test "accept_filter closes input but preserves admitted request for result correlation" do
    root = "/project"
    token = make_ref()

    ft =
      root
      |> open_tree()
      |> FileTreeState.start_filtering()
      |> FileTreeState.update_filter("needle")
      |> FileTreeState.track_filter_request(root, "needle", token)

    accepted_input = FileTreeState.accept_filter(ft)
    assert accepted_input.interaction == :browse
    assert accepted_input.filter_request == ft.filter_request

    result = Result.filesystem(root, "needle", [entry(root, "needle.ex")])

    assert {:accepted, updated} =
             FileTreeState.accept_filter_result(accepted_input, root, "needle", token, result)

    assert updated.filter_request == nil
    assert Enum.map(FileTree.visible_entries(updated.tree), & &1.name) == ["needle.ex"]
  end

  test "cache data is injected as a value and installed only for the current request" do
    ft = open_tree("/project") |> FileTreeState.update_filter("needle")
    token = make_ref()
    ft = FileTreeState.track_filter_request(ft, ft.tree.root, "needle", token)

    snapshot = Snapshot.new(ft.tree.root, true, ["lib/recomputed-would-differ.ex"], false)
    entries = [entry(ft.tree.root, "worker-materialized.ex")]
    result = Result.project_cache(ft.tree.root, "needle", entries, snapshot)

    assert {:accepted, updated} =
             FileTreeState.accept_filter_result(ft, ft.tree.root, "needle", token, result)

    assert updated.tree.entries == entries
    assert updated.tree.cached_files == snapshot.files
    assert updated.tree_status == :ready
    assert updated.filter_request == nil

    buffer = BufferSync.start_buffer(updated.tree)
    assert Minga.Buffer.content(buffer) =~ "worker-materialized.ex"
    refute Minga.Buffer.content(buffer) =~ "recomputed-would-differ.ex"
  end

  test "rebuilding empty cache remains loading without a filesystem fallback" do
    ft = open_tree("/project") |> FileTreeState.update_filter("needle")
    token = make_ref()
    ft = FileTreeState.track_filter_request(ft, ft.tree.root, "needle", token)
    snapshot = Snapshot.new(ft.tree.root, true, [], true)
    result = Result.project_cache(ft.tree.root, "needle", [], snapshot)

    assert {:accepted, updated} =
             FileTreeState.accept_filter_result(ft, ft.tree.root, "needle", token, result)

    assert updated.tree.cached_files == []
    assert updated.tree_status == :loading
  end

  test "filesystem rows install for the exact request and stale repeated filters are dropped" do
    root = "/nonexistent_root"
    old_token = make_ref()

    old =
      root
      |> open_tree()
      |> FileTreeState.update_filter("older")
      |> FileTreeState.track_filter_request(root, "older", old_token)

    newer_token = make_ref()

    newer =
      old
      |> FileTreeState.update_filter("newer")
      |> FileTreeState.track_filter_request(root, "newer", newer_token)

    old_result = Result.filesystem(root, "older", [entry(root, "older.ex")])
    new_result = Result.filesystem(root, "newer", [entry(root, "newer.ex")])

    assert {:stale, unchanged} =
             FileTreeState.accept_filter_result(newer, root, "older", old_token, old_result)

    assert unchanged == newer

    assert {:accepted, updated} =
             FileTreeState.accept_filter_result(newer, root, "newer", newer_token, new_result)

    assert Enum.map(FileTree.visible_entries(updated.tree), & &1.name) == ["newer.ex"]
  end

  test "closed and rerooted filter results remain harmless" do
    root = "/filter-root"
    token = make_ref()

    current =
      root
      |> open_tree()
      |> FileTreeState.update_filter("needle")
      |> FileTreeState.track_filter_request(root, "needle", token)

    result = Result.filesystem(root, "needle", [entry(root, "needle.ex")])
    closed = FileTreeState.close(current)

    assert {:closed, ^closed} =
             FileTreeState.accept_filter_result(closed, root, "needle", token, result)

    rerooted =
      FileTreeState.begin_root_scan(current, FileTree.reroot(current.tree, "/new-root"), :reroot)

    assert {:stale, ^rerooted} =
             FileTreeState.accept_filter_result(rerooted, root, "needle", token, result)
  end

  defp entry(root, name) do
    %{
      path: Path.join(root, name),
      name: name,
      dir?: false,
      depth: 0,
      last_child?: true,
      guides: []
    }
  end
end
