defmodule MingaAgent.Tools.WorkspaceEditApplier do
  @moduledoc """
  Applies parsed LSP workspace edits for agent tools.

  Language-server URIs are untrusted, because the server is influenced by the project it indexes. Before anything is applied, every document path is resolved through `MingaAgent.Changeset.PublicationTarget.relative_path/3`, which follows every symlink and requires the result to stay inside the project root. If any document fails that check, the whole workspace edit is refused and no file is changed: a rename or code action applied to only part of its files leaves the project inconsistent, which is worse than not applying it.

  Every edit is checked against the content the language server computed it from. For an open file that is the buffer's synchronized content; for a file without an open buffer it is the file on disk.

  When the session's `MingaAgent.ProjectView` stages changes (an overlay view), every edit goes through that view, the same owner that the other agent file tools use. An open file's edit lands in the session's buffer fork and is published or discarded with the agent's other edits; the live buffer does not change until publication.

  When the session does not stage, open files are changed through their buffer process directly, and files without an open buffer go through the session's view, which writes them.

  A file is stale when the view's current copy differs from the server's baseline, such as a staged draft the server has not seen. Before anything is written, every file that goes through the view is checked for staleness. If any file is stale, the whole workspace edit is refused and no file is changed, for the same reason as the containment refusal.

  The up-front check cannot hold the files still. A file can change between the check and its write; the view then rejects that one write through its revision check (`MingaAgent.ProjectView.conditional_mutate/4`), and the files written before it stay changed. Other per-file failures, such as an unverifiable document version, an unreadable file, or a read-only buffer, refuse only that file. In both cases the result retains successful file and edit counts together with every file-level error so callers can report partial application accurately.
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

  @typep contained :: {WorkspaceEdit.Document.t(), {String.t(), String.t()}}
  @typep open_buffer_route :: :staged_view | :live_buffer
  @typep target :: %{
           project_view: ProjectView.t() | nil,
           open_buffer_route: open_buffer_route(),
           relative_path: String.t(),
           real_path: String.t()
         }
  # The content the language server computed the edit positions against.
  @typep baseline :: {:disk, String.t()} | {:live_buffer, binary()}
  @typep view_write :: %{
           view: ProjectView.t(),
           path: String.t(),
           expected: String.t(),
           new_content: String.t(),
           baseline: baseline()
         }
  @typep view_plan :: {:view_write, view_write()} | {:stale, String.t()} | {:error, String.t()}
  # What the up-front pass decided for one file. A live buffer is edited in
  # place, so only view writes can be checked for staleness before writing.
  @typep plan :: :unchanged | :buffer_edit | view_plan()
  @typep planned :: {WorkspaceEdit.Document.t(), target(), plan()}

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
    open_buffer_route = open_buffer_route(project_view)

    planned =
      Enum.map(contained, fn {document, {relative_path, real_path}} ->
        target = %{
          project_view: project_view,
          open_buffer_route: open_buffer_route,
          relative_path: relative_path,
          real_path: real_path
        }

        {document, target, plan_file(document, target, client, encoding)}
      end)

    case stale_refusals(planned) do
      [] -> execute(planned, client, encoding)
      [_ | _] = refusals -> {0, 0, [stale_summary() | refusals]}
    end
  end

  # A staging view owns every agent edit, including edits to open files, so the
  # edit is reviewed and published with the rest. Without staging, the live
  # buffer is the only writer for an open file.
  @spec open_buffer_route(ProjectView.t() | nil) :: open_buffer_route()
  defp open_buffer_route(nil), do: :live_buffer

  defp open_buffer_route(%ProjectView{} = view) do
    case ProjectView.capabilities(view) do
      %{isolation: :overlay} -> :staged_view
      %{isolation: :none} -> :live_buffer
    end
  end

  # ── Containment ────────────────────────────────────────────────────────────

  @spec contain([WorkspaceEdit.Document.t()], String.t()) ::
          {:ok, [contained()]} | {:error, [String.t()]}
  defp contain(documents, project_root) do
    {contained, refusals} =
      Enum.reduce(documents, {[], []}, fn document, {contained, refusals} ->
        case PublicationTarget.relative_path(project_root, document.path, @file_system) do
          {:ok, resolved} ->
            {[{document, resolved} | contained], refusals}

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

  # ── Planning ───────────────────────────────────────────────────────────────

  @spec plan_file(
          WorkspaceEdit.Document.t(),
          target(),
          pid(),
          Minga.LSP.PositionEncoding.encoding()
        ) :: plan()
  defp plan_file(%WorkspaceEdit.Document{edits: [], version: nil}, _target, _client, _encoding),
    do: :unchanged

  defp plan_file(%WorkspaceEdit.Document{edits: []} = document, _target, client, _encoding) do
    case validate_empty_file_edit(document, client) do
      :ok -> :unchanged
      {:error, _reason} = error -> error
    end
  end

  defp plan_file(document, %{open_buffer_route: :live_buffer} = target, _client, encoding) do
    case Buffer.pid_for_path(document.path) do
      {:ok, _pid} -> :buffer_edit
      :not_found -> plan_view_write(document, target, {:disk, target.real_path}, encoding)
    end
  end

  defp plan_file(document, %{open_buffer_route: :staged_view} = target, client, encoding) do
    case live_buffer_baseline(document, client) do
      {:ok, content} ->
        plan_view_write(document, target, {:live_buffer, content}, encoding)

      :closed ->
        plan_view_write(document, target, {:disk, target.real_path}, encoding)

      {:error, _reason} = error ->
        error
    end
  end

  # Reads the content the language server saw for an open file without changing
  # the buffer. A buffer that is missing or exits during the read counts as
  # closed, so the caller uses the disk baseline instead.
  @spec live_buffer_baseline(WorkspaceEdit.Document.t(), pid()) ::
          {:ok, binary()} | {:error, String.t()} | :closed
  defp live_buffer_baseline(document, client) do
    case Buffer.pid_for_path(document.path) do
      {:ok, pid} ->
        {content, revision} = Buffer.content_with_version(pid)

        case validate_version(document, client, pid, revision) do
          :ok -> {:ok, content}
          {:error, reason} -> {:error, inspect(reason)}
        end

      :not_found ->
        :closed
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, _reason -> :closed
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

  # Computes the complete write and checks it against the view's current copy.
  # The live-buffer baseline has already passed the document version check
  # against its buffer; a disk baseline has no version to check.
  @spec plan_view_write(
          WorkspaceEdit.Document.t(),
          target(),
          baseline(),
          Minga.LSP.PositionEncoding.encoding()
        ) :: view_plan()
  defp plan_view_write(
         %WorkspaceEdit.Document{version: version},
         _target,
         {:disk, _path},
         _encoding
       )
       when is_integer(version),
       do: {:error, "cannot verify document version for a closed file"}

  defp plan_view_write(_document, %{project_view: nil}, {:disk, _path}, _encoding),
    do: {:error, "no editable project view for a closed file"}

  defp plan_view_write(
         document,
         %{project_view: %ProjectView{} = view, relative_path: path},
         baseline,
         encoding
       ) do
    with {:ok, server_content} <- read_server_baseline(baseline),
         {:ok, new_content} <- apply_text_edits(server_content, document.edits, encoding),
         {:ok, expected} <- view_revision(view, path, server_content),
         :ok <- check_current(view, path, server_content, baseline) do
      {:view_write,
       %{
         view: view,
         path: path,
         expected: expected,
         new_content: new_content,
         baseline: baseline
       }}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, "project view unavailable: #{inspect(reason)}"}
  end

  # A disk baseline reads the real path that containment checked, never the
  # server's raw path.
  @spec read_server_baseline(baseline()) :: {:ok, binary()} | {:error, String.t()}
  defp read_server_baseline({:live_buffer, content}), do: {:ok, content}

  defp read_server_baseline({:disk, path}) do
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

  # The revision binds the mutation to the server's baseline, so a view whose
  # content differs when the write commits refuses it as stale.
  @spec view_revision(ProjectView.t(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp view_revision(view, path, server_content) do
    case ProjectView.resolve_source(view, path) do
      {:ok, source} ->
        {:ok, FileMutation.revision(server_content, nil, {:project_view, source.source_id})}

      {:error, reason} ->
        {:error, "project view unavailable: #{inspect(reason)}"}
    end
  end

  # The up-front staleness check. A view copy that is missing has been deleted
  # in the view, which the server has not seen either.
  @spec check_current(ProjectView.t(), String.t(), binary(), baseline()) ::
          :ok | {:stale, String.t()} | {:error, String.t()}
  defp check_current(view, path, server_content, baseline) do
    case ProjectView.read_file(view, path) do
      {:ok, ^server_content} -> :ok
      {:ok, _other} -> {:stale, stale_message(baseline)}
      {:error, :enoent} -> {:stale, stale_message(baseline)}
      {:error, reason} -> {:error, "project view unavailable: #{inspect(reason)}"}
    end
  end

  @spec stale_refusals([planned()]) :: [String.t()]
  defp stale_refusals(planned) do
    for {document, _target, {:stale, reason}} <- planned, do: file_line(document, reason)
  end

  @spec stale_summary() :: String.t()
  defp stale_summary,
    do:
      "  workspace edit refused, no files were changed: the language server computed it against content that differs from the agent's view of some files"

  # ── Application ────────────────────────────────────────────────────────────

  @spec execute([planned()], pid(), Minga.LSP.PositionEncoding.encoding()) :: result()
  defp execute(planned, client, encoding) do
    {file_count, edit_count, errors} =
      Enum.reduce(planned, {0, 0, []}, fn {document, target, plan},
                                          {file_count, edit_count, errors} = counts ->
        case run_plan(document, target, plan, client, encoding) do
          :unchanged ->
            counts

          :ok ->
            {file_count + 1, edit_count + Enum.count(document.edits), errors}

          {:error, reason} ->
            {file_count, edit_count, [file_line(document, reason) | errors]}
        end
      end)

    {file_count, edit_count, Enum.reverse(errors)}
  end

  @spec run_plan(
          WorkspaceEdit.Document.t(),
          target(),
          :unchanged | :buffer_edit | {:view_write, view_write()} | {:error, String.t()},
          pid(),
          Minga.LSP.PositionEncoding.encoding()
        ) :: :unchanged | :ok | {:error, String.t()}
  defp run_plan(_document, _target, :unchanged, _client, _encoding), do: :unchanged
  defp run_plan(_document, _target, {:error, _reason} = error, _client, _encoding), do: error

  defp run_plan(_document, _target, {:view_write, write}, _client, _encoding),
    do: write_view(write)

  # A buffer that closed after planning falls back to the project view once,
  # with the disk baseline and no further staleness gate.
  defp run_plan(document, target, :buffer_edit, client, encoding) do
    case apply_edits_to_open_buffer(document, client, encoding) do
      :closed ->
        case plan_view_write(document, target, {:disk, target.real_path}, encoding) do
          {:view_write, write} -> write_view(write)
          {:stale, reason} -> {:error, reason}
          {:error, _reason} = error -> error
        end

      result ->
        result
    end
  end

  # A buffer that is missing or exits during the edit counts as closed, so the
  # caller falls back to the project view exactly once.
  @spec apply_edits_to_open_buffer(
          WorkspaceEdit.Document.t(),
          pid(),
          Minga.LSP.PositionEncoding.encoding()
        ) :: :ok | {:error, String.t()} | :closed
  defp apply_edits_to_open_buffer(document, client, encoding) do
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
        :closed
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, _reason -> :closed
  end

  @spec write_view(view_write()) :: :ok | {:error, String.t()}
  defp write_view(%{view: view, path: path, expected: expected} = write) do
    case ProjectView.conditional_mutate(view, path, expected, {:replace, write.new_content}) do
      {:ok, _receipt} -> :ok
      {:error, :stale_revision} -> {:error, stale_message(write.baseline)}
      {:error, reason} -> {:error, "could not write: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, "project view unavailable: #{inspect(reason)}"}
  end

  @spec file_line(WorkspaceEdit.Document.t(), String.t()) :: String.t()
  defp file_line(document, reason), do: "  #{Path.basename(document.path)}: #{reason}"

  @spec stale_message(baseline()) :: String.t()
  defp stale_message({:disk, _path}),
    do: "the agent's view of this file differs from the disk content the language server used"

  defp stale_message({:live_buffer, _content}),
    do:
      "the agent's staged copy of this open file differs from the buffer content the language server used"

  @spec file_error(File.posix()) :: String.t()
  defp file_error(reason), do: reason |> :file.format_error() |> IO.chardata_to_string()

  @spec validate_version(WorkspaceEdit.Document.t(), pid(), pid(), non_neg_integer()) ::
          :ok | {:error, atom()}
  defp validate_version(%WorkspaceEdit.Document{version: nil}, _client, _pid, _revision), do: :ok

  defp validate_version(document, client, pid, revision) do
    Client.validate_document_version(client, document.uri, document.version, pid, revision)
  end
end
