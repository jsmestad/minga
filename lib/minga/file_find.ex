defmodule Minga.FileFind do
  @moduledoc """
  Discovers project files for the `SPC f f` (find file) picker.

  Uses the fastest available tool to list files in the project directory:

  1. `fd` — preferred, fast, respects `.gitignore`
  2. `git ls-files` — fast in git repos, respects `.gitignore`
  3. `find` — universally available fallback, slower, no gitignore support

  All paths are returned relative to the given root directory.
  """

  require Logger

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
    case detect_strategy(root) do
      :fd -> list_with_fd(root)
      :git -> list_with_git(root)
      :find -> list_with_find(root)
      :none -> {:error, "No file-finding tool available. Install `fd` or `git` for best results."}
    end
  end

  @doc """
  Detects which file-finding strategy to use for the given root directory.
  """
  @spec detect_strategy(String.t()) :: strategy()
  def detect_strategy(root) do
    cond do
      executable_available?("fd") -> :fd
      git_repo?(root) && executable_available?("git") -> :git
      executable_available?("find") -> :find
      true -> :none
    end
  end

  # ── Strategies ──────────────────────────────────────────────────────────────

  @spec list_with_fd(String.t()) :: result()
  defp list_with_fd(root) do
    args = ["--type", "f", "--hidden", "--follow", "--exclude", ".git", "."]

    case System.cmd("fd", args, cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, parse_lines(output)}

      {error, _code} ->
        Logger.warning("fd failed: #{error}")
        # Fall through to next strategy
        fallback_without_fd(root)
    end
  end

  @spec fallback_without_fd(String.t()) :: result()
  defp fallback_without_fd(root) do
    cond do
      git_repo?(root) && executable_available?("git") -> list_with_git(root)
      executable_available?("find") -> list_with_find(root)
      true -> {:error, "File listing failed and no fallback available."}
    end
  end

  @spec list_with_git(String.t()) :: result()
  defp list_with_git(root) do
    args = ["ls-files", "--cached", "--others", "--exclude-standard"]

    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, parse_lines(output)}

      {error, _code} ->
        Logger.warning("git ls-files failed: #{error}")

        if executable_available?("find") do
          list_with_find(root)
        else
          {:error, "git ls-files failed: #{error}"}
        end
    end
  end

  @spec list_with_find(String.t()) :: result()
  defp list_with_find(root) do
    args = [".", "-type", "f", "-not", "-path", "*/.git/*"]

    case System.cmd("find", args, cd: root, stderr_to_stdout: true) do
      {output, code} when code in [0, 1] ->
        # find may exit 1 with permission errors but still produce output
        {:ok, parse_lines(output)}

      {error, _code} ->
        {:error, "find failed: #{error}"}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

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

  @spec git_repo?(String.t()) :: boolean()
  defp git_repo?(root) do
    File.dir?(Path.join(root, ".git"))
  end
end
