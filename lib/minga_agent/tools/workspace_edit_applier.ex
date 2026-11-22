defmodule MingaAgent.Tools.WorkspaceEditApplier do
  @moduledoc """
  Applies parsed LSP workspace edits for agent tools.

  Language-server URIs are untrusted, because the server is influenced by the project it indexes. Before anything is applied, every document path is resolved through `MingaAgent.Changeset.PublicationTarget.relative_path/3`, which follows every symlink and requires the result to stay inside the project root. If any document fails that check, the whole workspace edit is refused and no file is changed: a rename or code action applied to only part of its files leaves the project inconsistent, which is worse than not applying it.

  Open files are changed through their buffer process, because the language server computed the edit positions against that buffer's synchronized content. Files without an open buffer are changed through the session's `MingaAgent.ProjectView`, the same owner that the other agent file tools use, so the edit is staged when the view stages changes. The language server computed those positions against the file on disk, so the edit is committed only while the view's content still matches the disk content.

  Versioned edits are rejected when the current document version cannot be verified. The result retains successful file and edit counts together with every file-level error so callers can report partial application accurately.
  """

  alias Minga.Buffer
  alias Minga.Buffer.FileMutation
  alias Minga.Buffer.Persistence.SystemFileSystem
  alias Minga.LSP.BufferEdit
  alias Minga.LSP.Client
  alias Minga.LSP.TextEdit
  alias Minga.LSP.WorkspaceEdit
  alias MingaAgent.Changeset.PublicationTarget
  alias MingaAgent.ProjectView
  alias MingaAgent.Tool.Context, as: ToolContext

  @type result :: {non_neg_integer(), non_neg_integer(), [String.t()]}

  @typep contained :: {WorkspaceEdit.Document.t(), String.t()}
  @typep target :: %{project_view: ProjectView.t() | nil, relative_path: String.t()}

  @file_system {SystemFileSystem, []}

  @doc """
  Applies parsed workspace edits inside the tool context's project and reports successful totals and failures.

  A workspace edit that names any path outside the project root is refused whole, with one error per refused path.
  """
  @spec apply(
          [WorkspaceEdit.Document.t()],
          pid(),
          Minga.LSP.PositionEncoding.encoding(),
          ToolContext.t()
        ) :: result()
  def apply(documents, client, encoding, %ToolContext{} = context) do
    case contain(documents, context.project_root) do
      {:ok, contained} ->
        apply_contained(contained, client, encoding, context.router_context.project_view)

      {:error, refusals} ->
        {0, 0, [refusal_summary() | refusals]}
    end
  end

  @spec apply_contained(
          [contained()],
          pid(),
          Minga.LSP.PositionEncoding.encoding(),
          ProjectView.t() | nil
        ) :: result()
  defp apply_contained(contained, client, encoding, project_view) do
    {file_count, edit_count, errors} =
      Enum.reduce(contained, {0, 0, []}, fn {document, relative_path}, counts ->
        target = %{project_view: project_view, relative_path: relative_path}
        accumulate_file_edit(document, target, client, encoding, counts)
      end)

    {file_count, edit_count, Enum.reverse(errors)}
  end

  # ── Containment ────────────────────────────────────────────────────────────

  @spec contain([WorkspaceEdit.Document.t()], String.t()) ::
          {:ok, [contained()]} | {:error, [String.t()]}
  defp contain(documents, project_root) do
    {contained, refusals} =
      Enum.reduce(documents, {[], []}, fn document, {contained, refusals} ->
        case PublicationTarget.relative_path(project_root, document.path, @file_system) do
          {:ok, relative_path} ->
            {[{document, relative_path} | contained], refusals}

          {:error, reason} ->
            {contained, [refusal(document.path, reason) | refusals]}
        end
      end)

    case refusals do
      [] -> {:ok, Enum.reverse(contained)}
      [_ | _] -> {:error, Enum.reverse(refusals)}
    end
  end

  @spec refusal_summary() :: String.t()
  defp refusal_summary,
    do: "  workspace edit refused, no files were changed: it targets paths outside the project"

  @spec refusal(String.t(), PublicationTarget.error()) :: String.t()
  defp refusal(path, :outside_project_root), do: "  #{path}: outside the project root"
  defp refusal(path, :invalid_path), do: "  #{path}: not a file path inside the project"
  defp refusal(path, reason), do: "  #{path}: could not resolve the path: #{inspect(reason)}"

  # ── Application ────────────────────────────────────────────────────────────

  @spec accumulate_file_edit(
          WorkspaceEdit.Document.t(),
          target(),
          pid(),
          Minga.LSP.PositionEncoding.encoding(),
          result()
        ) :: result()
  defp accumulate_file_edit(
         %WorkspaceEdit.Document{edits: [], version: nil},
         _target,
         _client,
         _encoding,
         counts
       ),
       do: counts

  defp accumulate_file_edit(
         %WorkspaceEdit.Document{edits: []} = document,
         _target,
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

  defp accumulate_file_edit(document, target, client, encoding, {file_count, edit_count, errors}) do
    case apply_edits_to_file(document, target, client, encoding) do
      :ok ->
        {file_count + 1, edit_count + Enum.count(document.edits), errors}

      {:error, reason} ->
        {file_count, edit_count, ["  #{Path.basename(document.path)}: #{reason}" | errors]}
    end
  end

  @spec apply_edits_to_file(
          WorkspaceEdit.Document.t(),
          target(),
          pid(),
          Minga.LSP.PositionEncoding.encoding()
        ) :: :ok | {:error, String.t()}
  defp apply_edits_to_file(document, target, client, encoding) do
    case Buffer.pid_for_path(document.path) do
      {:ok, pid} ->
        {_content, revision} = snapshot = Buffer.content_with_version(pid)

        with :ok <- validate_version(document, client, pid, revision),
             {:ok, _revision} <- BufferEdit.apply(pid, snapshot, document.edits, encoding, :agent) do
          :ok
        else
          {:error, :read_only} -> {:error, "buffer is read-only"}
          {:error, reason} -> {:error, inspect(reason)}
        end

      :not_found ->
        apply_edits_via_project_view(document, target, encoding)
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, _reason -> apply_edits_via_project_view(document, target, encoding)
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

  @spec apply_edits_via_project_view(
          WorkspaceEdit.Document.t(),
          target(),
          Minga.LSP.PositionEncoding.encoding()
        ) :: :ok | {:error, String.t()}
  defp apply_edits_via_project_view(%WorkspaceEdit.Document{version: version}, _target, _encoding)
       when is_integer(version),
       do: {:error, "cannot verify document version for a closed file"}

  defp apply_edits_via_project_view(_document, %{project_view: nil}, _encoding),
    do: {:error, "no editable project view for a closed file"}

  defp apply_edits_via_project_view(
         document,
         %{project_view: view, relative_path: path},
         encoding
       ) do
    with {:ok, disk_content} <- read_server_baseline(document.path),
         {:ok, new_content} <- apply_text_edits(disk_content, document.edits, encoding),
         {:ok, expected} <- view_revision(view, path, disk_content) do
      mutate_view(view, path, expected, new_content)
    end
  end

  # The language server computed closed-file positions against the disk content.
  @spec read_server_baseline(String.t()) :: {:ok, binary()} | {:error, String.t()}
  defp read_server_baseline(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "could not read: #{file_error(reason)}"}
    end
  end

  @spec apply_text_edits(binary(), [map()], Minga.LSP.PositionEncoding.encoding()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp apply_text_edits(content, edits, encoding) do
    case TextEdit.apply(content, edits, encoding) do
      {:ok, new_content} -> {:ok, new_content}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # The revision binds the mutation to the disk content, so a view whose content
  # differs, such as a staged draft the server has not seen, refuses it as stale.
  @spec view_revision(ProjectView.t(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp view_revision(view, path, disk_content) do
    case ProjectView.resolve_source(view, path) do
      {:ok, source} ->
        {:ok, FileMutation.revision(disk_content, nil, {:project_view, source.source_id})}

      {:error, reason} ->
        {:error, "project view unavailable: #{inspect(reason)}"}
    end
  end

  @spec mutate_view(ProjectView.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  defp mutate_view(view, path, expected, new_content) do
    case ProjectView.conditional_mutate(view, path, expected, {:replace, new_content}) do
      {:ok, _receipt} ->
        :ok

      {:error, :stale_revision} ->
        {:error,
         "the agent's view of this file differs from the disk content the language server used"}

      {:error, reason} ->
        {:error, "could not write: #{inspect(reason)}"}
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
