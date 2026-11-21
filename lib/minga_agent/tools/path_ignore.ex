defmodule MingaAgent.Tools.PathIgnore do
  @moduledoc """
  Shared ignore policy for broad agent filesystem tools.

  Prefer project ignore rules when a path is inside a git worktree, and keep a
  conservative generated-directory denylist for non-git directories or fallback
  tools that cannot evaluate ignore files themselves.
  """

  @typep git_root_result :: {:ok, String.t()} | :error

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

  @doc "Returns true when a path is hidden by static ignored segments or project rules."
  @spec ignored_path?(String.t()) :: boolean()
  def ignored_path?(path) when is_binary(path) do
    path = Path.expand(path)

    ignored_path?(path, git_root(path))
  end

  @doc "Filters a successful directory listing by basename, preserving the original entries."
  @spec filter_listing(String.t(), [entry], (entry -> String.t())) :: [entry] when entry: var
  def filter_listing(dir, [], _entry_name) when is_binary(dir), do: []

  def filter_listing(dir, entries, entry_name) when is_binary(dir) and is_list(entries) do
    dir = Path.expand(dir)
    root = git_root(dir)

    if ignored_path?(dir, root) do
      []
    else
      filter_listing_children(dir, root, entries, entry_name)
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

  @spec filter_listing_children(String.t(), git_root_result(), [entry], (entry -> String.t())) ::
          [entry]
        when entry: var
  defp filter_listing_children(_dir, :error, entries, entry_name) do
    Enum.reject(entries, &ignored_name?(entry_name.(&1)))
  end

  defp filter_listing_children(dir, {:ok, root}, entries, entry_name) do
    candidates =
      for entry <- entries, name = entry_name.(entry), not ignored_name?(name) do
        {entry, dir |> Path.join(name) |> Path.relative_to(root)}
      end

    ignored = git_ignored_relative_paths(root, Enum.map(candidates, &elem(&1, 1)))

    for {entry, rel_path} <- candidates, not MapSet.member?(ignored, rel_path), do: entry
  end

  @spec git_root(String.t()) :: git_root_result()
  defp git_root(path) do
    case nearest_existing_dir(path) do
      nil ->
        :error

      dir ->
        case System.cmd("git", ["-C", dir, "rev-parse", "--show-toplevel"],
               stderr_to_stdout: true
             ) do
          {root, 0} -> {:ok, Path.expand(String.trim(root))}
          {_output, _code} -> :error
        end
    end
  rescue
    ErlangError -> :error
  end

  @spec nearest_existing_dir(String.t()) :: String.t() | nil
  defp nearest_existing_dir(path) do
    if File.dir?(path) do
      path
    else
      nearest_existing_parent(path, Path.dirname(path))
    end
  end

  @spec nearest_existing_parent(String.t(), String.t()) :: String.t() | nil
  defp nearest_existing_parent(path, path), do: nil
  defp nearest_existing_parent(_path, parent), do: nearest_existing_dir(parent)

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

  @spec ignored_path?(String.t(), git_root_result()) :: boolean()
  defp ignored_path?(path, {:ok, root}) do
    relative_path = Path.relative_to(path, root)

    ignored_path_name?(relative_path) or
      (relative_path != "." and git_ignored_relative_path?(root, relative_path))
  end

  defp ignored_path?(path, :error) do
    path |> Path.relative_to(System.tmp_dir!()) |> ignored_path_name?()
  end

  @spec ignored_path_name?(String.t() | nil) :: boolean()
  defp ignored_path_name?(nil), do: false

  defp ignored_path_name?(path) do
    path
    |> Path.split()
    |> Enum.any?(&ignored_name?/1)
  end
end
