defmodule MingaEditor.FileTree.ProjectCache do
  @moduledoc """
  Bridges the editor file tree to the project's background-rebuilt file cache
  (#2377).

  `Minga.Project` keeps a flat list of project-relative paths that it rebuilds in
  the background. When a tree (or picker) root is the active project root, the
  picker and the filtered tree read this cache instead of doing filesystem I/O on
  the editor path. This module centralizes the "is this the active project root?"
  decision and the cache reads, with `:exit` guards so callers work even when the
  Project GenServer is unavailable (early startup, tests).

  File-tree effects use `snapshot/1` in scheduler workers and pass the immutable
  value into pure state transitions. The state owner never calls this service.
  """

  alias MingaEditor.FileTree.ProjectCache.Snapshot

  @doc "Returns true when `root` expands to the active project root."
  @spec active_root?(String.t()) :: boolean()
  def active_root?(root) when is_binary(root) do
    case active_root() do
      active when is_binary(active) -> Path.expand(active) == Path.expand(root)
      _ -> false
    end
  end

  @doc "Returns the active project root, or nil when none is set or the process is down."
  @spec active_root() :: String.t() | nil
  def active_root do
    Minga.Project.root()
  catch
    :exit, _ -> nil
  end

  @doc "Returns the project's cached relative-path list (empty while rebuilding or unavailable)."
  @spec files() :: [String.t()]
  def files do
    Minga.Project.files()
  catch
    :exit, _ -> []
  end

  @doc "Returns true while the project's file cache is rebuilding."
  @spec rebuilding?() :: boolean()
  def rebuilding? do
    Minga.Project.rebuilding?()
  catch
    :exit, _ -> false
  end

  @doc "Reads all project-cache inputs needed to filter one root as an immutable value."
  @spec snapshot(String.t()) :: Snapshot.t()
  def snapshot(root) when is_binary(root) do
    expanded_root = Path.expand(root)
    active? = active_root?(expanded_root)

    if active? do
      Snapshot.new(expanded_root, true, files(), rebuilding?())
    else
      Snapshot.new(expanded_root, false, [], false)
    end
  end
end
