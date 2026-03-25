defmodule Minga.Project.ProjectSearch do
  @moduledoc """
  Searches across project files using `ripgrep` or `grep`.

  Shells out to the fastest available tool and parses structured output
  into a flat list of match results. All functions are pure — no process
  state is mutated.

  ## Tool preference

  1. `rg` (ripgrep) — preferred, fast, respects `.gitignore`, JSON output
  2. `grep -rn` — universally available fallback, slower, no column info
  """

  @max_results 10_000

  @typedoc "A single search match across the project."
  @type match :: %{
          file: String.t(),
          line: pos_integer(),
          col: non_neg_integer(),
          text: String.t()
        }

  @typedoc "Search result."
  @type result :: {:ok, [match()], truncated :: boolean()} | {:error, String.t()}

  @typedoc "Search strategy."
  @type strategy :: :rg | :grep | :none

  @doc """
  Searches for `query` in all files under `root`.

  Returns `{:ok, matches, truncated?}` on success where `truncated?` is
  `true` if results were capped at #{@max_results}.

  Returns `{:error, message}` if no search tool is available or the query
  is empty.
  """
  @spec search(String.t(), String.t()) :: result()
  def search(query, root \\ File.cwd!())

  def search("", _root), do: {:error, "Empty search query"}

  def search(query, root) do
    case detect_strategy() do
      :rg -> search_with_rg(query, root)
      :grep -> search_with_grep(query, root)
      :none -> {:error, "No search tool available. Install `ripgrep` (rg) for best results."}
    end
  end

  @doc """
  Detects which search strategy to use.
  """
  @spec detect_strategy() :: strategy()
  def detect_strategy do
    cond do
      System.find_executable("rg") != nil -> :rg
      System.find_executable("grep") != nil -> :grep
      true -> :none
    end
  end

  @doc """
  Parses a single ripgrep JSON line into a match map.

  Returns `{:ok, match}` for match lines, `:skip` for summary/context lines.

  ## Examples

      iex> json = ~s({"type":"match","data":{"path":{"text":"lib/foo.ex"},"lines":{"text":"defmodule Foo\\n"},"line_number":1,"submatches":[{"match":{"text":"Foo"},"start":10,"end":13}]}})
      iex> Minga.Project.ProjectSearch.parse_rg_json_line(json)
      {:ok, %{file: "lib/foo.ex", line: 1, col: 10, text: "defmodule Foo"}}
  """
  @spec parse_rg_json_line(String.t()) :: {:ok, match()} | :skip
  def parse_rg_json_line(line) do
    case JSON.decode(line) do
      {:ok, %{"type" => "match", "data" => data}} ->
        file = get_in(data, ["path", "text"]) || ""
        line_num = data["line_number"] || 1
        text = get_in(data, ["lines", "text"]) || ""

        col =
          case data["submatches"] do
            [%{"start" => start} | _] -> start
            _ -> 0
          end

        {:ok,
         %{
           file: normalize_path(file),
           line: line_num,
           col: col,
           text: String.trim_trailing(text, "\n")
         }}

      _ ->
        :skip
    end
  end

  @doc """
  Parses a single grep output line (`file:line:text`) into a match map.

  Returns `{:ok, match}` for valid lines, `:skip` for unparseable lines.

  ## Examples

      iex> Minga.Project.ProjectSearch.parse_grep_line("lib/foo.ex:42:defmodule Foo")
      {:ok, %{file: "lib/foo.ex", line: 42, col: 0, text: "defmodule Foo"}}

      iex> Minga.Project.ProjectSearch.parse_grep_line("not a match")
      :skip
  """
  @spec parse_grep_line(String.t()) :: {:ok, match()} | :skip
  def parse_grep_line(line) do
    case String.split(line, ":", parts: 3) do
      [file, line_str, text] ->
        case Integer.parse(line_str) do
          {line_num, _} ->
            {:ok,
             %{
               file: normalize_path(file),
               line: line_num,
               col: 0,
               text: String.trim_trailing(text, "\n")
             }}

          :error ->
            :skip
        end

      _ ->
        :skip
    end
  end

  # ── Ripgrep ──────────────────────────────────────────────────────────────

  @spec search_with_rg(String.t(), String.t()) :: result()
  defp search_with_rg(query, root) do
    args = ["--json", "--line-number", "--column", "--", query, "."]

    case System.cmd("rg", args, cd: root, stderr_to_stdout: true) do
      {output, code} when code in [0, 1] ->
        collect_matches(output, &parse_rg_json_line/1)

      {_output, code} ->
        {:error, "ripgrep exited with code #{code}"}
    end
  rescue
    e -> {:error, "ripgrep failed: #{Exception.message(e)}"}
  end

  # ── Grep fallback ────────────────────────────────────────────────────────

  @spec search_with_grep(String.t(), String.t()) :: result()
  defp search_with_grep(query, root) do
    args = ["-rn", "-I", "--", query, "."]

    case System.cmd("grep", args, cd: root, stderr_to_stdout: true) do
      {output, code} when code in [0, 1] ->
        collect_matches(output, &parse_grep_line/1)

      {_output, code} ->
        {:error, "grep exited with code #{code}"}
    end
  rescue
    e -> {:error, "grep failed: #{Exception.message(e)}"}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec collect_matches(String.t(), (String.t() -> {:ok, match()} | :skip)) :: result()
  defp collect_matches(output, parser) do
    lines = String.split(output, "\n", trim: true)
    {matches, truncated?} = collect_lines(lines, parser, [], false)
    {:ok, Enum.reverse(matches), truncated?}
  end

  @spec collect_lines([String.t()], (String.t() -> {:ok, match()} | :skip), [match()], boolean()) ::
          {[match()], boolean()}
  defp collect_lines([], _parser, acc, truncated?), do: {acc, truncated?}

  defp collect_lines(_lines, _parser, acc, _truncated?) when length(acc) >= @max_results do
    {acc, true}
  end

  defp collect_lines([line | rest], parser, acc, _truncated?) do
    case parser.(line) do
      {:ok, match} -> collect_lines(rest, parser, [match | acc], false)
      :skip -> collect_lines(rest, parser, acc, false)
    end
  end

  @spec normalize_path(String.t()) :: String.t()
  defp normalize_path("./" <> rest), do: rest
  defp normalize_path(path), do: path
end
