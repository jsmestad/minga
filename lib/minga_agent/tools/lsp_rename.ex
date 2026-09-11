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

  alias MingaAgent.Tools.LspBridge
  alias Minga.Buffer
  alias Minga.LSP.Client
  alias Minga.LSP.TextEdit
  alias Minga.LSP.WorkspaceEdit

  @doc """
  Renames the symbol at the given position to `new_name`.

  Flow:
  1. `textDocument/prepareRename` validates the position is renameable
  2. `textDocument/rename` returns a WorkspaceEdit
  3. The edit is applied across all affected files

  Line and column are 0-indexed.
  """
  @spec execute(String.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(path, line, col, new_name)
      when is_binary(path) and is_integer(line) and is_integer(col) and is_binary(new_name) do
    abs_path = Path.expand(path)

    case LspBridge.client_for_path(abs_path) do
      {:ok, client} ->
        encoding = Client.encoding(client)

        with {:ok, _} <- prepare_rename(client, abs_path, line, col, encoding),
             {:ok, workspace_edit} <- do_rename(client, abs_path, line, col, new_name, encoding) do
          apply_rename(workspace_edit, new_name, client, encoding)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec prepare_rename(
          pid(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Minga.LSP.PositionEncoding.encoding()
        ) ::
          {:ok, map()} | {:error, String.t()}
  defp prepare_rename(client, abs_path, line, col, encoding) do
    params = LspBridge.position_params(abs_path, line, col, encoding)

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
          pid(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          Minga.LSP.PositionEncoding.encoding()
        ) ::
          {:ok, map()} | {:error, String.t()}
  defp do_rename(client, abs_path, line, col, new_name, encoding) do
    params =
      LspBridge.position_params(abs_path, line, col, encoding)
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

  @spec apply_rename(map(), String.t(), pid(), Minga.LSP.PositionEncoding.encoding()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp apply_rename(workspace_edit, new_name, client, encoding) do
    case WorkspaceEdit.parse(workspace_edit) do
      {:ok, []} ->
        {:error, "Rename returned no edits to apply"}

      {:ok, documents} ->
        finish_rename(documents, new_name, client, encoding)

      {:error, reason} ->
        {:error, "Rename returned an invalid workspace edit: #{inspect(reason)}"}
    end
  end

  @spec finish_rename(
          [WorkspaceEdit.Document.t()],
          String.t(),
          pid(),
          Minga.LSP.PositionEncoding.encoding()
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp finish_rename(documents, new_name, client, encoding) do
    {file_count, edit_count, errors} = apply_file_edits(documents, client, encoding)

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

  @spec apply_file_edits(
          [WorkspaceEdit.Document.t()],
          pid(),
          Minga.LSP.PositionEncoding.encoding()
        ) ::
          {non_neg_integer(), non_neg_integer(), [String.t()]}
  defp apply_file_edits(documents, client, encoding) do
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
          {non_neg_integer(), non_neg_integer(), [String.t()]}
        ) :: {non_neg_integer(), non_neg_integer(), [String.t()]}
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
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> apply_edits_via_filesystem(document, encoding)
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
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, "cannot verify document version for a closed file"}
  end

  @spec apply_edits_via_filesystem(
          WorkspaceEdit.Document.t(),
          Minga.LSP.PositionEncoding.encoding()
        ) ::
          :ok | {:error, String.t()}
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
