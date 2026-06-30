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
  @type result ::
          {:file_tree_refresh_result, FileTree.t(), token()}
          | {:file_tree_refresh_failed, token()}

  @doc """
  Spawns a supervised Task that rescans `tree` off the calling process.

  The Task runs `FileTree.refresh/1` (filesystem I/O) followed by the cached
  git-status refresh, then sends `{:file_tree_refresh_result, refreshed_tree,
  token}` to `reply_to`.

  The Task body is wrapped in `try/rescue/catch` so it *always* replies, even
  when the filesystem walk or git-status decode raises or throws. On failure it
  sends `{:file_tree_refresh_failed, token}` so the Editor can clear its
  in-flight tracking and honour a coalesced refresh; the in-flight flag is never
  left stuck (which would otherwise wedge all future refreshes, since the
  coalescing path never spawns while one is "in flight").

  Returns `:ok` when the Task was spawned, or `{:error, reason}` when the
  supervisor refused (e.g. max children); the caller clears in-flight so a later
  timer can retry rather than wedging.
  """
  @spec start(FileTree.t(), token(), Minga.Events.registry(), pid()) :: :ok | {:error, term()}
  def start(%FileTree{} = tree, token, events_registry, reply_to)
      when is_reference(token) and is_pid(reply_to) do
    case Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
           run(tree, token, events_registry, reply_to)
         end) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs the rescan and ALWAYS sends a reply, converting any raise/throw/exit
  # into a failure sentinel so the Editor's in-flight flag is always cleared.
  @spec run(FileTree.t(), token(), Minga.Events.registry(), pid()) :: :ok
  defp run(tree, token, events_registry, reply_to) do
    message =
      try do
        refreshed_tree =
          tree
          |> FileTree.refresh()
          |> Freshness.refresh_tree_git_status_from_cache(events_registry)

        {:file_tree_refresh_result, refreshed_tree, token}
      rescue
        e ->
          Minga.Log.warning(:editor, "File tree refresh failed: #{Exception.message(e)}")
          {:file_tree_refresh_failed, token}
      catch
        kind, reason ->
          Minga.Log.warning(:editor, "File tree refresh #{kind}: #{inspect(reason)}")
          {:file_tree_refresh_failed, token}
      end

    send(reply_to, message)
    :ok
  end
end
