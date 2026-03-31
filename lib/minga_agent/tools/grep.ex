defmodule MingaAgent.Tools.Grep do
  @moduledoc """
  Structured file content search tool for the native agent provider.

  Prefers `rg` (ripgrep) if available on the system, falls back to
  `grep -rn`. Output is structured as `path:line:content` and truncated
  at a configurable match limit to avoid flooding the context window.
  """

  @max_matches 100

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
      do_execute(pattern, path, opts)
    else
      {:error, "Directory does not exist: #{path}"}
    end
  end

  @spec do_execute(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defp do_execute(pattern, path, opts) do
    glob = Map.get(opts, "glob")
    case_sensitive = Map.get(opts, "case_sensitive", true)
    context_lines = Map.get(opts, "context_lines", 0)

    {cmd, args} = build_command(pattern, path, glob, case_sensitive, context_lines)

    case System.cmd(cmd, args, stderr_to_stdout: true, cd: path) do
      {output, 0} ->
        {:ok, truncate_output(output)}

      {output, 1} ->
        # Exit code 1 means no matches (for both grep and rg)
        if String.trim(output) == "" do
          {:ok, "No matches found."}
        else
          {:ok, truncate_output(output)}
        end

      {output, _code} ->
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
    args = args ++ [pattern, "."]
    {grep, args}
  end

  @spec truncate_output(String.t()) :: String.t()
  defp truncate_output(output) do
    lines = String.split(output, "\n")

    if length(lines) > @max_matches do
      truncated = Enum.take(lines, @max_matches) |> Enum.join("\n")
      truncated <> "\n\n... (truncated, #{length(lines) - @max_matches} more lines)"
    else
      output
    end
  end
end
