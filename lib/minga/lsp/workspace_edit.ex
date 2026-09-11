defmodule Minga.LSP.WorkspaceEdit do
  @moduledoc """
  Validates an LSP WorkspaceEdit without losing its document contracts.

  Parsing is effect-free. Unsupported resource operations and malformed outer data fail the whole parse so callers can reject them before opening or changing any file.
  """

  alias Minga.LSP.SyncServer
  alias Minga.LSP.WorkspaceEdit.Document

  @type error ::
          :invalid_workspace_edit
          | :invalid_document_change
          | :invalid_text_edit
          | :unsupported_resource_operation

  @doc "Parses a WorkspaceEdit into ordered per-document values."
  @spec parse(map()) :: {:ok, [Document.t()]} | {:error, error()}
  def parse(%{"documentChanges" => changes}) when is_list(changes),
    do: parse_document_changes(changes, [])

  def parse(%{"documentChanges" => _}), do: {:error, :invalid_workspace_edit}

  def parse(%{"changes" => changes}) when is_map(changes) do
    changes
    |> Enum.sort_by(fn {uri, _edits} -> uri end)
    |> Enum.reduce_while({:ok, []}, fn {uri, edits}, {:ok, documents} ->
      case build_document(uri, nil, edits) do
        {:ok, document} -> {:cont, {:ok, [document | documents]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_documents()
  end

  def parse(%{"changes" => _}), do: {:error, :invalid_workspace_edit}
  def parse(edit) when is_map(edit) and map_size(edit) == 0, do: {:ok, []}
  def parse(_), do: {:error, :invalid_workspace_edit}

  @spec parse_document_changes([term()], [Document.t()]) ::
          {:ok, [Document.t()]} | {:error, error()}
  defp parse_document_changes([], documents), do: {:ok, Enum.reverse(documents)}

  defp parse_document_changes([change | rest], documents) do
    case parse_document_change(change) do
      {:ok, document} -> parse_document_changes(rest, [document | documents])
      {:error, _reason} = error -> error
    end
  end

  @spec parse_document_change(term()) :: {:ok, Document.t()} | {:error, error()}
  defp parse_document_change(%{"kind" => kind}) when kind in ["create", "rename", "delete"],
    do: {:error, :unsupported_resource_operation}

  defp parse_document_change(%{
         "textDocument" => %{"uri" => uri} = text_document,
         "edits" => edits
       }) do
    case Map.fetch(text_document, "version") do
      {:ok, version} when is_integer(version) and version >= 0 ->
        build_document(uri, version, edits)

      {:ok, nil} ->
        build_document(uri, nil, edits)

      {:ok, _invalid} ->
        {:error, :invalid_document_change}

      :error ->
        build_document(uri, nil, edits)
    end
  end

  defp parse_document_change(_), do: {:error, :invalid_document_change}

  @spec build_document(term(), non_neg_integer() | nil, term()) ::
          {:ok, Document.t()} | {:error, error()}
  defp build_document(uri, version, edits) when is_binary(uri) and is_list(edits) do
    if Enum.all?(edits, &valid_text_edit?/1) do
      {:ok,
       %Document{uri: uri, path: SyncServer.uri_to_path(uri), version: version, edits: edits}}
    else
      {:error, :invalid_text_edit}
    end
  end

  defp build_document(_uri, _version, _edits), do: {:error, :invalid_document_change}

  @spec valid_text_edit?(term()) :: boolean()
  defp valid_text_edit?(%{
         "range" => %{
           "start" => %{"line" => start_line, "character" => start_character},
           "end" => %{"line" => end_line, "character" => end_character}
         },
         "newText" => new_text
       }) do
    valid_position?(start_line, start_character) and valid_position?(end_line, end_character) and
      is_binary(new_text)
  end

  defp valid_text_edit?(_), do: false

  @spec valid_position?(term(), term()) :: boolean()
  defp valid_position?(line, character),
    do: is_integer(line) and line >= 0 and is_integer(character) and character >= 0

  @spec reverse_documents({:ok, [Document.t()]} | {:error, error()}) ::
          {:ok, [Document.t()]} | {:error, error()}
  defp reverse_documents({:ok, documents}), do: {:ok, Enum.reverse(documents)}
  defp reverse_documents({:error, _reason} = error), do: error
end
