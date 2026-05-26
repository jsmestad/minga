defmodule MingaAgent.Tools.ApplyDiff do
  @moduledoc """
  Applies unified diffs to a single file.

  The tool parses standard unified diff hunks, validates context against the current file content, and writes the resulting content only when every hunk applies. Hunk matching starts at the line declared in the header and then searches a small nearby window so diffs survive minor line offset drift without accepting stale context.
  """

  alias Minga.Buffer
  alias MingaAgent.Tools.WriteFile

  @max_fuzz 5

  @typedoc "A parsed unified diff operation."
  @type operation :: {:context, String.t()} | {:remove, String.t()} | {:add, String.t()}

  @typedoc "A parsed unified diff hunk."
  @type hunk :: map()

  @typedoc "Successful patch application metadata."
  @type apply_result :: %{content: String.t(), hunks: pos_integer()}

  @doc "Applies a unified diff to the file at `path`."
  @spec execute(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, diff) when is_binary(path) and is_binary(diff) do
    with {:ok, content} <- read_current_content(path),
         {:ok, %{content: new_content, hunks: hunk_count}} <- apply_to_content(content, diff),
         {:ok, _message} <- WriteFile.execute(path, new_content) do
      {:ok, "applied #{hunk_count} diff hunk(s) to #{path}"}
    end
  end

  @doc "Applies a unified diff string to `content` without writing it."
  @spec apply_to_content(String.t(), String.t()) :: {:ok, apply_result()} | {:error, String.t()}
  def apply_to_content(content, diff) when is_binary(content) and is_binary(diff) do
    with {:ok, hunks} <- parse(diff),
         {:ok, patched_lines} <- apply_hunks(content_lines(content), hunks) do
      {:ok, %{content: Enum.join(patched_lines, "\n"), hunks: length(hunks)}}
    end
  end

  @doc "Parses unified diff hunks from a diff string."
  @spec parse(String.t()) :: {:ok, [hunk()]} | {:error, String.t()}
  def parse(diff) when is_binary(diff) do
    diff
    |> diff_lines()
    |> parse_lines(1, [], nil)
    |> finalize_parse()
  end

  @spec read_current_content(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_current_content(path) do
    expanded = Path.expand(path)

    case Buffer.pid_for_path(expanded) do
      {:ok, pid} -> read_buffer_content(pid, expanded)
      :not_found -> read_file_content(expanded)
    end
  catch
    :exit, _ -> read_file_content(Path.expand(path))
  end

  @spec read_buffer_content(pid(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_buffer_content(pid, path) do
    {:ok, Buffer.content(pid)}
  catch
    :exit, _ -> {:error, "buffer process died for #{path}"}
  end

  @spec read_file_content(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_file_content(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "file not found: #{path}"}
      {:error, reason} -> {:error, "failed to read #{path}: #{reason}"}
    end
  end

  @spec diff_lines(String.t()) :: [String.t()]
  defp diff_lines(diff) do
    diff
    |> String.split("\n", trim: false)
    |> drop_trailing_empty_line()
  end

  @spec drop_trailing_empty_line([String.t()]) :: [String.t()]
  defp drop_trailing_empty_line([]), do: []

  defp drop_trailing_empty_line(lines) do
    if List.last(lines) == "" do
      Enum.slice(lines, 0, length(lines) - 1)
    else
      lines
    end
  end

  @spec parse_lines([String.t()], pos_integer(), [hunk()], hunk() | nil) ::
          {:ok, [hunk()]} | {:error, String.t()} | {:pending, [hunk()], hunk() | nil}
  defp parse_lines([], _line_no, parsed, current), do: {:pending, parsed, current}

  defp parse_lines([line | rest], line_no, parsed, current) do
    parse_line(line, rest, line_no, parsed, current)
  end

  @spec parse_line(String.t(), [String.t()], pos_integer(), [hunk()], hunk() | nil) ::
          {:ok, [hunk()]} | {:error, String.t()} | {:pending, [hunk()], hunk() | nil}
  defp parse_line(line, rest, line_no, parsed, current) do
    if hunk_header?(line) do
      parse_hunk_header(line, rest, line_no, parsed, current)
    else
      parse_non_header_line(line, rest, line_no, parsed, current)
    end
  end

  @spec parse_hunk_header(String.t(), [String.t()], pos_integer(), [hunk()], hunk() | nil) ::
          {:ok, [hunk()]} | {:error, String.t()} | {:pending, [hunk()], hunk() | nil}
  defp parse_hunk_header(line, rest, line_no, parsed, current) do
    with {:ok, hunk} <- new_hunk(line, line_no),
         {:ok, parsed} <- push_current_hunk(parsed, current, line_no) do
      parse_lines(rest, line_no + 1, parsed, hunk)
    end
  end

  @spec parse_non_header_line(String.t(), [String.t()], pos_integer(), [hunk()], hunk() | nil) ::
          {:ok, [hunk()]} | {:error, String.t()} | {:pending, [hunk()], hunk() | nil}
  defp parse_non_header_line(line, rest, line_no, parsed, nil) do
    if ignorable_header_line?(line) do
      parse_lines(rest, line_no + 1, parsed, nil)
    else
      {:error, "malformed diff at line #{line_no}: expected hunk header, got #{inspect(line)}"}
    end
  end

  defp parse_non_header_line(line, rest, line_no, parsed, current) do
    case parse_operation(line, line_no) do
      {:ok, operation} ->
        parse_lines(rest, line_no + 1, parsed, add_operation(current, operation))

      {:error, _message} = error ->
        error
    end
  end

  @spec hunk_header?(String.t()) :: boolean()
  defp hunk_header?(line), do: String.starts_with?(line, "@@")

  @spec ignorable_header_line?(String.t()) :: boolean()
  defp ignorable_header_line?(""), do: true
  defp ignorable_header_line?("---" <> _rest), do: true
  defp ignorable_header_line?("+++" <> _rest), do: true
  defp ignorable_header_line?("diff --git" <> _rest), do: true
  defp ignorable_header_line?("index " <> _rest), do: true
  defp ignorable_header_line?("new file mode " <> _rest), do: true
  defp ignorable_header_line?("deleted file mode " <> _rest), do: true
  defp ignorable_header_line?("old mode " <> _rest), do: true
  defp ignorable_header_line?("new mode " <> _rest), do: true
  defp ignorable_header_line?(_line), do: false

  @spec new_hunk(String.t(), pos_integer()) :: {:ok, hunk()} | {:error, String.t()}
  defp new_hunk(line, line_no) do
    case Regex.named_captures(
           ~r/^@@ -(?<old_start>\d+)(?:,(?<old_count>\d+))? \+(?<new_start>\d+)(?:,(?<new_count>\d+))? @@/,
           line
         ) do
      %{
        "old_start" => old_start,
        "old_count" => old_count,
        "new_start" => new_start,
        "new_count" => new_count
      } ->
        {:ok,
         %{
           old_start: String.to_integer(old_start),
           old_count: count_value(old_count),
           new_start: String.to_integer(new_start),
           new_count: count_value(new_count),
           operations: []
         }}

      nil ->
        {:error, "malformed diff at line #{line_no}: invalid hunk header #{inspect(line)}"}
    end
  end

  @spec count_value(String.t() | nil) :: non_neg_integer()
  defp count_value(nil), do: 1
  defp count_value(""), do: 1
  defp count_value(value), do: String.to_integer(value)

  @spec parse_operation(String.t(), pos_integer()) :: {:ok, operation()} | {:error, String.t()}
  defp parse_operation(" " <> text, _line_no), do: {:ok, {:context, text}}
  defp parse_operation("-" <> text, _line_no), do: {:ok, {:remove, text}}
  defp parse_operation("+" <> text, _line_no), do: {:ok, {:add, text}}

  defp parse_operation("\\ No newline at end of file", _line_no) do
    {:error, "unsupported diff: no-newline-at-EOF markers are not supported"}
  end

  defp parse_operation(line, line_no) do
    {:error,
     "malformed diff at line #{line_no}: expected hunk line prefix ' ', '+', or '-', got #{inspect(line)}"}
  end

  @spec add_operation(hunk(), operation()) :: hunk()
  defp add_operation(hunk, operation), do: %{hunk | operations: [operation | hunk.operations]}

  @spec push_current_hunk([hunk()], hunk() | nil, non_neg_integer()) ::
          {:ok, [hunk()]} | {:error, String.t()}
  defp push_current_hunk(parsed, nil, _line_no), do: {:ok, parsed}

  defp push_current_hunk(parsed, current, line_no) do
    current = %{current | operations: Enum.reverse(current.operations)}

    case validate_hunk_counts(current, line_no) do
      :ok -> {:ok, [current | parsed]}
      {:error, _message} = error -> error
    end
  end

  @spec finalize_parse({:pending, [hunk()], hunk() | nil} | {:error, String.t()}) ::
          {:ok, [hunk()]} | {:error, String.t()}
  defp finalize_parse({:error, _message} = error), do: error

  defp finalize_parse({:pending, parsed, current}) do
    with {:ok, parsed} <- push_current_hunk(parsed, current, 0) do
      require_hunks(Enum.reverse(parsed))
    end
  end

  @spec require_hunks([hunk()]) :: {:ok, [hunk()]} | {:error, String.t()}
  defp require_hunks([]), do: {:error, "malformed diff: no hunks found"}
  defp require_hunks(hunks), do: {:ok, hunks}

  @spec validate_hunk_counts(hunk(), non_neg_integer()) :: :ok | {:error, String.t()}
  defp validate_hunk_counts(hunk, line_no) do
    old_seen = count_old_lines(hunk.operations)
    new_seen = count_new_lines(hunk.operations)

    case validate_line_count(:old, hunk.old_count, old_seen, line_no) do
      :ok -> validate_line_count(:new, hunk.new_count, new_seen, line_no)
      {:error, _message} = error -> error
    end
  end

  @spec validate_line_count(:old | :new, non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, String.t()}
  defp validate_line_count(_kind, expected, actual, _line_no) when expected == actual, do: :ok

  defp validate_line_count(kind, expected, actual, 0) do
    {:error, "malformed diff: #{kind} line count expected #{expected}, got #{actual}"}
  end

  defp validate_line_count(kind, expected, actual, line_no) do
    {:error,
     "malformed diff before line #{line_no}: #{kind} line count expected #{expected}, got #{actual}"}
  end

  @spec count_old_lines([operation()]) :: non_neg_integer()
  defp count_old_lines(operations), do: Enum.count(operations, &old_line?/1)

  @spec count_new_lines([operation()]) :: non_neg_integer()
  defp count_new_lines(operations), do: Enum.count(operations, &new_line?/1)

  @spec old_line?(operation()) :: boolean()
  defp old_line?({:context, _text}), do: true
  defp old_line?({:remove, _text}), do: true
  defp old_line?({:add, _text}), do: false

  @spec new_line?(operation()) :: boolean()
  defp new_line?({:context, _text}), do: true
  defp new_line?({:add, _text}), do: true
  defp new_line?({:remove, _text}), do: false

  @spec content_lines(String.t()) :: [String.t()]
  defp content_lines(content), do: String.split(content, "\n", trim: false)

  @spec apply_hunks([String.t()], [hunk()]) :: {:ok, [String.t()]} | {:error, String.t()}
  defp apply_hunks(lines, hunks) do
    hunks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, lines, 0}, &apply_hunk_step/2)
    |> case do
      {:ok, patched_lines, _delta} -> {:ok, patched_lines}
      {:error, _message} = error -> error
    end
  end

  @spec apply_hunk_step({hunk(), pos_integer()}, {:ok, [String.t()], integer()}) ::
          {:cont, {:ok, [String.t()], integer()}} | {:halt, {:error, String.t()}}
  defp apply_hunk_step({hunk, index}, {:ok, lines, delta}) do
    case apply_hunk(lines, hunk, index, delta) do
      {:ok, patched_lines, hunk_delta} -> {:cont, {:ok, patched_lines, delta + hunk_delta}}
      {:error, _message} = error -> {:halt, error}
    end
  end

  @spec apply_hunk([String.t()], hunk(), pos_integer(), integer()) ::
          {:ok, [String.t()], integer()} | {:error, String.t()}
  defp apply_hunk(lines, hunk, hunk_index, delta) do
    old_lines = old_hunk_lines(hunk.operations)
    new_lines = new_hunk_lines(hunk.operations)
    expected_index = expected_index(hunk, delta)

    case find_hunk_index(lines, old_lines, expected_index) do
      {:ok, index} ->
        patched = replace_slice(lines, index, length(old_lines), new_lines)
        {:ok, patched, length(new_lines) - length(old_lines)}

      :error ->
        {:error,
         "stale diff: hunk #{hunk_index} context did not match near original line #{hunk.old_start}"}
    end
  end

  @spec expected_index(hunk(), integer()) :: non_neg_integer()
  defp expected_index(%{old_count: 0, old_start: old_start}, delta), do: max(old_start + delta, 0)
  defp expected_index(%{old_start: old_start}, delta), do: max(old_start - 1 + delta, 0)

  @spec old_hunk_lines([operation()]) :: [String.t()]
  defp old_hunk_lines(operations) do
    operations
    |> Enum.reject(&match?({:add, _text}, &1))
    |> Enum.map(&operation_text/1)
  end

  @spec new_hunk_lines([operation()]) :: [String.t()]
  defp new_hunk_lines(operations) do
    operations
    |> Enum.reject(&match?({:remove, _text}, &1))
    |> Enum.map(&operation_text/1)
  end

  @spec operation_text(operation()) :: String.t()
  defp operation_text({_kind, text}), do: text

  @spec find_hunk_index([String.t()], [String.t()], non_neg_integer()) ::
          {:ok, non_neg_integer()} | :error
  defp find_hunk_index(lines, [], expected_index) do
    if expected_index <= max_insert_index(lines) do
      {:ok, expected_index}
    else
      :error
    end
  end

  defp find_hunk_index(lines, old_lines, expected_index) do
    candidates(expected_index)
    |> Enum.find(&matches_at?(lines, old_lines, &1))
    |> case do
      nil -> :error
      index -> {:ok, index}
    end
  end

  @spec max_insert_index([String.t()]) :: non_neg_integer()
  defp max_insert_index([]), do: 0

  defp max_insert_index(lines) do
    if List.last(lines) == "" do
      length(lines) - 1
    else
      length(lines)
    end
  end

  @spec candidates(non_neg_integer()) :: [non_neg_integer()]
  defp candidates(expected_index) do
    0..@max_fuzz
    |> Enum.flat_map(&candidate_offsets(expected_index, &1))
    |> Enum.filter(&(&1 >= 0))
    |> Enum.uniq()
  end

  @spec candidate_offsets(non_neg_integer(), non_neg_integer()) :: [integer()]
  defp candidate_offsets(expected, 0), do: [expected]
  defp candidate_offsets(expected, distance), do: [expected - distance, expected + distance]

  @spec matches_at?([String.t()], [String.t()], non_neg_integer()) :: boolean()
  defp matches_at?(lines, old_lines, index) do
    index <= length(lines) - length(old_lines) and
      Enum.slice(lines, index, length(old_lines)) == old_lines
  end

  @spec replace_slice([String.t()], non_neg_integer(), non_neg_integer(), [String.t()]) :: [
          String.t()
        ]
  defp replace_slice(lines, index, count, replacement) do
    {prefix, rest} = Enum.split(lines, index)
    {_removed, suffix} = Enum.split(rest, count)
    prefix ++ replacement ++ suffix
  end
end
