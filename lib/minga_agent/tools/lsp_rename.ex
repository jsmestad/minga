defmodule MingaAgent.Tools.LspRename do
  @moduledoc """
  Agent tool that performs semantic renames using LSP.

  Replaces dangerous find-and-replace with compiler-verified rename that
  knows every location that needs to change (including aliases, imports,
  re-exports) and nothing else. Catches false positives in comments,
  strings, and similarly-named variables.

  This tool is classified as destructive (requires approval) because it
  modifies multiple files.

  Part of epic #1241. See #1246.
  """

  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tools.LspBridge
  alias MingaAgent.Tools.WorkspaceEditApplier
  alias Minga.LSP.Client
  alias Minga.LSP.WorkspaceEdit

  @doc """
  Renames the symbol at the given position to `new_name`.

  Flow:
  1. `textDocument/prepareRename` validates the position is renameable
  2. `textDocument/rename` returns a WorkspaceEdit
  3. The edit is applied across all affected files through `context`, and refused whole if any file is outside its project root

  Line and column are 0-indexed.
  """
  @spec execute(ToolContext.t(), String.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%ToolContext{} = context, path, line, col, new_name)
      when is_binary(path) and is_integer(line) and is_integer(col) and is_binary(new_name) do
    abs_path = Path.expand(path)

    case LspBridge.document_for_path(abs_path) do
      {:ok, %{client: client} = document} ->
        encoding = Client.encoding(client)

        with {:ok, _} <- prepare_rename(document, abs_path, line, col, encoding),
             {:ok, workspace_edit} <- do_rename(document, line, col, new_name, encoding) do
          apply_rename(workspace_edit, new_name, client, encoding, context)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec prepare_rename(
          LspBridge.document(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Minga.LSP.PositionEncoding.encoding()
        ) ::
          {:ok, map()} | {:error, String.t()}
  defp prepare_rename(%{client: client} = document, abs_path, line, col, encoding) do
    params = LspBridge.position_params(document, line, col, encoding)

    case LspBridge.request_sync(client, "textDocument/prepareRename", params) do
      {:ok, nil} ->
        {:error, "Cannot rename at this position (#{Path.basename(abs_path)}:#{line + 1}:#{col})"}

      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:error, %{"message" => msg}} ->
        {:error, "Cannot rename: #{msg}"}

      {:error, :timeout} ->
        {:error, "Prepare rename request timed out"}

      {:error, error} ->
        {:error, "Prepare rename failed: #{inspect(error)}"}
    end
  end

  @spec do_rename(
          LspBridge.document(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          Minga.LSP.PositionEncoding.encoding()
        ) ::
          {:ok, map()} | {:error, String.t()}
  defp do_rename(%{client: client} = document, line, col, new_name, encoding) do
    params =
      document
      |> LspBridge.position_params(line, col, encoding)
      |> Map.put("newName", new_name)

    case LspBridge.request_sync(client, "textDocument/rename", params) do
      {:ok, nil} ->
        {:error, "Rename returned no edits"}

      {:ok, edit} when is_map(edit) ->
        {:ok, edit}

      {:error, %{"message" => msg}} ->
        {:error, "Rename failed: #{msg}"}

      {:error, :timeout} ->
        {:error, "Rename request timed out"}

      {:error, error} ->
        {:error, "Rename failed: #{inspect(error)}"}
    end
  end

  @spec apply_rename(
          map(),
          String.t(),
          pid(),
          Minga.LSP.PositionEncoding.encoding(),
          ToolContext.t()
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp apply_rename(workspace_edit, new_name, client, encoding, context) do
    case WorkspaceEdit.parse(workspace_edit) do
      {:ok, []} ->
        {:error, "Rename returned no edits to apply"}

      {:ok, documents} ->
        finish_rename(documents, new_name, client, encoding, context)

      {:error, reason} ->
        {:error, "Rename returned an invalid workspace edit: #{inspect(reason)}"}
    end
  end

  @spec finish_rename(
          [WorkspaceEdit.Document.t()],
          String.t(),
          pid(),
          Minga.LSP.PositionEncoding.encoding(),
          ToolContext.t()
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp finish_rename(documents, new_name, client, encoding, context) do
    {file_count, edit_count, errors} =
      WorkspaceEditApplier.apply(documents, client, encoding, context)

    case {edit_count, errors} do
      {0, []} ->
        {:error, "Rename returned no edits to apply"}

      {_count, []} ->
        {:ok,
         "Renamed to `#{new_name}` across #{file_count} file#{if file_count == 1, do: "", else: "s"} (#{edit_count} edits)"}

      {_count, _errors} ->
        {:error,
         "Failed to rename to `#{new_name}`: #{edit_count} edits across #{file_count} files\n" <>
           Enum.join(errors, "\n")}
    end
  end
end
