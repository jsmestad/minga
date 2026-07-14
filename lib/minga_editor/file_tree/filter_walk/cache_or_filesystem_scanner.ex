defmodule MingaEditor.FileTree.FilterWalk.CacheOrFilesystemScanner do
  @moduledoc "Production filter scanner that prefers the project cache and otherwise walks disk."

  @behaviour MingaEditor.FileTree.FilterWalk.Scanner

  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.FilterWalk.Result
  alias MingaEditor.FileTree.ProjectCache
  alias MingaEditor.FileTree.ProjectCache.Snapshot

  @impl true
  @spec scan(FileTree.t(), Snapshot.t() | nil) :: Result.t()
  def scan(%FileTree{root: root} = tree, nil) do
    scan_with_snapshot(tree, ProjectCache.snapshot(root))
  end

  def scan(%FileTree{} = tree, %Snapshot{} = snapshot), do: scan_with_snapshot(tree, snapshot)

  @spec scan_with_snapshot(FileTree.t(), Snapshot.t()) :: Result.t()
  defp scan_with_snapshot(
         %FileTree{root: root, filter: filter} = tree,
         %Snapshot{} = snapshot
       )
       when is_binary(filter) do
    if snapshot.active? and Path.expand(snapshot.root) == Path.expand(root) do
      entries =
        tree
        |> FileTree.put_cached_files(snapshot.files)
        |> FileTree.set_filter(filter)
        |> FileTree.visible_entries()

      Result.project_cache(root, filter, entries, snapshot)
    else
      Result.filesystem(root, filter, FileTree.filtered_walk_entries(tree))
    end
  end
end
