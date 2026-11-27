defmodule Minga.Git.Metadata do
  @moduledoc "Resolves the physical file and metadata paths used by Git."

  alias Minga.Project.Root

  @doc "Resolves a worktree's `.git` directory or its `gitdir` pointer file."
  @spec directory(String.t()) :: String.t()
  def directory(root) do
    dot_git = Path.join(root, ".git")

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= 4_096 <- File.stat(dot_git),
         {:ok, "gitdir: " <> path} <- File.read(dot_git),
         relative when relative != "" <- String.trim(path) do
      Path.expand(relative, root)
    else
      _not_linked -> dot_git
    end
  end

  @doc "Resolves a regular file or a missing file under a resolvable parent."
  @spec file_target(String.t()) :: String.t() | nil
  def file_target(path) do
    case Root.canonical_path(path) do
      {:ok, target} ->
        if File.regular?(target), do: target

      {:error, :enoent} ->
        # A dangling link is not a missing file at the same path.
        path = Path.expand(path)

        with {:error, :enoent} <- File.lstat(path),
             {:ok, parent} <- Root.canonical_path(Path.dirname(path)) do
          Path.join(parent, Path.basename(path))
        else
          _ -> nil
        end

      {:error, _reason} ->
        nil
    end
  end
end
