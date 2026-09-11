defmodule MingaAgent.Tools.SearchRoot do
  @moduledoc "Shared directory and ignore-policy boundary for agent search tools."

  alias MingaAgent.Tools.PathIgnore

  @type search_fun :: (String.t(), String.t(), map(), keyword() ->
                         {:ok, String.t()} | {:error, String.t()})

  @doc "Validates a search root, applies ignore policy, and invokes the tool-specific search."
  @spec run(String.t(), String.t(), map(), keyword(), search_fun()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(pattern, path, opts, exec_opts, search_fun)
      when is_binary(pattern) and is_binary(path) and is_function(search_fun, 4) do
    filter_root = Keyword.get(exec_opts, :filter_root, path)

    if File.dir?(path) do
      run_allowed_search(pattern, path, opts, exec_opts, filter_root, search_fun)
    else
      {:error, "Directory does not exist: #{path}"}
    end
  end

  @spec run_allowed_search(String.t(), String.t(), map(), keyword(), String.t(), search_fun()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp run_allowed_search(pattern, path, opts, exec_opts, filter_root, search_fun) do
    if PathIgnore.ignored_path?(filter_root) do
      {:ok, "No matches found."}
    else
      search_fun.(pattern, path, opts, exec_opts)
    end
  end
end
