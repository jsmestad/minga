defmodule MingaAgent.Tools.Find do
  @moduledoc """
  Structured file discovery with a small first page and one retained,
  canonical item capture for later pagination.
  """

  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Output.Revision
  alias MingaAgent.Tools.DirectoryListing
  alias MingaAgent.Tools.OutputCapture
  alias MingaAgent.Tools.OutputLimit
  alias MingaAgent.Tools.OutputLimit.Result
  alias MingaAgent.Tools.PathIgnore
  alias MingaAgent.Tools.SearchRoot

  @capture_bytes 16 * 1_024 * 1_024
  @plain_bytes 51_200

  @type exec_opts :: [
          filter_root: String.t(),
          max_output_bytes: pos_integer(),
          timeout_ms: pos_integer(),
          artifact_store: GenServer.server(),
          capture_key: term()
        ]

  @doc "Searches for matching files for a plain, explicitly non-retained consumer."
  @spec execute(String.t(), String.t(), map(), exec_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(pattern, path, opts \\ %{}, exec_opts \\ [])
      when is_binary(pattern) and is_binary(path) do
    exec_opts = Keyword.put_new(exec_opts, :max_output_bytes, @plain_bytes)
    SearchRoot.run(pattern, path, public_opts(opts), exec_opts, &execute_plain/4)
  end

  @doc "Captures all filtered canonical records once for stable item pagination."
  @spec capture(String.t(), String.t(), map(), exec_opts()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  def capture(pattern, path, opts, exec_opts)
      when is_binary(pattern) and is_binary(path) and is_map(opts) and is_list(exec_opts) do
    SearchRoot.run(pattern, path, public_opts(opts), exec_opts, &execute_capture/4)
  end

  @spec public_opts(map()) :: map()
  defp public_opts(opts), do: Map.take(opts, ["type", "max_depth"])

  @spec execute_plain(String.t(), String.t(), map(), exec_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp execute_plain(pattern, path, opts, exec_opts) do
    case collect(pattern, path, opts, exec_opts) do
      {:ok, [], :complete} -> {:ok, "No matches found."}
      {:ok, records, :complete} -> {:ok, plain_records(records)}
      {:ok, records, {:incomplete, reason}} ->
        {:error, incomplete_message("Find", reason, records)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec plain_records([String.t()]) :: String.t()
  defp plain_records(records) do
    if length(records) > 1_000 do
      Enum.join(Enum.take(records, 1_000), "\n") <>
        "\n... (truncated, refine the pattern or path for fewer results)"
    else
      Enum.join(records, "\n")
    end
  end

  @spec execute_capture(String.t(), String.t(), map(), exec_opts()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp execute_capture(pattern, path, opts, exec_opts) do
    with {:ok, records, capture} <- collect(pattern, path, opts, exec_opts),
         {:ok, selection} <- item_range(records, capture),
         {:ok, revision} <- query_revision("find", pattern, path, opts, records, selection) do
      output_opts = [
        visible_items: records,
        capture_status: capture,
        selection: selection,
        revision: revision
      ]

      output_opts =
        if records == [], do: [{:view, "No matches found."} | output_opts], else: output_opts

      OutputCapture.items(
        Keyword.get(exec_opts, :artifact_store),
        Keyword.get(exec_opts, :capture_key),
        records,
        output_opts
      )
    end
  end

  @spec collect(String.t(), String.t(), map(), exec_opts()) ::
          {:ok, [String.t()], Output.capture_status()} | {:error, String.t()}
  defp collect(pattern, path, opts, exec_opts) do
    type = Map.get(opts, "type", "file")
    max_depth = Map.get(opts, "max_depth", 10)
    filter_root = Keyword.get(exec_opts, :filter_root, path)
    max_bytes = Keyword.get(exec_opts, :max_output_bytes, @capture_bytes)
    timeout_ms = Keyword.get(exec_opts, :timeout_ms, OutputLimit.default_timeout_ms())
    {cmd, args} = build_command(pattern, type, max_depth)

    case OutputLimit.collect_command(cmd, args,
           cd: path,
           stderr_to_stdout: true,
           max_bytes: max_bytes,
           timeout_ms: timeout_ms
         ) do
      %Result{output: output, status: status, capture: capture} when status in [0, 1, :terminated] ->
        records =
          output
          |> OutputLimit.complete_lines(capture != :complete)
          |> PathIgnore.filter_paths(filter_root)
          |> Enum.sort()

        {:ok, records, capture}

      %Result{status: :timeout, output: output, capture: capture} ->
        records =
          output
          |> OutputLimit.complete_lines(true)
          |> PathIgnore.filter_paths(filter_root)
          |> Enum.sort()

        {:ok, records, capture}

      %Result{output: output} ->
        {:error, "Find failed: #{String.trim(output)}"}
    end
  rescue
    error in ErlangError -> {:error, "Find command not found: #{Exception.message(error)}"}
  end

  @spec build_command(String.t(), String.t(), non_neg_integer()) :: {String.t(), [String.t()]}
  defp build_command(pattern, type, max_depth) do
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

    {fd, args ++ ["--", pattern, "."]}
  end

  @spec build_find_command(String.t(), String.t(), non_neg_integer()) ::
          {String.t(), [String.t()]}
  defp build_find_command(pattern, type, max_depth) do
    find = System.find_executable("find") || "find"
    args = [".", "-maxdepth", Integer.to_string(max_depth)] ++ find_prune_args()

    args =
      case type do
        "file" -> args ++ ["-type", "f"]
        "directory" -> args ++ ["-type", "d"]
        _ -> args
      end

    {find, args ++ ["-name", pattern, "-print"]}
  end

  @spec fd_ignore_args() :: [String.t()]
  defp fd_ignore_args do
    Enum.flat_map(DirectoryListing.ignored_names(), fn name -> ["--exclude", name] end)
  end

  @spec find_prune_args() :: [String.t()]
  defp find_prune_args do
    ["("] ++ find_name_expression(DirectoryListing.ignored_names()) ++ [")", "-prune", "-o"]
  end

  @spec find_name_expression([String.t()]) :: [String.t()]
  defp find_name_expression([name]), do: ["-name", name]
  defp find_name_expression([name | rest]), do: ["-name", name, "-o"] ++ find_name_expression(rest)

  @spec item_range([String.t()], Output.capture_status()) ::
          {:ok, Range.t()} | {:error, :invalid_range}
  defp item_range(records, :complete), do: Range.new(:full, :items, 0, length(records), length(records))

  defp item_range(records, {:incomplete, _reason}),
    do: Range.new(:captured_prefix, :items, 0, length(records), :unknown)

  @spec query_revision(
          String.t(),
          String.t(),
          String.t(),
          map(),
          [String.t()],
          Range.t()
        ) :: {:ok, Revision.t()} | {:error, :invalid_revision}
  defp query_revision(tool, pattern, path, opts, records, range) do
    identity = JSON.encode!([tool, pattern, path, opts])
    bytes = Enum.map_join(records, "", &(&1 <> "\n"))

    Revision.new(
      source_kind: :query_snapshot,
      source_id: identity,
      scope: range,
      sha256: Reference.digest(bytes)
    )
  end

  @spec incomplete_message(String.t(), Output.incomplete_reason(), [String.t()]) :: String.t()
  defp incomplete_message(tool, reason, records) do
    prefix = Enum.join(records, "\n")
    "#{tool} capture incomplete (#{reason}). Retained prefix:\n#{prefix}"
  end
end
