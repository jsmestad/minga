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
        git_root
        |> run_porcelain()
        |> parse_porcelain(git_root)
        |> propagate_to_directories(root_path)

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

  @spec run_porcelain(String.t()) :: String.t()
  defp run_porcelain(git_root) do
    case System.cmd("git", ["status", "--porcelain=v1", "-uall"],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      _ -> ""
    end
  rescue
    _ -> ""
  end

  @spec parse_porcelain(String.t(), String.t()) :: status_map()
  defp parse_porcelain(output, git_root) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_status_line(line, git_root) do
        {path, status} -> merge_status(acc, path, status)
        nil -> acc
      end
    end)
  end

  @spec parse_status_line(String.t(), String.t()) :: {String.t(), file_status()} | nil
  defp parse_status_line(line, git_root) when byte_size(line) >= 4 do
    <<x::utf8, y::utf8, ?\s, rest::binary>> = line

    # For renames/copies, the path after " -> " is the current name
    path_str =
      case String.split(rest, " -> ") do
        [_, new_path] -> new_path
        _ -> rest
      end

    abs_path = Path.join(git_root, String.trim(path_str))
    status = classify(x, y)

    if status, do: {abs_path, status}, else: nil
  end

  defp parse_status_line(_line, _git_root), do: nil

  @spec classify(non_neg_integer(), non_neg_integer()) :: file_status() | nil
  # Both modified in index and worktree
  defp classify(?U, _), do: :conflict
  defp classify(_, ?U), do: :conflict
  defp classify(?D, ?D), do: :conflict
  defp classify(?A, ?A), do: :conflict

  # Untracked
  defp classify(??, ??), do: :untracked

  # Staged (index has changes, worktree clean)
  defp classify(x, ?\s) when x in [?A, ?M, ?D, ?R, ?C], do: :staged

  # Renamed
  defp classify(?R, _), do: :renamed

  # Deleted
  defp classify(?D, _), do: :deleted
  defp classify(?\s, ?D), do: :deleted

  # Modified in worktree
  defp classify(_, ?M), do: :modified
  defp classify(?M, _), do: :modified

  # Ignored or unknown
  defp classify(_, _), do: nil

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
