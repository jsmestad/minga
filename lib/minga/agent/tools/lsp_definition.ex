defmodule Minga.Agent.Tools.LspDefinition do
  @moduledoc """
  Agent tool that resolves where a symbol is defined using LSP.

  Replaces the agent's current approach of grepping for `def function_name`
  with compiler-verified semantic resolution. Handles macros, re-exports,
  dynamic dispatch, and anything else the language server understands.

  Part of epic #1241. See #1243.
  """

  alias Minga.Agent.Tools.LspBridge

  @doc """
  Returns the definition location for the symbol at the given position.

  The line and column are 0-indexed to match LSP conventions.
  """
  @spec execute(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(path, line, col) when is_binary(path) and is_integer(line) and is_integer(col) do
    abs_path = Path.expand(path)

    case LspBridge.client_for_path(abs_path) do
      {:ok, client} -> do_definition(client, abs_path, path, line, col)
      {:error, reason} -> {:ok, reason}
    end
  end

  @spec do_definition(pid(), String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp do_definition(client, abs_path, path, line, col) do
    params = LspBridge.position_params(abs_path, line, col)
    not_found = "No definition found at #{Path.basename(path)}:#{line + 1}:#{col}"

    case LspBridge.request_sync(client, "textDocument/definition", params) do
      {:ok, nil} ->
        {:ok, not_found}

      {:ok, []} ->
        {:ok, not_found}

      {:ok, result} ->
        format_definition_result(result, not_found)

      {:error, :timeout} ->
        {:error, "Definition request timed out"}

      {:error, error} ->
        {:error, "Definition request failed: #{inspect(error)}"}
    end
  end

  @spec format_definition_result(term(), String.t()) :: {:ok, String.t()}
  defp format_definition_result(result, not_found) do
    case LspBridge.parse_location(result) do
      nil ->
        {:ok, not_found}

      {def_path, def_line, def_col} ->
        context = read_context(def_path, def_line)
        {:ok, format_definition(def_path, def_line, def_col, context)}
    end
  end

  @spec format_definition(String.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          String.t()
  defp format_definition(path, line, col, context) do
    rel = relative_path(path)
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
