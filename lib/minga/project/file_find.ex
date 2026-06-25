defmodule Minga.Project.FileFind do
  @moduledoc """
  Discovers project files for the `SPC f f` (find file) picker.

  Uses the cheapest available tool to list files in the project directory:

  1. `git ls-files` — preferred inside git repos, reads the index instead of
     walking the filesystem, and respects `.gitignore`
  2. `fd` — preferred outside git repos, fast, respects `.gitignore`
  3. `find` — universally available fallback, slower, no gitignore support

  In a large monorepo the git index is far cheaper than a full filesystem
  walk, so git wins whenever the root is a git repository or worktree root
  (it has a `.git` entry). `fd` no longer follows symlinks, so symlinked or
  cyclic trees are never traversed.

  Because `git ls-files` reads the index, files inside git **submodules** appear
  only as their gitlink entry, not as individual files. This matches git's own
  view of the worktree; open the submodule directly to browse its files. (The
  previous `fd`-first behaviour walked into submodules.)

  All paths are returned relative to the given root directory.
  """

  @typedoc "A file discovery strategy."
  @type strategy :: :fd | :git | :find | :none

  @typedoc "Result of file discovery."
  @type result :: {:ok, [String.t()]} | {:error, String.t()}

  @doc """
  Lists all files under `root`, returning `{:ok, paths}` with paths relative
  to `root`, sorted alphabetically.

  Detects the best available tool automatically. Returns an error tuple if
  no suitable tool is found.
  """
  @spec list_files(String.t()) :: result()
  def list_files(root \\ File.cwd!()) do
    if File.dir?(root) do
      case detect_strategy(root) do
        :fd ->
          list_with_fd(root)

        :git ->
          list_with_git(root)

        :find ->
          list_with_find(root)

        :none ->
          {:error, "No file-finding tool available. Install `fd` or `git` for best results."}
      end
    else
      {:error, "Directory not found: #{root}"}
    end
  end

  @doc """
  Detects which file-finding strategy to use for the given root directory.

  Git repos prefer `:git` whenever `git` is available and `root` is a git
  repository or worktree root (it has a `.git` entry), since reading the index
  avoids traversing the filesystem. Otherwise `fd` is preferred, falling back
  to `find`.
  """
  @spec detect_strategy(String.t()) :: strategy()
  def detect_strategy(root) do
    detect_strategy(git_strategy_available?(root), root)
  end

  @spec detect_strategy(boolean(), String.t()) :: strategy()
  defp detect_strategy(true, _root), do: :git
  defp detect_strategy(false, root), do: detect_strategy_without_git(root)

  @spec detect_strategy_without_git(String.t()) :: strategy()
  defp detect_strategy_without_git(_root) do
    case fd_executable() do
      fd when is_binary(fd) -> :fd
      nil -> detect_find_strategy()
    end
  end

  @spec detect_find_strategy() :: strategy()
  defp detect_find_strategy do
    if executable_available?("find") do
      :find
    else
      :none
    end
  end

  # ── Strategies ──────────────────────────────────────────────────────────────

  @spec excludes() :: [String.t()]
  defp excludes, do: Minga.Config.get(:file_find_excludes)

  @doc """
  Builds the argument list for the `fd` file-discovery command.

  Symlinks are deliberately not followed (no `--follow`), so large or cyclic
  symlinked trees are never traversed. Configured excludes are passed through
  as `--exclude` pairs.
  """
  @spec fd_args([String.t()]) :: [String.t()]
  def fd_args(exclude_list \\ excludes()) do
    exclude_args = Enum.flat_map(exclude_list, &["--exclude", &1])
    ["--type", "f", "--hidden"] ++ Enum.concat(exclude_args, ["."])
  end

  @spec list_with_fd(String.t()) :: result()
  defp list_with_fd(root) do
    case System.cmd(fd_executable(), fd_args(), cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, parse_lines(output)}

      {error, _code} ->
        {:error, "fd failed: #{String.trim(error)}"}
    end
  end

  @spec list_with_git(String.t()) :: result()
  defp list_with_git(root) do
    args = ["ls-files", "--cached", "--others", "--exclude-standard"]

    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output |> parse_lines() |> filter_excludes()}

      {error, _code} ->
        {:error, "git ls-files failed: #{String.trim(error)}"}
    end
  end

  @spec list_with_find(String.t()) :: result()
  defp list_with_find(root) do
    exclude_args =
      Enum.flat_map(excludes(), &["-not", "-path", "*/#{&1}/*", "-not", "-name", &1])

    args = [".", "-type", "f"] ++ exclude_args

    case System.cmd("find", args, cd: root, stderr_to_stdout: true) do
      {output, code} when code in [0, 1] ->
        # find may exit 1 with permission errors but still produce output
        {:ok, parse_lines(output)}

      {error, _code} ->
        {:error, "find failed: #{error}"}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec filter_excludes([String.t()]) :: [String.t()]
  defp filter_excludes(paths) do
    excluded = MapSet.new(excludes())

    Enum.reject(paths, fn path ->
      path
      |> Path.split()
      |> Enum.any?(&MapSet.member?(excluded, &1))
    end)
  end

  @spec parse_lines(String.t()) :: [String.t()]
  defp parse_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&normalize_path/1)
    |> Enum.sort()
  end

  @spec normalize_path(String.t()) :: String.t()
  defp normalize_path("./" <> rest), do: rest
  defp normalize_path(path), do: path

  @spec executable_available?(String.t()) :: boolean()
  defp executable_available?(name) do
    System.find_executable(name) != nil
  end

  # Ubuntu's fd-find package installs the binary as `fdfind`.
  @spec fd_executable() :: String.t() | nil
  defp fd_executable do
    System.find_executable("fd") || System.find_executable("fdfind")
  end

  @spec git_strategy_available?(String.t()) :: boolean()
  defp git_strategy_available?(root) do
    executable_available?("git") and git_repo_root?(root)
  end

  # True when `root` is the top of a git repository or worktree, i.e. it has a
  # `.git` entry. Uses `File.exists?` (not `File.dir?`) because git worktrees
  # store `.git` as a *file* pointing at the real git dir.
  #
  # Deliberately does not walk up the tree (as `git rev-parse` would): the file
  # picker's root is the project root, and a non-repo directory that merely sits
  # *inside* a larger repo (e.g. an ignored build/tmp dir) should fall back to
  # `fd` rather than run `git ls-files`, which would list nothing for an ignored
  # subtree.
  @spec git_repo_root?(String.t()) :: boolean()
  defp git_repo_root?(root) do
    File.exists?(Path.join(root, ".git"))
  end
end
