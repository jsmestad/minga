defmodule MingaAgent.Tools.PathIgnore do
  @moduledoc """
  Shared ignore policy for broad agent filesystem tools.

  Prefer project ignore rules when a path is inside a git worktree, and keep a
  conservative generated-directory denylist for non-git directories or fallback
  tools that cannot evaluate ignore files themselves.
  """

  @ignored_names MapSet.new([
                   ".build",
                   ".elixir_ls",
                   ".env",
                   ".envrc",
                   ".expert",
                   ".git",
                   ".mypy_cache",
                   ".next",
                   ".pytest_cache",
                   ".ruff_cache",
                   ".terraform",
                   ".venv",
                   "DerivedData",
                   "_build",
                   "burrito_out",
                   "cover",
                   "deps",
                   "dist",
                   "node_modules",
                   "tmp"
                 ])

  @doc "Returns true when a basename should be hidden from broad agent tools."
  @spec ignored_name?(String.t()) :: boolean()
  def ignored_name?(name) when is_binary(name), do: MapSet.member?(@ignored_names, name)

  @doc "Returns conservative basenames broad agent filesystem tools omit by default."
  @spec ignored_names() :: [String.t()]
  def ignored_names, do: MapSet.to_list(@ignored_names)

  @doc "Filters child entry names under `dir` using static and project ignore rules."
  @spec filter_child_names(String.t(), [String.t()]) :: [String.t()]
  def filter_child_names(dir, names) when is_binary(dir) and is_list(names) do
    names
    |> Enum.reject(&ignored_name?/1)
    |> reject_gitignored_children(dir)
  end

  @spec reject_gitignored_children([String.t()], String.t()) :: [String.t()]
  defp reject_gitignored_children([], _dir), do: []

  defp reject_gitignored_children(names, dir) do
    case git_root(dir) do
      {:ok, root} ->
        if git_ignored_path?(root, dir) do
          names
        else
          ignored = git_ignored_child_names(root, dir, names)
          Enum.reject(names, &MapSet.member?(ignored, &1))
        end

      :error ->
        names
    end
  end

  @spec git_root(String.t()) :: {:ok, String.t()} | :error
  defp git_root(dir) do
    case System.cmd("git", ["-C", dir, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> {:ok, String.trim(root)}
      {_output, _code} -> :error
    end
  rescue
    ErlangError -> :error
  end

  @spec git_ignored_child_names(String.t(), String.t(), [String.t()]) :: MapSet.t(String.t())
  defp git_ignored_child_names(root, dir, names) do
    names
    |> Enum.filter(&git_ignored_child?(root, dir, &1))
    |> MapSet.new()
  rescue
    ErlangError -> MapSet.new()
  end

  @spec git_ignored_child?(String.t(), String.t(), String.t()) :: boolean()
  defp git_ignored_child?(root, dir, name) do
    rel_path =
      dir
      |> Path.join(name)
      |> Path.relative_to(root)

    git_ignored_relative_path?(root, rel_path)
  end

  @spec git_ignored_path?(String.t(), String.t()) :: boolean()
  defp git_ignored_path?(root, dir) do
    case Path.relative_to(dir, root) do
      "." -> false
      rel_path -> git_ignored_relative_path?(root, rel_path)
    end
  end

  @spec git_ignored_relative_path?(String.t(), String.t()) :: boolean()
  defp git_ignored_relative_path?(root, rel_path) do
    case System.cmd("git", ["-C", root, "check-ignore", rel_path]) do
      {_output, 0} -> true
      {_output, _code} -> false
    end
  end
end
