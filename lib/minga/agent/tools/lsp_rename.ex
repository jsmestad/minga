defmodule Minga.Agent.Tools.LspRename do
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

  alias Minga.Agent.Tools.LspBridge
  alias Minga.Buffer
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
        with {:ok, _} <- prepare_rename(client, abs_path, line, col),
             {:ok, workspace_edit} <- do_rename(client, abs_path, line, col, new_name) do
          apply_rename(workspace_edit, new_name)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec prepare_rename(pid(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, String.t()}
  defp prepare_rename(client, abs_path, line, col) do
    params = LspBridge.position_params(abs_path, line, col)

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

  @spec do_rename(pid(), String.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  defp do_rename(client, abs_path, line, col, new_name) do
    params =
      LspBridge.position_params(abs_path, line, col)
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

  @spec apply_rename(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp apply_rename(workspace_edit, new_name) do
    file_edits = WorkspaceEdit.parse(workspace_edit)

    case file_edits do
      [] ->
        {:error, "Rename returned no edits to apply"}

      edits ->
        {file_count, edit_count, errors} = apply_file_edits(edits)

        result =
          "Renamed to `#{new_name}` across #{file_count} file#{if file_count == 1, do: "", else: "s"} (#{edit_count} edits)"

        result =
          case errors do
            [] -> result
            _ -> result <> "\n\nWarnings:\n" <> Enum.join(errors, "\n")
          end

        {:ok, result}
    end
  end

  @spec apply_file_edits([WorkspaceEdit.file_edits()]) ::
          {non_neg_integer(), non_neg_integer(), [String.t()]}
  defp apply_file_edits(file_edits) do
    Enum.reduce(file_edits, {0, 0, []}, fn {path, edits}, {fc, ec, errs} ->
      case apply_edits_to_file(path, edits) do
        :ok ->
          {fc + 1, ec + length(edits), errs}

        {:error, reason} ->
          {fc, ec, ["  #{Path.basename(path)}: #{reason}" | errs]}
      end
    end)
  end

  @spec apply_edits_to_file(String.t(), [WorkspaceEdit.text_edit()]) :: :ok | {:error, String.t()}
  defp apply_edits_to_file(path, edits) do
    case Buffer.Server.pid_for_path(path) do
      {:ok, pid} ->
        Buffer.apply_edits(pid, edits)
        :ok

      :not_found ->
        apply_edits_via_filesystem(path, edits)
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> apply_edits_via_filesystem(path, edits)
  end

  @spec apply_edits_via_filesystem(String.t(), [WorkspaceEdit.text_edit()]) ::
          :ok | {:error, String.t()}
  defp apply_edits_via_filesystem(path, edits) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n", trim: false)

        new_lines =
          Enum.reduce(edits, lines, fn {{sl, sc}, {el, ec}, new_text}, acc ->
            apply_text_edit(acc, sl, sc, el, ec, new_text)
          end)

        File.write(path, Enum.join(new_lines, "\n"))
        :ok

      {:error, reason} ->
        {:error, "could not read: #{reason}"}
    end
  end

  @spec apply_text_edit(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: [String.t()]
  defp apply_text_edit(lines, start_line, start_col, end_line, end_col, new_text) do
    before_edit = Enum.at(lines, start_line, "") |> String.slice(0, start_col)
    after_edit = Enum.at(lines, end_line, "") |> String.slice(end_col..-1//1)

    replacement = before_edit <> new_text <> after_edit
    replacement_lines = String.split(replacement, "\n", trim: false)

    prefix = Enum.take(lines, start_line)
    suffix = Enum.drop(lines, end_line + 1)

    prefix ++ replacement_lines ++ suffix
  end
end
