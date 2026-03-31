defmodule MingaAgent.Tools.LspDocumentSymbols do
  @moduledoc """
  Agent tool that lists all symbols defined in a file using LSP.

  Returns a hierarchical outline: modules, functions, types, constants.
  Replaces the agent's current approach of reading entire files and
  mentally parsing them to understand module structure.

  Part of epic #1241. See #1244.
  """

  alias MingaAgent.Tools.LspBridge

  @doc """
  Returns the symbol outline for the given file path.

  Shows hierarchical structure with symbol kind, name, and line number.
  """
  @spec execute(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path) when is_binary(path) do
    abs_path = Path.expand(path)

    case LspBridge.client_for_path(abs_path) do
      {:ok, client} ->
        uri = LspBridge.path_to_uri(abs_path)

        params = %{
          "textDocument" => %{"uri" => uri}
        }

        case LspBridge.request_sync(client, "textDocument/documentSymbol", params) do
          {:ok, nil} ->
            {:ok, "No symbols found in #{Path.basename(path)}"}

          {:ok, []} ->
            {:ok, "No symbols found in #{Path.basename(path)}"}

          {:ok, symbols} when is_list(symbols) ->
            items = LspBridge.flatten_document_symbols(symbols)
            {:ok, format_symbols(path, items)}

          {:error, :timeout} ->
            {:error, "Document symbols request timed out"}

          {:error, error} ->
            {:error, "Document symbols request failed: #{inspect(error)}"}
        end

      {:error, reason} ->
        {:ok, reason}
    end
  end

  @spec format_symbols(
          String.t(),
          [{String.t(), non_neg_integer(), non_neg_integer(), String.t()}]
        ) :: String.t()
  defp format_symbols(path, items) do
    rel = relative_path(path)
    header = "#{rel} symbols (#{length(items)}):"

    details =
      Enum.map(items, fn {_path, line, _col, label} ->
        "  #{label}  line #{line + 1}"
      end)

    Enum.join([header | details], "\n")
  end

  @spec relative_path(String.t()) :: String.t()
  defp relative_path(path) do
    cwd = File.cwd!()
    expanded = Path.expand(path)

    if String.starts_with?(expanded, cwd <> "/") do
      Path.relative_to(expanded, cwd)
    else
      path
    end
  end
end
