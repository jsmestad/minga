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

  ## Flags after `--`

  Text after ` -- ` is ripgrep options, not part of the pattern. For example, `limit_lable -- -uu` includes ignored and hidden files. Search options can match or filter files and lines, but cannot replace the JSON match output. Requests with options require ripgrep; the recursive grep fallback includes ignored and hidden files by default.

  Minga does not load `RIPGREP_CONFIG_PATH` because it owns the result format and needs to report which files were searched. Put case, pattern, and file filters in the query instead.

  ## Tool preference

  1. `rg` (ripgrep) — preferred, fast, respects `.gitignore`, JSON output
  2. `grep -rn` — universally available fallback, slower, no column info
  """

  alias Minga.Project.Root

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

  @typedoc "Which file classes the scan included, before any explicit glob or type filters."
  @type coverage :: :visible | :with_ignored | :with_hidden | :all

  @typedoc "Search result, including the actual tool's coverage."
  @type result :: {:ok, [match()], truncated :: boolean(), coverage()} | {:error, String.t()}
  @typep tool_result :: {:ok, [match()], truncated :: boolean()} | {:error, String.t()}

  @typedoc "Search strategy."
  @type strategy :: :rg | :grep | :none

  @doc """
  Searches for `query` under an explicitly authorized directory root.

  Returns `{:ok, matches, truncated?, coverage}` on success. `truncated?` is true if results were capped at #{@max_results}. Coverage records whether the scan included ignored and hidden files.

  Returns `{:error, message}` if the query is empty, the options are invalid, or no search tool can run the search.
  """
  @spec search(String.t(), Root.t()) :: result()
  def search(query, %Root{} = root) do
    case parse_query(query) do
      {"", _flags} -> {:error, "Empty search query"}
      {pattern, flags} -> search_workspace(pattern, flags, root)
    end
  end

  @spec search_workspace(String.t(), [String.t()], Root.t()) :: result()
  defp search_workspace(pattern, flags, root) do
    case Root.inventory_path(root) do
      {:ok, path} -> search_pattern(pattern, flags, path)
      {:error, reason} -> {:error, "Project search root is not authorized: #{reason}"}
    end
  end

  @doc """
  Splits a query into its pattern and the ripgrep flags after ` -- `.

      iex> Minga.Project.ProjectSearch.parse_query("limit_lable -- -u --hidden")
      {"limit_lable", ["-u", "--hidden"]}

      iex> Minga.Project.ProjectSearch.parse_query("limit_lable -- -g *.ex")
      {"limit_lable", ["-g", "*.ex"]}

      iex> Minga.Project.ProjectSearch.parse_query("limit_lable")
      {"limit_lable", []}
  """
  @spec parse_query(String.t()) :: {pattern :: String.t(), flags :: [String.t()]}
  def parse_query(query) when is_binary(query) do
    case String.split(query, " -- ", parts: 2) do
      [pattern, flags] -> {pattern, flags |> String.split() |> take_flags([])}
      [pattern] -> {pattern, []}
    end
  end

  # Keep the JSON match contract intact. Accept search and traversal options, not alternate output modes or commands.
  @switch_flags ~w(-F --fixed-strings -i --ignore-case -s --case-sensitive -S --smart-case -v --invert-match
                   -w --word-regexp -x --line-regexp -U --multiline --multiline-dotall --no-unicode)
  @short_value_flags ~w(-g -t -T -e -d -m)
  @long_value_flags ~w(--glob --iglob --type --type-not --regexp --max-depth --max-count --max-filesize)
  @value_flags @short_value_flags ++ @long_value_flags

  # A flag starts with `-`, and a value flag keeps the word after it; a stray word is never a path to search.
  # A bare `--` would end ripgrep's options before its own arguments, so it never passes through.
  @spec take_flags([String.t()], [String.t()]) :: [String.t()]
  defp take_flags([], acc), do: Enum.reverse(acc)
  defp take_flags(["--" | rest], acc), do: take_flags(rest, acc)

  defp take_flags([flag, value | rest], acc) when flag in @value_flags,
    do: take_flags(rest, [value, flag | acc])

  defp take_flags([flag], acc) when flag in @value_flags, do: Enum.reverse([flag | acc])

  defp take_flags(["-" <> _ = flag | rest], acc), do: take_flags(rest, [flag | acc])
  defp take_flags([_word | rest], acc), do: take_flags(rest, acc)

  @spec search_pattern(String.t(), [String.t()], String.t()) :: result()
  defp search_pattern(pattern, flags, root) do
    case select_executable() do
      {:rg, executable} ->
        with {:ok, coverage} <- rg_coverage(flags, 0, false, false),
             {:ok, matches, truncated?} <- search_with_rg(executable, pattern, flags, root) do
          {:ok, matches, truncated?, coverage}
        end

      {:grep, executable} when flags == [] ->
        with {:ok, matches, truncated?} <- search_with_grep(executable, pattern, root) do
          {:ok, matches, truncated?, :all}
        end

      {:grep, _executable} ->
        {:error, "Search options require ripgrep (rg)."}

      :none ->
        {:error, "No search tool available. Install `ripgrep` (rg) for best results."}
    end
  end

  @spec rg_coverage([String.t()], non_neg_integer(), boolean(), boolean()) ::
          {:ok, coverage()} | {:error, String.t()}
  defp rg_coverage([], unrestricted, hidden?, no_ignore?) do
    cond do
      unrestricted > 3 ->
        {:error, "Ripgrep accepts at most three -u flags."}

      unrestricted >= 2 or (hidden? and (no_ignore? or unrestricted == 1)) ->
        {:ok, :all}

      no_ignore? or unrestricted == 1 ->
        {:ok, :with_ignored}

      hidden? ->
        {:ok, :with_hidden}

      true ->
        {:ok, :visible}
    end
  end

  defp rg_coverage(["--hidden" | rest], unrestricted, _hidden?, no_ignore?),
    do: rg_coverage(rest, unrestricted, true, no_ignore?)

  defp rg_coverage(["--no-ignore" | rest], unrestricted, hidden?, _no_ignore?),
    do: rg_coverage(rest, unrestricted, hidden?, true)

  defp rg_coverage(["--unrestricted" | rest], unrestricted, hidden?, no_ignore?),
    do: rg_coverage(rest, unrestricted + 1, hidden?, no_ignore?)

  defp rg_coverage([flag | rest], unrestricted, hidden?, no_ignore?)
       when flag in ["-u", "-uu", "-uuu"],
       do: rg_coverage(rest, unrestricted + byte_size(flag) - 1, hidden?, no_ignore?)

  defp rg_coverage([flag, value | rest], unrestricted, hidden?, no_ignore?)
       when flag in @value_flags and value not in ["", "--"],
       do: rg_coverage(rest, unrestricted, hidden?, no_ignore?)

  defp rg_coverage([flag | rest], unrestricted, hidden?, no_ignore?) do
    cond do
      flag in @switch_flags or joined_value_flag?(flag) ->
        rg_coverage(rest, unrestricted, hidden?, no_ignore?)

      flag in @value_flags ->
        {:error, "Missing value for search option #{flag}."}

      true ->
        {:error, "Unsupported search option #{flag}."}
    end
  end

  @spec joined_value_flag?(String.t()) :: boolean()
  defp joined_value_flag?("--" <> _ = flag) do
    case String.split(flag, "=", parts: 2) do
      [name, value] -> name in @long_value_flags and value != ""
      [_name] -> false
    end
  end

  defp joined_value_flag?(<<name::binary-size(2), value::binary>>),
    do: name in @short_value_flags and value != ""

  defp joined_value_flag?(_flag), do: false

  @doc "Returns the in-process result cap applied while collecting matches."
  @spec max_results() :: pos_integer()
  def max_results, do: @max_results

  @doc """
  Detects which search strategy to use.
  """
  @spec detect_strategy() :: strategy()
  def detect_strategy do
    case select_executable() do
      {strategy, _executable} -> strategy
      :none -> :none
    end
  end

  @spec select_executable() :: {:rg | :grep, String.t()} | :none
  defp select_executable do
    cond do
      executable = System.find_executable("rg") -> {:rg, executable}
      executable = System.find_executable("grep") -> {:grep, executable}
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

  @typedoc "Line-parser used to turn a single tool output line into a match or skip."
  @type parser :: (String.t() -> {:ok, match()} | :skip)

  # ── Ripgrep ──────────────────────────────────────────────────────────────

  @spec search_with_rg(String.t(), String.t(), [String.t()], String.t()) :: tool_result()
  defp search_with_rg(executable, query, flags, root) do
    args =
      ["--no-config", "--json", "--line-number", "--column", "-e", query] ++ flags ++ ["--", "."]

    run_capped(executable, args, root, &parse_rg_json_line/1, "ripgrep")
  end

  # ── Grep fallback ────────────────────────────────────────────────────────

  @spec search_with_grep(String.t(), String.t(), String.t()) :: tool_result()
  defp search_with_grep(executable, query, root) do
    args = ["-rn", "-I", "--", query, "."]
    run_capped(executable, args, root, &parse_grep_line/1, "grep")
  end

  # ── Capped, incremental subprocess collection ──────────────────────────────

  # Spawns the tool through a Port in line mode and parses output as it arrives,
  # accumulating matches until the cap is hit. Reaching the cap closes the port,
  # which terminates the still-running scan — the cap is enforced *while*
  # collecting, not after the full output has been buffered.
  @spec run_capped(String.t(), [String.t()], String.t(), parser(), String.t()) :: tool_result()
  defp run_capped(executable, args, root, parser, label) do
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
  rescue
    e -> {:error, "#{label} failed: #{Exception.message(e)}"}
  end

  # Drains the port. `acc` holds matches newest-first, `count` tracks how many we
  # have, and `partial` buffers the tail of an over-long line that the port split
  # across `:line` fragments. On the cap, close the port and stop.
  @spec collect(port(), parser(), [match()], non_neg_integer(), String.t(), String.t()) ::
          tool_result()
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
