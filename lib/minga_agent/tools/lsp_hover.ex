defmodule MingaAgent.Tools.LspHover do
  @moduledoc """
  Agent tool that returns type information and documentation for a symbol using LSP.

  Gives the agent access to the same hover information a human developer
  sees: type signatures, `@doc` content, parameter descriptions. Replaces
  the agent's current approach of reading entire files to understand
  function signatures.

  Part of epic #1241. See #1243.
  """

  alias MingaAgent.Tools.LspBridge

  @hover_timeout 10_000

  @doc """
  Returns type information and documentation for the symbol at the given position.

  Uses a shorter timeout (10s) than other LSP tools since hover should be
  near-instant. The line and column are 0-indexed.
  """
  @spec execute(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(path, line, col) when is_binary(path) and is_integer(line) and is_integer(col) do
    abs_path = Path.expand(path)

    case LspBridge.client_for_path(abs_path) do
      {:ok, client} -> do_hover(client, abs_path, path, line, col)
      {:error, reason} -> {:ok, reason}
    end
  end

  @spec do_hover(pid(), String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp do_hover(client, abs_path, path, line, col) do
    params = LspBridge.position_params(abs_path, line, col)
    not_found = "No hover information at #{Path.basename(path)}:#{line + 1}:#{col}"

    case LspBridge.request_sync(client, "textDocument/hover", params, @hover_timeout) do
      {:ok, nil} ->
        {:ok, not_found}

      {:ok, %{"contents" => contents}} ->
        format_hover_contents(contents, path, line, col, not_found)

      {:ok, _} ->
        {:ok, not_found}

      {:error, :timeout} ->
        {:error, "Hover request timed out"}

      {:error, error} ->
        {:error, "Hover request failed: #{inspect(error)}"}
    end
  end

  @spec format_hover_contents(
          term(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) ::
          {:ok, String.t()}
  defp format_hover_contents(contents, path, line, col, not_found) do
    case LspBridge.extract_hover_markdown(contents) do
      "" -> {:ok, not_found}
      text -> {:ok, "Hover info for #{Path.basename(path)}:#{line + 1}:#{col}\n\n#{text}"}
    end
  end
end
