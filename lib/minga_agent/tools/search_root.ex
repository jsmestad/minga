defmodule MingaAgent.Tools.SearchRoot do
  @moduledoc "Shared root validation, ignore policy, and retained publication for agent search tools."

  alias MingaAgent.Tool.Output
  alias MingaAgent.Tools.OutputCapture
  alias MingaAgent.Tools.PathIgnore

  @plain_bytes 51_200
  @capture_bytes 16 * 1_024 * 1_024

  @type search_result :: {:ok, String.t()} | {:error, String.t()}
  @type collect_result ::
          {:ok, [String.t()], Output.capture_status()} | {:error, String.t()}
  @type capture_result :: {:ok, Output.t()} | {:error, Output.t() | term()}
  @type search_fun :: (String.t(), String.t(), map(), keyword() -> search_result())
  @type collect_fun :: (String.t(), String.t(), map(), keyword() -> collect_result())
  @typep query ::
           {tool :: String.t(), pattern :: String.t(), path :: String.t(), options :: map()}
  @typep captured_query ::
           {:ok, {query(), [String.t()], Output.capture_status()}} | {:error, String.t()}

  @doc "Validates a search root, applies ignore policy, and invokes the tool-specific search."
  @spec run(String.t(), String.t(), map(), keyword(), search_fun()) ::
          search_result()
  def run(pattern, path, opts, exec_opts, search_fun)
      when is_binary(pattern) and is_binary(path) and is_function(search_fun, 4) do
    exec_opts = Keyword.put_new(exec_opts, :max_output_bytes, @plain_bytes)

    case root_disposition(path, exec_opts) do
      :search -> search_fun.(pattern, path, opts, exec_opts)
      :ignored -> {:ok, "No matches found."}
      {:error, _reason} = error -> error
    end
  end

  @doc "Runs collection and retention under one root decision, including explicit empty retention."
  @spec capture(String.t(), String.t(), String.t(), map(), keyword(), collect_fun()) ::
          capture_result()
  def capture(tool, pattern, path, opts, exec_opts, collect_fun)
      when is_binary(pattern) and is_binary(path) and is_function(collect_fun, 4) do
    {tool, pattern, path, opts}
    |> collect_for_capture(exec_opts, collect_fun)
    |> retain_query_items(exec_opts)
  end

  @spec root_disposition(String.t(), keyword()) ::
          :search | :ignored | {:error, String.t()}
  defp root_disposition(path, exec_opts) do
    filter_root = Keyword.get(exec_opts, :filter_root, path)

    if File.dir?(path) do
      if PathIgnore.ignored_path?(filter_root), do: :ignored, else: :search
    else
      {:error, "Directory does not exist: #{path}"}
    end
  end

  @spec collect_for_capture(query(), keyword(), collect_fun()) :: captured_query()
  defp collect_for_capture({_tool, pattern, path, opts} = query, exec_opts, collect_fun) do
    case root_disposition(path, exec_opts) do
      :search ->
        exec_opts = Keyword.put_new(exec_opts, :max_output_bytes, @capture_bytes)

        with {:ok, records, capture} <- collect_fun.(pattern, path, opts, exec_opts) do
          {:ok, {query, records, capture}}
        end

      :ignored ->
        {:ok, {query, [], :complete}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec retain_query_items(captured_query(), keyword()) :: capture_result()
  defp retain_query_items({:error, _reason} = error, _exec_opts), do: error

  defp retain_query_items({:ok, {{tool, pattern, path, opts}, records, capture}}, exec_opts) do
    output_opts = [
      visible_items: records,
      capture_status: capture,
      query_identity: JSON.encode!([tool, pattern, path, opts])
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
