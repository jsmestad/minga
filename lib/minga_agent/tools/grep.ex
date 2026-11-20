defmodule MingaAgent.Tools.Grep do
  @moduledoc """
  Structured content search with a retained canonical item capture and a
  100-record first page.
  """

  alias MingaAgent.Tool.Output
  alias MingaAgent.Tools.DirectoryListing
  alias MingaAgent.Tools.OutputLimit
  alias MingaAgent.Tools.OutputLimit.Result
  alias MingaAgent.Tools.PathIgnore
  alias MingaAgent.Tools.SearchRoot

  @type exec_opts :: [
          filter_root: String.t(),
          max_output_bytes: pos_integer(),
          timeout_ms: pos_integer(),
          artifact_store: GenServer.server(),
          capture_key: term()
        ]

  @doc "Searches content for a plain, explicitly non-retained consumer."
  @spec execute(String.t(), String.t(), map(), exec_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(pattern, path, opts \\ %{}, exec_opts \\ [])
      when is_binary(pattern) and is_binary(path) do
    SearchRoot.run(
      pattern,
      path,
      public_opts(opts),
      exec_opts,
      &execute_plain/4
    )
  end

  @doc "Captures filtered canonical search records once for stable item pagination."
  @spec capture(String.t(), String.t(), map(), exec_opts()) :: SearchRoot.capture_result()
  def capture(pattern, path, %{} = opts, exec_opts) when is_list(exec_opts) do
    SearchRoot.capture(
      "grep",
      pattern,
      path,
      public_opts(opts),
      exec_opts,
      &collect/4
    )
  end

  @spec public_opts(map()) :: map()
  defp public_opts(opts), do: Map.take(opts, ["glob", "case_sensitive", "context_lines"])

  @spec execute_plain(String.t(), String.t(), map(), exec_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp execute_plain(pattern, path, opts, exec_opts) do
    case collect(pattern, path, opts, exec_opts) do
      {:ok, [], :complete} ->
        {:ok, "No matches found."}

      {:ok, records, :complete} ->
        {:ok, records |> Enum.take(100) |> Enum.join("\n")}

      {:ok, records, {:incomplete, reason}} ->
        {:error, incomplete_message(reason, records)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec collect(String.t(), String.t(), map(), exec_opts()) :: SearchRoot.collect_result()
  defp collect(pattern, path, opts, exec_opts) do
    glob = Map.get(opts, "glob")
    case_sensitive = Map.get(opts, "case_sensitive", true)
    context_lines = Map.get(opts, "context_lines", 0)
    filter_root = Keyword.get(exec_opts, :filter_root, path)
    max_bytes = Keyword.fetch!(exec_opts, :max_output_bytes)
    timeout_ms = Keyword.get(exec_opts, :timeout_ms, OutputLimit.default_timeout_ms())
    {cmd, args} = build_command(pattern, glob, case_sensitive, context_lines)

    case OutputLimit.collect_command(cmd, args,
           cd: path,
           stderr_to_stdout: true,
           max_bytes: max_bytes,
           timeout_ms: timeout_ms
         ) do
      %Result{output: output, status: status, capture: capture}
      when status in [0, 1, :terminated] ->
        {:ok, filtered_records(output, filter_root, capture), capture}

      %Result{status: :timeout, output: output, capture: capture} ->
        {:ok, filtered_records(output, filter_root, capture), capture}

      %Result{output: output} ->
        {:error, "Search failed: #{String.trim(output)}"}
    end
  rescue
    error in ErlangError -> {:error, "Search command not found: #{Exception.message(error)}"}
  end

  @spec filtered_records(binary(), String.t(), Output.capture_status()) :: [String.t()]
  defp filtered_records(output, filter_root, capture) do
    records =
      PathIgnore.filter_grep_lines(
        filter_root,
        OutputLimit.complete_lines(output, capture != :complete)
      )

    if Enum.any?(records, &grep_result_line?/1), do: records, else: []
  end

  @spec build_command(String.t(), String.t() | nil, boolean(), non_neg_integer()) ::
          {String.t(), [String.t()]}
  defp build_command(pattern, glob, case_sensitive, context_lines) do
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
    {rg, args ++ ["--", pattern, "."]}
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
    {grep, args ++ ["--", pattern, "."]}
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

  @spec grep_result_line?(String.t()) :: boolean()
  defp grep_result_line?(line) do
    case Regex.run(~r/^(.*?)([:\-])\d+\2/, line) do
      [_whole, _path, _separator] -> true
      _ -> false
    end
  end

  @spec incomplete_message(Output.incomplete_reason(), [String.t()]) :: String.t()
  defp incomplete_message(reason, records) do
    "Search capture incomplete (#{reason}). Retained prefix:\n#{Enum.join(records, "\n")}"
  end
end
