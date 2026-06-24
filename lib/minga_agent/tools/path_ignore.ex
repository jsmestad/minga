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
                   ".npmrc",
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

  @env_prefix ".env"

  @doc "Returns true when a basename should be hidden from broad agent tools."
  @spec ignored_name?(String.t()) :: boolean()
  def ignored_name?(name) when is_binary(name) do
    MapSet.member?(@ignored_names, name) or String.starts_with?(name, @env_prefix)
  end

  @doc "Returns conservative basenames broad agent filesystem tools omit by default."
  @spec ignored_names() :: [String.t()]
  def ignored_names do
    @ignored_names
    |> MapSet.to_list()
    |> Kernel.++([".env*"])
    |> Enum.uniq()
  end

  @doc "Returns true when a directory itself is ignored by project rules."
  @spec ignored_directory?(String.t()) :: boolean()
  def ignored_directory?(dir) when is_binary(dir) do
    dir = Path.expand(dir)

    case git_root(dir) do
      {:ok, root} -> git_ignored_path?(root, dir)
      :error -> false
    end
  end

  @doc "Filters child entry names under `dir` using static and project ignore rules."
  @spec filter_child_names(String.t(), [String.t()]) :: [String.t()]
  def filter_child_names(dir, names) when is_binary(dir) and is_list(names) do
    dir = Path.expand(dir)

    if ignored_directory?(dir) do
      []
    else
      names
      |> Enum.reject(&ignored_name?/1)
      |> reject_gitignored_children(dir)
    end
  end

  @doc "Filters relative result paths using static and project ignore rules."
  @spec filter_paths(String.t(), [String.t()]) :: [String.t()]
  def filter_paths(root, paths) when is_binary(root) and is_list(paths) do
    root = Path.expand(root)

    case git_root(root) do
      {:ok, repo_root} -> Enum.reject(paths, &ignored_result_path?(repo_root, root, &1))
      :error -> Enum.reject(paths, &ignored_path_name?/1)
    end
  end

  @doc "Filters grep-style result lines using the path prefix before the line number."
  @spec filter_grep_lines(String.t(), [String.t()]) :: [String.t()]
  def filter_grep_lines(root, lines) when is_binary(root) and is_list(lines) do
    root = Path.expand(root)

    case git_root(root) do
      {:ok, repo_root} -> Enum.reject(lines, &ignored_grep_line?(repo_root, root, &1))
      :error -> Enum.reject(lines, &(grep_line_path(&1) |> ignored_path_name?()))
    end
  end

  @spec reject_gitignored_children([String.t()], String.t()) :: [String.t()]
  defp reject_gitignored_children([], _dir), do: []

  defp reject_gitignored_children(names, dir) do
    case git_root(dir) do
      {:ok, root} ->
        ignored = git_ignored_child_names(root, dir, names)
        Enum.reject(names, &MapSet.member?(ignored, &1))

      :error ->
        names
    end
  end

  @spec git_root(String.t()) :: {:ok, String.t()} | :error
  defp git_root(dir) do
    case System.cmd("git", ["-C", dir, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> {:ok, Path.expand(String.trim(root))}
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
    case System.cmd("git", ["-C", root, "check-ignore", "--", rel_path]) do
      {_output, 0} -> true
      {_output, _code} -> false
    end
  end

  @spec ignored_result_path?(String.t(), String.t(), String.t()) :: boolean()
  defp ignored_result_path?(repo_root, root, path) do
    normalized_path = normalize_result_path(repo_root, root, path)

    ignored_path_name?(normalized_path) or git_ignored_relative_path?(repo_root, normalized_path)
  end

  @spec ignored_grep_line?(String.t(), String.t(), String.t()) :: boolean()
  defp ignored_grep_line?(repo_root, root, line) do
    case grep_line_path(line) do
      nil -> false
      path -> ignored_result_path?(repo_root, root, path)
    end
  end

  @spec grep_line_path(String.t()) :: String.t() | nil
  defp grep_line_path(line) do
    case Regex.run(~r/^(.*?)([:\-])\d+\2/, line, capture: :all_but_first) do
      [path, _separator] -> path
      _ -> nil
    end
  end

  @spec normalize_result_path(String.t(), String.t(), String.t()) :: String.t()
  defp normalize_result_path(repo_root, root, path) do
    repo_root = Path.expand(repo_root)

    Path.join(root, path)
    |> Path.expand()
    |> Path.relative_to(repo_root)
  end

  @spec ignored_path_name?(String.t() | nil) :: boolean()
  defp ignored_path_name?(nil), do: false

  defp ignored_path_name?(path) do
    path
    |> Path.split()
    |> Enum.any?(&ignored_name?/1)
  end
end
