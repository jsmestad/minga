defmodule Minga.Project.ProjectSearch do
  @moduledoc """
  Searches across project files using `ripgrep` or `grep`.

  Shells out to the fastest available tool and parses its output, line by line,
  into a flat list of match results.

  The subprocess is driven through an Erlang `Port` in `{:line, _}` mode so output
  is collected and parsed incrementally. The result cap is enforced *while*
  collecting: once #{10_000} matches have been gathered the port is closed, which
  terminates the still-running scan instead of letting it walk the whole tree and
  buffer megabytes of output we would only throw away. This keeps memory and time
  bounded on large repositories, where `rg`/`grep` can otherwise emit far more than
  the cap.

  This is line collection, not a streaming JSON Port protocol; structured streaming
  of `rg --json` results into the picker as they arrive is a separate follow-up.

  ## Tool preference

  1. `rg` (ripgrep) — preferred, fast, respects `.gitignore`, JSON output
  2. `grep -rn` — universally available fallback, slower, no column info
  """

  @max_results 10_000

  # Upper bound on subprocess wall-clock time. A pathological scan that never
  # reaches the cap (e.g. a huge tree with few matches) still returns rather than
  # blocking the background task forever.
  @search_timeout_ms 30_000

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

  @doc "Returns the in-process result cap applied while collecting matches."
  @spec max_results() :: pos_integer()
  def max_results, do: @max_results

  @doc """
  Detects which search strategy to use.
  """
  @spec detect_strategy() :: strategy()
  def detect_strategy do
    detect_strategy(System.find_executable("rg"), System.find_executable("grep"))
  end

  @spec detect_strategy(String.t() | nil, String.t() | nil) :: strategy()
  defp detect_strategy(rg, _grep) when is_binary(rg), do: :rg
  defp detect_strategy(_rg, grep) when is_binary(grep), do: :grep
  defp detect_strategy(_rg, _grep), do: :none

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

  @typedoc "Line-parser used to turn a single tool output line into a match or skip."
  @type parser :: (String.t() -> {:ok, match()} | :skip)

  # ── Ripgrep ──────────────────────────────────────────────────────────────

  @spec search_with_rg(String.t(), String.t()) :: result()
  defp search_with_rg(query, root) do
    args = ["--json", "--line-number", "--column", "--", query, "."]
    run_capped("rg", args, root, &parse_rg_json_line/1, "ripgrep")
  end

  # ── Grep fallback ────────────────────────────────────────────────────────

  @spec search_with_grep(String.t(), String.t()) :: result()
  defp search_with_grep(query, root) do
    args = ["-rn", "-I", "--", query, "."]
    run_capped("grep", args, root, &parse_grep_line/1, "grep")
  end

  # ── Capped, incremental subprocess collection ──────────────────────────────

  # Spawns the tool through a Port in line mode and parses output as it arrives,
  # accumulating matches until the cap is hit. Reaching the cap closes the port,
  # which terminates the still-running scan — the cap is enforced *while*
  # collecting, not after the full output has been buffered.
  @spec run_capped(String.t(), [String.t()], String.t(), parser(), String.t()) :: result()
  defp run_capped(tool, args, root, parser, label) do
    case System.find_executable(tool) do
      nil ->
        {:error, "#{label} not found"}

      executable ->
        open_and_collect(executable, args, root, parser, label)
    end
  rescue
    e -> {:error, "#{label} failed: #{Exception.message(e)}"}
  end

  @spec open_and_collect(String.t(), [String.t()], String.t(), parser(), String.t()) :: result()
  defp open_and_collect(executable, args, root, parser, label) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :hide,
        {:args, args},
        {:cd, root},
        {:line, 65_536}
      ])

    collect(port, parser, [], 0, "", label)
  end

  # Drains the port. `acc` holds matches newest-first, `count` tracks how many we
  # have, and `partial` buffers the tail of an over-long line that the port split
  # across `:line` fragments. On the cap, close the port and stop.
  @spec collect(port(), parser(), [match()], non_neg_integer(), String.t(), String.t()) ::
          result()
  defp collect(port, _parser, acc, count, _partial, _label) when count >= @max_results do
    close_port(port)
    {:ok, Enum.reverse(acc), true}
  end

  defp collect(port, parser, acc, count, partial, label) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        {acc, count} = accumulate(parser, partial <> chunk, acc, count)
        collect(port, parser, acc, count, "", label)

      {^port, {:data, {:noeol, chunk}}} ->
        collect(port, parser, acc, count, partial <> chunk, label)

      {^port, {:exit_status, status}} when status in [0, 1] ->
        {acc, _count} = accumulate(parser, partial, acc, count)
        {:ok, Enum.reverse(acc), false}

      {^port, {:exit_status, status}} ->
        {:error, "#{label} exited with code #{status}"}
    after
      @search_timeout_ms ->
        close_port(port)
        {:error, "#{label} timed out"}
    end
  end

  @spec accumulate(parser(), String.t(), [match()], non_neg_integer()) ::
          {[match()], non_neg_integer()}
  defp accumulate(_parser, "", acc, count), do: {acc, count}

  defp accumulate(parser, line, acc, count) do
    case parser.(line) do
      {:ok, match} -> {[match | acc], count + 1}
      :skip -> {acc, count}
    end
  end

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec normalize_path(String.t()) :: String.t()
  defp normalize_path("./" <> rest), do: rest
  defp normalize_path(path), do: path
end
