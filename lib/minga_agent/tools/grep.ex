defmodule MingaAgent.Tools.Grep do
  @moduledoc """
  Structured file content search tool for the native agent provider.

  Prefers `rg` (ripgrep) if available on the system, falls back to
  `grep -rn`. Output is structured as `path:line:content` and truncated
  at a configurable match limit to avoid flooding the context window.
  """

  alias MingaAgent.Tools.DirectoryListing
  alias MingaAgent.Tools.OutputLimit
  alias MingaAgent.Tools.PathIgnore

  @max_matches 100
  @max_output_bytes OutputLimit.default_max_bytes()

  @doc """
  Searches for `pattern` in files under `path`.

  Options:
  - `glob` — file pattern filter (e.g. `"*.ex"`)
  - `case_sensitive` — whether the search is case-sensitive (default: true)
  - `context_lines` — number of context lines around each match (default: 0)

  Returns structured output with file path, line number, and matching line.
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
    glob = Map.get(opts, "glob")
    case_sensitive = Map.get(opts, "case_sensitive", true)
    context_lines = Map.get(opts, "context_lines", 0)
    filter_root = Map.get(opts, "_filter_root", path)

    {cmd, args} = build_command(pattern, path, glob, case_sensitive, context_lines)

    case OutputLimit.collect_command(cmd, args,
           cd: path,
           stderr_to_stdout: true,
           max_bytes: @max_output_bytes
         ) do
      {output, 0, truncated?} ->
        {:ok, truncate_output(filter_root, output, truncated?)}

      {output, 1, truncated?} ->
        # Exit code 1 means no matches (for both grep and rg)
        if String.trim(output) == "" do
          {:ok, "No matches found."}
        else
          {:ok, truncate_output(filter_root, output, truncated?)}
        end

      {output, _code, _truncated?} ->
        {:error, "Search failed: #{String.trim(output)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "Search command not found: #{Exception.message(e)}"}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec build_command(String.t(), String.t(), String.t() | nil, boolean(), non_neg_integer()) ::
          {String.t(), [String.t()]}
  defp build_command(pattern, _path, glob, case_sensitive, context_lines) do
    case System.find_executable("rg") do
      nil -> build_grep_command(pattern, glob, case_sensitive, context_lines)
      rg -> build_rg_command(rg, pattern, glob, case_sensitive, context_lines)
    end
  end

  @spec build_rg_command(String.t(), String.t(), String.t() | nil, boolean(), non_neg_integer()) ::
          {String.t(), [String.t()]}
  defp build_rg_command(rg, pattern, glob, case_sensitive, context_lines) do
    args = ["--no-heading", "--line-number", "--color", "never"]
    args = if case_sensitive, do: args, else: args ++ ["--ignore-case"]

    args =
      if context_lines > 0,
        do: args ++ ["--context", Integer.to_string(context_lines)],
        else: args

    args = if glob, do: args ++ ["--glob", glob], else: args
    args = args ++ rg_ignore_args()
    args = args ++ ["--max-count", Integer.to_string(@max_matches), pattern, "."]
    {rg, args}
  end

  @spec build_grep_command(String.t(), String.t() | nil, boolean(), non_neg_integer()) ::
          {String.t(), [String.t()]}
  defp build_grep_command(pattern, glob, case_sensitive, context_lines) do
    grep = System.find_executable("grep") || "grep"
    args = ["-rn", "-I"]
    args = if case_sensitive, do: args, else: args ++ ["-i"]
    args = if context_lines > 0, do: args ++ ["-C", Integer.to_string(context_lines)], else: args
    args = if glob, do: args ++ ["--include", glob], else: args
    args = args ++ grep_ignore_args()
    args = args ++ [pattern, "."]
    {grep, args}
  end

  @spec rg_ignore_args() :: [String.t()]
  defp rg_ignore_args do
    Enum.flat_map(DirectoryListing.ignored_names(), fn name ->
      ["--glob", "!#{name}", "--glob", "!#{name}/**"]
    end)
  end

  @spec grep_ignore_args() :: [String.t()]
  defp grep_ignore_args do
    Enum.flat_map(DirectoryListing.ignored_names(), fn name ->
      ["--exclude", name, "--exclude-dir", name]
    end)
  end

  @spec truncate_output(String.t(), String.t(), boolean()) :: String.t()
  defp truncate_output(root, output, command_truncated?) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> then(&PathIgnore.filter_grep_lines(root, &1))

    if Enum.any?(lines, &grep_result_line?/1) do
      lines
      |> bounded_lines(command_truncated?)
      |> OutputLimit.truncate_utf8(
        @max_output_bytes,
        "\n\n... (truncated at #{div(@max_output_bytes, 1000)}KB, refine the pattern or path for fewer results)"
      )
    else
      "No matches found."
    end
  end

  @spec bounded_lines([String.t()], boolean()) :: String.t()
  defp bounded_lines(lines, command_truncated?) do
    marker =
      if command_truncated?,
        do:
          "\n\n... (truncated at #{div(@max_output_bytes, 1000)}KB, refine the pattern or path for fewer results)",
        else: ""

    if length(lines) > @max_matches do
      truncated = Enum.take(lines, @max_matches) |> Enum.join("\n")
      truncated <> "\n\n... (truncated, #{length(lines) - @max_matches} more lines)" <> marker
    else
      Enum.join(lines, "\n") <> marker
    end
  end

  @spec grep_result_line?(String.t()) :: boolean()
  defp grep_result_line?(line) do
    case Regex.run(~r/^(.*?)([:\-])\d+\2/, line) do
      [_whole, _path, _separator] -> true
      _ -> false
    end
  end
end
