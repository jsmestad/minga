defmodule MingaAgent.Tools.SearchRoot do
  @moduledoc "Shared directory and ignore-policy boundary for agent search tools."

  alias MingaAgent.Tools.PathIgnore
  alias MingaAgent.Tool.Output

  @plain_bytes 51_200

  @type search_result :: {:ok, String.t()} | {:error, String.t()}
  @type collect_result ::
          {:ok, [String.t()], Output.capture_status()} | {:error, String.t()}
  @type capture_result :: {:ok, Output.t()} | {:error, Output.t() | term()}
  @type search_fun :: (String.t(), String.t(), map(), keyword() -> search_result())
  @type collect_fun :: (String.t(), String.t(), map(), keyword() -> collect_result())
  @type retain_fun ::
          (String.t(), String.t(), map(), keyword(), {[String.t()], Output.capture_status()} ->
             capture_result())

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
  @spec capture(
          String.t(),
          String.t(),
          map(),
          keyword(),
          collect_fun(),
          retain_fun()
        ) :: capture_result()
  def capture(
        pattern,
        path,
        opts,
        exec_opts,
        collect_fun,
        retain_fun
      )
      when is_binary(pattern) and is_binary(path) and is_function(collect_fun, 4) and
             is_function(retain_fun, 5) do
    case root_disposition(path, exec_opts) do
      :search ->
        collect_and_retain(pattern, path, opts, exec_opts, collect_fun, retain_fun)

      :ignored ->
        retain_fun.(pattern, path, opts, exec_opts, {[], :complete})

      {:error, _reason} = error ->
        error
    end
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

  @spec collect_and_retain(
          String.t(),
          String.t(),
          map(),
          keyword(),
          collect_fun(),
          retain_fun()
        ) :: capture_result()
  defp collect_and_retain(pattern, path, opts, exec_opts, collect_fun, retain_fun) do
    with {:ok, records, capture} <- collect_fun.(pattern, path, opts, exec_opts) do
      retain_fun.(pattern, path, opts, exec_opts, {records, capture})
    end
  end
end
