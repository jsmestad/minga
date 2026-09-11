defmodule MingaAgent.Tools.LspCodeActions do
  @moduledoc """
  Agent tool that discovers and applies LSP code actions.

  Code actions include quickfixes (add missing import, fix typo),
  refactorings (extract function, inline variable), and source actions
  (organize imports, fix all). The agent can list available actions and
  optionally apply one by title or index.

  Listing is not destructive; applying is destructive (requires approval).

  Part of epic #1241. See #1246.
  """

  alias MingaAgent.Tools.LspBridge
  alias Minga.Buffer
  alias Minga.Diagnostics
  alias Minga.LSP.Client
  alias Minga.LSP.TextEdit
  alias Minga.LSP.WorkspaceEdit

  @doc """
  Lists or applies code actions at the given file position.

  When `apply` is nil, lists available actions. When `apply` is a string
  (action title) or integer (1-indexed position), applies that action.

  Line is 0-indexed.
  """
  @spec execute(String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(path, line, opts \\ []) when is_binary(path) and is_integer(line) do
    abs_path = Path.expand(path)
    col = Keyword.get(opts, :col, 0)
    apply_action = Keyword.get(opts, :apply, nil)

    case LspBridge.client_for_path(abs_path) do
      {:ok, client} -> do_code_actions(client, abs_path, path, line, col, apply_action)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec do_code_actions(
          pid(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          term()
        ) ::
          {:ok, String.t()} | {:error, String.t()}
  defp do_code_actions(client, abs_path, path, line, col, apply_action) do
    case fetch_actions(client, abs_path, line, col, Client.encoding(client)) do
      {:ok, []} ->
        {:ok, "No code actions available at #{Path.basename(path)}:#{line + 1}"}

      {:ok, actions} ->
        if apply_action do
          apply_selected_action(client, actions, apply_action, path)
        else
          {:ok, format_actions(path, line, actions)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private: fetch ─────────────────────────────────────────────────────────

  @spec fetch_actions(
          pid(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Minga.LSP.PositionEncoding.encoding()
        ) ::
          {:ok, [map()]} | {:error, String.t()}
  defp fetch_actions(client, abs_path, line, col, encoding) do
    uri = LspBridge.path_to_uri(abs_path)
    position = LspBridge.position_params(abs_path, line, col, encoding)["position"]

    range = %{
      "start" => position,
      "end" => position
    }

    diagnostics = diagnostics_at_line(uri, line)

    params = %{
      "textDocument" => %{"uri" => uri},
      "range" => range,
      "context" => %{
        "diagnostics" => diagnostics
      }
    }

    case LspBridge.request_sync(client, "textDocument/codeAction", params) do
      {:ok, nil} -> {:ok, []}
      {:ok, actions} when is_list(actions) -> {:ok, actions}
      {:error, :timeout} -> {:error, "Code actions request timed out"}
      {:error, error} -> {:error, "Code actions request failed: #{inspect(error)}"}
    end
  end

  @spec diagnostics_at_line(String.t(), non_neg_integer()) :: [map()]
  defp diagnostics_at_line(uri, line) do
    uri
    |> Diagnostics.on_line(line)
    |> Enum.map(fn diag ->
      %{
        "range" => %{
          "start" => %{"line" => diag.range.start_line, "character" => diag.range.start_col},
          "end" => %{"line" => diag.range.end_line, "character" => diag.range.end_col}
        },
        "message" => diag.message,
        "severity" => severity_to_lsp(diag.severity)
      }
    end)
  end

  # ── Private: format ────────────────────────────────────────────────────────

  @spec format_actions(String.t(), non_neg_integer(), [map()]) :: String.t()
  defp format_actions(path, line, actions) do
    header =
      "#{Enum.count(actions)} code action#{if Enum.count(actions) == 1, do: "", else: "s"} at #{Path.basename(path)}:#{line + 1}:"

    details =
      actions
      |> Enum.with_index(1)
      |> Enum.map(fn {action, idx} ->
        title = Map.get(action, "title", "Untitled")
        kind = Map.get(action, "kind", "")
        kind_str = if kind != "", do: " [#{kind}]", else: ""
        preferred = if Map.get(action, "isPreferred", false), do: " ★", else: ""
        "  #{idx}. #{title}#{kind_str}#{preferred}"
      end)

    hint =
      "\nTo apply an action, call code_actions again with apply set to the action number or title."

    Enum.join([header | details], "\n") <> hint
  end

  # ── Private: apply ─────────────────────────────────────────────────────────

  @spec apply_selected_action(pid(), [map()], String.t() | integer(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp apply_selected_action(client, actions, selection, path) do
    action = find_action(actions, selection)

    case action do
      nil ->
        {:error, "No matching code action found for #{inspect(selection)}"}

      action ->
        do_apply_action(client, action, path)
    end
  end

  @spec find_action([map()], String.t() | integer()) :: map() | nil
  defp find_action(actions, index) when is_integer(index) and index > 0 do
    Enum.at(actions, index - 1)
  end

  defp find_action(actions, title) when is_binary(title) do
    Enum.find(actions, fn a ->
      String.downcase(Map.get(a, "title", "")) == String.downcase(title)
    end)
  end

  defp find_action(_actions, _), do: nil

  @spec do_apply_action(pid(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp do_apply_action(client, action, _path) do
    # Some actions need resolving to get the full edit
    action =
      case Map.get(action, "edit") do
        nil -> resolve_action(client, action)
        _edit -> action
      end

    title = Map.get(action, "title", "code action")

    case Map.get(action, "edit") do
      nil ->
        # Action has a command but no edit; execute the command
        case Map.get(action, "command") do
          nil ->
            {:error, "Code action \"#{title}\" has no edit or command to apply"}

          command ->
            apply_command_action(client, command, title)
        end

      workspace_edit ->
        case WorkspaceEdit.parse(workspace_edit) do
          {:ok, documents} ->
            encoding = Client.encoding(client)
            {file_count, edit_count, errors} = apply_file_edits(documents, client, encoding)
            finish_workspace_edit(client, action, title, file_count, edit_count, errors)

          {:error, reason} ->
            {:error, "Code action returned an invalid workspace edit: #{inspect(reason)}"}
        end
    end
  end

  @spec apply_command_action(pid(), map(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp apply_command_action(client, command, title) do
    case execute_command(client, command) do
      :ok -> {:ok, "Executed command: #{title}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec finish_workspace_edit(pid(), map(), String.t(), non_neg_integer(), non_neg_integer(), [
          String.t()
        ]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp finish_workspace_edit(client, action, title, 0, 0, []) do
    finish_workspace_edit_success(client, action, "Code action \"#{title}\": no edits to apply")
  end

  defp finish_workspace_edit(client, action, title, file_count, edit_count, []) do
    success = "Applied \"#{title}\": #{edit_count} edits across #{file_count} files"
    finish_workspace_edit_success(client, action, success)
  end

  defp finish_workspace_edit(_client, _action, title, file_count, edit_count, errors) do
    {:error,
     "Failed to apply \"#{title}\": #{edit_count} edits across #{file_count} files\n" <>
       Enum.join(errors, "\n")}
  end

  @spec finish_workspace_edit_success(pid(), map(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp finish_workspace_edit_success(client, action, success) do
    case Map.get(action, "command") do
      nil ->
        {:ok, success}

      command ->
        case execute_command(client, command) do
          :ok -> {:ok, success}
          {:error, reason} -> {:error, "#{success}, but #{reason}"}
        end
    end
  end

  @spec resolve_action(pid(), map()) :: map()
  defp resolve_action(client, action) do
    case LspBridge.request_sync(client, "codeAction/resolve", action) do
      {:ok, resolved} when is_map(resolved) -> resolved
      _ -> action
    end
  end

  @spec execute_command(pid(), map()) :: :ok | {:error, String.t()}
  defp execute_command(client, %{"command" => cmd, "arguments" => args}) do
    request_execute_command(client, cmd, args)
  end

  defp execute_command(client, %{"command" => cmd}) do
    request_execute_command(client, cmd, [])
  end

  defp execute_command(_client, _), do: {:error, "Code action command is invalid"}

  @spec request_execute_command(pid(), String.t(), list()) :: :ok | {:error, String.t()}
  defp request_execute_command(client, cmd, args) do
    params = %{"command" => cmd, "arguments" => args}

    case LspBridge.request_sync(client, "workspace/executeCommand", params, 10_000) do
      {:ok, _result} -> :ok
      {:error, :timeout} -> {:error, "command \"#{cmd}\" timed out"}
      {:error, error} -> {:error, "command \"#{cmd}\" failed: #{inspect(error)}"}
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

  @spec severity_to_lsp(atom()) :: non_neg_integer()
  defp severity_to_lsp(:error), do: 1
  defp severity_to_lsp(:warning), do: 2
  defp severity_to_lsp(:info), do: 3
  defp severity_to_lsp(:hint), do: 4
end
