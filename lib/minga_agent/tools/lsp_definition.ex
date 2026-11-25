defmodule MingaAgent.Tools.LspDefinition do
  @moduledoc """
  Agent tool that resolves where a symbol is defined using LSP.

  Replaces the agent's current approach of grepping for `def function_name`
  with compiler-verified semantic resolution. Handles macros, re-exports,
  dynamic dispatch, and anything else the language server understands.

  Part of epic #1241. See #1243.
  """

  alias Minga.LSP.Client
  alias MingaAgent.Tools.LspBridge

  @doc """
  Returns the definition location for the symbol at the given position.

  The line and column are 0-indexed to match LSP conventions.
  """
  @spec execute(String.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(path, line, col, opts \\ [])
      when is_binary(path) and is_integer(line) and is_integer(col) do
    abs_path = Path.expand(path)

    case LspBridge.document_for_path(abs_path) do
      {:ok, document} -> do_definition(document, path, line, col, Keyword.get(opts, :root))
      {:error, reason} -> {:ok, reason}
    end
  end

  @spec do_definition(
          LspBridge.document(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t() | nil
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp do_definition(%{client: client} = document, path, line, col, root) do
    params = LspBridge.position_params(document, line, col, Client.encoding(client))
    not_found = "No definition found at #{Path.basename(path)}:#{line + 1}:#{col}"

    case LspBridge.request_sync(client, "textDocument/definition", params) do
      {:ok, nil} ->
        {:ok, not_found}

      {:ok, []} ->
        {:ok, not_found}

      {:ok, result} ->
        format_definition_result(result, not_found, root)

      {:error, :timeout} ->
        {:error, "Definition request timed out"}

      {:error, error} ->
        {:error, "Definition request failed: #{inspect(error)}"}
    end
  end

  @spec format_definition_result(term(), String.t(), String.t() | nil) :: {:ok, String.t()}
  defp format_definition_result(result, not_found, root) do
    case LspBridge.parse_location(result) do
      nil ->
        {:ok, not_found}

      {def_path, def_line, def_col} ->
        context = read_context(def_path, def_line)
        {:ok, format_definition(def_path, def_line, def_col, context, root)}
    end
  end

  @spec format_definition(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          String.t() | nil
        ) :: String.t()
  defp format_definition(path, line, col, context, root) do
    rel = LspBridge.display_path(path, root)
    header = "Definition: #{rel}:#{line + 1}:#{col}"
    if context == "", do: header, else: "#{header}\n  #{context}"
  end

  @spec read_context(String.t(), non_neg_integer()) :: String.t()
  defp read_context(path, line) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.at(line, "")
        |> String.trim()

      {:error, _} ->
        ""
    end
  end
end
