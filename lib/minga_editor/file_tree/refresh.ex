defmodule MingaEditor.FileTree.Refresh do
  @moduledoc """
  Async filesystem rescan for the open file tree (#2632).

  A burst of filesystem events debounces into one `:file_tree_refresh_timer`.
  When that timer fires the Editor must *not* run `FileTree.refresh/1` inline:
  the rescan does recursive `File.ls`/`File.lstat` per expanded directory and
  would block the Editor mailbox for all that I/O on projects with many
  expanded dirs.

  Instead the Editor spawns this Task. It captures the current tree, runs the
  filesystem rescan and the cached git-status refresh off the Editor process,
  then sends `{:file_tree_refresh_result, refreshed_tree, token}` back. The
  Editor applies the result with a cheap, atomic whole-tree swap and discards
  it if the user re-rooted or closed the tree while the walk was running (the
  `token` plus root comparison in `MingaEditor.FileTree.Freshness`).
  """

  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.Freshness

  @typedoc "Opaque token identifying one in-flight refresh; minted per spawn."
  @type token :: reference()

  @typedoc "The result message the Editor receives when a refresh Task finishes."
  @type result :: {:file_tree_refresh_result, FileTree.t(), token()}

  @doc """
  Spawns a supervised Task that rescans `tree` off the calling process.

  The Task runs `FileTree.refresh/1` (filesystem I/O) followed by the cached
  git-status refresh, then sends `{:file_tree_refresh_result, refreshed_tree,
  token}` to `reply_to`. Returns `:ok`. A crash in the Task is isolated by the
  supervisor; the Editor simply keeps its prior tree.
  """
  @spec start(FileTree.t(), token(), Minga.Events.registry(), pid()) :: :ok
  def start(%FileTree{} = tree, token, events_registry, reply_to)
      when is_reference(token) and is_pid(reply_to) do
    Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
      refreshed_tree =
        tree
        |> FileTree.refresh()
        |> Freshness.refresh_tree_git_status_from_cache(events_registry)

      send(reply_to, {:file_tree_refresh_result, refreshed_tree, token})
    end)

    :ok
  end
end
