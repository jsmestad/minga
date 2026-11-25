defmodule MingaAgent.Tools.LspWorkspaceSymbols do
  @moduledoc """
  Agent tool that searches for symbols across the entire project using LSP.

  Provides a fuzzy-searchable index of every named entity in the project:
  modules, functions, types, constants. Replaces project-wide grep for
  "where is module X defined?" with semantic search.

  Part of epic #1241. See #1244.
  """

  alias MingaAgent.Tools.LspBridge

  @max_results 50

  @doc """
  Searches for symbols matching the given query across the workspace.

  Results are limited to #{@max_results} to avoid overwhelming the agent's context.
  Any running LSP client can answer this request since it's project-scoped.
  """
  @spec execute(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(query, opts \\ []) when is_binary(query) do
    case LspBridge.any_client() do
      {:ok, client} ->
        params = %{"query" => query}

        case LspBridge.request_sync(client, "workspace/symbol", params) do
          {:ok, nil} ->
            {:ok, "No symbols found matching \"#{query}\""}

          {:ok, []} ->
            {:ok, "No symbols found matching \"#{query}\""}

          {:ok, symbols} when is_list(symbols) ->
            items =
              symbols
              |> Enum.take(@max_results)
              |> Enum.map(&LspBridge.workspace_symbol_to_location/1)

            truncated = Enum.count(symbols) > @max_results
            root = Keyword.get(opts, :root)
            {:ok, format_results(query, items, truncated, Enum.count(symbols), root)}

          {:error, :timeout} ->
            {:error, "Workspace symbols request timed out"}

          {:error, error} ->
            {:error, "Workspace symbols request failed: #{inspect(error)}"}
        end

      {:error, reason} ->
        {:ok, reason}
    end
  end

  @spec format_results(
          String.t(),
          [{String.t(), non_neg_integer(), non_neg_integer(), String.t()}],
          boolean(),
          non_neg_integer(),
          String.t() | nil
        ) :: String.t()
  defp format_results(query, items, truncated, total, root) do
    count_str =
      if truncated do
        "#{Enum.count(items)} of #{total} symbols matching \"#{query}\" (showing first #{@max_results}):"
      else
        "#{Enum.count(items)} symbol#{if Enum.count(items) == 1, do: "", else: "s"} matching \"#{query}\":"
      end

    details =
      Enum.map(items, fn {path, line, _col, label} ->
        rel = LspBridge.display_path(path, root)
        "  #{label}  #{rel}:#{line + 1}"
      end)

    Enum.join([count_str | details], "\n")
  end
end
