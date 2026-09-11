defmodule MingaAgent.Tools.WorkspaceEditApplier do
  @moduledoc """
  Applies parsed LSP workspace edits for agent tools.

  Open files are changed through their buffer process. Files without an open buffer are changed on disk. Versioned edits are rejected when the current document version cannot be verified. The result retains successful file and edit counts together with every file-level error so callers can report partial application accurately.
  """

  alias Minga.Buffer
  alias Minga.LSP.Client
  alias Minga.LSP.TextEdit
  alias Minga.LSP.WorkspaceEdit

  @type result :: {non_neg_integer(), non_neg_integer(), [String.t()]}

  @doc "Applies parsed workspace edits and reports successful totals and failures."
  @spec apply(
          [WorkspaceEdit.Document.t()],
          pid(),
          Minga.LSP.PositionEncoding.encoding()
        ) :: result()
  def apply(documents, client, encoding) do
    {file_count, edit_count, errors} =
      Enum.reduce(documents, {0, 0, []}, fn document, counts ->
        accumulate_file_edit(document, client, encoding, counts)
      end)

    {file_count, edit_count, Enum.reverse(errors)}
  end

  @spec accumulate_file_edit(
          WorkspaceEdit.Document.t(),
          pid(),
          Minga.LSP.PositionEncoding.encoding(),
          result()
        ) :: result()
  defp accumulate_file_edit(
         %WorkspaceEdit.Document{edits: [], version: nil},
         _client,
         _encoding,
         counts
       ),
       do: counts

  defp accumulate_file_edit(
         %WorkspaceEdit.Document{edits: []} = document,
         client,
         _encoding,
         {file_count, edit_count, errors} = counts
       ) do
    case validate_empty_file_edit(document, client) do
      :ok ->
        counts

      {:error, reason} ->
        {file_count, edit_count, ["  #{Path.basename(document.path)}: #{reason}" | errors]}
    end
  end

  defp accumulate_file_edit(document, client, encoding, {file_count, edit_count, errors}) do
    case apply_edits_to_file(document, client, encoding) do
      :ok ->
        {file_count + 1, edit_count + Enum.count(document.edits), errors}

      {:error, reason} ->
        {file_count, edit_count, ["  #{Path.basename(document.path)}: #{reason}" | errors]}
    end
  end

  @spec apply_edits_to_file(
          WorkspaceEdit.Document.t(),
          pid(),
          Minga.LSP.PositionEncoding.encoding()
        ) :: :ok | {:error, String.t()}
  defp apply_edits_to_file(document, client, encoding) do
    case Buffer.pid_for_path(document.path) do
      {:ok, pid} ->
        {content, revision} = Buffer.content_with_version(pid)

        with :ok <- validate_version(document, client, pid, revision),
             {:ok, new_content} <- TextEdit.apply(content, document.edits, encoding),
             {:ok, _revision} <-
               Buffer.replace_content_if_version(pid, revision, new_content, :agent) do
          :ok
        else
          {:error, :read_only} -> {:error, "buffer is read-only"}
          {:error, reason} -> {:error, inspect(reason)}
        end

      :not_found ->
        apply_edits_via_filesystem(document, encoding)
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, _reason -> apply_edits_via_filesystem(document, encoding)
  end

  @spec validate_empty_file_edit(WorkspaceEdit.Document.t(), pid()) ::
          :ok | {:error, String.t()}
  defp validate_empty_file_edit(document, client) do
    case Buffer.pid_for_path(document.path) do
      {:ok, pid} ->
        {_content, revision} = Buffer.content_with_version(pid)

        case validate_version(document, client, pid, revision) do
          :ok -> :ok
          {:error, reason} -> {:error, inspect(reason)}
        end

      :not_found ->
        {:error, "cannot verify document version for a closed file"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, _reason -> {:error, "cannot verify document version for a closed file"}
  end

  @spec apply_edits_via_filesystem(
          WorkspaceEdit.Document.t(),
          Minga.LSP.PositionEncoding.encoding()
        ) :: :ok | {:error, String.t()}
  defp apply_edits_via_filesystem(%WorkspaceEdit.Document{version: version}, _encoding)
       when is_integer(version),
       do: {:error, "cannot verify document version for a closed file"}

  defp apply_edits_via_filesystem(document, encoding) do
    case File.read(document.path) do
      {:ok, content} ->
        apply_filesystem_text_edit(document, encoding, content)

      {:error, reason} ->
        {:error, "could not read: #{reason}"}
    end
  end

  @spec apply_filesystem_text_edit(
          WorkspaceEdit.Document.t(),
          Minga.LSP.PositionEncoding.encoding(),
          String.t()
        ) :: :ok | {:error, String.t()}
  defp apply_filesystem_text_edit(document, encoding, content) do
    case TextEdit.apply(content, document.edits, encoding) do
      {:ok, new_content} -> write_filesystem_edit(document.path, new_content)
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @spec write_filesystem_edit(String.t(), String.t()) :: :ok | {:error, String.t()}
  defp write_filesystem_edit(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write: #{file_error(reason)}"}
    end
  end

  @spec file_error(File.posix()) :: String.t()
  defp file_error(reason), do: reason |> :file.format_error() |> IO.chardata_to_string()

  @spec validate_version(WorkspaceEdit.Document.t(), pid(), pid(), non_neg_integer()) ::
          :ok | {:error, atom()}
  defp validate_version(%WorkspaceEdit.Document{version: nil}, _client, _pid, _revision), do: :ok

  defp validate_version(document, client, pid, revision) do
    Client.validate_document_version(client, document.uri, document.version, pid, revision)
  end
end
