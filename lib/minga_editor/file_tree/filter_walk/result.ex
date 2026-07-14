defmodule MingaEditor.FileTree.FilterWalk.Result do
  @moduledoc "Typed immutable result of one scheduled file-tree filter scan."

  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.ProjectCache.Snapshot

  @enforce_keys [:root, :filter, :source, :entries]
  defstruct [:root, :filter, :source, :entries, :project_cache]

  @type source :: :filesystem | :project_cache

  @type t :: %__MODULE__{
          root: String.t(),
          filter: String.t(),
          source: source(),
          entries: [FileTree.entry()],
          project_cache: Snapshot.t() | nil
        }

  @doc "Builds a filesystem-backed filter result."
  @spec filesystem(String.t(), String.t(), [FileTree.entry()]) :: t()
  def filesystem(root, filter, entries)
      when is_binary(root) and is_binary(filter) and is_list(entries) do
    %__MODULE__{
      root: Path.expand(root),
      filter: filter,
      source: :filesystem,
      entries: entries
    }
  end

  @doc "Builds a project-cache-backed filter result with final materialized entries."
  @spec project_cache(String.t(), String.t(), [FileTree.entry()], Snapshot.t()) :: t()
  def project_cache(root, filter, entries, %Snapshot{} = snapshot)
      when is_binary(root) and is_binary(filter) and is_list(entries) do
    %__MODULE__{
      root: Path.expand(root),
      filter: filter,
      source: :project_cache,
      entries: entries,
      project_cache: snapshot
    }
  end
end
