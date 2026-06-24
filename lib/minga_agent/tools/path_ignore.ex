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
      {:ok, repo_root} ->
        paths_with_normalized =
          Enum.map(paths, fn path -> {path, normalize_result_path(repo_root, root, path)} end)

        ignored =
          git_ignored_relative_paths(repo_root, Enum.map(paths_with_normalized, &elem(&1, 1)))

        paths_with_normalized
        |> Enum.reject(fn {_path, normalized} ->
          ignored_path_name?(normalized) or MapSet.member?(ignored, normalized)
        end)
        |> Enum.map(&elem(&1, 0))

      :error ->
        Enum.reject(paths, &ignored_path_name?/1)
    end
  end

  @doc "Filters grep-style result lines using the path prefix before the line number."
  @spec filter_grep_lines(String.t(), [String.t()]) :: [String.t()]
  def filter_grep_lines(root, lines) when is_binary(root) and is_list(lines) do
    root = Path.expand(root)

    case git_root(root) do
      {:ok, repo_root} ->
        lines_with_paths =
          Enum.map(lines, fn line -> {line, grep_line_path(line)} end)

        normalized_paths =
          Enum.flat_map(lines_with_paths, fn
            {_line, nil} -> []
            {_line, path} -> [normalize_result_path(repo_root, root, path)]
          end)

        ignored = git_ignored_relative_paths(repo_root, normalized_paths)

        lines_with_paths
        |> Enum.reject(fn
          {_line, nil} -> false
          {_line, path} -> ignored_normalized_path?(repo_root, root, path, ignored)
        end)
        |> Enum.map(&elem(&1, 0))

      :error ->
        Enum.reject(lines, &(grep_line_path(&1) |> ignored_path_name?()))
    end
  end

  @spec reject_gitignored_children([String.t()], String.t()) :: [String.t()]
  defp reject_gitignored_children([], _dir), do: []

  defp reject_gitignored_children(names, dir) do
    case git_root(dir) do
      {:ok, root} ->
        names_with_rel_paths =
          Enum.map(names, fn name ->
            rel_path = dir |> Path.join(name) |> Path.relative_to(root)
            {name, rel_path}
          end)

        ignored = git_ignored_relative_paths(root, Enum.map(names_with_rel_paths, &elem(&1, 1)))

        names_with_rel_paths
        |> Enum.reject(fn {_name, rel_path} -> MapSet.member?(ignored, rel_path) end)
        |> Enum.map(&elem(&1, 0))

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

  @spec git_ignored_path?(String.t(), String.t()) :: boolean()
  defp git_ignored_path?(root, dir) do
    case Path.relative_to(dir, root) do
      "." -> false
      rel_path -> git_ignored_relative_path?(root, rel_path)
    end
  end

  @spec git_ignored_relative_path?(String.t(), String.t()) :: boolean()
  defp git_ignored_relative_path?(root, rel_path) do
    root
    |> git_ignored_relative_paths([rel_path])
    |> MapSet.member?(rel_path)
  end

  @spec git_ignored_relative_paths(String.t(), [String.t()]) :: MapSet.t(String.t())
  defp git_ignored_relative_paths(_root, []), do: MapSet.new()

  defp git_ignored_relative_paths(root, rel_paths) do
    rel_paths = rel_paths |> Enum.reject(&(&1 in ["", "."])) |> Enum.uniq()

    case rel_paths do
      [] ->
        MapSet.new()

      [_ | _] ->
        rel_paths
        |> Enum.chunk_every(100)
        |> Enum.reduce(MapSet.new(), &MapSet.union(&2, git_ignored_relative_path_batch(root, &1)))
    end
  rescue
    ErlangError -> MapSet.new(rel_paths)
  end

  @spec git_ignored_relative_path_batch(String.t(), [String.t()]) :: MapSet.t(String.t())
  defp git_ignored_relative_path_batch(root, rel_paths) do
    case System.cmd("git", ["-C", root, "check-ignore", "--"] ++ rel_paths) do
      {output, 0} -> output |> String.split("\n", trim: true) |> MapSet.new()
      {_output, 1} -> MapSet.new()
      {_output, _code} -> MapSet.new(rel_paths)
    end
  end

  @spec ignored_normalized_path?(String.t(), String.t(), String.t(), MapSet.t(String.t())) ::
          boolean()
  defp ignored_normalized_path?(repo_root, root, path, ignored) do
    normalized_path = normalize_result_path(repo_root, root, path)
    ignored_path_name?(normalized_path) or MapSet.member?(ignored, normalized_path)
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
