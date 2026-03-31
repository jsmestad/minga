defmodule MingaAgent.Tools.LspReferences do
  @moduledoc """
  Agent tool that finds all references to a symbol using LSP.

  Replaces grep-based text matching with compiler-verified semantic search.
  Finds references through aliases, imports, re-exports, and indirect uses
  that text search would miss.

  Part of epic #1241. See #1243.
  """

  alias MingaAgent.Tools.LspBridge

  @doc """
  Returns all locations that reference the symbol at the given position.

  Includes the declaration by default. The line and column are 0-indexed.
  """
  @spec execute(String.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(path, line, col, opts \\ [])
      when is_binary(path) and is_integer(line) and is_integer(col) do
    abs_path = Path.expand(path)
    include_declaration = Keyword.get(opts, :include_declaration, true)

    case LspBridge.client_for_path(abs_path) do
      {:ok, client} ->
        params =
          LspBridge.position_params(abs_path, line, col)
          |> Map.put("context", %{"includeDeclaration" => include_declaration})

        case LspBridge.request_sync(client, "textDocument/references", params) do
          {:ok, nil} ->
            {:ok, "No references found at #{Path.basename(path)}:#{line + 1}:#{col}"}

          {:ok, []} ->
            {:ok, "No references found at #{Path.basename(path)}:#{line + 1}:#{col}"}

          {:ok, locations} when is_list(locations) ->
            items = LspBridge.parse_all_locations(locations)
            {:ok, format_references(items)}

          {:error, :timeout} ->
            {:error, "References request timed out"}

          {:error, error} ->
            {:error, "References request failed: #{inspect(error)}"}
        end

      {:error, reason} ->
        {:ok, reason}
    end
  end

  @spec format_references([{String.t(), non_neg_integer(), non_neg_integer(), String.t()}]) ::
          String.t()
  defp format_references(items) do
    count = length(items)
    header = "#{count} reference#{if count == 1, do: "", else: "s"} found:"

    details =
      Enum.map(items, fn {path, line, col, context} ->
        rel = relative_path(path)
        ctx = if context == "", do: "", else: " — #{context}"
        "  #{rel}:#{line + 1}:#{col}#{ctx}"
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
