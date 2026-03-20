defmodule Minga.LSP.WorkspaceEdit do
  @moduledoc """
  Parses and normalizes LSP WorkspaceEdit objects.

  A WorkspaceEdit can arrive in two formats from the server:

  1. `"changes"` — a map of `{uri => [TextEdit]}` entries
  2. `"documentChanges"` — an array of `TextDocumentEdit` objects

  Both formats ultimately produce a list of `{file_path, [text_edit]}`
  tuples where text edits are sorted in reverse document order for safe
  sequential application (later edits first so earlier offsets stay valid).

  This module is pure data transformation. It does not open buffers or
  apply edits. The caller (e.g., `LspActions`) handles editor state
  mutation.
  """

  alias Minga.LSP.SyncServer

  @typedoc "A single text edit: `{start_pos, end_pos, replacement_text}`."
  @type text_edit ::
          {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()},
           String.t()}

  @typedoc "Edits grouped by file path, sorted in reverse document order."
  @type file_edits :: {file_path :: String.t(), edits :: [text_edit()]}

  @doc """
  Parses an LSP WorkspaceEdit JSON object into a list of `{path, edits}` tuples.

  Handles both `"documentChanges"` (preferred) and `"changes"` formats.
  Returns an empty list if the edit is nil or empty.

  Each edit tuple is `{{start_line, start_col}, {end_line, end_col}, new_text}`.
  Edits within each file are sorted in reverse document order (last position
  first) so they can be applied sequentially without invalidating earlier offsets.
  """
  @spec parse(map() | nil) :: [file_edits()]
  def parse(nil), do: []
  def parse(edit) when not is_map(edit), do: []

  def parse(%{"documentChanges" => doc_changes}) when is_list(doc_changes) do
    doc_changes
    |> Enum.flat_map(&parse_document_change/1)
    |> group_and_sort()
  end

  def parse(%{"changes" => changes}) when is_map(changes) do
    changes
    |> Enum.flat_map(fn {uri, edits} ->
      path = uri_to_path(uri)
      Enum.map(edits, fn edit -> {path, parse_text_edit(edit)} end)
    end)
    |> group_and_sort()
  end

  def parse(_), do: []

  @doc """
  Parses a single LSP TextEdit object into a text_edit tuple.

  A TextEdit has a `"range"` with `"start"` and `"end"` positions,
  and a `"newText"` replacement string.
  """
  @spec parse_text_edit(map()) :: text_edit()
  def parse_text_edit(%{"range" => range, "newText" => new_text}) do
    {start_line, start_col} = extract_position(range["start"])
    {end_line, end_col} = extract_position(range["end"])
    {{start_line, start_col}, {end_line, end_col}, new_text}
  end

  def parse_text_edit(%{"range" => range}) do
    {start_line, start_col} = extract_position(range["start"])
    {end_line, end_col} = extract_position(range["end"])
    {{start_line, start_col}, {end_line, end_col}, ""}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec parse_document_change(map()) :: [{String.t(), text_edit()}]
  defp parse_document_change(%{"textDocument" => %{"uri" => uri}, "edits" => edits})
       when is_list(edits) do
    path = uri_to_path(uri)
    Enum.map(edits, fn edit -> {path, parse_text_edit(edit)} end)
  end

  # CreateFile, RenameFile, DeleteFile — not yet supported
  defp parse_document_change(_), do: []

  @spec group_and_sort([{String.t(), text_edit()}]) :: [file_edits()]
  defp group_and_sort(flat_edits) do
    flat_edits
    |> Enum.group_by(fn {path, _edit} -> path end, fn {_path, edit} -> edit end)
    |> Enum.map(fn {path, edits} -> {path, sort_edits_reverse(edits)} end)
  end

  @spec sort_edits_reverse([text_edit()]) :: [text_edit()]
  defp sort_edits_reverse(edits) do
    Enum.sort(edits, fn {{l1, c1}, _, _}, {{l2, c2}, _, _} ->
      {l1, c1} > {l2, c2}
    end)
  end

  @spec extract_position(map() | nil) :: {non_neg_integer(), non_neg_integer()}
  defp extract_position(%{"line" => line, "character" => col}), do: {line, col}
  defp extract_position(_), do: {0, 0}

  @spec uri_to_path(String.t()) :: String.t()
  defp uri_to_path(uri), do: SyncServer.uri_to_path(uri)
end
