defmodule MingaEditor.FileTree.Refresh.FilesystemScanner do
  @moduledoc "Filesystem scanner used by the typed file-tree refresh effect."

  @behaviour MingaEditor.FileTree.Refresh.Scanner

  alias Minga.Project.FileTree

  @impl true
  @spec scan(FileTree.t(), term()) :: FileTree.t() | {:error, {:root_unavailable, File.posix()}}
  def scan(%FileTree{} = tree, _context) do
    case FileTree.refresh_checked(tree) do
      {:ok, refreshed} -> refreshed
      {:error, reason} -> {:error, {:root_unavailable, reason}}
    end
  end
end
