defmodule Minga.FileTree.GitStatus do
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
          {:ok, entries} ->
            entries
            |> entries_to_status_map(git_root)
            |> propagate_to_directories(root_path)

          {:error, _} ->
            %{}
        end

      :not_git ->
        %{}
    end
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
    if String.starts_with?(dir, root) do
      do_ancestor_dirs(Path.dirname(dir), root, [dir | acc])
    else
      acc
    end
  end
end
