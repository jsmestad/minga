defmodule MingaEditor.FileTree.FilterWalk do
  @moduledoc """
  Async filesystem walk for filtering a file tree whose root is NOT covered by
  the active project cache (#2377 AC4).

  The active project root filters in memory from `Minga.Project.files/0`, so this
  fallback only runs for other roots (e.g. a tree pointed at a subdirectory or a
  directory opened before project detection). The walk runs off the Editor
  process and its result is keyed by `(root, filter)`; the Editor drops the
  result if the user has since changed the filter or re-rooted the tree
  (stale-result dropping), so a slow walk can never clobber newer state.
  """

  alias Minga.Project.FileTree

  @typedoc "An async walk result tagged with the (root, filter) it was computed for."
  @type result ::
          {:file_tree_filter_walk, root :: String.t(), filter :: String.t(), [FileTree.entry()]}

  @doc """
  Spawns an unlinked walk that computes the filtered entries for `tree` and
  sends `{:file_tree_filter_walk, root, filter, entries}` back to `reply_to`.

  Returns `:ok`. The process is unlinked so a walk crash never takes down the
  Editor; a dropped result simply means the tree keeps its prior entries.
  """
  @spec start(FileTree.t(), pid()) :: :ok
  def start(%FileTree{root: root, filter: filter} = tree, reply_to)
      when is_binary(filter) and is_pid(reply_to) do
    {:ok, _pid} =
      Task.start(fn ->
        entries = FileTree.filtered_walk_entries(tree)
        send(reply_to, {:file_tree_filter_walk, root, filter, entries})
      end)

    :ok
  end

  @doc """
  Returns true when an async walk result still matches the tree's current
  `(root, filter)`. Stale results (the user changed the filter or re-rooted)
  return false and must be dropped.
  """
  @spec fresh?(FileTree.t(), String.t(), String.t()) :: boolean()
  def fresh?(%FileTree{root: root, filter: filter}, result_root, result_filter) do
    root == result_root and filter == result_filter
  end
end
