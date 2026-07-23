defmodule MingaEditor.State.FileTree.RefreshTest do
  @moduledoc "Behavior tests for pure file-tree refresh ownership and correlation."

  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.FileTree.Refresh

  test "one debounce intent is consumed only by its correlated timer" do
    file_tree = open_tree("/tmp/minga-refresh-debounce")
    timer = make_ref()

    assert {:scheduled, file_tree} = FileTreeState.request_refresh_debounce(file_tree, timer)

    assert {:already_scheduled, ^file_tree} =
             FileTreeState.request_refresh_debounce(file_tree, make_ref())

    assert {:stale, ^file_tree} = FileTreeState.refresh_debounce_elapsed(file_tree, make_ref())

    assert {:ready, %FileTree{}, 0, elapsed} =
             FileTreeState.refresh_debounce_elapsed(file_tree, timer)

    assert {:stale, ^elapsed} = FileTreeState.refresh_debounce_elapsed(elapsed, timer)
  end

  test "a newer debounce intent immediately invalidates older result authority" do
    root = "/tmp/minga-refresh-newer-intent"
    request = make_ref()
    timer = make_ref()

    tracked = open_tree(root) |> FileTreeState.track_refresh_request(root, request)
    assert tracked.refresh.phase == {:admitted, Path.expand(root), %{token: request}}

    assert {:scheduled, pending} = FileTreeState.request_refresh_debounce(tracked, timer)
    assert pending.refresh.phase == {:debounced, timer, 0}
  end

  test "an admission retry keeps one correlated pending intent and advances backoff" do
    file_tree = open_tree("/tmp/minga-refresh-retry")
    first_timer = make_ref()
    second_timer = make_ref()

    assert {1, first} = FileTreeState.track_refresh_retry(file_tree, first_timer)
    assert first.refresh.phase == {:debounced, first_timer, 1}

    assert {:ready, _tree, 1, elapsed} =
             FileTreeState.refresh_debounce_elapsed(first, first_timer)

    assert {2, second} = FileTreeState.track_refresh_retry(elapsed, second_timer)
    assert second.refresh.phase == {:debounced, second_timer, 2}
  end

  test "refresh phase source transitions accept only intended source tags" do
    token = make_ref()
    request = make_ref()
    root = "/tmp/minga-refresh-source-phase"

    assert {:already_scheduled, %{phase: {:debounced, ^token, 0}}} =
             Refresh.request_debounce(%Refresh{phase: {:debounced, token, 4}}, make_ref())

    assert {:scheduled, %{phase: {:debounced, ^token, 0}}} =
             Refresh.request_debounce(
               %Refresh{phase: {:admitted, Path.expand(root), %{token: request}}},
               token
             )

    Enum.each([{:idle, 2}], fn phase ->
      assert {3, %Refresh{phase: {:debounced, ^token, 3}}} =
               Refresh.retry_debounce(%Refresh{phase: phase}, token)
    end)

    Enum.each(
      [{:debounced, token, 2}, {:admitted, Path.expand(root), %{token: request}}],
      fn phase ->
        assert_raise FunctionClauseError, fn ->
          Refresh.retry_debounce(%Refresh{phase: phase}, token)
        end
      end
    )

    assert %Refresh{phase: {:admitted, expanded_root, %{token: ^request}}} =
             Refresh.request_admitted(%Refresh{phase: {:idle, 2}}, root, request)

    assert expanded_root == Path.expand(root)

    Enum.each(
      [{:debounced, token, 2}, {:admitted, Path.expand(root), %{token: request}}],
      fn phase ->
        assert_raise FunctionClauseError, fn ->
          Refresh.request_admitted(%Refresh{phase: phase}, root, request)
        end
      end
    )
  end

  test "a current request atomically replaces the tree and clears correlation" do
    root = "/tmp/minga-refresh-current"
    original = open_tree(root)
    request = make_ref()
    refreshed = tree(root, [entry(root, "new.ex")])

    tracked = FileTreeState.track_refresh_request(original, root, request)

    assert {:accepted, accepted} =
             FileTreeState.accept_refresh_result(tracked, root, request, refreshed)

    assert FileTreeState.tree(accepted) == refreshed
    assert FileTreeState.content(accepted) == {:ready, refreshed}

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

    assert FileTreeState.tree(unchanged) == FileTreeState.tree(file_tree)

    assert {:accepted, accepted} =
             FileTreeState.accept_refresh_result(unchanged, root, current, refreshed)

    assert FileTreeState.tree(accepted) == refreshed
  end

  test "a matching request and tree root still require the current project root" do
    root = "/tmp/minga-refresh-project-root"
    other_root = "/tmp/minga-refresh-other-project"
    request = make_ref()

    file_tree =
      root
      |> open_tree()
      |> FileTreeState.track_refresh_request(root, request)
      |> FileTreeState.set_project_root(other_root)

    result = tree(root, [entry(root, "stale.ex")])

    assert {:rerooted, unchanged} =
             FileTreeState.accept_refresh_result(file_tree, root, request, result)

    assert FileTreeState.tree(unchanged) == FileTreeState.tree(file_tree)
    assert unchanged.project_root == Path.expand(other_root)
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

    assert FileTreeState.tree(unchanged) == nil

    reopened = FileTreeState.open(closed, tree(root, [entry(root, "current.ex")]), nil)
    old_result = tree(root, [entry(root, "old.ex")])

    assert {:stale, still_current} =
             FileTreeState.accept_refresh_result(reopened, root, request, old_result)

    assert Enum.map(FileTreeState.tree(still_current).entries, & &1.name) == ["current.ex"]
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

    assert Enum.map(FileTreeState.tree(current).entries, & &1.name) == ["current.ex"]
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

    assert FileTreeState.content(replaced) == {:error, "no such file or directory", metadata_tree}
    assert FileTreeState.status(replaced) == FileTreeState.status(file_tree)
    assert replaced.refresh == file_tree.refresh

    loading = root |> open_tree() |> FileTreeState.loading()
    loading_replaced = FileTreeState.replace_tree_metadata(loading, metadata_tree)
    assert FileTreeState.content(loading_replaced) == {:loading, metadata_tree}
  end

  test "hidden loaded content remains resident when refresh phase changes" do
    root = "/tmp/minga-refresh-hidden-resident"
    loaded = tree(root, [entry(root, "resident.ex")])
    timer = make_ref()

    hidden =
      %FileTreeState{}
      |> FileTreeState.open(loaded, nil)
      |> FileTreeState.hide()

    assert {:scheduled, pending} = FileTreeState.request_refresh_debounce(hidden, timer)
    assert FileTreeState.content(pending) == {:ready, loaded}
    assert FileTreeState.status(pending) == :hidden
    assert pending.refresh.phase == {:debounced, timer, 0}
  end

  test "failed and canceled terminals clear only the matching request" do
    root = "/tmp/minga-refresh-terminal"
    first = make_ref()
    second = make_ref()

    file_tree = open_tree(root) |> FileTreeState.track_refresh_request(root, first)
    original_content = FileTreeState.content(file_tree)
    assert {:stale, ^file_tree} = FileTreeState.finish_refresh(file_tree, root, second)
    assert {:current, finished} = FileTreeState.finish_refresh(file_tree, root, first)
    assert FileTreeState.content(finished) == original_content

    reusable = FileTreeState.track_refresh_request(finished, root, second)
    reusable_content = FileTreeState.content(reusable)
    assert {:current, finished_again} = FileTreeState.finish_refresh(reusable, root, second)
    assert FileTreeState.content(finished_again) == reusable_content
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
