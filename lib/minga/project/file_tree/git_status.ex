defmodule Minga.Project.FileTree.GitStatus do
  @moduledoc """
  Computes git status for all files under a directory tree.

  Runs `git status --porcelain=v1` and parses the output into a map
  of `%{absolute_path => status_atom}`. Also propagates status up to
  parent directories so collapsed dirs show the "worst" child status.

  This module is pure (no GenServer). The caller is responsible for
  caching the result and refreshing it on save/git operations.
  """

  @typedoc "Git status for a single file."
  @type file_status :: :staged | :modified | :untracked | :conflict | :renamed | :deleted

  @typedoc "Status map keyed by absolute file path."
  @type status_map :: %{String.t() => file_status()}

  @doc """
  Computes git status for all files under `root_path`.

  Returns a status map with absolute paths as keys. If the path is not
  inside a git repo, returns an empty map. Directory entries are included
  with the "worst" status of any descendant.

  Runs asynchronously-friendly: no side effects, no process state.
  """
  @spec compute(String.t()) :: status_map()
  def compute(root_path) when is_binary(root_path) do
    case Minga.Git.root_for(root_path) do
      {:ok, git_root} ->
        case Minga.Git.status(git_root) do
          {:ok, entries} -> from_entries(entries, git_root, root_path)
          {:error, _} -> %{}
        end

      :not_git ->
        %{}
    end
  end

  @doc """
  Builds file-tree git status from an already-fetched git status event.

  This lets event handlers refresh badges without shelling out during render or recomputing status that `Minga.Git.Repo` already fetched.
  """
  @spec from_entries([Minga.Git.status_entry()], String.t(), String.t()) :: status_map()
  def from_entries(entries, git_root, root_path)
      when is_list(entries) and is_binary(git_root) and is_binary(root_path) do
    entries
    |> entries_to_status_map(git_root)
    |> filter_under_root(root_path)
    |> propagate_to_directories(root_path)
  end

  @doc """
  Returns the display symbol for a git status.
  """
  @spec symbol(file_status()) :: String.t()
  def symbol(:modified), do: "●"
  def symbol(:staged), do: "✚"
  def symbol(:untracked), do: "?"
  def symbol(:conflict), do: "!"
  def symbol(:renamed), do: "R"
  def symbol(:deleted), do: "D"

  @doc """
  Returns the severity rank for a status (higher = more urgent).
  Used for directory propagation: the "worst" child status wins.
  """
  @spec severity(file_status()) :: non_neg_integer()
  def severity(:untracked), do: 1
  def severity(:staged), do: 2
  def severity(:renamed), do: 3
  def severity(:deleted), do: 4
  def severity(:modified), do: 5
  def severity(:conflict), do: 6

  # ── Private ────────────────────────────────────────────────────────────────

  @spec entries_to_status_map([Minga.Git.status_entry()], String.t()) :: status_map()
  defp entries_to_status_map(entries, git_root) do
    Enum.reduce(entries, %{}, fn %{path: path, status: status, staged: staged}, acc ->
      abs_path = Path.join(git_root, path)
      file_status = entry_to_file_status(status, staged)
      merge_status(acc, abs_path, file_status)
    end)
  end

  @spec entry_to_file_status(atom(), boolean()) :: file_status()
  defp entry_to_file_status(:conflict, _), do: :conflict
  defp entry_to_file_status(:added, true), do: :staged
  defp entry_to_file_status(:modified, true), do: :staged
  defp entry_to_file_status(:deleted, true), do: :staged
  defp entry_to_file_status(:renamed, _), do: :renamed
  defp entry_to_file_status(:copied, _), do: :staged
  defp entry_to_file_status(:untracked, _), do: :untracked
  defp entry_to_file_status(:modified, false), do: :modified
  defp entry_to_file_status(:deleted, false), do: :deleted
  defp entry_to_file_status(_, _), do: :untracked

  @spec merge_status(status_map(), String.t(), file_status()) :: status_map()
  defp merge_status(acc, path, new_status) do
    Map.update(acc, path, new_status, fn existing ->
      if severity(new_status) > severity(existing), do: new_status, else: existing
    end)
  end

  @spec filter_under_root(status_map(), String.t()) :: status_map()
  defp filter_under_root(file_statuses, root_path) do
    expanded_root = Path.expand(root_path)

    Map.filter(file_statuses, fn {path, _status} ->
      path |> Path.expand() |> path_under_root?(expanded_root)
    end)
  end

  @spec propagate_to_directories(status_map(), String.t()) :: status_map()
  defp propagate_to_directories(file_statuses, root_path) do
    expanded_root = Path.expand(root_path)

    Enum.reduce(file_statuses, file_statuses, fn {file_path, status}, acc ->
      file_path
      |> ancestor_dirs(expanded_root)
      |> Enum.reduce(acc, fn dir, inner_acc ->
        merge_status(inner_acc, dir, status)
      end)
    end)
  end

  @spec ancestor_dirs(String.t(), String.t()) :: [String.t()]
  defp ancestor_dirs(path, root) do
    do_ancestor_dirs(Path.dirname(path), root, [])
  end

  @spec do_ancestor_dirs(String.t(), String.t(), [String.t()]) :: [String.t()]
  defp do_ancestor_dirs(dir, root, acc) when dir == root, do: acc

  defp do_ancestor_dirs(dir, root, acc) do
    if path_under_root?(dir, root) do
      do_ancestor_dirs(Path.dirname(dir), root, [dir | acc])
    else
      acc
    end
  end

  @spec path_under_root?(String.t(), String.t()) :: boolean()
  defp path_under_root?(path, root) do
    path == root or String.starts_with?(path, path_prefix(root))
  end

  @spec path_prefix(String.t()) :: String.t()
  defp path_prefix("/"), do: "/"
  defp path_prefix(root), do: root <> "/"
end
