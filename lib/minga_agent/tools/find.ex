defmodule MingaAgent.Tools.Find do
  @moduledoc """
  Structured file discovery tool for the native agent provider.

  Prefers `fd` if available on the system, falls back to `find`.
  Output is a sorted list of matching paths relative to the search
  directory, truncated at a configurable limit.
  """

  alias MingaAgent.Tools.DirectoryListing
  alias MingaAgent.Tools.OutputLimit
  alias MingaAgent.Tools.PathIgnore

  @max_results 200
  @max_output_bytes OutputLimit.default_max_bytes()

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
      if ignored_search_root?(path),
        do: {:ok, "No matches found."},
        else: do_execute(pattern, path, opts)
    else
      {:error, "Directory does not exist: #{path}"}
    end
  end

  @spec ignored_search_root?(String.t()) :: boolean()
  defp ignored_search_root?(path) do
    PathIgnore.ignored_name?(Path.basename(Path.expand(path))) or
      PathIgnore.ignored_directory?(path)
  end

  @spec do_execute(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defp do_execute(pattern, path, opts) do
    type = Map.get(opts, "type", "file")
    max_depth = Map.get(opts, "max_depth", 10)
    filter_root = Map.get(opts, "_filter_root", path)

    {cmd, args} = build_command(pattern, path, type, max_depth)

    case OutputLimit.collect_command(cmd, args,
           cd: path,
           stderr_to_stdout: true,
           max_bytes: @max_output_bytes
         ) do
      {output, 0, truncated?} ->
        {:ok, format_output(filter_root, output, truncated?)}

      {output, 1, truncated?} ->
        # Exit code 1 means no matches for fd/find
        {:ok, format_output(filter_root, output, truncated?)}

      {output, _code, _truncated?} ->
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
    args = args ++ fd_ignore_args()

    args =
      case type do
        "file" -> args ++ ["--type", "f"]
        "directory" -> args ++ ["--type", "d"]
        _ -> args
      end

    args = args ++ ["--max-results", Integer.to_string(@max_results + 1), pattern, "."]
    {fd, args}
  end

  @spec build_find_command(String.t(), String.t(), non_neg_integer()) ::
          {String.t(), [String.t()]}
  defp build_find_command(pattern, type, max_depth) do
    find = System.find_executable("find") || "find"

    args = [".", "-maxdepth", Integer.to_string(max_depth)]
    args = args ++ find_prune_args()

    args =
      case type do
        "file" -> args ++ ["-type", "f"]
        "directory" -> args ++ ["-type", "d"]
        _ -> args
      end

    args = args ++ ["-name", pattern, "-print"]
    {find, args}
  end

  @spec fd_ignore_args() :: [String.t()]
  defp fd_ignore_args do
    Enum.flat_map(DirectoryListing.ignored_names(), fn name -> ["--exclude", name] end)
  end

  @spec find_prune_args() :: [String.t()]
  defp find_prune_args do
    ignored_names = DirectoryListing.ignored_names()

    ["("] ++ find_name_expression(ignored_names) ++ [")", "-prune", "-o"]
  end

  @spec find_name_expression([String.t()]) :: [String.t()]
  defp find_name_expression([name]), do: ["-name", name]

  defp find_name_expression([name | rest]) do
    ["-name", name, "-o"] ++ find_name_expression(rest)
  end

  @spec format_output(String.t(), String.t(), boolean()) :: String.t()
  defp format_output(root, output, command_truncated?) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> then(&PathIgnore.filter_paths(root, &1))
      |> Enum.sort()

    if lines == [] do
      "No matches found."
    else
      lines
      |> bounded_lines(command_truncated?)
      |> OutputLimit.truncate_utf8(
        @max_output_bytes,
        "\n\n... (truncated at #{div(@max_output_bytes, 1000)}KB, refine the pattern or path for fewer results)"
      )
    end
  end

  @spec bounded_lines([String.t()], boolean()) :: String.t()
  defp bounded_lines(lines, command_truncated?) do
    marker =
      if command_truncated?,
        do:
          "\n\n... (truncated at #{div(@max_output_bytes, 1000)}KB, refine the pattern or path for fewer results)",
        else: ""

    if length(lines) > @max_results do
      truncated = Enum.take(lines, @max_results) |> Enum.join("\n")
      truncated <> "\n\n... (truncated, refine the pattern or path for fewer results)" <> marker
    else
      Enum.join(lines, "\n") <> marker
    end
  end
end
