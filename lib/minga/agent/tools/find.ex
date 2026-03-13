defmodule Minga.Agent.Tools.Find do
  @moduledoc """
  Structured file discovery tool for the native agent provider.

  Prefers `fd` if available on the system, falls back to `find`.
  Output is a sorted list of matching paths relative to the search
  directory, truncated at a configurable limit.
  """

  @max_results 200

  @doc """
  Searches for files matching `pattern` under `path`.

  Options:
  - `type` — `"file"`, `"directory"`, or `"any"` (default: `"file"`)
  - `max_depth` — maximum directory depth (default: 10)

  Returns a sorted list of matching paths, one per line.
  """
  @spec execute(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(pattern, path, opts \\ %{}) when is_binary(pattern) and is_binary(path) do
    if File.dir?(path) do
      do_execute(pattern, path, opts)
    else
      {:error, "Directory does not exist: #{path}"}
    end
  end

  @spec do_execute(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defp do_execute(pattern, path, opts) do
    type = Map.get(opts, "type", "file")
    max_depth = Map.get(opts, "max_depth", 10)

    {cmd, args} = build_command(pattern, path, type, max_depth)

    case System.cmd(cmd, args, stderr_to_stdout: true, cd: path) do
      {output, 0} ->
        if String.trim(output) == "" do
          {:ok, "No matches found."}
        else
          {:ok, format_output(output)}
        end

      {output, 1} ->
        # Exit code 1 means no matches for fd/find
        trimmed = String.trim(output)

        if trimmed == "" do
          {:ok, "No matches found."}
        else
          {:ok, format_output(output)}
        end

      {output, _code} ->
        {:error, "Find failed: #{String.trim(output)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "Find command not found: #{Exception.message(e)}"}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec build_command(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {String.t(), [String.t()]}
  defp build_command(pattern, _path, type, max_depth) do
    case System.find_executable("fd") do
      nil -> build_find_command(pattern, type, max_depth)
      fd -> build_fd_command(fd, pattern, type, max_depth)
    end
  end

  @spec build_fd_command(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {String.t(), [String.t()]}
  defp build_fd_command(fd, pattern, type, max_depth) do
    args = ["--color", "never", "--glob", "--max-depth", Integer.to_string(max_depth)]

    args =
      case type do
        "file" -> args ++ ["--type", "f"]
        "directory" -> args ++ ["--type", "d"]
        _ -> args
      end

    args = args ++ ["--max-results", Integer.to_string(@max_results), pattern, "."]
    {fd, args}
  end

  @spec build_find_command(String.t(), String.t(), non_neg_integer()) ::
          {String.t(), [String.t()]}
  defp build_find_command(pattern, type, max_depth) do
    find = System.find_executable("find") || "find"

    args = [".", "-maxdepth", Integer.to_string(max_depth)]

    args =
      case type do
        "file" -> args ++ ["-type", "f"]
        "directory" -> args ++ ["-type", "d"]
        _ -> args
      end

    # Use -name for glob matching
    args = args ++ ["-name", pattern]
    {find, args}
  end

  @spec format_output(String.t()) :: String.t()
  defp format_output(output) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.sort()

    if length(lines) > @max_results do
      truncated = Enum.take(lines, @max_results) |> Enum.join("\n")
      truncated <> "\n\n... (truncated, #{length(lines) - @max_results} more results)"
    else
      Enum.join(lines, "\n")
    end
  end
end
