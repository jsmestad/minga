defmodule MingaEditor.FileTree.ProjectCache do
  @moduledoc """
  Bridges the editor file tree to the project's background-rebuilt file cache
  (#2377).

  `Minga.Project` owns one atomic typed workspace snapshot. File-tree effects
  read that value once in scheduler workers and derive an immutable tree-root
  cache value before pure state transitions. The state owner never calls this
  service, and no second discovery or scheduling workflow is introduced here.
  """

  alias Minga.Project.Root
  alias Minga.Project.WorkspaceSnapshot
  alias MingaEditor.FileTree.ProjectCache.Snapshot

  @doc "Reads and derives all cache inputs for one tree root from one Project call."
  @spec snapshot(String.t(), GenServer.server()) :: Snapshot.t()
  def snapshot(root, project_server \\ Minga.Project) when is_binary(root) do
    expanded_root = Path.expand(root)
    workspace = Minga.Project.snapshot(project_server)
    tree_snapshot(expanded_root, workspace)
  catch
    :exit, _ -> Snapshot.new(Path.expand(root), false, [], false)
  end

  @spec tree_snapshot(String.t(), WorkspaceSnapshot.t() | nil) :: Snapshot.t()
  defp tree_snapshot(root, nil), do: Snapshot.new(root, false, [], false)

  defp tree_snapshot(
         root,
         %WorkspaceSnapshot{
           root: %Root{path: active_root},
           files: files,
           rebuilding?: rebuilding?
         }
       ) do
    tree_snapshot(root, files, rebuilding?, Path.expand(active_root) == root)
  end

  @spec tree_snapshot(String.t(), [String.t()], boolean(), boolean()) :: Snapshot.t()
  defp tree_snapshot(root, files, rebuilding?, true),
    do: Snapshot.new(root, true, files, rebuilding?)

  defp tree_snapshot(root, _files, _rebuilding?, false),
    do: Snapshot.new(root, false, [], false)
end
